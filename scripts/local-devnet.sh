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
# Leios / Endorser Blocks: by default the block producer runs in Leios mode so it
# can forge & certify Endorser Blocks (EBs). This needs a BLS ("Leios") key: we
# generate one, launch the node with --shelley-bls-key, and re-register the pool
# with --bls-signing-key-file so its LeiosKey lands in the ledger and it joins the
# Leios committee. See https://leios.cardano-scaling.org/docs/testnet/register-stake-pool
# Disable with --no-leios (plain Praos block production only).
#
# Phases (default action):
#   1 genesis   create-testnet-data (funded utxo + pool + delegators + DReps +
#               committee); patch shelley for PV12 + fast blocks; gen pool BLS key.
#   2 config    fetch leios node config + dijkstra genesis; force every era's
#               hard fork to epoch 0; wire genesis hashes; isolated topology.
#   3 launch    run the block producer (with --shelley-bls-key); wait for socket.
#   4 leios     re-register the pool with its BLS key so it joins the Leios
#               committee and can certify EBs (skip with --no-leios).
#   5 govern    ParameterChange -> 350-entry PlutusV3 cost model; vote with all
#               DReps + SPOs; wait for enactment (skip with --skip-governance).
#   6 emit      pnb-config.json (era dijkstra) for setup-bench; report EB status.

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
PORT=3001                   # node i listens on PORT+(i-1); Prometheus on 12798+(i-1)
START_OFFSET=20
NODES=2                     # block producers (Leios needs >=2 to certify EBs)
STAKE_DELEGATORS=4; DREPS=3; COMMITTEE=1; UTXO_KEYS=1
DO_GOV=1; DO_LEIOS=1; STOP=0
COSTMODEL_FILE="$SELF_DIR/lib/costmodels-pv12.json"

die() { printf '[devnet] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[devnet] %s\n' "$*" >&2; }

# Kill a running devnet by its pidfile (one pid/pgid per line, one per node),
# pkill-by-dir as fallback.
stop_devnet() {
  local dir="$1" pf="$1/devnet.pid" pid n=0
  if [ -f "$pf" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      n=$((n+1))
    done < "$pf"
    [ "$n" -gt 0 ] && log "stopped devnet ($n node(s))"; rm -f "$pf"
  else
    pkill -TERM -f "cardano-node.*$dir" 2>/dev/null && log "stopped cardano-node matching $dir" || true
  fi
  rm -f "$dir"/node*.socket
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
    --leios)           DO_LEIOS=1; shift 1 ;;
    --no-leios)        DO_LEIOS=0; shift 1 ;;
    --nodes)           NODES="$2"; shift 2 ;;
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

# Leios needs >=2 meshed block producers to form a committee and certify EBs; a
# single node just parks at "leiosFetchLogic: wait for leios ready". Without
# --no-leios we require >=2. Plain Praos (--no-leios) runs a single node.
if [ "$DO_LEIOS" -eq 0 ]; then
  NODES=1
elif [ "$NODES" -lt 2 ]; then
  log "warn: Leios needs >=2 block producers to certify EBs; bumping --nodes to 2"
  NODES=2
fi
POOLS="$NODES"              # one pool per block producer

OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
GEN="$OUT_DIR/gen"
SOCKET="$OUT_DIR/node1.socket"   # node 1 is the one we query / fund / govern via
stop_devnet "$OUT_DIR"; rm -rf "$GEN" "$OUT_DIR"/db* "$OUT_DIR"/node*.socket

# query helper against the running node
q() { CARDANO_NODE_SOCKET_PATH="$SOCKET" "$CLI" "$RUN_ERA" "$@" --testnet-magic "$MAGIC"; }

