#!/usr/bin/env bash
# local-devnet — stand up an isolated, block-producing Cardano devnet in the
# DIJKSTRA era at PV12, then enact the 350-entry PlutusV3 cost model via on-chain
# governance so the worst-case Plutus benchmark (native multiScalarMul /
# replicateByte) can run entirely locally.
#
#   local-devnet --out-dir ./devnet [--magic 42] [--skip-governance]
#   local-devnet --stop --out-dir ./devnet
#
# Uses whatever cardano-node/cardano-cli are on PATH (e.g. the ouroboros-leios
# dev-testnet devshell), or --cardano-node / --cardano-cli.
#
# Why governance: the node hard-expects a 251-entry PlutusV3 model in the conway
# genesis, and the extra builtins (multiScalarMul, replicateByte, …) only exist
# at PV11+. So 350 can't be set at genesis — it must be enacted on-chain, exactly
# as the public Musashi net did. On a local devnet we own every committee / DRep
# / SPO key, so we can script the vote. See docs/local-devnet.md.
#
# Phases (default action):
#   1 genesis   create-testnet-data (funded utxo + pool + delegators + DReps +
#               committee); patch shelley for PV12 + fast blocks.
#   2 config    fetch leios node config + dijkstra genesis; force every era's
#               hard fork to epoch 0; wire genesis hashes; isolated topology.
#   3 launch    run the block producer; wait for the socket.
#   4 govern    ParameterChange -> 350-entry PlutusV3 cost model; vote with all
#               DReps + SPOs; wait for enactment (skip with --skip-governance).
#   5 emit      pnb-config.json (era dijkstra) for setup-bench.

set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- config / flags ----------------------------------------------------------
OUT_DIR="./devnet"
MAGIC=42
GENESIS_ERA=conway          # era subcommand used to *generate* genesis
RUN_ERA=dijkstra            # era the chain actually runs in (queries/txs/gov)
NODE_BIN=""; CLI_BIN=""
ENV_URL="https://raw.githubusercontent.com/input-output-hk/cardano-playground/main/docs/environments-pre/leios"
TOTAL_SUPPLY=30000000000000000
PORT=3001
START_OFFSET=20
POOLS=1; STAKE_DELEGATORS=3; DREPS=3; COMMITTEE=1; UTXO_KEYS=1
DO_GOV=1; STOP=0
COSTMODEL_FILE="$SELF_DIR/lib/costmodels-pv12.json"

die() { printf '[devnet] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[devnet] %s\n' "$*" >&2; }

# Kill a running devnet by its pidfile (process group), pkill-by-dir as fallback.
stop_devnet() {
  local dir="$1" pf="$1/devnet.pid" pid
  if [ -f "$pf" ] && pid="$(cat "$pf" 2>/dev/null)" && [ -n "$pid" ]; then
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    log "stopped devnet (pgid/pid $pid)"; rm -f "$pf"
  else
    pkill -TERM -f "cardano-node.*$dir" 2>/dev/null && log "stopped cardano-node matching $dir" || true
  fi
  rm -f "$dir/node.socket"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir)         OUT_DIR="$2"; shift 2 ;;
    --magic)           MAGIC="$2"; shift 2 ;;
    --cardano-node)    NODE_BIN="$2"; shift 2 ;;
    --cardano-cli)     CLI_BIN="$2"; shift 2 ;;
    --env-url)         ENV_URL="$2"; shift 2 ;;
    --total-supply)    TOTAL_SUPPLY="$2"; shift 2 ;;
    --port)            PORT="$2"; shift 2 ;;
    --cost-model-file) COSTMODEL_FILE="$2"; shift 2 ;;
    --skip-governance) DO_GOV=0; shift 1 ;;
    --stop)            STOP=1; shift 1 ;;
    -h|--help)         sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

if [ "$STOP" -eq 1 ]; then
  OUT_DIR="$(cd "$OUT_DIR" 2>/dev/null && pwd || echo "$OUT_DIR")"
  [ -d "$OUT_DIR" ] || die "out-dir not found: $OUT_DIR"
  stop_devnet "$OUT_DIR"; exit 0
fi

CLI="${CLI_BIN:-cardano-cli}"; NODE="${NODE_BIN:-cardano-node}"
command -v "$CLI"  >/dev/null 2>&1 || die "cardano-cli not found (or pass --cardano-cli)"
command -v "$NODE" >/dev/null 2>&1 || die "cardano-node not found (or pass --cardano-node)"
[ -f "$COSTMODEL_FILE" ] || die "cost model file not found: $COSTMODEL_FILE"
log "cardano-cli: $($CLI --version 2>/dev/null | head -1)"

OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
GEN="$OUT_DIR/gen"
SOCKET="$OUT_DIR/node.socket"
stop_devnet "$OUT_DIR"; rm -rf "$GEN" "$OUT_DIR/db" "$SOCKET"

# query helper against the running node
q() { CARDANO_NODE_SOCKET_PATH="$SOCKET" "$CLI" "$RUN_ERA" "$@" --testnet-magic "$MAGIC"; }

# ============================================================================
# Phase 1: genesis
# ============================================================================
phase_genesis() {
  local start; start="$(date -u -d "+${START_OFFSET} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                       || date -u -v+${START_OFFSET}S +%Y-%m-%dT%H:%M:%SZ)"
  log "phase 1/5 genesis: create-testnet-data (pools=$POOLS delegators=$STAKE_DELEGATORS dreps=$DREPS committee=$COMMITTEE)"
  "$CLI" "$GENESIS_ERA" genesis create-testnet-data \
    --testnet-magic "$MAGIC" --pools "$POOLS" --stake-delegators "$STAKE_DELEGATORS" \
    --drep-keys "$DREPS" --committee-keys "$COMMITTEE" --utxo-keys "$UTXO_KEYS" \
    --total-supply "$TOTAL_SUPPLY" --delegated-supply "$((TOTAL_SUPPLY/2))" \
    --start-time "$start" --out-dir "$GEN"

  # Boot directly at PV12 and with fast local blocks. epochLength must stay
  # >= 3*securityParam/activeSlotsCoeff (= 300 here) for chain stability.
  jq '.protocolParams.protocolVersion = {"major":12,"minor":0}
      | .slotLength = 0.1 | .activeSlotsCoeff = 0.1
      | .securityParam = 10 | .epochLength = 500' \
    "$GEN/shelley-genesis.json" > "$GEN/shelley-genesis.json.tmp" \
    && mv "$GEN/shelley-genesis.json.tmp" "$GEN/shelley-genesis.json"
}

