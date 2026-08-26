#!/usr/bin/env bash
# setup-bench — create the on-chain fixtures for a worst-case benchmark and write
# a manifest. Retargetable to any network: everything comes from the config/flags
# and the queried protocol parameters.
#
#   setup-bench --config cfg.json --socket <sock> --skey <payment.skey> [--magic N|--mainnet]
#
# Stages:
#   S0 preflight     resolve network + artifacts, query pparams, pick funding UTxO
#   S1 fan-out       many fee + collateral UTxOs (for concurrency), chained
#   S2 io_ref        one ~16 KB reference-script UTxO per io_ref instance
#   S3 datums        big-datum UTxOs of compressed G1 points (MSM point source)
#   S4 registrations register all msm_main creds + all io_ref creds
#   S5 manifest      write $STATE/manifest.json
#
# Deterministic UTxO tracking: every stage spends the running "bank" UTxO and
# emits outputs in a fixed order, so each role is a known txid#ix — never
# re-selected by lovelace amount.

set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# lovelace min-UTxO for an output carrying `nbytes` of script/datum, with buffer.
min_utxo_for_bytes() {
  local nbytes="$1" per; per="$(pp_utxo_per_byte)"
  awk -v b="$nbytes" -v p="$per" 'BEGIN{ printf "%d", (b+200)*p + 3000000 }'
}
ada() { awk -v a="$1" 'BEGIN{ printf "%d", a*1000000 }'; }

# ---- S0: artifacts ------------------------------------------------------------
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
      ART_DIR="$ARTIFACTS"; ART_SOURCE="nix"
      pnb_log "using nix-built artifacts: $ART_DIR"
      return
    fi
    pnb_log "config counts differ from nix-built set; regenerating artifacts"
  fi

  ART_DIR="$PNB_STATE/artifacts"; ART_SOURCE="runtime"
  local blueprint="${ARTIFACTS:+$ARTIFACTS/plutus.json}"
  [ -n "$blueprint" ] && [ -f "$blueprint" ] || pnb_die "no unapplied blueprint to regenerate from (set PLUTUS_BENCH_ARTIFACTS)"
  python3 "$PNB_LIB_DIR/lib/apply-instances.py" \
    --blueprint "$blueprint" --out "$ART_DIR" \
    --namespace "$(cfg '.run.namespace')" \
    --n-io-ref "$want_io" --io-param-bytes "$want_iob" --n-msm-indices "$want_msm"
}

stake_addr_of() {
  "$CARDANO_CLI" "$ERA" stake-address build --stake-script-file "$1" "${NET_ARGS[@]}"
}

# ---- manifest skeleton --------------------------------------------------------
init_manifest() {
  MANIFEST="$PNB_STATE/manifest.json"
  jq -n \
    --arg ns "$(cfg '.run.namespace')" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson net "$(cfg_raw '.network')" \
    --arg art "$ART_DIR" --arg artsrc "$ART_SOURCE" \
    --arg seed "$SEED_ADDR" \
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
      fee_utxos:[], collateral_utxos:[], io_refs:[], datum_utxos:[],
      msm_indices:[], setup_txs:[]}' > "$MANIFEST"
}

# build a tx spending $BANK, tracking the new change UTxO as the next $BANK.
# usage: bank_build <label> <n_explicit_outputs> -- <build args...>
bank_build() {
  local label="$1" nout="$2"; shift 2
  [ "$1" = "--" ] && shift
  mkdir -p "$PNB_STATE/txs"
  local body="$PNB_STATE/txs/${label}.body" signed="$PNB_STATE/txs/${label}.signed"
  "$CARDANO_CLI" "$ERA" transaction build \
    --tx-in "$BANK" "$@" \
    --change-address "$CHANGE_ADDR" "${NET_ARGS[@]}" --out-file "$body"
  pnb_sign "$body" "$signed" >/dev/null
  local txid; txid="$(pnb_txid "$signed")"
  pnb_submit "$signed"
  pnb_wait_utxo "${txid}#${nout}" || pnb_die "tx '$label' not confirmed on-chain"
  BANK="${txid}#${nout}"
  manifest_set ".setup_txs += [{role:\"$label\", txid:\"$txid\"}]"
  printf '%s' "$txid"
}

