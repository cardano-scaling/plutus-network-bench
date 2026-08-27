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

> Status: **core, network-agnostic**, plus a bundled Leios local devnet that
> forges Endorser Blocks and enacts the 350-entry cost model via on-chain
> governance (see below). Deferred: per-EB validation wall-clock measurement and
> budget-sweep genesis overlays. See [`docs/design.md`](docs/design.md).

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

## What you provide

- a **JSON config** describing the test (per-axis targets, concurrency, IO
  setup) — see [`examples/`](examples) and [`schema/config.schema.json`](schema/config.schema.json);
- a **node socket** for the target network;
- a **funded seed-UTxO payment signing key** (`.skey`).

## Access (private repo)

This repository is **private**, so the `github:` flake fetcher won't work (it
calls the unauthenticated GitHub API and gets a 404). Access it one of two ways:

- **Over SSH** — your GitHub SSH key must have access to the repo:

  ```bash
  FLAKE='git+ssh://git@github.com/cardano-scaling/plutus-network-bench?ref=main'
  ```

  If your auth key lives on a smartcard/GPG key, make sure `SSH_AUTH_SOCK`
  points at `gpg-agent` (`gpgconf --list-dirs agent-ssh-socket`) and the key is
  added to GitHub.

- **From a local checkout** — clone it and use the flake in place:

  ```bash
  git clone git@github.com:cardano-scaling/plutus-network-bench.git
  cd plutus-network-bench
  FLAKE='.'
  ```

- **With a token** — if you prefer the `github:` form, give nix a PAT with read
  access via `access-tokens = github.com=<token>` in your nix config, then use
  `FLAKE='github:cardano-scaling/plutus-network-bench'`.

## Usage

The commands below use `$FLAKE` from above.

```bash
# 1. Set up on-chain fixtures + write a manifest to the state dir.
#    (splits UTxOs for concurrency, deploys io_ref reference scripts, creates
#     big-datum UTxOs, registers all msm_main + io_ref stake creds)
nix run "$FLAKE#setup-bench" -- \
  --config config.json \
  --socket /run/cardano/node.socket --skey payment.skey
# -> ./state/<namespace>-<timestamp>/manifest.json

# 2. Calibrate the knob -> cost map against the live network (fits ExSteps/ExMem
#    as linear functions of k, m, n_points). Skip if you set knobs_override.
nix run "$FLAKE#calibrate" -- \
  --state-dir ./state/<namespace>-<timestamp>

# 3. Solve the config targets into knobs, build the corpus, and submit it.
nix run "$FLAKE#run-bench" -- \
  --state-dir ./state/<namespace>-<timestamp>
# -> run-report.json (submitted / accepted / per-run tip delta)
```

After `setup-bench`, `calibrate` and `run-bench` run from `--state-dir` alone —
they inherit the network (magic/socket/era) and config that `setup-bench`
resolved into that directory. Pass `--config`/`--socket`/`--set …` only to
override.

### What calibrate gives you, and how to use it

`calibrate` writes `calibration.json`: a **knob → cost map** for the target
network, fitting the per-tx budget each dial consumes —

```
ExSteps ≈ a_n·n + a_k·k + a_m·m + c      ExMem ≈ a_n·n + a_k·k + a_m·m + c
  k = MSM passes (CPU)   m = replicateByte chunks (mem)   n = points·n_datums
```

You don't edit it or pick `k`/`m` by hand. Instead you state **targets** — a
fraction of each per-tx budget (or an absolute value) — and `run-bench` inverts
the fit to solve the exact `{k, m, n_datums, io_refs, pad}` that hit them:

```json
"targets": {
  "ex_steps":         { "mode": "fraction", "value": 1.0 },   // phase-2 CPU
  "ex_mem":           { "mode": "fraction", "value": 1.0 },   // phase-2 memory
  "ref_script_bytes": { "mode": "fraction", "value": 0.95 },  // phase-1 IO
  "tx_size":          { "mode": "fraction", "value": 0.95 }
}
```

`1.0` = saturate that dimension per transaction (worst case). `mem` and `CPU`
can both be maxed in the same tx (`m` is just a redeemer integer, so it costs
memory without tx bytes); `ref_script_bytes` and `tx_size` are solved from
geometry, not the fit. `run-bench` logs the `solved knobs: k=… m=… n_datums=…`
it chose before building, so you can see the decision. Set `knobs_override` to
skip solving and pin exact knobs for a reproducible run.

`--config` is a path on your own filesystem (the flake doesn't copy the
[`examples/`](examples) into your working directory); copy one as a starting
point, or pass everything as flags (`--magic N --socket … --skey …`).