# ============================================================================
# Phase 1: genesis
# ============================================================================
phase_genesis() {
  local start; start="$(date -u -d "+${START_OFFSET} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                       || date -u -v+${START_OFFSET}S +%Y-%m-%dT%H:%M:%SZ)"
  log "phase 1/6 genesis: create-testnet-data (pools=$POOLS delegators=$STAKE_DELEGATORS dreps=$DREPS committee=$COMMITTEE)"
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

  # One BLS ("Leios") key per pool so each can vote on / certify Endorser Blocks.
  # Each node is launched with its pool's signing key and the pool is re-registered
  # with it in phase_leios. Harmless if --no-leios (key just goes unused).
  if [ "$DO_LEIOS" -eq 1 ]; then
    local i p
    for ((i=1; i<=NODES; i++)); do
      p="$GEN/pools-keys/pool$i"
      "$CLI" "$RUN_ERA" node key-gen-BLS \
        --verification-key-file "$p/bls.vkey" --signing-key-file "$p/bls.skey"
    done
    log "  generated $NODES pool BLS (Leios) key(s)"
  fi
}

# ============================================================================
# Phase 2: node config + genesis wiring + isolated topology
# ============================================================================
phase_config() {
  log "phase 2/6 config: fetch node config + dijkstra genesis, force hard forks, isolate"
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
  # Per-node config (distinct Prometheus port so they don't collide) + a meshed,
  # isolated topology: each node's localRoots point only at the OTHER nodes
  # (trustable, no public peers) so the Leios committee can announce/fetch/vote.
  local i aps val
  for ((i=1; i<=NODES; i++)); do
    jq --arg pport "$((12798 + i - 1))" \
       'walk(if type=="string" and test("PrometheusSimple") then sub("[0-9]+$"; $pport) else . end)' \
       "$OUT_DIR/config.json" > "$OUT_DIR/config-$i.json"
    aps="$(jq -cn --argjson port "$PORT" --argjson n "$NODES" --argjson self "$i" \
      '[range(1; $n+1) | select(. != $self) | {address:"127.0.0.1", port:($port + . - 1)}]')"
    val=$([ "$NODES" -gt 1 ] && echo $((NODES-1)) || echo 0)
    jq -n --argjson aps "$aps" --argjson val "$val" \
      '{localRoots:[{accessPoints:$aps, advertise:false, trustable:true, valency:$val}],
        publicRoots:[{accessPoints:[], advertise:false}], useLedgerAfterSlot:-1}' \
      > "$OUT_DIR/topology-$i.json"
  done
  log "  wrote $NODES node config(s) + meshed isolated topology (ports $PORT..$((PORT+NODES-1)))"
}

# ============================================================================
# Phase 3: launch the block producer(s)
# ============================================================================
phase_launch() {
  log "phase 3/6 launch: $NODES block producer(s) on ports $PORT..$((PORT+NODES-1))$([ "$DO_LEIOS" -eq 1 ] && echo ' (Leios mode)')"
  : > "$OUT_DIR/devnet.pid"
  local i p port sock nlog
  for ((i=1; i<=NODES; i++)); do
    p="$GEN/pools-keys/pool$i"; port=$((PORT + i - 1))
    sock="$OUT_DIR/node$i.socket"; nlog="$OUT_DIR/node$i.log"
    # --shelley-bls-key supplies the node's Leios voting key; without it the node
    # logs "runLeiosVoting: disabled because no topLevelConfigVotingKey".
    local -a bls_arg=()
    [ "$DO_LEIOS" -eq 1 ] && [ -f "$p/bls.skey" ] && bls_arg=(--shelley-bls-key "$p/bls.skey")
    setsid "$NODE" run +RTS -qg -qb -RTS \
      --config "$OUT_DIR/config-$i.json" --topology "$OUT_DIR/topology-$i.json" \
      --database-path "$OUT_DIR/db$i" --socket-path "$sock" \
      --host-addr 0.0.0.0 --port "$port" \
      --shelley-kes-key "$p/kes.skey" --shelley-vrf-key "$p/vrf.skey" \
      --shelley-operational-certificate "$p/opcert.cert" \
      "${bls_arg[@]}" \
      < /dev/null > "$nlog" 2>&1 &
    echo "$!" >> "$OUT_DIR/devnet.pid"
    log "  node$i pid $! ; port $port ; log $nlog"
  done
  log "stop: local-devnet --stop --out-dir $OUT_DIR"
  # wait for every node's socket
  for ((i=1; i<=NODES; i++)); do
    sock="$OUT_DIR/node$i.socket"; local j
    for ((j=0; j<90; j++)); do [ -S "$sock" ] && break; sleep 2; done
    [ -S "$sock" ] || die "node$i socket never appeared; see $OUT_DIR/node$i.log"
  done
  # wait until node1 produces at least one block (leadership working)
  for ((i=0; i<60; i++)); do
    [ "$(q query tip 2>/dev/null | jq -r '.block // 0')" -gt 0 ] && { log "  nodes forging blocks"; return; }
    sleep 2
  done
  die "nodes up but not forging blocks; see $OUT_DIR/node1.log"
}

