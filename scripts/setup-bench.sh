#!/usr/bin/env bash
# setup-bench — create the on-chain fixtures for a worst-case benchmark and write
# a manifest. Retargetable to any network: everything comes from the config/flags
# and the queried protocol parameters.
#
#   setup-bench --config cfg.json --socket <sock> --skey <payment.skey> [--magic N|--mainnet]
#   setup-bench --resume ./state/<ns-timestamp>            # continue a partial run
#
# Stages (each is idempotent — safe to re-run / resume):
#   S0 bootstrap     consolidate the seed address's pure UTxOs into one bank UTxO
#   S1 fan-out       top up to N fee + M collateral UTxOs (for concurrency)
#   S2 io_ref        one ~16 KB reference-script UTxO per io_ref instance
#   S3 datums        big-datum UTxOs of compressed G1 points (MSM point source)
#   S4 registrations register all msm_main + io_ref stake creds
#
# Resumability: the running "bank" UTxO is persisted to the manifest after every
# tx, each stage tops up from what the manifest already records, and S4 checks
# on-chain registration status — so a failed run can be continued with --resume
# and re-runs never double-create or fail with "already registered".

set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

min_utxo_for_bytes() {
  local nbytes="$1" per; per="$(pp_utxo_per_byte)"
  awk -v b="$nbytes" -v p="$per" 'BEGIN{ printf "%d", (b+200)*p + 3000000 }'
}
ada() { awk -v a="$1" 'BEGIN{ printf "%d", a*1000000 }'; }

resolve_artifacts() {
  local want_io want_iob want_msm have_io have_iob have_msm
  want_io="$(cfg '.io_setup.n_io_ref')"
  want_iob="$(cfg '.io_setup.io_param_bytes')"
  want_msm="$(cfg '.concurrency.n_msm_indices')"
  if [ -n "$ARTIFACTS" ] && [ -f "$ARTIFACTS/blueprint-manifest.json" ]; then
    have_io="$(jq -r '.io_ref|length' "$ARTIFACTS/blueprint-manifest.json")"
    have_iob="$(jq -r '.io_param_bytes' "$ARTIFACTS/blueprint-manifest.json")"
    have_msm="$(jq -r '.msm_main|length' "$ARTIFACTS/blueprint-manifest.json")"
    if [ "$have_io" -ge "$want_io" ] && [ "$have_iob" = "$want_iob" ] && [ "$have_msm" -ge "$want_msm" ]; then
      ART_DIR="$ARTIFACTS"; ART_SOURCE="nix"; pnb_log "using nix-built artifacts: $ART_DIR"; return
    fi
    pnb_log "config counts differ from nix-built set; regenerating artifacts"
  fi
  ART_DIR="$PNB_STATE/artifacts"; ART_SOURCE="runtime"
  local blueprint="${ARTIFACTS:+$ARTIFACTS/plutus.json}"
  [ -n "$blueprint" ] && [ -f "$blueprint" ] || pnb_die "no unapplied blueprint to regenerate from (set PLUTUS_BENCH_ARTIFACTS)"
  python3 "$PNB_LIB_DIR/lib/apply-instances.py" \
    --blueprint "$blueprint" --out "$ART_DIR" --namespace "$(cfg '.run.namespace')" \
    --n-io-ref "$want_io" --io-param-bytes "$want_iob" --n-msm-indices "$want_msm"
}

stake_addr_of() {
  "$CARDANO_CLI" "$ERA" stake-address build --stake-script-file "$1" "${NET_ARGS[@]}"
}

# is a stake address already registered on-chain?
is_registered() {
  local out
  out="$("$CARDANO_CLI" "$ERA" query stake-address-info --address "$1" "${NET_ARGS[@]}" \
        --output-json 2>/dev/null || echo '[]')"
  [ "$(jq 'length' <<<"$out" 2>/dev/null || echo 0)" -gt 0 ]
}