# ============================================================================
# Phase 2: node config + genesis wiring + isolated topology
# ============================================================================
phase_config() {
  log "phase 2/5 config: fetch node config + dijkstra genesis, force hard forks, isolate"
  curl -fsSL "$ENV_URL/config.json"          -o "$OUT_DIR/config.json"       || die "cannot fetch config.json from $ENV_URL"
  curl -fsSL "$ENV_URL/dijkstra-genesis.json" -o "$GEN/dijkstra-genesis.json" || log "warn: no dijkstra-genesis.json fetched"

  set_field() { jq --arg k "$2" --argjson v "$3" '.[$k]=$v' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
  byron_hash() { "$CLI" byron genesis print-genesis-hash --genesis-json "$1" | tr -d '[:space:]'; }
  era_hash()   { "$CLI" "$GENESIS_ERA" genesis hash --genesis "$1" | tr -d '[:space:]'; }

  local pair fkey hkey fpath kind h
  for pair in \
    "ByronGenesisFile:ByronGenesisHash:$GEN/byron-genesis.json:byron" \
    "ShelleyGenesisFile:ShelleyGenesisHash:$GEN/shelley-genesis.json:era" \
    "AlonzoGenesisFile:AlonzoGenesisHash:$GEN/alonzo-genesis.json:era" \
    "ConwayGenesisFile:ConwayGenesisHash:$GEN/conway-genesis.json:era" \
    "DijkstraGenesisFile:DijkstraGenesisHash:$GEN/dijkstra-genesis.json:era" ; do
    IFS=: read -r fkey hkey fpath kind <<<"$pair"
    [ -s "$fpath" ] || continue
    set_field "$OUT_DIR/config.json" "$fkey" "$(jq -Rn --arg s "$fpath" '$s')"
    if [ "$kind" = byron ]; then h="$(byron_hash "$fpath")"; else h="$(era_hash "$fpath")"; fi
    set_field "$OUT_DIR/config.json" "$hkey" "$(jq -Rn --arg s "$h" '$s')"
  done
  # boot straight into dijkstra/PV12
  local e
  for e in Shelley Allegra Mary Alonzo Babbage Conway Dijkstra; do
    set_field "$OUT_DIR/config.json" "Test${e}HardForkAtEpoch" 0
  done
  # isolated single-node topology (trustable localRoot, no peers) — never public
  printf '%s\n' '{"localRoots":[{"accessPoints":[],"advertise":false,"trustable":true,"valency":0}],"publicRoots":[{"accessPoints":[],"advertise":false}],"useLedgerAfterSlot":-1}' \
    > "$OUT_DIR/topology.json"
}

# ============================================================================
# Phase 3: launch the block producer
# ============================================================================
phase_launch() {
  log "phase 3/5 launch: block producer on port $PORT"
  local p="$GEN/pools-keys/pool1"
  setsid "$NODE" run +RTS -qg -qb -RTS \
    --config "$OUT_DIR/config.json" --topology "$OUT_DIR/topology.json" \
    --database-path "$OUT_DIR/db" --socket-path "$SOCKET" \
    --host-addr 0.0.0.0 --port "$PORT" \
    --shelley-kes-key "$p/kes.skey" --shelley-vrf-key "$p/vrf.skey" \
    --shelley-operational-certificate "$p/opcert.cert" \
    < /dev/null > "$OUT_DIR/node.log" 2>&1 &
  echo "$!" > "$OUT_DIR/devnet.pid"
  log "node pid $! ; log $OUT_DIR/node.log ; stop: local-devnet --stop --out-dir $OUT_DIR"
  local i
  for ((i=0; i<90; i++)); do [ -S "$SOCKET" ] && break; sleep 2; done
  [ -S "$SOCKET" ] || die "node socket never appeared; see $OUT_DIR/node.log"
  # wait until it produces at least one block (leadership working)
  for ((i=0; i<60; i++)); do
    [ "$(q query tip 2>/dev/null | jq -r '.block // 0')" -gt 0 ] && { log "node forging blocks"; return; }
    sleep 2
  done
  die "node is up but not forging blocks; see $OUT_DIR/node.log"
}

# ============================================================================
# Phase 4: governance — enact the 350-entry PlutusV3 cost model
# ============================================================================
current_v3() { q query protocol-parameters 2>/dev/null | jq -r '.costModels.PlutusV3|length' 2>/dev/null || echo 0; }
current_epoch() { q query tip 2>/dev/null | jq -r '.epoch' 2>/dev/null || echo 0; }

phase_govern() {
  local have; have="$(current_v3)"
  log "phase 4/5 govern: PlutusV3 model currently $have entries; enacting 350"
  [ "$have" -eq 350 ] && { log "already 350; skipping"; return; }

  local pay_skey pay_addr fee dep ret_vk
  pay_skey="$GEN/utxo-keys/utxo1/utxo.skey"
  pay_addr="$("$CLI" address build --payment-verification-key-file "$GEN/utxo-keys/utxo1/utxo.vkey" --testnet-magic "$MAGIC")"
  dep="$(q query protocol-parameters | jq -r '.govActionDeposit')"
  ret_vk="$GEN/stake-delegators/delegator1/staking.vkey"
  mkdir -p "$OUT_DIR/gov"

  # 4a. create the ParameterChange action. `transaction build` re-fetches the
  # proposal's anchor and only supports http/https, so serve a local anchor.
  # Use a high port well clear of the node's own ports (incl. its metrics port
  # at PORT+100), and confirm the anchor is actually being served before use.
  local anchor="$OUT_DIR/gov/anchor.json" ahash aport=38080 t
  echo '{"comment":"local devnet: enact 350-entry PlutusV3 cost model"}' > "$anchor"
  ahash="$("$CLI" hash anchor-data --file-binary "$anchor" | tr -d '[:space:]')"
  python3 -m http.server "$aport" --bind 127.0.0.1 --directory "$OUT_DIR/gov" >/dev/null 2>&1 &
  echo $! > "$OUT_DIR/gov/http.pid"
  for t in 1 2 3 4 5; do curl -fsS "http://127.0.0.1:$aport/anchor.json" -o /dev/null 2>/dev/null && break; sleep 1; done
  curl -fsS "http://127.0.0.1:$aport/anchor.json" -o /dev/null 2>/dev/null || die "anchor http server not serving on :$aport"
  "$CLI" "$GENESIS_ERA" governance action create-protocol-parameters-update --testnet \
    --governance-action-deposit "$dep" \
    --deposit-return-stake-verification-key-file "$ret_vk" \
    --anchor-url "http://127.0.0.1:$aport/anchor.json" --anchor-data-hash "$ahash" \
    --cost-model-file "$COSTMODEL_FILE" --out-file "$OUT_DIR/gov/costmodel.action"

  # 4b. submit the proposal (then stop the anchor server)
  fee="$(q query utxo --address "$pay_addr" --output-json | jq -r 'to_entries|sort_by(.value.value.lovelace)|reverse|.[0].key')"
  q transaction build --tx-in "$fee" --proposal-file "$OUT_DIR/gov/costmodel.action" \
    --change-address "$pay_addr" --out-file "$OUT_DIR/gov/prop.body"
  kill "$(cat "$OUT_DIR/gov/http.pid" 2>/dev/null)" 2>/dev/null || true
  "$CLI" "$RUN_ERA" transaction sign --tx-body-file "$OUT_DIR/gov/prop.body" \
    --signing-key-file "$pay_skey" --testnet-magic "$MAGIC" --out-file "$OUT_DIR/gov/prop.signed"
  local atxid; atxid="$("$CLI" "$RUN_ERA" transaction txid --tx-file "$OUT_DIR/gov/prop.signed" | jq -r '.txhash // .')"
  q transaction submit --tx-file "$OUT_DIR/gov/prop.signed"
  log "  proposal submitted: action $atxid#0"
  for ((i=0; i<60; i++)); do q query utxo --tx-in "$atxid#0" --output-json 2>/dev/null | jq -e 'length>0' >/dev/null && break; sleep 2; done

  # 4c. vote YES with every DRep (committee threshold is 0 -> auto-approved;
  # SPOs are disallowed voters for a cost-model ParameterChange).
  local -a votes=() signers=(--signing-key-file "$pay_skey")
  local dir vk n=0
  for dir in "$GEN"/drep-keys/drep*/; do
    vk="${dir}drep.vkey"; [ -f "$vk" ] || continue
    "$CLI" "$GENESIS_ERA" governance vote create --yes --governance-action-tx-id "$atxid" \
      --governance-action-index 0 --drep-verification-key-file "$vk" --out-file "${dir}yes.vote"
    votes+=(--vote-file "${dir}yes.vote"); signers+=(--signing-key-file "${dir}drep.skey"); n=$((n+1))
  done
  fee="$(q query utxo --address "$pay_addr" --output-json | jq -r 'to_entries|sort_by(.value.value.lovelace)|reverse|.[0].key')"
  q transaction build --tx-in "$fee" "${votes[@]}" --change-address "$pay_addr" --out-file "$OUT_DIR/gov/votes.body"
  "$CLI" "$RUN_ERA" transaction sign --tx-body-file "$OUT_DIR/gov/votes.body" \
    "${signers[@]}" --testnet-magic "$MAGIC" --out-file "$OUT_DIR/gov/votes.signed"
  q transaction submit --tx-file "$OUT_DIR/gov/votes.signed"
  log "  $n DRep votes submitted"

  # 4d. wait for ratification + enactment (~2-3 short epochs). Tolerate transient
  # query hiccups so the poll never aborts the run.
  local v e; log "  waiting for enactment (epoch $(current_epoch), ~2-3 epochs)…"
  for ((i=0; i<60; i++)); do
    v="$(current_v3 || true)"; [ -z "$v" ] && v=0
    if [ "$v" -eq 350 ]; then log "  PlutusV3 cost model enacted: 350 entries"; return; fi
    e="$(current_epoch || true)"; [ $((i % 3)) -eq 0 ] && log "    …epoch ${e:-?}, V3=$v"
    sleep 10
  done
  die "cost model not enacted after timeout; inspect: $CLI $RUN_ERA query gov-state --testnet-magic $MAGIC"
}

# ============================================================================
# Phase 5: emit pnb config
# ============================================================================
phase_emit() {
  local cfg="$OUT_DIR/pnb-config.json" skey="$GEN/utxo-keys/utxo1/utxo.skey"
  jq -n --argjson magic "$MAGIC" --arg era "$RUN_ERA" --arg sock "$SOCKET" --arg skey "$skey" \
    '{schema_version:1, network:{kind:"testnet",magic:$magic,era:$era,socket:$sock},
      wallet:{seed_skey:$skey}, run:{namespace:"devnet",state_dir:"./state"}}' > "$cfg"
  cat >&2 <<EOF
[devnet] ready.
  socket:      $SOCKET
  funded skey: $skey
  pnb config:  $cfg
  V3 cost model entries: $(current_v3)
Next:
  nix run '.#setup-bench' -- --config $cfg
EOF
  echo "$cfg"
}

phase_genesis
phase_config
phase_launch
if [ "$DO_GOV" -eq 1 ]; then
  phase_govern
else
  log "phase 4/5 govern: skipped (--skip-governance); V3 stays 251"
fi
phase_emit