# ============================================================================
# Phase 4: leios — re-register every pool with its BLS key (join the committee)
# ============================================================================
# create-testnet-data registers each pool at genesis WITHOUT a BLS key, so none
# have a LeiosKey and none can be on the Leios committee. We submit one tx
# carrying a pool re-registration cert per pool (--bls-signing-key-file). Best-
# effort: a failure here must not block the (proven) governance / benchmark path.
phase_leios() {
  log "phase 4/6 leios: re-register $NODES pool(s) with BLS keys (join Leios committee)"
  mkdir -p "$OUT_DIR/leios"
  local pay_skey pay_addr fee i p cert
  pay_skey="$GEN/utxo-keys/utxo1/utxo.skey"
  pay_addr="$("$CLI" address build --payment-verification-key-file "$GEN/utxo-keys/utxo1/utxo.vkey" --testnet-magic "$MAGIC")"

  # Build one re-registration cert per pool and collect certs + signers. Re-
  # registration = same cold key, now with the BLS key. stakePoolDeposit is 0 on
  # this devnet (no extra deposit); owner/reward = the pool's genesis reward key.
  local -a certs=() signers=(--signing-key-file "$pay_skey")
  for ((i=1; i<=NODES; i++)); do
    p="$GEN/pools-keys/pool$i"; cert="$OUT_DIR/leios/pool$i-rereg.cert"
    [ -f "$p/bls.skey" ] || { log "  warn: pool$i has no BLS key; skipping"; continue; }
    if ! "$CLI" "$RUN_ERA" stake-pool registration-certificate \
          --cold-verification-key-file "$p/cold.vkey" \
          --vrf-verification-key-file "$p/vrf.vkey" \
          --bls-signing-key-file "$p/bls.skey" \
          --pool-pledge 0 --pool-cost 0 --pool-margin 0 \
          --pool-reward-account-verification-key-file "$p/staking-reward.vkey" \
          --pool-owner-stake-verification-key-file "$p/staking-reward.vkey" \
          --pool-relay-ipv4 127.0.0.1 --pool-relay-port "$((PORT + i - 1))" \
          --testnet-magic "$MAGIC" --out-file "$cert" 2>>"$OUT_DIR/leios/cert.err"; then
      log "  warn: could not build BLS cert for pool$i (see $OUT_DIR/leios/cert.err); skipping"; continue
    fi
    certs+=(--certificate-file "$cert")
    signers+=(--signing-key-file "$p/cold.skey" --signing-key-file "$p/staking-reward.skey")
  done
  [ "${#certs[@]}" -gt 0 ] || { log "  warn: no BLS certs built; continuing"; return 0; }

  fee="$(q query utxo --address "$pay_addr" --output-json | jq -r 'to_entries|sort_by(.value.value.lovelace)|reverse|.[0].key')"
  if q transaction build --tx-in "$fee" "${certs[@]}" \
       --change-address "$pay_addr" --out-file "$OUT_DIR/leios/rereg.body" 2>"$OUT_DIR/leios/build.err" \
     && "$CLI" "$RUN_ERA" transaction sign --tx-body-file "$OUT_DIR/leios/rereg.body" \
          "${signers[@]}" --testnet-magic "$MAGIC" --out-file "$OUT_DIR/leios/rereg.signed" 2>>"$OUT_DIR/leios/build.err" \
     && q transaction submit --tx-file "$OUT_DIR/leios/rereg.signed" 2>>"$OUT_DIR/leios/build.err"; then
    log "  $(( ${#certs[@]} / 2 )) pool(s) re-registered with BLS keys; committee active next epoch"
  else
    log "  warn: BLS re-registration tx failed (see $OUT_DIR/leios/build.err); continuing"
  fi
}

