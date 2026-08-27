# Local devnet

`scripts/local-devnet.sh` (exposed as `nix run .#local-devnet`) stands up a
**funded, isolated, multi-node devnet in the dijkstra era at PV12**, running in
**Leios mode** (≥2 meshed block producers that forge Endorser Blocks under load),
then **enacts the 350-entry PlutusV3 cost model via on-chain governance** — so the
worst-case benchmark (native `multiScalarMul` / `replicateByte`) runs entirely
locally, against EBs. It hands `setup-bench` a socket + funded `.skey` via
`pnb-config.json`. Use `--no-leios` for a single plain-Praos node.

It uses whatever `cardano-node` / `cardano-cli` are on your `PATH` (e.g. the
`ouroboros-leios#dev-testnet` devshell) or `--cardano-node` / `--cardano-cli`;
plutus-network-bench does not take the Leios monorepo as a flake input.

## Usage

```bash
nix develop github:input-output-hk/ouroboros-leios#dev-testnet   # node + cli on PATH

nix run "$FLAKE#local-devnet" -- --out-dir ./devnet --magic 42
# -> ./devnet/pnb-config.json (socket + funded skey, V3 cost model = 350)

nix run "$FLAKE#setup-bench" -- --config ./devnet/pnb-config.json
# then calibrate / run-bench against the printed state dir

nix run "$FLAKE#local-devnet" -- --stop --out-dir ./devnet   # tear down
```

Flags: `--out-dir`, `--magic`, `--port`, `--nodes N` (block producers; default 2,
forced ≥2 in Leios mode), `--total-supply`, `--cardano-node`, `--cardano-cli`,
`--env-url` (node-config + dijkstra-genesis template base), `--cost-model-file`
(the 350-entry model to enact; defaults to the shipped
`scripts/lib/costmodels-pv12.json`), `--skip-governance` (bring up a 251-model
devnet for plumbing tests only), `--no-leios` (single Praos node, no Endorser
Blocks), `--stop`.

## Leios / Endorser Blocks (EBs)

By default the devnet runs in **Leios mode**: it stands up `--nodes N` (default 2)
meshed block producers so they can form a Leios committee and forge **Endorser
Blocks**. Per node it: generates a BLS ("Leios") key (`node key-gen-BLS`), launches
with `--shelley-bls-key`, and re-registers the pool with `--bls-signing-key-file`
so its `LeiosKey` lands in the ledger (committee membership takes effect the next
epoch). See https://leios.cardano-scaling.org/docs/testnet/register-stake-pool.

Three conditions must all hold for EBs to actually be forged (verified live):

1. **≥2 meshed block producers.** A lone node parks forever at
   `leiosFetchLogic: wait for leios ready` — the Leios fetch/notify protocols are
   peer-to-peer. The topology wires each node's `localRoots` at the others
   (trustable, still isolated from any public net).
2. **Both pools on the committee** (the BLS re-registration, effective next epoch).
3. **Transaction load that overflows the ranking block.** EBs endorse the backlog
   of txs that don't fit in the 64 KB RB, so an **idle** devnet forges **zero**
   EBs. They only appear once the mempool is saturated — i.e. under `run-bench`.

Under load, each node logs `Consensus.LeiosKernel.BlockForged` (with `numTxs` =
the overflow it endorsed), `BlockAnnounced` (ebHash ← announcing rbHash) and
`LeiosVoted`. Watch them with:

```bash
grep -h '"kind":"LeiosBlockForged"' ./devnet/node*.log | jq -c .data
```

Notes / current limits of this node build (11.1.0.164, a demo Leios):
- **EB Plutus budget is 2× the per-tx ExUnit limit**, so a worst-case Plutus sweep
  packs ~2 saturating txs per EB (ExUnit-bound). This is the budget dimension to
  vary across node builds when measuring how far EB budgets can be pushed.
- **Certificate quorum** is not reached with 2 equal-stake voters (each carries
  0.5 weight; a single seat is below quorum). EBs are forged/announced/voted but
  not yet *certified* — use more nodes or uneven stake to reach quorum.

## Why governance (the crux)

The 350-entry PlutusV3 cost model **cannot be set at genesis** on this node
build. Two hard constraints, both verified against the live node:

- The V3 parameter count is **protocol-version-gated** — the extra builtins
  (`multiScalarMul`, `replicateByte`, …) exist only at **PV11+**, full set at
  PV12 (see plutus `PlutusLedgerApi/V3/ParamName.hs`).
- The node **hard-expects a 251-entry model in the conway genesis**
  (`plutusV3CostModel`): injecting 350 there fails with *"Number of parameters
  supplied 350 does not match the expected number of 251"*. Even at PV12 the
  node defaults to 251.

So 350 is reachable only by an **on-chain governance protocol-parameter update**,
exactly as the public Musashi net did. On a local devnet we own every DRep /
committee / SPO key, so this helper scripts it end to end.

## What it does

1. **genesis** — `create-testnet-data` with `--pools` (= `--nodes`),
   `--stake-delegators` (active pool stake), `--drep-keys`, `--committee-keys`,
   `--utxo-keys` (funded). Patches `shelley-genesis` to `protocolVersion.major = 12`
   and fast local blocks (`slotLength 0.1`, `activeSlotsCoeff 0.1`,
   `epochLength 500`, `securityParam 10`; epochLength stays ≥ 3·k/f). Generates one
   BLS (Leios) key per pool.
2. **config** — fetches only `config.json` + `dijkstra-genesis.json` from
   `--env-url` (never the topology — it lists public relays), forces every era's
   `TestXHardForkAtEpoch = 0` (incl. dijkstra) so the chain boots straight into
   dijkstra/PV12, and rewrites genesis paths/hashes. Writes **per-node** configs
   (distinct Prometheus port) and a **meshed, isolated** topology (each node's
   `localRoots` = the other nodes, `trustable`, no public peers).
3. **launch** — runs the `--nodes N` block producers (each with its pool's
   `--shelley-bls-key`), waits for every socket and the first forged block.
4. **leios** — re-registers every pool with its BLS key (one batched tx) so they
   join the Leios committee (effective next epoch). Skipped with `--no-leios`.
5. **govern** — submits a `ParameterChange` action setting `PlutusV3` to the
   350-entry model, votes **yes with every DRep** (committee `threshold = 0` is
   auto-approved; SPOs are disallowed voters for this action), and waits ~2–3
   short epochs for ratification + enactment, confirming `V3 == 350`.
   (`--skip-governance` stops after step 4 with the 251 model.)
6. **emit** — writes `pnb-config.json` (era `dijkstra`, node 1's socket).

The governance proposal's anchor must be fetched over http by `transaction
build` (file:// unsupported), so the helper briefly serves it from a local
`python3 -m http.server` on a high port.

## Notes

- Re-running the same `--out-dir` stops any running node and wipes the db for a
  clean respin; `--stop` tears down via the pidfile (process group).
- Governance enactment takes a few short epochs (~50 s each) — the run blocks
  until `V3 == 350`.
- This mirrors Musashi's setup, so a local run and a Musashi run exercise the
  same 350-entry model; the local one is just isolated and disposable.
