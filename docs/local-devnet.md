# Local devnet

`scripts/local-devnet.sh` (exposed as `nix run .#local-devnet`) spins up a
**funded, single-node local testnet** and hands you exactly what `setup-bench`
needs: a node socket and a funded payment `.skey`.

It is **decoupled from any node distribution**: it uses whatever `cardano-node`
and `cardano-cli` are on your `PATH` — e.g. from
`nix develop github:input-output-hk/ouroboros-leios#dev-testnet` — or the ones you
pass with `--cardano-node` / `--cardano-cli`. plutus-network-bench does *not*
take the Leios monorepo as a flake input.

## Create vs. join

Two different things, only the first gives you funds to benchmark with:

- **Create (this helper).** `cardano-cli <era> genesis create-testnet-data` mints
  a fresh genesis plus a **funded UTxO key you control** and a block producer, so
  you can actually submit transactions. This is what benchmarking needs.
- **Join a public network** (mainnet / Musashi). Download `config.json`,
  `topology.json`, and the genesis files from the environment
  (`https://book.play.dev.cardano.org/` / `cardano-playground`), then
  `cardano-node run --config … --topology …`. You get a syncing node but **no
  funds** — only useful here if you already hold a funded key on that network,
  which you then pass straight to `setup-bench` (no devnet needed).

## Usage

```bash
# in a shell where the leios cardano-node/cardano-cli are on PATH:
nix develop github:input-output-hk/ouroboros-leios#dev-testnet

nix run 'git+ssh://git@github.com/cardano-scaling/plutus-network-bench?ref=main#local-devnet' -- \
  --out-dir ./devnet --magic 42
# -> ./devnet/node.socket, ./devnet/gen/utxo-keys/utxo1/utxo.skey, ./devnet/pnb-config.json

nix run '…#setup-bench' -- --config ./devnet/pnb-config.json
```

Flags: `--out-dir`, `--magic`, `--era`, `--port`, `--total-supply`,
`--cardano-node`, `--cardano-cli`, `--env-url` (config/topology/dijkstra-genesis
template base; defaults to the public Leios environment), `--conway-spec`
(supply a Conway genesis spec — see the cost-model caveat), `--no-launch`
(materialise everything but don't start the node).

## What it does

1. `create-testnet-data` → `gen/{byron,shelley,alonzo,conway}-genesis.json`,
   `gen/utxo-keys/utxo1/utxo.{skey,vkey}` (funded), `gen/pools-keys/pool1/…` (BP).
2. Fetches `config.json`, `topology.json`, and `dijkstra-genesis.json` from
   `--env-url`, then rewrites every `*GenesisFile` to the generated absolute paths
   and every `*GenesisHash` to the recomputed value (byron via
   `print-genesis-hash`, the rest via `<era> genesis hash`).
3. Launches `cardano-node run` as a lone block producer (using the pool's
   KES/VRF/opcert) and waits for the socket.
4. Emits `pnb-config.json` wired to the socket + funded key.

## Cost-model caveat (important)

`msm_main` uses native `bls12_381_G1_multiScalarMul` and `replicateByte`, which
are **only priced under the 350-entry PlutusV3 cost model** (PV12+). Some node
builds (e.g. the `11.1.0.164` prototype) boot **only the 251-entry model** and
leave those builtins unpriced — any `msm_main` tx then instantly overspends.

Consequences:

- The **plumbing** — fan-out, io_ref reference scripts, registrations, read-only
  reference inputs, tx-size padding — works on either model, so a 251-entry local
  devnet is fine for shaking out `setup-bench` / `run-bench`.
- The **CPU/mem dials** need a 350-entry model. Supply a Conway genesis spec that
  carries the 350-entry `PlutusV3` cost model via `--conway-spec`, *and* a node
  build that accepts it. If your node hard-requires 251 entries, do the full
  benchmark against the public Musashi net (which has the 350-entry model via
  governance) instead.