init_manifest() {
  MANIFEST="$PNB_STATE/manifest.json"
  jq -n \
    --arg ns "$(cfg '.run.namespace')" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson net "$(cfg_raw '.network')" \
    --arg art "$ART_DIR" --arg artsrc "$ART_SOURCE" --arg seed "$SEED_ADDR" \
    --argjson lim "$(jq -n \
        --argjson a "$(pp_max_tx_size)" --argjson b "$(pp_max_tx_steps)" \
        --argjson c "$(pp_max_tx_mem)"  --argjson d "$(pp_max_blk_steps)" \
        --argjson e "$(pp_max_blk_mem)" --argjson f "$(pp_ref_per_tx)" \
        --argjson g "$(pp_stake_deposit)" --argjson h "$(pp_utxo_per_byte)" \
        '{max_tx_size:$a,max_tx_ex_steps:$b,max_tx_ex_mem:$c,max_block_ex_steps:$d,max_block_ex_mem:$e,max_ref_script_bytes_per_tx:$f,stake_deposit:$g,utxo_cost_per_byte:$h}')" \
    '{schema_version:1, namespace:$ns, created_at:$ts,
      network:{kind:$net.kind, magic:($net.magic//null), era:$net.era},
      pparams_file:"pparams.json", limits:$lim,
      artifacts:{store_path:$art, source:$artsrc}, seed_address:$seed,
      bank:null, fee_utxos:[], collateral_utxos:[], io_refs:[], datum_utxos:[],
      msm_indices:[], io_registered:[], setup_txs:[]}' > "$MANIFEST"
}

# build a tx spending $BANK; the change UTxO becomes the next $BANK (persisted to
# the manifest for resume). Returns via GLOBALS — never $(...) (a subshell would
# lose the $BANK update):  BANK -> change UTxO (txid#nout),  BANK_TXID -> txid.
bank_build() {
  local label="$1" nout="$2"; shift 2
  [ "$1" = "--" ] && shift
  mkdir -p "$PNB_STATE/txs"
  local body="$PNB_STATE/txs/${label}.body" signed="$PNB_STATE/txs/${label}.signed"
  "$CARDANO_CLI" "$ERA" transaction build \
    --tx-in "$BANK" "$@" \
    --change-address "$CHANGE_ADDR" "${NET_ARGS[@]}" --out-file "$body" >&2
  pnb_sign "$body" "$signed" >/dev/null
  local txid; txid="$(pnb_txid "$signed")"
  pnb_submit "$signed" >&2
  pnb_log "submitted '$label' tx $txid; awaiting ${txid}#${nout}"
  pnb_wait_utxo "${txid}#${nout}" || pnb_die "tx '$label' not confirmed on-chain"
  BANK="${txid}#${nout}"; BANK_TXID="$txid"
  manifest_set ".bank=\"$BANK\" | .setup_txs += [{role:\"$label\", txid:\"$txid\"}]"
}

# ---- S0: consolidate the seed address into one bank UTxO ----------------------
bootstrap_bank() {
  local rb; rb="$(jq -r '.bank // empty' "$MANIFEST")"
  if [ -n "$rb" ]; then
    if pnb_wait_utxo "$rb" 1; then BANK="$rb"; pnb_log "reusing recorded bank: $BANK"; return; fi
    pnb_log "recorded bank $rb no longer on-chain; re-consolidating leftovers"
  fi
  local uj excl
  uj="$("$CARDANO_CLI" "$ERA" query utxo --address "$SEED_ADDR" "${NET_ARGS[@]}" --output-json)"
  # never sweep UTxOs the manifest already committed to a role
  excl="$(jq -c '[.fee_utxos[].utxo,.collateral_utxos[].utxo,.io_refs[].refscript_utxo,.datum_utxos[].utxo]' "$MANIFEST")"
  mapfile -t ALLUTXO < <(jq -r --argjson ex "$excl" 'to_entries
    | map(select(.value.inlineDatum==null and (.value.referenceScript//null)==null))
    | map(.key) | map(select(($ex|index(.))|not)) | .[]' <<<"$uj")
  local n="${#ALLUTXO[@]}"
  [ "$n" -ge 1 ] || pnb_die "no spendable pure-ada UTxO at seed address $SEED_ADDR"
  if [ "$n" -eq 1 ]; then
    BANK="${ALLUTXO[0]}"; manifest_set ".bank=\"$BANK\""
    pnb_log "funding UTxO (bank): $BANK"; return
  fi
  pnb_log "S0: consolidating $n UTxOs into one bank UTxO"
  mkdir -p "$PNB_STATE/txs"
  local batch=80 start=0 round=0 carry="" i
  while [ "$start" -lt "$n" ]; do
    local -a ins=(); [ -n "$carry" ] && ins+=(--tx-in "$carry")
    local c=0
    for ((i=start; i<n && c<batch; i++, c++)); do ins+=(--tx-in "${ALLUTXO[i]}"); done
    local body="$PNB_STATE/txs/consol_${round}.body" signed="$PNB_STATE/txs/consol_${round}.signed"
    "$CARDANO_CLI" "$ERA" transaction build "${ins[@]}" \
      --change-address "$SEED_ADDR" "${NET_ARGS[@]}" --out-file "$body" >&2
    pnb_sign "$body" "$signed" >/dev/null
    local txid; txid="$(pnb_txid "$signed")"
    pnb_submit "$signed" >&2
    pnb_wait_utxo "${txid}#0" || pnb_die "consolidation round $round not confirmed"
    carry="${txid}#0"; start="$i"; round=$((round+1))
    pnb_log "  consolidated $start/$n -> $carry"
  done
  BANK="$carry"; manifest_set ".bank=\"$BANK\""
  pnb_log "funding UTxO (bank): $BANK"
}

# ---- S1: fan-out fee + collateral (top-up) -----------------------------------
s1_fanout() {
  local corpus col fee_l col_l have_fee have_col need_fee need_col
  corpus="$(cfg '.concurrency.corpus_size')"; col="$(cfg '.concurrency.collateral_pool')"
  fee_l="$(ada "$(cfg '.concurrency.fee_ada')")"; col_l="$(ada "$(cfg '.concurrency.collateral_ada')")"
  have_fee="$(jq '.fee_utxos|length' "$MANIFEST")"; have_col="$(jq '.collateral_utxos|length' "$MANIFEST")"
  need_fee=$(( corpus > have_fee ? corpus - have_fee : 0 ))
  need_col=$(( col > have_col ? col - have_col : 0 ))
  if [ "$need_fee" -eq 0 ] && [ "$need_col" -eq 0 ]; then
    pnb_log "S1: fee/collateral already provisioned ($have_fee/$corpus, $have_col/$col)"; return
  fi
  pnb_log "S1 fan-out: +$need_fee fee, +$need_col collateral (have $have_fee/$corpus, $have_col/$col)"
  local -a roles=() amounts=(); local i
  for ((i=0; i<need_fee; i++)); do roles+=(fee); amounts+=("$fee_l"); done
  for ((i=0; i<need_col; i++)); do roles+=(col); amounts+=("$col_l"); done
  local total="${#roles[@]}" batch=100 start=0 b
  b="$(jq '[.setup_txs[]|select(.role|startswith("fanout"))]|length' "$MANIFEST")"
  while [ "$start" -lt "$total" ]; do
    local -a outs=(); local nb=0 j
    for ((j=start; j<total && nb<batch; j++, nb++)); do outs+=(--tx-out "$SEED_ADDR+${amounts[j]}"); done
    bank_build "fanout_$b" "$nb" -- "${outs[@]}"; local txid="$BANK_TXID"
    for ((j=0; j<nb; j++)); do
      if [ "${roles[start+j]}" = fee ]; then manifest_set ".fee_utxos += [{utxo:\"${txid}#${j}\"}]"
      else manifest_set ".collateral_utxos += [{utxo:\"${txid}#${j}\"}]"; fi
    done
    start="$j"; b=$((b+1))
  done
}

# ---- S2: io_ref reference-script UTxOs (top-up) -------------------------------
s2_io_refs() {
  local n have; n="$(cfg '.io_setup.n_io_ref')"; have="$(jq '.io_refs|length' "$MANIFEST")"
  if [ "$have" -ge "$n" ]; then pnb_log "S2: io_refs already provisioned ($have/$n)"; return; fi
  pnb_log "S2: creating io_refs $have..$((n-1))"
  local i
  for ((i=have; i<n; i++)); do
    local pl idx hash size amt stake; idx="$(printf '%03d' "$i")"
    pl="$ART_DIR/io_ref/io_ref_${idx}.plutus"
    hash="$(jq -r --argjson i "$i" '.io_ref[$i].hash' "$ART_DIR/blueprint-manifest.json")"
    size="$(jq -r --argjson i "$i" '.io_ref[$i].size_bytes' "$ART_DIR/blueprint-manifest.json")"
    amt="$(min_utxo_for_bytes "$size")"
    bank_build "io_${idx}" 1 -- --tx-out "$SEED_ADDR+$amt" --tx-out-reference-script-file "$pl"
    stake="$(stake_addr_of "$pl")"
    manifest_set ".io_refs += [{index:$i, hash:\"$hash\", refscript_utxo:\"${BANK_TXID}#0\", stake_addr:\"$stake\", size_bytes:$size}]"
  done
}

# ---- S3: big-datum UTxOs (top-up) --------------------------------------------
s3_datums() {
  local n pts have; n="$(cfg '.io_setup.n_datum_utxos')"; pts="$(cfg '.io_setup.points_per_datum')"
  [ "$n" -eq 0 ] && { pnb_log "S3: no datum UTxOs requested"; return; }
  have="$(jq '.datum_utxos|length' "$MANIFEST")"
  if [ "$have" -ge "$n" ]; then pnb_log "S3: datum UTxOs already provisioned ($have/$n)"; return; fi
  pnb_log "S3: creating datum UTxOs $have..$((n-1))"
  python3 "$PNB_LIB_DIR/lib/gen-datums.py" \
    --out-dir "$PNB_STATE/datums" --n-datums "$n" --points-per-datum "$pts" \
    --namespace "$(cfg '.run.namespace')"
  local dbytes amt; dbytes="$(jq -r '.[0].bytes' "$PNB_STATE/datums/datums.manifest.json")"
  amt="$(min_utxo_for_bytes "$dbytes")"
  local batch=4 start="$have" b
  b="$(jq '[.setup_txs[]|select(.role|startswith("datum"))]|length' "$MANIFEST")"
  while [ "$start" -lt "$n" ]; do
    local -a outs=(); local cnt=0 j
    for ((j=start; j<n && cnt<batch; j++, cnt++)); do
      outs+=(--tx-out "$SEED_ADDR+$amt" --tx-out-inline-datum-file "$PNB_STATE/datums/datum_$(printf '%03d' "$j").json")
    done
    bank_build "datum_$b" "$cnt" -- "${outs[@]}"; local txid="$BANK_TXID"
    for ((j=0; j<cnt; j++)); do
      manifest_set ".datum_utxos += [{index:$((start+j)), utxo:\"${txid}#${j}\", n_points:$pts, bytes:$dbytes}]"
    done
    start="$((start+cnt))"; b=$((b+1))
  done
}

# ---- S4: registrations (idempotent) ------------------------------------------
next_collateral() {
  COL_REF="$(jq -r --argjson i "$COL_IDX" '.collateral_utxos[$i].utxo // empty' "$MANIFEST")"
  [ -n "$COL_REF" ] || pnb_die "ran out of collateral UTxOs (increase collateral_pool)"
  COL_IDX=$((COL_IDX+1))
}

s4_registrations() {
  local dep unit; dep="$(pp_stake_deposit)"
  unit="$PNB_STATE/unit.json"; echo '{"int":0}' > "$unit"
  COL_IDX=0
  local nmsm nio; nmsm="$(cfg '.concurrency.n_msm_indices')"; nio="$(cfg '.io_setup.n_io_ref')"

  # --- S4a: msm_main creds (inline the small script) ---
  pnb_log "S4a: ensure $nmsm msm_main creds registered"
  local -a pend=(); local j
  for ((j=0; j<nmsm; j++)); do
    jq -e --argjson i "$j" '.msm_indices|any(.index==$i)' "$MANIFEST" >/dev/null && continue
    local pl stake hash; pl="$ART_DIR/msm_main/msm_main_$(printf '%03d' "$j").plutus"
    stake="$(stake_addr_of "$pl")"
    hash="$(jq -r --argjson i "$j" '.msm_main[$i].hash' "$ART_DIR/blueprint-manifest.json")"
    if is_registered "$stake"; then
      manifest_set ".msm_indices += [{index:$j, hash:\"$hash\", stake_addr:\"$stake\"}]"
    else
      pend+=("$j")
    fi
  done
  local batch=15 k=0
  while [ "$k" -lt "${#pend[@]}" ]; do
    local -a args=(); local cnt=0
    while [ "$cnt" -lt "$batch" ] && [ "$k" -lt "${#pend[@]}" ]; do
      local jj="${pend[k]}" pl cert; pl="$ART_DIR/msm_main/msm_main_$(printf '%03d' "$jj").plutus"
      cert="$PNB_STATE/txs/reg_msm_$(printf '%03d' "$jj").cert"
      "$CARDANO_CLI" "$ERA" stake-address registration-certificate \
        --stake-script-file "$pl" --key-reg-deposit-amt "$dep" --out-file "$cert"
      args+=(--certificate-file "$cert" --certificate-script-file "$pl" --certificate-redeemer-file "$unit")
      cnt=$((cnt+1)); k=$((k+1))
    done
    next_collateral
    bank_build "reg_msm_$k" 0 -- --tx-in-collateral "$COL_REF" "${args[@]}"
    local m
    for ((m=k-cnt; m<k; m++)); do
      local jj="${pend[m]}" pl hash stake; pl="$ART_DIR/msm_main/msm_main_$(printf '%03d' "$jj").plutus"
      hash="$(jq -r --argjson i "$jj" '.msm_main[$i].hash' "$ART_DIR/blueprint-manifest.json")"
      stake="$(stake_addr_of "$pl")"
      manifest_set ".msm_indices += [{index:$jj, hash:\"$hash\", stake_addr:\"$stake\"}]"
    done
  done

  # --- S4b: io_ref creds (via on-chain reference scripts) ---
  pnb_log "S4b: ensure $nio io_ref creds registered"
  pend=(); k=0
  for ((j=0; j<nio; j++)); do
    jq -e --argjson i "$j" '.io_registered|index($i)' "$MANIFEST" >/dev/null && continue
    local stake; stake="$(jq -r --argjson i "$j" '.io_refs[$i].stake_addr' "$MANIFEST")"
    if [ -n "$stake" ] && [ "$stake" != null ] && is_registered "$stake"; then
      manifest_set ".io_registered += [$j]"
    else
      pend+=("$j")
    fi
  done
  batch=8; k=0
  while [ "$k" -lt "${#pend[@]}" ]; do
    local -a args=(); local cnt=0
    while [ "$cnt" -lt "$batch" ] && [ "$k" -lt "${#pend[@]}" ]; do
      local jj="${pend[k]}" pl cert ref; pl="$ART_DIR/io_ref/io_ref_$(printf '%03d' "$jj").plutus"
      cert="$PNB_STATE/txs/reg_io_$(printf '%03d' "$jj").cert"
      ref="$(jq -r --argjson i "$jj" '.io_refs[$i].refscript_utxo' "$MANIFEST")"
      "$CARDANO_CLI" "$ERA" stake-address registration-certificate \
        --stake-script-file "$pl" --key-reg-deposit-amt "$dep" --out-file "$cert"
      args+=(--certificate-file "$cert" --certificate-tx-in-reference "$ref" \
             --certificate-plutus-script-v3 --certificate-reference-tx-in-redeemer-file "$unit")
      cnt=$((cnt+1)); k=$((k+1))
    done
    next_collateral
    bank_build "reg_io_$k" 0 -- --tx-in-collateral "$COL_REF" "${args[@]}"
    local m
    for ((m=k-cnt; m<k; m++)); do manifest_set ".io_registered += [${pend[m]}]"; done
  done
}

main() {
  pnb_parse_args "$@"
  if [ -n "${PNB_RESUME_DIR:-}" ]; then
    pnb_resume_state
    pnb_init_network
    MANIFEST="$PNB_STATE/manifest.json"
    PNB_PPARAMS="$PNB_STATE/pparams.json"; [ -f "$PNB_PPARAMS" ] || pnb_query_pparams
    ART_DIR="$(jq -r '.artifacts.store_path' "$MANIFEST")"
    ART_SOURCE="$(jq -r '.artifacts.source' "$MANIFEST")"
    [ -d "$ART_DIR" ] || resolve_artifacts
  else
    pnb_load_config
    pnb_init_state_new
    pnb_init_network
    pnb_query_pparams
    resolve_artifacts
    init_manifest
  fi

  bootstrap_bank
  s1_fanout
  s2_io_refs
  s3_datums
  s4_registrations

  pnb_log "setup complete. manifest: $MANIFEST"
  echo "$MANIFEST"
}

main "$@"