# ---- S1: fan-out fee + collateral --------------------------------------------
s1_fanout() {
  local corpus col fee_l col_l
  corpus="$(cfg '.concurrency.corpus_size')"
  col="$(cfg '.concurrency.collateral_pool')"
  fee_l="$(ada "$(cfg '.concurrency.fee_ada')")"
  col_l="$(ada "$(cfg '.concurrency.collateral_ada')")"
  pnb_log "S1 fan-out: $corpus fee + $col collateral UTxOs"

  # roles list: fee*corpus then collateral*col, split into size-safe batches
  local -a roles=() amounts=()
  local i
  for ((i=0; i<corpus; i++)); do roles+=("fee"); amounts+=("$fee_l"); done
  for ((i=0; i<col;    i++)); do roles+=("col"); amounts+=("$col_l"); done

  local total="${#roles[@]}" batch=100 start=0 b=0
  while [ "$start" -lt "$total" ]; do
    local -a outs=(); local n=0 j
    for ((j=start; j<total && n<batch; j++, n++)); do
      outs+=(--tx-out "$SEED_ADDR+${amounts[j]}")
    done
    local txid; txid="$(bank_build "fanout_$b" "$n" -- "${outs[@]}")"
    # record each output's role/utxo by its fixed index
    for ((j=0; j<n; j++)); do
      local role="${roles[start+j]}" ref="${txid}#${j}"
      if [ "$role" = "fee" ]; then
        manifest_set ".fee_utxos += [{utxo:\"$ref\"}]"
      else
        manifest_set ".collateral_utxos += [{utxo:\"$ref\"}]"
      fi
    done
    start="$j"; b=$((b+1))
  done
}

# ---- S2: io_ref reference-script UTxOs ----------------------------------------
s2_io_refs() {
  local n; n="$(cfg '.io_setup.n_io_ref')"
  pnb_log "S2: $n io_ref reference-script UTxOs (one tx each)"
  local i
  for ((i=0; i<n; i++)); do
    local pl idx hash size amt txid stake
    idx="$(printf '%03d' "$i")"
    pl="$ART_DIR/io_ref/io_ref_${idx}.plutus"
    hash="$(jq -r --argjson i "$i" '.io_ref[$i].hash' "$ART_DIR/blueprint-manifest.json")"
    size="$(jq -r --argjson i "$i" '.io_ref[$i].size_bytes' "$ART_DIR/blueprint-manifest.json")"
    amt="$(min_utxo_for_bytes "$size")"
    txid="$(bank_build "io_${idx}" 1 -- \
      --tx-out "$SEED_ADDR+$amt" --tx-out-reference-script-file "$pl")"
    stake="$(stake_addr_of "$pl")"
    manifest_set ".io_refs += [{index:$i, hash:\"$hash\", refscript_utxo:\"${txid}#0\", stake_addr:\"$stake\", size_bytes:$size}]"
  done
}

# ---- S3: big-datum UTxOs ------------------------------------------------------
s3_datums() {
  local n pts
  n="$(cfg '.io_setup.n_datum_utxos')"
  pts="$(cfg '.io_setup.points_per_datum')"
  [ "$n" -eq 0 ] && { pnb_log "S3: no datum UTxOs requested"; return; }
  pnb_log "S3: $n datum UTxOs of $pts points"
  python3 "$PNB_LIB_DIR/lib/gen-datums.py" \
    --out-dir "$PNB_STATE/datums" --n-datums "$n" --points-per-datum "$pts" \
    --namespace "$(cfg '.run.namespace')"

  local dbytes amt; dbytes="$(jq -r '.[0].bytes' "$PNB_STATE/datums/datums.manifest.json")"
  amt="$(min_utxo_for_bytes "$dbytes")"

  # batch a few datum outputs per tx (each ~few KB)
  local batch=4 start=0 b=0
  while [ "$start" -lt "$n" ]; do
    local -a outs=(); local cnt=0 j
    for ((j=start; j<n && cnt<batch; j++, cnt++)); do
      outs+=(--tx-out "$SEED_ADDR+$amt" --tx-out-inline-datum-file "$PNB_STATE/datums/datum_$(printf '%03d' "$j").json")
    done
    local txid; txid="$(bank_build "datum_$b" "$cnt" -- "${outs[@]}")"
    for ((j=0; j<cnt; j++)); do
      manifest_set ".datum_utxos += [{index:$((start+j)), utxo:\"${txid}#${j}\", n_points:$pts, bytes:$dbytes}]"
    done
    start="$((start+cnt))"; b=$((b+1))
  done
}

