#!/usr/bin/env bash
# local-devnet — mint and launch a FUNDED single-node local testnet, decoupled
# from any particular node distribution: it uses whatever cardano-node/cardano-cli
# are on PATH (e.g. `nix develop github:input-output-hk/ouroboros-leios#dev-testnet`)
# or the ones you pass via --cardano-node / --cardano-cli.
#
# It produces exactly what setup-bench needs: a node socket and a funded payment
# .skey. Unlike joining a public network, create-testnet-data mints genesis + a
# funded UTxO key you control, so you can actually submit.
#
#   local-devnet --out-dir ./devnet --magic 42 [--env-url <base>] [--no-launch]
#   local-devnet --stop --out-dir ./devnet          # terminate a running devnet
#
# Re-running against the same --out-dir first stops any node still running for it
# and wipes the old db, so it always respins a fresh chain.
#
# Flow:
#   1. cardano-cli <era> genesis create-testnet-data  -> genesis + funded keys + a BP
#   2. fetch the node config template + dijkstra-genesis + topology from --env-url
#      (default: the public Leios/Musashi environment), rewrite every *GenesisFile
#      to our absolute paths and every *GenesisHash to the recomputed value
#   3. launch cardano-node as a lone block producer; wait for the socket
#   4. print the funded .skey + socket + a ready plutus-network-bench config
#
# CAVEAT (cost model): the msm_main validator uses native bls12_381_G1_multiScalarMul
# and replicateByte, which are only PRICED under the 350-entry PlutusV3 cost model
# (PV12+). Some node builds boot only the 251-entry model and leave those builtins
# unpriced (instant overspend). This helper injects the 350-entry model when a
# --conway-spec is given; otherwise it warns. The IO / size / registration plumbing
# works regardless. See docs/local-devnet.md.

set -euo pipefail

OUT_DIR="./devnet"
MAGIC=42
ERA=conway
NODE_BIN=""
CLI_BIN=""
ENV_URL="https://raw.githubusercontent.com/input-output-hk/cardano-playground/main/docs/environments-pre/leios"
CONWAY_SPEC=""
TOTAL_SUPPLY=30000000000000000     # 30e15 lovelace = 30e9 ADA
UTXO_KEYS=2
PORT=3001
START_OFFSET=30                    # start-time this many seconds in the future
LAUNCH=1
STOP=0

die() { printf '[devnet] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[devnet] %s\n' "$*" >&2; }

# stop a running devnet: kill its process group via the pidfile (fallback: pkill
# the cardano-node whose command line references this out-dir), then clear the
# socket. Never matches nodes for other directories (e.g. a Musashi relay).
stop_devnet() {
  local dir="$1" pf="$1/devnet.pid" pid
  if [ -f "$pf" ] && pid="$(cat "$pf" 2>/dev/null)" && [ -n "$pid" ]; then
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    log "stopped devnet (pgid/pid $pid)"
    rm -f "$pf"
  else
    pkill -TERM -f "cardano-node.*$dir" 2>/dev/null && log "stopped cardano-node matching $dir" || true
  fi
  rm -f "$dir/node.socket"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir)       OUT_DIR="$2"; shift 2 ;;
    --magic)         MAGIC="$2"; shift 2 ;;
    --era)           ERA="$2"; shift 2 ;;
    --cardano-node)  NODE_BIN="$2"; shift 2 ;;
    --cardano-cli)   CLI_BIN="$2"; shift 2 ;;
    --env-url)       ENV_URL="$2"; shift 2 ;;
    --conway-spec)   CONWAY_SPEC="$2"; shift 2 ;;
    --total-supply)  TOTAL_SUPPLY="$2"; shift 2 ;;
    --port)          PORT="$2"; shift 2 ;;
    --no-launch)     LAUNCH=0; shift 1 ;;
    --stop)          STOP=1; shift 1 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

# --stop: terminate an existing devnet and exit (no cli/node needed).
if [ "$STOP" -eq 1 ]; then
  OUT_DIR="$(cd "$OUT_DIR" 2>/dev/null && pwd || echo "$OUT_DIR")"
  [ -d "$OUT_DIR" ] || die "out-dir not found: $OUT_DIR"
  stop_devnet "$OUT_DIR"
  exit 0
fi

CLI="${CLI_BIN:-cardano-cli}"
NODE="${NODE_BIN:-cardano-node}"
command -v "$CLI"  >/dev/null 2>&1 || die "cardano-cli not found on PATH (or pass --cardano-cli)"
[ "$LAUNCH" -eq 0 ] || command -v "$NODE" >/dev/null 2>&1 || die "cardano-node not found on PATH (or pass --cardano-node / --no-launch)"
log "cardano-cli: $($CLI --version 2>/dev/null | head -1)"

OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"     # absolute
GEN="$OUT_DIR/gen"
# fresh chain: stop any prior node for this dir and wipe old genesis + db + socket
stop_devnet "$OUT_DIR"
rm -rf "$GEN" "$OUT_DIR/db" "$OUT_DIR/node.socket"