# Count Endorser Blocks FORGED across all node logs (best-effort). EBs are only
# produced under load — when the tx backlog overflows the ranking block — so this
# is 0 on an idle devnet and only climbs once run-bench floods txs.
eb_status() {
  local n
  n="$(grep -acE '"kind":"LeiosBlockForged"|LeiosKernel.BlockForged' "$OUT_DIR"/node*.log 2>/dev/null \
       | awk -F: '{s+=$NF} END{print s+0}')" || n=0
  printf '%s' "${n:-0}"
}

# ============================================================================
# Phase 5: governance — enact the 350-entry PlutusV3 cost model
# ============================================================================
current_v3() { q query protocol-parameters 2>/dev/null | jq -r '.costModels.PlutusV3|length' 2>/dev/null || echo 0; }
current_epoch() { q query tip 2>/dev/null | jq -r '.epoch' 2>/dev/null || echo 0; }
# Max active DRep voting stake (0 until the genesis delegations enter the active
# stake snapshot, ~epoch 2). Tolerant of query hiccups.
drep_active_stake() {
  q query drep-stake-distribution --all-dreps --output-json 2>/dev/null \
    | jq -r '[.[]?] | map(select(type=="number")) + [0] | max' 2>/dev/null || echo 0
}

phase_govern() {
  local have; have="$(current_v3)"
  log "phase 5/6 govern: PlutusV3 model currently $have entries; enacting 350"
  [ "$have" -eq 350 ] && { log "already 350; skipping"; return; }

  # Wait for DRep stake to become ACTIVE before proposing. Genesis delegations
  # only enter the active snapshot ~2 epochs in; proposing/voting before then
  # means the votes carry no weight and the action expires unratified (the
  # intermittent failure this guards against).
  local i s
  log "  waiting for DRep voting stake to activate (epoch $(current_epoch))…"
  for ((i=0; i<60; i++)); do
    s="$(drep_active_stake)"; [ -z "$s" ] && s=0
    [ "$s" -gt 0 ] 2>/dev/null && { log "  DRep active stake ready ($s at epoch $(current_epoch))"; break; }
    sleep 5
  done

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
  local eb_line=""
  if [ "$DO_LEIOS" -eq 1 ]; then
    local ebn; ebn="$(eb_status)"
    if [ "$ebn" -gt 0 ]; then
      eb_line="  Endorser Blocks: Leios active — $ebn EB(s) forged so far (see node*.log)"
    else
      eb_line="  Endorser Blocks: $NODES-node committee ready (BLS keys registered). EBs are only
                   forged under load, when the tx backlog overflows the ranking block —
                   run the benchmark (run-bench) to drive them; watch:
                   grep -h LeiosBlockForged $OUT_DIR/node*.log"
    fi
  fi
  cat >&2 <<EOF
[devnet] ready.
  socket:      $SOCKET
  funded skey: $skey
  pnb config:  $cfg
  V3 cost model entries: $(current_v3)
${eb_line:+$eb_line
}Next:
  nix run '.#setup-bench' -- --config $cfg
EOF
  echo "$cfg"
}

phase_genesis
phase_config
phase_launch
if [ "$DO_LEIOS" -eq 1 ]; then
  phase_leios
else
  log "phase 4/6 leios: skipped (--no-leios); plain Praos block production only"
fi
if [ "$DO_GOV" -eq 1 ]; then
  phase_govern
else
  log "phase 5/6 govern: skipped (--skip-governance); V3 stays 251"
fi
phase_emit
