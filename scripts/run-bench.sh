#!/usr/bin/env bash
# run-bench — build and submit a corpus of re-submittable worst-case txs.
#
#   run-bench --state-dir ./state/<ns-timestamp>
#
# Reads the manifest (and calibration.json, unless knobs_override is set),
# solves the config targets into knobs, then builds one tx per corpus slot with a
# distinct msm_main index + nonce (distinct reward accounts => no in-block
# contention) and submits burst or at a target rate.

set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# target value for an axis: fraction of a limit, or absolute
axis_target() {
  local axis="$1" limit="$2" mode val
  mode="$(cfg ".targets.${axis}.mode")"
  val="$(cfg ".targets.${axis}.value")"
  if [ "$mode" = "absolute" ]; then
    awk -v v="$val" 'BEGIN{printf "%d", v}'
  else
    awk -v f="$val" -v l="$limit" 'BEGIN{printf "%d", f*l}'
  fi
}

resolve_knobs() {
  local override; override="$(cfg '.knobs_override')"
  if [ "$override" != "null" ]; then
    K="$(cfg '.knobs_override.k')"; M="$(cfg '.knobs_override.m')"
    NDAT="$(cfg '.knobs_override.n_datums')"; IOREFS="$(cfg '.knobs_override.io_refs')"
    PAD="$(cfg '.knobs_override.pad_bytes')"
    pnb_log "using knobs_override: k=$K m=$M n_datums=$NDAT io_refs=$IOREFS pad=$PAD"
    return
  fi
  [ -f "$PNB_STATE/calibration.json" ] || pnb_die "no calibration.json; run calibrate or set knobs_override"
  local st mt pts solved
  st="$(axis_target ex_steps "$(pp_max_tx_steps)")"
  mt="$(axis_target ex_mem "$(pp_max_tx_mem)")"
  pts="$(cfg '.io_setup.points_per_datum')"
  solved="$(python3 "$PNB_LIB_DIR/lib/solve-knobs.py" solve \
    --calibration "$PNB_STATE/calibration.json" --steps "$st" --mem "$mt" \
    --points-per-datum "$pts")"
  K="$(jq -r '.k' <<<"$solved")"; M="$(jq -r '.m' <<<"$solved")"
  NDAT="$(jq -r '.n_datums' <<<"$solved")"
  pnb_log "solved knobs: k=$K m=$M n_datums=$NDAT (target steps=$st mem=$mt)"

  # io_refs from the ref-script-bytes axis
  local iosize iotarget navail
  iosize="$(jq -r '.io_refs[0].size_bytes // 15668' "$MANIFEST")"
  iotarget="$(axis_target ref_script_bytes "$(pp_ref_per_tx)")"
  navail="$(jq -r '.io_refs|length' "$MANIFEST")"
  IOREFS="$(awk -v t="$iotarget" -v s="$iosize" -v n="$navail" 'BEGIN{c=int(t/s); if(c>n)c=n; print c}')"
  PAD="fit"  # padding is computed once at build time to hit the tx_size target
}

# clamp n_datums / io_refs to what the manifest actually holds
clamp_to_manifest() {
  local da io
  da="$(jq -r '.datum_utxos|length' "$MANIFEST")"
  io="$(jq -r '.io_refs|length' "$MANIFEST")"
  [ "$NDAT" -le "$da" ] || { pnb_log "clamping n_datums $NDAT -> $da"; NDAT="$da"; }
  [ "$IOREFS" -le "$io" ] || { pnb_log "clamping io_refs $IOREFS -> $io"; IOREFS="$io"; }
}

signed_size() { awk -v h="$(jq -r '.cborHex|length' "$1")" 'BEGIN{printf "%d", h/2}'; }

# build one corpus tx; args: <index> [pad_entries]. Echoes the signed path.
build_tx() {
  local i="$1" pad="${2:-0}"
  local nonce; nonce="$(printf '%016x' "$i")"
  local msm_i; msm_i=$(( i % NMSM ))
  local stake; stake="$(jq -r --argjson i "$msm_i" '.msm_indices[$i].stake_addr' "$MANIFEST")"
  local msm_pl idx3; idx3="$(printf '%03d' "$msm_i")"; msm_pl="$ART/msm_main/msm_main_${idx3}.plutus"
  local fee col r body signed
  fee="$(jq -r --argjson i "$i" '.fee_utxos[$i].utxo' "$MANIFEST")"
  col="$(jq -r --argjson j "$(( i % NCOL ))" '.collateral_utxos[$j].utxo' "$MANIFEST")"
  r="$PNB_STATE/corpus/r_$i.json"
  body="$PNB_STATE/corpus/tx_$(printf '%04d' "$i").body"
  signed="$PNB_STATE/corpus/tx_$(printf '%04d' "$i").signed"
  printf '{"constructor":0,"fields":[{"int":%d},{"int":%d},{"bytes":"%s"}]}' "$K" "$M" "$nonce" > "$r"

  local -a a=(--tx-in "$fee" --tx-in-collateral "$col")
  local d
  for ((d=0; d<NDAT; d++)); do
    a+=(--read-only-tx-in-reference "$(jq -r --argjson i "$d" '.datum_utxos[$i].utxo' "$MANIFEST")")
  done
  a+=(--withdrawal "${stake}+0" --withdrawal-script-file "$msm_pl" --withdrawal-redeemer-file "$r")
  local o
  for ((o=0; o<IOREFS; o++)); do
    local ist iref
    ist="$(jq -r --argjson i "$o" '.io_refs[$i].stake_addr' "$MANIFEST")"
    iref="$(jq -r --argjson i "$o" '.io_refs[$i].refscript_utxo' "$MANIFEST")"
    a+=(--withdrawal "${ist}+0" --withdrawal-tx-in-reference "$iref" \
        --withdrawal-plutus-script-v3 --withdrawal-reference-tx-in-redeemer-file "$UNIT")
  done
  if [ "$pad" -gt 0 ]; then
    python3 - "$pad" > "$PNB_STATE/corpus/meta_$i.json" <<'PY'
import json,sys
n=int(sys.argv[1])
print(json.dumps({"674":{"msg":["%064x"%j for j in range(n)]}}))
PY
    a+=(--metadata-json-file "$PNB_STATE/corpus/meta_$i.json")
  fi

  "$CARDANO_CLI" "$ERA" transaction build "${a[@]}" \
    --change-address "$SEED_ADDR" "${NET_ARGS[@]}" --out-file "$body"
  pnb_sign "$body" "$signed" >/dev/null
  printf '%s' "$signed"
}

