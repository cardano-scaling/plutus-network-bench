#!/usr/bin/env bash
# calibrate — measure the msm_main knob->cost map against the live network and
# fit a linear model, so run-bench can solve a target point into knobs.
#
#   calibrate --state-dir ./state/<ns-timestamp>
#
# Method: for a sweep of (k, m, n_datums), build-raw a probe tx (msm_main
# withdrawal + n_datums datum reference inputs) and price it with
# `transaction calculate-plutus-script-cost online`. All limits come from the
# manifest's pparams; nothing is hardcoded.

set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# measure one (k, m, n_datums) point -> echoes "steps mem status"
measure() {
  local k="$1" m="$2" nd="$3"
  local r="$PNB_STATE/calib/r_${k}_${m}_${nd}.json"
  local raw="$PNB_STATE/calib/raw_${k}_${m}_${nd}.tx"
  printf '{"constructor":0,"fields":[{"int":%d},{"int":%d},{"bytes":"00"}]}' "$k" "$m" > "$r"

  local -a refs=(); local i ref
  for ((i=0; i<nd; i++)); do
    ref="$(jq -r --argjson i "$i" '.datum_utxos[$i].utxo' "$MANIFEST")"
    refs+=(--read-only-tx-in-reference "$ref")
  done

  local errf="$PNB_STATE/calib/err_${k}_${m}_${nd}.log"
  if ! "$CARDANO_CLI" "$ERA" transaction build-raw \
        --tx-in "$FEE" --tx-in-collateral "$COL" \
        "${refs[@]}" \
        --withdrawal "${STAKE}+0" \
        --withdrawal-script-file "$MSM_PLUTUS" \
        --withdrawal-redeemer-file "$r" \
        --withdrawal-execution-units "($MAXS,$MAXM)" \
        --tx-out "$SEED_ADDR+2000000" --fee 2000000 \
        --protocol-params-file "$PNB_PPARAMS" \
        --out-file "$raw" 2>"$errf"; then
    pnb_log "    build-raw failed: $(sed 's/\x1b\[[0-9;]*m//g' "$errf" | grep -iE 'error|exceed|budget|unpriced|cost' | head -1)"
    echo "0 0 err"; return
  fi

  local out
  out="$("$CARDANO_CLI" "$ERA" transaction calculate-plutus-script-cost online \
        --tx-file "$raw" "${NET_ARGS[@]}" 2>"$errf" || true)"
  local steps mem
  steps="$(jq -r '.[0].executionUnits.steps // empty' <<<"$out" 2>/dev/null || true)"
  mem="$(jq -r '.[0].executionUnits.memory // empty' <<<"$out" 2>/dev/null || true)"
  if [ -z "$steps" ] || [ -z "$mem" ]; then
    pnb_log "    cost failed: $(sed 's/\x1b\[[0-9;]*m//g' "$errf" | grep -iE 'error|exceed|budget|unpriced|cost|overspent' | head -1)"
    echo "0 0 err"
  else
    echo "$steps $mem ok"
  fi
}

add_sample() {
  local k="$1" m="$2" nd="$3" steps="$4" mem="$5" status="$6" pts n
  pts="$(cfg '.io_setup.points_per_datum')"
  n=$((nd * pts))
  jq --argjson k "$k" --argjson m "$m" --argjson n "$n" \
     --argjson s "$steps" --argjson me "$mem" --arg st "$status" \
     '. += [{k:$k, m:$m, n_points:$n, ex_steps:$s, ex_mem:$me, status:$st}]' \
     "$SAMPLES" > "$SAMPLES.tmp" && mv "$SAMPLES.tmp" "$SAMPLES"
  pnb_log "  sample k=$k m=$m nd=$nd -> steps=$steps mem=$mem [$status]"
}

main() {
  pnb_parse_args "$@"
  pnb_load_config
  pnb_use_state_existing
  pnb_init_network
  MANIFEST="$PNB_STATE/manifest.json"
  [ -f "$MANIFEST" ] || pnb_die "manifest not found in state dir; run setup-bench first"
  PNB_PPARAMS="$PNB_STATE/pparams.json"
  [ -f "$PNB_PPARAMS" ] || pnb_query_pparams
  mkdir -p "$PNB_STATE/calib"

  local art; art="$(jq -r '.artifacts.store_path' "$MANIFEST")"
  MSM_PLUTUS="$art/msm_main/msm_main_000.plutus"
  STAKE="$(jq -r '.msm_indices[0].stake_addr' "$MANIFEST")"
  FEE="$(jq -r '.fee_utxos[0].utxo' "$MANIFEST")"
  COL="$(jq -r '.collateral_utxos[0].utxo' "$MANIFEST")"
  SEED_ADDR="$(jq -r '.seed_address' "$MANIFEST")"
  # `calculate-plutus-script-cost online` evaluates against the network's real
  # per-tx ExUnits budget (it ignores the tx's declared units), so a probe that
  # would overspend simply errors. We therefore sweep only WITHIN budget and
  # stop each axis at the first over-budget probe, then fit + extrapolate.
  MAXS="$(pp_max_tx_steps)"; MAXM="$(pp_max_tx_mem)"
  local avail; avail="$(jq -r '.datum_utxos|length' "$MANIFEST")"
  [ "$avail" -ge 1 ] || pnb_die "no datum UTxOs in manifest (set io_setup.n_datum_utxos > 0)"

  SAMPLES="$PNB_STATE/calib/samples.json"; echo '[]' > "$SAMPLES"
  pnb_log "calibrating within per-tx budget (steps=$MAXS mem=$MAXM)"

  local nd s m st mm
  # n sweep (k=1, m=0): stop at the first datum count that overspends
  for nd in $(seq 1 "$avail"); do
    read -r s m st <<<"$(measure 1 0 "$nd")"; add_sample 1 0 "$nd" "$s" "$m" "$st"
    [ "$st" = ok ] || { pnb_log "  n sweep hit budget at nd=$nd; stopping"; break; }
  done
  # k sweep (m=0, nd=1): a second CPU-varying point
  read -r s m st <<<"$(measure 2 0 1)"; add_sample 2 0 1 "$s" "$m" "$st"
  # m sweep (k=1, nd=1): increase until it overspends, then stop
  for mm in 300 900 1500 2400; do
    read -r s m st <<<"$(measure 1 "$mm" 1)"; add_sample 1 "$mm" 1 "$s" "$m" "$st"
    [ "$st" = ok ] || { pnb_log "  m sweep hit budget at m=$mm; stopping"; break; }
  done

  python3 "$PNB_LIB_DIR/lib/solve-knobs.py" fit \
    --samples "$SAMPLES" --pparams "$PNB_PPARAMS" \
    --out "$PNB_STATE/calibration.json"
  pnb_log "wrote $PNB_STATE/calibration.json"
  echo "$PNB_STATE/calibration.json"
}

main "$@"
