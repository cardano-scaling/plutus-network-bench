# shellcheck shell=bash
# Shared library for setup-bench / calibrate / run-bench.
#
# Responsibilities:
#   * parse a small, uniform set of CLI flags (config file + overrides)
#   * merge config = built-in defaults * config file * --set overrides
#   * resolve the network (mainnet vs magic), era, socket, seed key, cardano-cli
#   * query protocol-parameters ONCE and expose limits via pp_* helpers
#   * deterministic UTxO helpers (track by fixed output index, never by amount)
#   * atomic JSON state writes
#
# Nothing here hardcodes a network, a path, or a protocol constant.

set -euo pipefail

PNB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PNB_LIB_DIR

# --- built-in config defaults (deep-merged under the user's config) ------------
pnb_defaults_json() {
  cat <<'JSON'
{
  "network": { "kind": "testnet", "era": "conway", "cardano_cli": null },
  "wallet":  { "seed_vkey": null, "change_address": null },
  "targets": {
    "ex_steps":         { "mode": "fraction", "value": 1.0 },
    "ex_mem":           { "mode": "fraction", "value": 1.0 },
    "ref_script_bytes": { "mode": "fraction", "value": 0.95 },
    "tx_size":          { "mode": "fraction", "value": 0.95 }
  },
  "knobs_override": null,
  "io_setup":    { "n_io_ref": 12, "io_param_bytes": 15000, "n_datum_utxos": 8, "points_per_datum": 56 },
  "concurrency": { "n_msm_indices": 64, "corpus_size": 500, "fee_ada": 60, "collateral_ada": 10, "collateral_pool": 32 },
  "submit":      { "mode": "burst", "tps": 20, "duration_s": 120 },
  "run":         { "namespace": "bench", "state_dir": "./state" }
}
JSON
}

# --- argument parsing ----------------------------------------------------------
# Populates PNB_CONFIG_FILE, PNB_SETS[], and per-flag PNB_OVERRIDE_* values.
# Unrecognised args are collected into PNB_REST[] for the calling tool.
pnb_parse_args() {
  PNB_CONFIG_FILE=""
  PNB_SETS=()
  PNB_REST=()
  declare -gA PNB_OVERRIDE=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --config)        PNB_CONFIG_FILE="$2"; shift 2 ;;
      --socket)        PNB_OVERRIDE[network.socket]="$2"; shift 2 ;;
      --skey)          PNB_OVERRIDE[wallet.seed_skey]="$2"; shift 2 ;;
      --magic)         PNB_OVERRIDE[network.kind]="testnet"; PNB_OVERRIDE[network.magic]="$2"; shift 2 ;;
      --mainnet)       PNB_OVERRIDE[network.kind]="mainnet"; shift 1 ;;
      --era)           PNB_OVERRIDE[network.era]="$2"; shift 2 ;;
      --cardano-cli)   PNB_OVERRIDE[network.cardano_cli]="$2"; shift 2 ;;
      --state-dir)     PNB_OVERRIDE[run.state_dir]="$2"; shift 2 ;;
      --namespace)     PNB_OVERRIDE[run.namespace]="$2"; shift 2 ;;
      --set)           PNB_SETS+=("$2"); shift 2 ;;
      --)              shift; while [ $# -gt 0 ]; do PNB_REST+=("$1"); shift; done ;;
      *)               PNB_REST+=("$1"); shift 1 ;;
    esac
  done
}

# jq assignment path from a dotted key, quoting each segment.
_pnb_jq_path() {
  local dotted="$1" out=""
  local IFS=.
  # shellcheck disable=SC2086
  for seg in $dotted; do out+="[\"$seg\"]"; done
  printf '%s' "$out"
}

# Coerce a --set / --flag value to JSON (number/bool/null as-is, else string).
_pnb_json_value() {
  local v="$1"
  if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || [[ "$v" == "true" || "$v" == "false" || "$v" == "null" ]]; then
    printf '%s' "$v"
  else
    printf '%s' "$v" | jq -Rs .
  fi
}