# 1. mint genesis + funded keys + a block producer
START_TIME="$(date -u -d "+${START_OFFSET} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -v+${START_OFFSET}S +%Y-%m-%dT%H:%M:%SZ)"
log "create-testnet-data (magic $MAGIC, start $START_TIME)"
# shellcheck disable=SC2086
"$CLI" "$ERA" genesis create-testnet-data \
  --testnet-magic "$MAGIC" --pools 1 --utxo-keys "$UTXO_KEYS" \
  --total-supply "$TOTAL_SUPPLY" --delegated-supply "$((TOTAL_SUPPLY/2))" \
  --start-time "$START_TIME" \
  ${CONWAY_SPEC:+--spec-conway "$CONWAY_SPEC"} \
  --out-dir "$GEN"

# 2. fetch node config template + dijkstra genesis + topology, rewrite genesis refs
fetch() { curl -fsSL "$ENV_URL/$1" -o "$2" || log "warn: could not fetch $1"; }
fetch config.json          "$OUT_DIR/config.json"
fetch topology.json        "$OUT_DIR/topology.json"
fetch dijkstra-genesis.json "$GEN/dijkstra-genesis.json" || true

byron_hash() { "$CLI" byron genesis print-genesis-hash --genesis-json "$1" | tr -d '[:space:]'; }
era_hash()   { "$CLI" "$ERA" genesis hash --genesis "$1" | tr -d '[:space:]'; }

if [ -s "$OUT_DIR/config.json" ]; then
  log "wiring config.json to generated genesis files + hashes"
  set_field() { # <jsonfile> <key> <value-json>
    jq --arg k "$2" --argjson v "$3" '.[$k]=$v' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
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
else
  die "no config.json template (fetch from --env-url failed); pass a reachable --env-url"
fi

# minimal isolated p2p topology if none was fetched
if [ ! -s "$OUT_DIR/topology.json" ]; then
  printf '%s\n' '{"bootstrapPeers":[],"localRoots":[],"publicRoots":[],"useLedgerAfterSlot":-1}' \
    > "$OUT_DIR/topology.json"
fi

FUNDED_SKEY="$GEN/utxo-keys/utxo1/utxo.skey"
[ -f "$FUNDED_SKEY" ] || die "expected funded key not found: $FUNDED_SKEY"
SOCKET="$OUT_DIR/node.socket"

# 3. launch the block producer
if [ "$LAUNCH" -eq 1 ]; then
  P="$GEN/pools-keys/pool1"
  log "launching cardano-node block producer on port $PORT"
  setsid "$NODE" run +RTS -qg -qb -RTS \
    --config "$OUT_DIR/config.json" \
    --topology "$OUT_DIR/topology.json" \
    --database-path "$OUT_DIR/db" \
    --socket-path "$SOCKET" \
    --host-addr 0.0.0.0 --port "$PORT" \
    --shelley-kes-key "$P/kes.skey" \
    --shelley-vrf-key "$P/vrf.skey" \
    --shelley-operational-certificate "$P/opcert.cert" \
    < /dev/null > "$OUT_DIR/node.log" 2>&1 &
  # setsid makes the child a session leader, so its PID == PGID: kill -- -PID
  # (done by --stop / stop_devnet) tears down the whole node.
  echo "$!" > "$OUT_DIR/devnet.pid"
  log "node pid $! ; log $OUT_DIR/node.log ; stop: local-devnet --stop --out-dir $OUT_DIR"
  log "waiting for socket $SOCKET ..."
  for _ in $(seq 1 60); do [ -S "$SOCKET" ] && break; sleep 2; done
  [ -S "$SOCKET" ] || die "node socket did not appear; check $OUT_DIR/node.log"
  if CARDANO_NODE_SOCKET_PATH="$SOCKET" "$CLI" "$ERA" query tip --testnet-magic "$MAGIC" >/dev/null 2>&1; then
    log "node is answering queries"
  else
    log "warn: node not answering tip yet (still starting?)"
  fi
fi

# 4. emit a ready-to-use plutus-network-bench config
CFG_OUT="$OUT_DIR/pnb-config.json"
jq -n --argjson magic "$MAGIC" --arg era "$ERA" --arg sock "$SOCKET" --arg skey "$FUNDED_SKEY" \
  '{schema_version:1,
    network:{kind:"testnet", magic:$magic, era:$era, socket:$sock},
    wallet:{seed_skey:$skey},
    run:{namespace:"devnet", state_dir:"./state"}}' > "$CFG_OUT"

cat >&2 <<EOF
[devnet] ready.
  socket:      $SOCKET
  funded skey: $FUNDED_SKEY
  pnb config:  $CFG_OUT
Next:
  nix run '.#setup-bench' -- --config $CFG_OUT
EOF
echo "$CFG_OUT"
