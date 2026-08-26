//// Point sourcing + the CPU "pass" loop.
////
//// Points are NOT in the redeemer (that would waste the 16 KB tx budget). They
//// live in ~15 KB inline datums on-chain, attached to the worst-case tx as
//// cheap read-only reference inputs (~40 B each). This module reads those datums
//// and runs K passes of (uncompress ALL points -> MSM), varying the scalar by
//// the pass index so common-subexpression elimination cannot collapse the passes.

use aiken/builtin
use cardano/transaction.{InlineDatum, Input}
use wc/bls

/// A point datum is just a list of 48-byte compressed G1 points.
pub type PointDatum =
  List<ByteArray>

/// Collect every compressed point from the inline datums of the reference inputs.
/// Reference inputs that carry no inline datum (e.g. the io_ref reference-script
/// UTxOs) contribute nothing. We control every datum shape, so the `expect` is
/// safe: point-datum UTxOs decode as List<ByteArray>.
pub fn collect(reference_inputs: List<Input>) -> List<ByteArray> {
  when reference_inputs is {
    [] -> []
    [input, ..rest] -> {
      let here =
        when input.output.datum is {
          InlineDatum(d) -> {
            expect points: PointDatum = d
            points
          }
          _ -> []
        }
      list_concat(here, collect(rest))
    }
  }
}

fn list_concat(a: List<ByteArray>, b: List<ByteArray>) -> List<ByteArray> {
  when a is {
    [] -> b
    [x, ..xs] -> [x, ..list_concat(xs, b)]
  }
}

/// Run K passes. Each pass re-uncompresses ALL points and runs one MSM whose
/// scalars depend on (index, pass, point) so the pass cannot be hoisted or
/// deduplicated. Returns an Int witness (a byte of the final compressed MSM
/// result), which the validator folds into its success gate to force evaluation.
pub fn run_passes(points: List<ByteArray>, k: Int, index: Int) -> Int {
  passes_loop(points, k, index, 0)
}

fn passes_loop(points: List<ByteArray>, k: Int, index: Int, acc: Int) -> Int {
  if k <= 0 {
    acc
  } else {
    let witness = one_pass(points, index, k)
    passes_loop(points, k - 1, index, acc + witness)
  }
}

fn one_pass(points: List<ByteArray>, index: Int, pass: Int) -> Int {
  // re-decode every point on every pass (dominant per-point cost)
  let g1s = map_uncompress(points)
  // per-point, per-pass scalar; varies with `pass` => defeats CSE across passes
  let scalars = map_scalar(points, index, pass)
  // native multiScalarMul over all points
  let result = bls.msm(scalars, g1s)
  // compress forces the result to be evaluated (not pruned)
  builtin.index_bytearray(bls.compress(result), 0)
}

fn map_uncompress(points: List<ByteArray>) -> List<G1Element> {
  when points is {
    [] -> []
    [p, ..ps] -> [bls.uncompress(p), ..map_uncompress(ps)]
  }
}

fn map_scalar(points: List<ByteArray>, index: Int, pass: Int) -> List<Int> {
  when points is {
    [] -> []
    [p, ..ps] -> {
      // nonzero scalar derived from a byte of the point + index + pass
      let s = ( index + pass ) * 1000003 + builtin.index_bytearray(p, 0) + 1
      [s, ..map_scalar(ps, index, pass)]
    }
  }
}
