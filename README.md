# plutus-network-bench

A general, Nix-based tool for stress-testing a Cardano network with **worst-case
Plutus V3 transactions**. It saturates the four Plutus budget dimensions the node
charges for — phase-2 CPU (`ExSteps`), phase-2 memory (`ExMem`), phase-1 disk IO
(bytes read via reference scripts and read-only reference-input datums), and
transaction size — and can be pointed at any testnet or mainnet.

Give it a JSON config, a funded seed-UTxO payment key, and a node socket. It will
set up the on-chain fixtures (split UTxOs for concurrency, deploy reference
scripts, register stake credentials, create big-datum UTxOs), then submit a
corpus of re-submittable worst-case transactions while you measure the node.

> Status: **core, network-agnostic.** Deferred: per-EB validation wall-clock
> measurement, a bundled local devnet, and budget-sweep genesis overlays. See
> [`docs/design.md`](docs/design.md).

## How it works

Two withdraw-0 stake validators, both re-submittable every block:

- **`io_ref(tag)`** — a trivial validator applied with N distinct ~16 KB byte
  parameters, giving N distinct ~16 KB reference scripts. Each withdraw-0 via
  reference forces the node to read a ~16 KB script off disk (the phase-1 IO dial).
- **`msm_main(index)`** — the CPU/mem dial. Redeemer `{k, m, nonce}`: `k` passes
  of native BLS `multiScalarMul` over compressed G1 points sourced from
  reference-input datums (CPU), `m` `replicateByte` chunks (memory). The `index`
  parameter yields distinct stake credentials so many transactions run in parallel
  with no reward-account contention.

This assumes the target network carries the **350-entry PlutusV3 cost model**
(PV12+), where `bls12_381_G1_multiScalarMul` and `replicateByte` are priced.

## Usage

```bash
# 1. Set up on-chain fixtures + write a manifest to the state dir.
nix run github:cardano-scaling/plutus-network-bench#setup-bench -- \
  --config examples/config.preprod.json \
  --socket /run/cardano/node.socket --skey payment.skey

# 2. (optional) Calibrate the knob -> cost map against the live network.
nix run github:cardano-scaling/plutus-network-bench#calibrate -- \
  --state-dir ./state/bench-<timestamp>

# 3. Build and submit the worst-case corpus.
nix run github:cardano-scaling/plutus-network-bench#run-bench -- \
  --state-dir ./state/bench-<timestamp>
```

The `cardano-cli` used is swappable without editing anything: pass
`--cardano-cli /path/to/cardano-cli`, set `$CARDANO_CLI`, or override the flake
input (`--override-input cardano-node github:IntersectMBO/cardano-node/<tag>`).

## Development

```bash
nix develop     # aiken + cardano-cli + jq + python3
nix build .#validators   # compile + apply the validators -> artifacts + manifest
```

## Layout

```
aiken/     the two validators + shared lib (native MSM + replicateByte)
nix/       flake modules: stdlib pin, validator build, apps, devshell
scripts/   setup-bench / run-bench / calibrate (bash + cardano-cli) + python helpers
schema/    JSON Schemas for config, manifest, calibration
examples/  example configs
docs/      design notes
```