# ---- S4: registrations --------------------------------------------------------
next_collateral() {
  # returns the next unused collateral UTxO from the manifest pool
  local ref
  ref="$(jq -r --argjson i "$COL_IDX" '.collateral_utxos[$i].utxo // empty' "$MANIFEST")"
  [ -n "$ref" ] || pnb_die "ran out of collateral UTxOs (increase collateral_pool)"
  COL_IDX=$((COL_IDX+1))
  printf '%s' "$ref"
}

s4_registrations() {
  local dep unit; dep="$(pp_stake_deposit)"
  unit="$PNB_STATE/unit.json"; echo '{"int":0}' > "$unit"
  COL_IDX=0

  # -- msm_main: inline the small (~656 B) script in each registration cert
  local nmsm; nmsm="$(cfg '.concurrency.n_msm_indices')"
  pnb_log "S4a: register $nmsm msm_main stake creds"
  local batch=15 start=0 b=0
  while [ "$start" -lt "$nmsm" ]; do
    local -a args=(); local cnt=0 j
    for ((j=start; j<nmsm && cnt<batch; j++, cnt++)); do
      local pl cert; pl="$ART_DIR/msm_main/msm_main_$(printf '%03d' "$j").plutus"
      cert="$PNB_STATE/txs/reg_msm_$(printf '%03d' "$j").cert"
      "$CARDANO_CLI" "$ERA" stake-address registration-certificate \
        --stake-script-file "$pl" --key-reg-deposit-amt "$dep" --out-file "$cert"
      args+=(--certificate-file "$cert" --certificate-script-file "$pl" --certificate-redeemer-file "$unit")
    done
    bank_build "reg_msm_$b" 0 -- --tx-in-collateral "$(next_collateral)" "${args[@]}" >/dev/null
    for ((j=start; j<start+cnt; j++)); do
      local pl hash stake; pl="$ART_DIR/msm_main/msm_main_$(printf '%03d' "$j").plutus"
      hash="$(jq -r --argjson i "$j" '.msm_main[$i].hash' "$ART_DIR/blueprint-manifest.json")"
      stake="$(stake_addr_of "$pl")"
      manifest_set ".msm_indices += [{index:$j, hash:\"$hash\", stake_addr:\"$stake\"}]"
    done
    start="$((start+cnt))"; b=$((b+1))
  done

  # -- io_ref: reference the on-chain ref-script UTxOs (too big to inline)
  local nio; nio="$(cfg '.io_setup.n_io_ref')"
  pnb_log "S4b: register $nio io_ref stake creds (via reference scripts)"
  batch=8; start=0; b=0
  while [ "$start" -lt "$nio" ]; do
    local -a args=(); local cnt=0 j
    for ((j=start; j<nio && cnt<batch; j++, cnt++)); do
      local pl cert ref; pl="$ART_DIR/io_ref/io_ref_$(printf '%03d' "$j").plutus"
      cert="$PNB_STATE/txs/reg_io_$(printf '%03d' "$j").cert"
      ref="$(jq -r --argjson i "$j" '.io_refs[$i].refscript_utxo' "$MANIFEST")"
      "$CARDANO_CLI" "$ERA" stake-address registration-certificate \
        --stake-script-file "$pl" --key-reg-deposit-amt "$dep" --out-file "$cert"
      args+=(--certificate-file "$cert" --certificate-tx-in-reference "$ref" \
             --certificate-plutus-script-v3 --certificate-reference-tx-in-redeemer-file "$unit")
    done
    bank_build "reg_io_$b" 0 -- --tx-in-collateral "$(next_collateral)" "${args[@]}" >/dev/null
    start="$((start+cnt))"; b=$((b+1))
  done
}

main() {
  pnb_parse_args "$@"
  pnb_load_config
  pnb_init_state_new
  pnb_init_network
  pnb_query_pparams
  resolve_artifacts
  init_manifest

  BANK="$(pnb_largest_pure_utxo "$SEED_ADDR")"
  [ -n "$BANK" ] || pnb_die "no funded pure-ada UTxO at seed address $SEED_ADDR"
  pnb_log "funding UTxO (bank): $BANK"

  s1_fanout
  s2_io_refs
  s3_datums
  s4_registrations

  pnb_log "setup complete. manifest: $MANIFEST"
  echo "$MANIFEST"
}

main "$@"