Any config field is overridable on the command line: `--socket`, `--skey`,
`--magic N` / `--mainnet`, `--era`, `--namespace`, or the generic
`--set dotted.path=value`. Per-run state lives under its own timestamped
directory, so runs against different networks never collide.

The `cardano-cli` used is swappable without editing anything: pass
`--cardano-cli /path/to/cardano-cli`, set `$CARDANO_CLI`, or override the flake
input (`--override-input cardano-node github:IntersectMBO/cardano-node/<tag>`).
For networks whose era isn't the flake's default `cardano-cli` (e.g. a Leios
dijkstra net), enter a shell that has the matching cli — the wrapped apps put
their bundled cli *behind* your `PATH`, so yours wins.

### Configure once, run repeatedly

`setup-bench` and `calibrate` are **one-time** per (network + validator +
fixture shape); `run-bench` is the **repeatable execution**:

- `setup-bench` deploys the reference scripts, datum UTxOs, and stake
  registrations and writes `manifest.json` — these persist on-chain and in the
  state dir.
- `calibrate` writes `calibration.json` — valid as long as the network's cost
  model is unchanged.
- `run-bench` re-runs as often as you like against the same `--state-dir`: it
  solves knobs from your targets, **auto-replenishes the fee pool** (re-fanning
  out from the seed when earlier runs spent it), builds the corpus, and submits.
  Collateral is never consumed (valid txs), so only fees are used, and they
  refill automatically. Vary `--set concurrency.corpus_size=…`,
  `submit.tps=…`, `submit.mode=rate`, or the targets between runs — no re-setup.

A **new setup** is only needed when you change the Aiken validators (script
hashes change), increase `io_setup`/`n_msm_indices` beyond what's deployed
(`setup-bench --resume <dir>` tops those up idempotently instead of redoing
everything), or target a different/respun network.

The one ongoing resource is the **seed address's ADA**: each worst-case tx pays
the protocol-minimum fee (dominated by the reference-script read and ExUnits it
induces — a few ADA), so a run of N txs burns ≈ N × that. Everything else
(fee-UTxO change, collateral, stake deposits, fixture min-UTxOs) is locked, not
spent, and recycles. Refund the seed from a faucet when it runs low.

> Status: proven end-to-end against the public Musashi (Leios) testnet —
> setup → calibrate → repeatable run-bench, with worst-case txs accepted
> on-chain. The 350-entry PlutusV3 cost model is required for the CPU/mem dials
> (native `multiScalarMul` / `replicateByte`); see the caveat below. The
> per-EB validation-timing analysis layer is still out of scope.

## Local devnet (Leios, forges Endorser Blocks)

No node to point at? `nix run "$FLAKE#local-devnet"` mints a **funded, isolated,
disposable** devnet using whatever `cardano-node`/`cardano-cli` are on your `PATH`
(e.g. from `nix develop github:input-output-hk/ouroboros-leios#dev-testnet`) and
emits a socket + funded `.skey` + a ready config:

```bash
nix run "$FLAKE#local-devnet" -- --out-dir ./devnet --magic 42
nix run "$FLAKE#setup-bench" -- --config ./devnet/pnb-config.json
nix run "$FLAKE#local-devnet" -- --stop --out-dir ./devnet   # tear down
```

Unlike a plain devnet, it stands up everything the worst-case benchmark needs
locally, against Endorser Blocks:

- **Leios mode (default):** `--nodes N` (default 2) meshed block producers, each
  with a BLS ("Leios") key registered to its pool, so they form a Leios committee
  and **forge Endorser Blocks**. EBs endorse the tx backlog that overflows the
  ranking block, so they appear once `run-bench` saturates the mempool. Use
  `--no-leios` for a single plain-Praos node.
- **350-entry cost model via governance:** the node can't take a 350-entry
  PlutusV3 model at genesis, so the helper boots dijkstra/PV12 and enacts it with
  an on-chain `ParameterChange` (it owns every DRep/committee key). This makes the
  CPU/mem dials (native `multiScalarMul` / `replicateByte`) run locally.

See [`docs/local-devnet.md`](docs/local-devnet.md) for the full flow, the
BLS-key recipe, and the current node-build limits (EB Plutus budget ≈ 2× the
per-tx limit; certificate quorum needs >2 nodes or uneven stake).

## Development

```bash
nix develop     # aiken + cardano-cli + jq + python3
nix build .#validators   # compile + apply the validators -> artifacts + manifest
```

## Layout

```
aiken/     the two validators + shared lib (native MSM + replicateByte)
nix/       flake modules: stdlib pin, validator build, apps, devshell
scripts/   setup-bench / run-bench / calibrate / local-devnet (bash + cardano-cli) + python helpers
schema/    JSON Schemas for config, manifest, calibration
examples/  example configs
docs/      design notes
```
