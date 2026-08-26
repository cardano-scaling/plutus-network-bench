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

> The orchestrator (`setup-bench` / `calibrate` / `run-bench`) is shellcheck-clean
> and builds under nix; end-to-end validation against a live node is still
> pending. The validators and the nix build are verified.

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