# --- config load + merge -------------------------------------------------------
# Produces the merged, resolved config in $PNB_STATE/config.resolved.json and
# loads frequently used values into globals.
pnb_load_config() {
  local defaults file_json merged
  defaults="$(pnb_defaults_json)"
  if [ -n "${PNB_CONFIG_FILE}" ]; then
    [ -f "$PNB_CONFIG_FILE" ] || pnb_die "config file not found: $PNB_CONFIG_FILE"
    file_json="$(jq -c . "$PNB_CONFIG_FILE")" || pnb_die "config file is not valid JSON: $PNB_CONFIG_FILE"
  else
    file_json='{}'
  fi
  # deep-merge defaults * file (recursive object merge; right wins)
  merged="$(jq -n --argjson a "$defaults" --argjson b "$file_json" '
    def deepmerge(x): reduce (x|to_entries[]) as $e (.;
      if ($e.value|type)=="object" and ((.[$e.key]?|type)=="object")
      then .[$e.key] |= deepmerge($e.value) else .[$e.key] = $e.value end);
    deepmerge($a) | deepmerge($b)')"

  # apply shorthand flag overrides
  local k
  for k in "${!PNB_OVERRIDE[@]}"; do
    merged="$(jq -c ".$(_pnb_jq_path "$k") = $(_pnb_json_value "${PNB_OVERRIDE[$k]}")" <<<"$merged")"
  done
  # apply --set dotted.path=value overrides
  local kv key val
  for kv in "${PNB_SETS[@]:-}"; do
    [ -z "$kv" ] && continue
    key="${kv%%=*}"; val="${kv#*=}"
    merged="$(jq -c ".$(_pnb_jq_path "$key") = $(_pnb_json_value "$val")" <<<"$merged")"
  done

  PNB_CFG="$merged"
}

# read a value from the merged config
cfg() { jq -r "$1" <<<"$PNB_CFG"; }
cfg_raw() { jq -c "$1" <<<"$PNB_CFG"; }

# --- state dir -----------------------------------------------------------------
# For setup-bench: create a fresh timestamped dir. For calibrate/run-bench: reuse
# an existing one named by --state-dir (must contain manifest.json).
pnb_init_state_new() {
  local base ns ts
  base="$(cfg '.run.state_dir')"
  ns="$(cfg '.run.namespace')"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  PNB_STATE="$base/${ns}-${ts}"
  mkdir -p "$PNB_STATE"
  echo "$PNB_CFG" | jq . > "$PNB_STATE/config.resolved.json"
  pnb_log "state dir: $PNB_STATE"
}

pnb_use_state_existing() {
  PNB_STATE="$(cfg '.run.state_dir')"
  [ -d "$PNB_STATE" ] || pnb_die "state dir not found: $PNB_STATE (pass --state-dir)"
}

# --- network / toolchain resolution -------------------------------------------
pnb_init_network() {
  # cardano-cli: explicit config/flag > $CARDANO_CLI > PATH
  local cli; cli="$(cfg '.network.cardano_cli')"
  if [ "$cli" = "null" ] || [ -z "$cli" ]; then cli="${CARDANO_CLI:-cardano-cli}"; fi
  command -v "$cli" >/dev/null 2>&1 || pnb_die "cardano-cli not found: $cli"
  CARDANO_CLI="$cli"

  ERA="$(cfg '.network.era')"

  local kind; kind="$(cfg '.network.kind')"
  if [ "$kind" = "mainnet" ]; then
    NET_ARGS=(--mainnet)
  else
    local magic; magic="$(cfg '.network.magic')"
    [ "$magic" != "null" ] || pnb_die "testnet requires network.magic"
    NET_ARGS=(--testnet-magic "$magic")
  fi

  local sock; sock="$(cfg '.network.socket')"
  [ "$sock" != "null" ] || pnb_die "network.socket is required (config or --socket)"
  export CARDANO_NODE_SOCKET_PATH="$sock"

  SEED_SKEY="$(cfg '.wallet.seed_skey')"
  [ "$SEED_SKEY" != "null" ] || pnb_die "wallet.seed_skey is required (config or --skey)"
  [ -f "$SEED_SKEY" ] || pnb_die "seed signing key not found: $SEED_SKEY"

  # verification key: use given, else derive next to the state dir
  SEED_VKEY="$(cfg '.wallet.seed_vkey')"
  if [ "$SEED_VKEY" = "null" ] || [ -z "$SEED_VKEY" ]; then
    SEED_VKEY="$PNB_STATE/seed.vkey"
    "$CARDANO_CLI" "$ERA" key verification-key \
      --signing-key-file "$SEED_SKEY" --verification-key-file "$SEED_VKEY"
  fi

  SEED_ADDR="$("$CARDANO_CLI" "$ERA" address build \
    --payment-verification-key-file "$SEED_VKEY" "${NET_ARGS[@]}")"

  CHANGE_ADDR="$(cfg '.wallet.change_address')"
  if [ "$CHANGE_ADDR" = "null" ] || [ -z "$CHANGE_ADDR" ]; then CHANGE_ADDR="$SEED_ADDR"; fi

  # shellcheck disable=SC2034  # consumed by the sourcing tool (setup-bench)
  ARTIFACTS="${PLUTUS_BENCH_ARTIFACTS:-}"
  pnb_log "cardano-cli: $($CARDANO_CLI --version 2>/dev/null | head -1)"
  pnb_log "network: ${NET_ARGS[*]}  era: $ERA"
  pnb_log "seed address: $SEED_ADDR"
}

