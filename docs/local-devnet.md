# Local devnet

`scripts/local-devnet.sh` (exposed as `nix run .#local-devnet`) stands up a
**funded, isolated, block-producing devnet in the dijkstra era at PV12**, then
**enacts the 350-entry PlutusV3 cost model via on-chain governance** — so the
worst-case benchmark (native `multiScalarMul` / `replicateByte`) runs entirely
locally. It hands `setup-bench` a socket + funded `.skey` via `pnb-config.json`.

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

Flags: `--out-dir`, `--magic`, `--port`, `--total-supply`, `--cardano-node`,
`--cardano-cli`, `--env-url` (node-config + dijkstra-genesis template base),
`--cost-model-file` (the 350-entry model to enact; defaults to the shipped
`scripts/lib/costmodels-pv12.json`), `--skip-governance` (bring up a 251-model
devnet for plumbing tests only), `--stop`.

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

1. **genesis** — `create-testnet-data` with `--pools`, `--stake-delegators`
   (active pool stake), `--drep-keys`, `--committee-keys`, `--utxo-keys`
   (funded). Patches `shelley-genesis` to `protocolVersion.major = 12` and fast
   local blocks (`slotLength 0.1`, `activeSlotsCoeff 0.1`, `epochLength 500`,
   `securityParam 10`; epochLength stays ≥ 3·k/f).
2. **config** — fetches only `config.json` + `dijkstra-genesis.json` from
   `--env-url` (never the topology — it lists public relays), forces every era's
   `TestXHardForkAtEpoch = 0` (incl. dijkstra) so the chain boots straight into
   dijkstra/PV12, and rewrites genesis paths/hashes. Writes an **isolated**
   topology (a `trustable` localRoot, no peers) — never dials a public net.
3. **launch** — runs the lone block producer, waits for the socket and for the
   first forged block.
4. **govern** — submits a `ParameterChange` action setting `PlutusV3` to the
   350-entry model, votes **yes with every DRep** (committee `threshold = 0` is
   auto-approved; SPOs are disallowed voters for this action), and waits ~2–3
   short epochs for ratification + enactment, confirming `V3 == 350`.
   (`--skip-governance` stops after step 3 with the 251 model.)
5. **emit** — writes `pnb-config.json` (era `dijkstra`).

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
