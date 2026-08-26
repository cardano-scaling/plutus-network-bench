#!/usr/bin/env python3
"""Generate big inline-datum files of compressed BLS12-381 G1 points.

Each datum is a `List<ByteArray>` of 48-byte compressed G1 points, written as
cardano-cli detailed-schema JSON ({"list":[{"bytes":"..."},...]}). These become
the ~15 KB inline-datum UTxOs that the worst-case transaction attaches as
read-only reference inputs; msm_main uncompresses them and runs the MSM.

Points are produced by evaluating `bls12_381_G1_compress(hashToGroup(msg, dst))`
with `aiken uplc eval`, which guarantees genuinely-on-curve points (so
uncompress does real work). A pool of `points_per_datum` unique points is
generated once and reused across the N datum files: identical datum bytes still
occupy distinct UTxOs (distinct disk objects) and still cost a full uncompress
per occurrence, so both the IO and CPU axes are preserved.

Outputs, under --out-dir:
    datum_%03d.json          detailed-schema inline datum
    datums.manifest.json     [{index, file, n_points, bytes}]
"""

import argparse
import json
import os
import re
import subprocess
import sys

_HEXRE = re.compile(r"#([0-9a-fA-F]+)")


def eval_point(aiken: str, dst_hex: str, msg_hex: str) -> str:
    prog = (
        "(program 1.0.0\n"
        "  [ (builtin bls12_381_G1_compress)\n"
        f"    [ [ (builtin bls12_381_G1_hashToGroup) (con bytestring #{msg_hex}) ]"
        f" (con bytestring #{dst_hex}) ] ])\n"
    )
    proc = subprocess.run(
        [aiken, "uplc", "eval", "/dev/stdin"],
        input=prog, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout + proc.stderr)
        raise SystemExit("aiken uplc eval failed")
    result = json.loads(proc.stdout)["result"]
    m = _HEXRE.search(result)
    if not m:
        raise SystemExit(f"could not parse point from: {result!r}")
    hx = m.group(1)
    if len(hx) != 96:
        raise SystemExit(f"expected 48-byte (96 hex) point, got {len(hx)} hex")
    return hx


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--n-datums", type=int, default=8)
    ap.add_argument("--points-per-datum", type=int, default=56)
    ap.add_argument("--namespace", default="plutus-bench")
    ap.add_argument("--aiken", default=os.environ.get("AIKEN", "aiken"))
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    dst_hex = f"{args.namespace}-DST".encode().hex()

    # generate the shared pool of unique points
    pool = []
    for i in range(args.points_per_datum):
        msg_hex = f"{args.namespace}-pt-{i}".encode().hex()
        pool.append(eval_point(args.aiken, dst_hex, msg_hex))
        if (i + 1) % 10 == 0 or i + 1 == args.points_per_datum:
            sys.stderr.write(f"  points {i + 1}/{args.points_per_datum}\n")

    datum = {"list": [{"bytes": p} for p in pool]}
    datum_bytes = len(json.dumps(datum))

    manifest = []
    for d in range(args.n_datums):
        fname = f"datum_{d:03d}.json"
        with open(os.path.join(args.out_dir, fname), "w") as f:
            json.dump(datum, f)
        manifest.append(
            {"index": d, "file": fname,
             "n_points": len(pool), "bytes": datum_bytes})

    with open(os.path.join(args.out_dir, "datums.manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"wrote {args.n_datums} datum files of {len(pool)} points "
          f"(~{datum_bytes} B each) into {args.out_dir}")


if __name__ == "__main__":
    main()