# query protocol parameters once; expose via pp_*
pnb_query_pparams() {
  PNB_PPARAMS="$PNB_STATE/pparams.json"
  "$CARDANO_CLI" "$ERA" query protocol-parameters "${NET_ARGS[@]}" \
    --out-file "$PNB_PPARAMS"
}
pp()               { jq -r "$1" "$PNB_PPARAMS"; }
pp_max_tx_size()   { pp '.maxTxSize'; }
pp_max_tx_steps()  { pp '.maxTxExecutionUnits.steps'; }
pp_max_tx_mem()    { pp '.maxTxExecutionUnits.memory'; }
pp_max_blk_steps() { pp '.maxBlockExecutionUnits.steps'; }
pp_max_blk_mem()   { pp '.maxBlockExecutionUnits.memory'; }
pp_ref_per_tx()    { pp '.maxReferenceScriptsSize // .maxRefScriptSizePerTx // 204800'; }
pp_stake_deposit() { pp '.stakeAddressDeposit'; }
pp_utxo_per_byte() { pp '.utxoCostPerByte // .coinsPerUTxOByte // 4310'; }

# --- deterministic UTxO helpers ------------------------------------------------
# sign a tx body with the seed key -> signed file (echoes the signed path)
pnb_sign() {
  local body="$1" out="$2"
  "$CARDANO_CLI" "$ERA" transaction sign \
    --tx-body-file "$body" --signing-key-file "$SEED_SKEY" \
    "${NET_ARGS[@]}" --out-file "$out"
  printf '%s' "$out"
}

pnb_txid() { "$CARDANO_CLI" "$ERA" transaction txid --tx-file "$1"; }

pnb_submit() {
  "$CARDANO_CLI" "$ERA" transaction submit --tx-file "$1" "${NET_ARGS[@]}"
}

# poll for a utxo (existence check only, never used for selection)
pnb_wait_utxo() {
  local ref="$1" tries="${2:-60}" i
  for ((i=0; i<tries; i++)); do
    if "$CARDANO_CLI" "$ERA" query utxo --tx-in "$ref" "${NET_ARGS[@]}" \
         --output-json 2>/dev/null | jq -e 'length > 0' >/dev/null; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# largest pure-ada (no datum, no reference script) UTxO at an address -> txid#ix
pnb_largest_pure_utxo() {
  local addr="$1"
  "$CARDANO_CLI" "$ERA" query utxo --address "$addr" "${NET_ARGS[@]}" --output-json \
    | jq -r 'to_entries
             | map(select(.value.inlineDatum == null
                          and (.value.referenceScript // null) == null))
             | sort_by(.value.value.lovelace) | reverse | .[0].key // empty'
}

# --- atomic JSON state ---------------------------------------------------------
# manifest_set '<jq expr>' : apply a jq transform to the manifest in place
MANIFEST=""
manifest_set() {
  local tmp="$MANIFEST.tmp"
  jq "$1" "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
}

# --- logging -------------------------------------------------------------------
pnb_log() { printf '[pnb] %s\n' "$*" >&2; }
pnb_die() { printf '[pnb] ERROR: %s\n' "$*" >&2; exit 1; }
