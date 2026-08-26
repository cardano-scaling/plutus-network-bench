# Design notes

## Purpose

Measure the empirical worst-case validation cost a single Cardano transaction (and,
by extension, a block or Leios Endorser Block packed with such transactions) can
impose on a node. The node charges four budget dimensions; this tool exposes one
tunable dial per dimension and can drive each to its per-transaction ceiling:

1. **Phase-2 CPU (`ExSteps`)** — real elliptic-curve compute, looped.
2. **Phase-2 memory (`ExMem`)** — a cheap byte-builder, looped, largely
   independent of steps.
3. **Phase-1 disk IO** — reference scripts and reference-input datums force large
   off-disk reads for a byte-cheap transaction.
4. **Transaction size** — inert padding, spent last.

The scarce resource within one transaction is the 16 KB size limit. Byte-for-byte,
a reference (~40 B) that forces a ~16 KB disk read buys far more node work than
inline bytes, so the byte budget is spent references-first and inert padding last.

## What is nix vs. what is runtime

- **Nix owns *what to build*:** the aiken toolchain (pinned fork), a default
  `cardano-cli`, the compiled + applied validators, and the wrapped bash apps.
  Everything is referenced by store path; nothing about a specific network is
  baked in.
- **Runtime owns *where to run*:** node socket, network id/era, seed key, target
  axes, concurrency, TPS — all from a JSON config plus CLI flags.

This split is deliberate: the predecessor (`cardano-tx-bench`) baked
`/home/thomas/...` paths, `/nix/store/...` literals, `--testnet-magic 164`, and the
`dijkstra` era into every script, and passed state through one shared, unschema'd
directory. None of that survives here.

## Validators

Both are **withdraw-0 stake validators** — a withdrawal of zero does not consume
the reward account, so the same credential can be exercised every block, making
the transactions re-submittable. See `aiken/validators/` and `aiken/lib/wc/`.

- `io_ref(tag: ByteArray)` — `withdraw` returns `length_of_bytearray(tag) > 0`
  (forces the ~16 KB parameter to be read, defeating dead-code elimination);
  trivial `publish` so the script credential can be registered.
- `msm_main(index: Int)` — redeemer `{k, m, nonce}`. Reads compressed G1 points
  from reference-input inline datums, runs `k` passes of (uncompress all points →
  native `multiScalarMul`), fills memory with `m` `replicateByte` chunks, and
  gates success on all three witnesses (plus the nonce) so nothing is pruned.

### Native builtins only

The tool assumes the target network has the **350-entry PlutusV3 cost model**,
where `bls12_381_G1_multiScalarMul` and `replicateByte` are priced. The
predecessor had to carry fallback paths (a naive `scalarMul`+`add` fold, and an
`appendByteString` filler) because the local proto-devnet booted only a 251-entry
model where those native builtins were unpriced (→ instant overspend). Those
fallbacks are the bulk of the complexity we dropped. If you must target a
251-entry network, that is out of scope for this tool.

The aiken fork `github:cardano-scaling/aiken/178d444d…` is pinned specifically
because it exposes the native MSM builtin. Do not move off it without
re-verifying that `bls12_381_g1_multi_scalar_mul` and `replicate_byte` still
compile.

## Build-time vs. runtime validator counts

`nix build .#validators` applies the validators with default instance counts
(`nIoRef`, `nMsmIndices`) — the reproducible path. Because `nMsmIndices` is a real
concurrency knob that can be large, `setup-bench` regenerates the applied scripts
into the run's state dir when the requested counts differ from the nix-built set.
Both paths use the same `apply-instances.py`.

## Tools

- `setup-bench` — preflight, fan-out for concurrency, deploy `io_ref` reference
  scripts, create big-datum UTxOs, register stake credentials (all `msm_main`
  indices + the `io_ref` creds), write `manifest.json`.
- `calibrate` — sweep `(k, m, n_points)` and price each with
  `transaction calculate-plutus-script-cost online`; fit `steps`/`mem` as linear
  functions of the knobs so a config *target* can be solved into knobs.
- `run-bench` — read the manifest, solve targets → knobs (or take
  `knobs_override`), build+sign a corpus of re-submittable transactions (distinct
  `msm_main` index + nonce per tx), and submit at the target rate.

All three read protocol limits (ExUnits, deposits, `maxTxSize`) from a single
`query protocol-parameters` call — never hardcoded.