main() {
  pnb_parse_args "$@"
  pnb_load_config
  pnb_use_state_existing
  pnb_init_network
  MANIFEST="$PNB_STATE/manifest.json"
  [ -f "$MANIFEST" ] || pnb_die "manifest not found; run setup-bench first"
  PNB_PPARAMS="$PNB_STATE/pparams.json"; [ -f "$PNB_PPARAMS" ] || pnb_query_pparams
  ART="$(jq -r '.artifacts.store_path' "$MANIFEST")"
  SEED_ADDR="$(jq -r '.seed_address' "$MANIFEST")"
  NMSM="$(jq -r '.msm_indices|length' "$MANIFEST")"
  NCOL="$(jq -r '.collateral_utxos|length' "$MANIFEST")"
  UNIT="$PNB_STATE/unit.json"; echo '{"int":0}' > "$UNIT"
  mkdir -p "$PNB_STATE/corpus"

  resolve_knobs
  clamp_to_manifest

  local corpus nfee
  corpus="$(cfg '.concurrency.corpus_size')"
  nfee="$(jq -r '.fee_utxos|length' "$MANIFEST")"
  [ "$corpus" -le "$nfee" ] || { pnb_log "clamping corpus_size $corpus -> $nfee (fee UTxOs)"; corpus="$nfee"; }

  # determine padding once from tx[0] to hit the tx_size target
  local pad=0
  if [ "${PAD:-fit}" = "fit" ]; then
    local s0 tgt; s0="$(signed_size "$(build_tx 0 0)")"
    tgt="$(axis_target tx_size "$(pp_max_tx_size)")"
    pad="$(awk -v t="$tgt" -v s="$s0" 'BEGIN{c=int((t-s-40)/66); if(c<0)c=0; print c}')"
    pnb_log "base tx size=$s0, tx_size target=$tgt -> $pad metadata pad entries"
  elif [ "${PAD:-0}" != "0" ]; then
    pad=$(awk -v p="$PAD" 'BEGIN{c=int((p-40)/66); if(c<0)c=0; print c}')
  fi

  pnb_log "building corpus of $corpus txs (k=$K m=$M n_datums=$NDAT io_refs=$IOREFS pad=$pad)"
  local i
  for ((i=0; i<corpus; i++)); do
    build_tx "$i" "$pad" >/dev/null
    [ $(( (i+1) % 25 )) -eq 0 ] && pnb_log "  built $((i+1))/$corpus"
  done
  local last; last="$(signed_size "$PNB_STATE/corpus/tx_0000.signed")"
  pnb_log "corpus built; tx size ~= ${last}B / $(pp_max_tx_size)B"

  # submit
  local mode tps dur tip0 tip1 ok=0 fail=0
  mode="$(cfg '.submit.mode')"; tps="$(cfg '.submit.tps')"; dur="$(cfg '.submit.duration_s')"
  tip0="$("$CARDANO_CLI" "$ERA" query tip "${NET_ARGS[@]}" | jq -r '.block')"
  pnb_log "submitting ($mode) from tip block $tip0"
  local delay; delay="$(awk -v t="$tps" 'BEGIN{ if(t>0) printf "%.4f", 1/t; else print 0 }')"
  local start; start="$SECONDS"
  for ((i=0; i<corpus; i++)); do
    if "$CARDANO_CLI" "$ERA" transaction submit \
         --tx-file "$PNB_STATE/corpus/tx_$(printf '%04d' "$i").signed" "${NET_ARGS[@]}" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      fail=$((fail+1))
    fi
    if [ "$mode" = "rate" ]; then
      sleep "$delay"
      [ $((SECONDS - start)) -ge "$dur" ] && { pnb_log "duration reached"; break; }
    fi
  done
  tip1="$("$CARDANO_CLI" "$ERA" query tip "${NET_ARGS[@]}" | jq -r '.block')"

  jq -n --argjson ok "$ok" --argjson fail "$fail" \
        --argjson t0 "$tip0" --argjson t1 "$tip1" \
        --argjson k "$K" --argjson m "$M" --argjson nd "$NDAT" \
        --argjson io "$IOREFS" --argjson pad "$pad" \
    '{schema_version:1, submitted:($ok+$fail), accepted:$ok, rejected:$fail,
      tip_block_before:$t0, tip_block_after:$t1,
      knobs:{k:$k, m:$m, n_datums:$nd, io_refs:$io, pad_entries:$pad}}' \
    > "$PNB_STATE/run-report.json"
  pnb_log "submitted=$((ok+fail)) accepted=$ok rejected=$fail (blocks $tip0..$tip1)"
  echo "$PNB_STATE/run-report.json"
}

main "$@"
