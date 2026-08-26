#!/usr/bin/env python3
"""Apply parameters to the compiled validators to produce concrete instances.

Reads the unapplied CIP-57 blueprint (plutus.json) and, for each requested
instance, runs `aiken blueprint apply` with a CBOR-encoded parameter:

  * io_ref(tag: ByteArray)  -- N distinct ~ioParamBytes-byte pseudo-random tags,
    each yielding a distinct script hash and a ~16 KB reference script.
  * msm_main(index: Int)    -- one per index, each yielding a distinct stake
    credential so many worst-case transactions run in parallel with no
    reward-account contention.

Outputs, under --out:
    io_ref/io_ref_%03d.plutus        PlutusScriptV3 text envelopes
    msm_main/msm_main_%03d.plutus
    blueprint-manifest.json          {io_ref:[{index,hash,size_bytes,file}],
                                      msm_main:[{index,hash,size_bytes,file}],
                                      namespace, io_param_bytes}

The tags are derived deterministically from the namespace, so the same inputs
always produce the same hashes (reproducible under nix and re-runnable at
runtime). `aiken` must be on PATH.
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys


def cbor_uint(n: int) -> bytes:
    """Minimal CBOR encoding of a non-negative integer (Plutus Data I n)."""
    if n < 0:
        raise ValueError("index must be non-negative")
    if n < 24:
        return bytes([n])
    if n < 0x100:
        return bytes([0x18, n])
    if n < 0x10000:
        return bytes([0x19]) + n.to_bytes(2, "big")
    if n < 0x100000000:
        return bytes([0x1A]) + n.to_bytes(4, "big")
    return bytes([0x1B]) + n.to_bytes(8, "big")


def cbor_bytes(data: bytes) -> bytes:
    """CBOR encoding of a ByteArray (Plutus Data B bs).

    Plutus caps a definite bytestring chunk at 64 bytes, so anything longer is
    encoded as an indefinite-length bytestring of 64-byte definite chunks
    (0x5f ... 0xff). This matches how the node expects large on-chain
    bytestrings and is what the predecessor tool shipped on public networks.
    """
    if len(data) <= 64:
        if len(data) < 24:
            return bytes([0x40 + len(data)]) + data
        return bytes([0x58, len(data)]) + data
    out = bytearray([0x5F])
    for i in range(0, len(data), 64):
        chunk = data[i : i + 64]
        out += bytes([0x58, len(chunk)]) + chunk
    out += bytes([0xFF])
    return bytes(out)


def derive_tag(namespace: str, index: int, nbytes: int) -> bytes:
    """Deterministic pseudo-random tag of exactly nbytes for io_ref instance."""
    seed = f"{namespace}-io_ref-{index}".encode()
    out = bytearray()
    counter = 0
    while len(out) < nbytes:
        out += hashlib.sha256(seed + counter.to_bytes(4, "big")).digest()
        counter += 1
    return bytes(out[:nbytes])


def apply(aiken: str, blueprint: str, module: str, validator: str,
          cbor_hex: str) -> dict:
    """Run `aiken blueprint apply` and return the applied validator entry."""
    proc = subprocess.run(
        [aiken, "blueprint", "apply", cbor_hex,
         "-m", module, "-v", validator, "-i", blueprint],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout + proc.stderr)
        raise SystemExit(f"aiken blueprint apply failed for {module}.{validator}")
    bp = json.loads(proc.stdout)
    # The applied blueprint has this validator's parameters removed; find the
    # entry whose parameters are now absent/empty and whose title matches.
    for v in bp["validators"]:
        if v["title"].startswith(f"{module}.{validator}.") and not v.get("parameters"):
            return v
    # Fallback: first entry matching the title prefix.
    for v in bp["validators"]:
        if v["title"].startswith(f"{module}.{validator}."):
            return v
    raise SystemExit(f"no {module}.{validator} entry in applied blueprint")


def write_envelope(path: str, code_hex: str, description: str) -> int:
    env = {
        "type": "PlutusScriptV3",
        "description": description,
        "cborHex": code_hex,
    }
    with open(path, "w") as f:
        json.dump(env, f)
    return len(code_hex) // 2


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--blueprint", required=True, help="unapplied plutus.json")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--namespace", default="plutus-bench")
    ap.add_argument("--n-io-ref", type=int, default=16)
    ap.add_argument("--io-param-bytes", type=int, default=16000)
    ap.add_argument("--n-msm-indices", type=int, default=64)
    ap.add_argument("--aiken", default=os.environ.get("AIKEN", "aiken"))
    args = ap.parse_args()

    io_dir = os.path.join(args.out, "io_ref")
    msm_dir = os.path.join(args.out, "msm_main")
    os.makedirs(io_dir, exist_ok=True)
    os.makedirs(msm_dir, exist_ok=True)

    manifest = {
        "namespace": args.namespace,
        "io_param_bytes": args.io_param_bytes,
        "io_ref": [],
        "msm_main": [],
    }

    io_hashes = set()
    for i in range(args.n_io_ref):
        tag = derive_tag(args.namespace, i, args.io_param_bytes)
        cbor_hex = cbor_bytes(tag).hex()
        v = apply(args.aiken, args.blueprint, "io_ref", "io_ref", cbor_hex)
        fname = f"io_ref_{i:03d}.plutus"
        size = write_envelope(
            os.path.join(io_dir, fname), v["compiledCode"],
            f"io_ref[{i}] ({args.io_param_bytes}B tag)")
        assert v["hash"] not in io_hashes, f"duplicate io_ref hash at {i}"
        io_hashes.add(v["hash"])
        manifest["io_ref"].append(
            {"index": i, "hash": v["hash"], "size_bytes": size,
             "file": f"io_ref/{fname}"})

    for i in range(args.n_msm_indices):
        cbor_hex = cbor_uint(i).hex()
        v = apply(args.aiken, args.blueprint, "msm_main", "msm_main", cbor_hex)
        fname = f"msm_main_{i:03d}.plutus"
        size = write_envelope(
            os.path.join(msm_dir, fname), v["compiledCode"],
            f"msm_main[{i}] (native MSM + replicateByte)")
        manifest["msm_main"].append(
            {"index": i, "hash": v["hash"], "size_bytes": size,
             "file": f"msm_main/{fname}"})

    with open(os.path.join(args.out, "blueprint-manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"applied {args.n_io_ref} io_ref + {args.n_msm_indices} msm_main "
          f"instances into {args.out}")


if __name__ == "__main__":
    main()
