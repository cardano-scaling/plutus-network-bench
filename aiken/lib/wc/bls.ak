//// BLS12-381 G1 primitives for the worst-case phase-2 CPU dial.
////
//// The CPU dial is the native `bls12_381_G1_multiScalarMul` builtin: given a
//// list of scalars and a list of G1 points it returns sum_i scalars[i]·pts[i]
//// in one call. This is the real, priced worst case on a network carrying the
//// 350-entry PlutusV3 cost model (PV12+). All builtin names are localised in
//// this module so there is a single swap point.

use aiken/builtin

/// Decode a compressed 48-byte G1 point. Constant CPU cost (~52.9M ExSteps/pt),
/// the dominant per-point cost. Random points => real decode work, no shortcut.
pub fn uncompress(compressed: ByteArray) -> G1Element {
  builtin.bls12_381_g1_uncompress(compressed)
}

/// Compress a G1 point back to 48 bytes. Used to *force evaluation* of the
/// result so the optimiser cannot prune the work as dead code.
pub fn compress(p: G1Element) -> ByteArray {
  builtin.bls12_381_g1_compress(p)
}

/// Native multi-scalar multiplication: sum_i scalars[i]·points[i].
/// Cost is linear in the number of points (intercept ~321.8M, slope ~25.1M),
/// which combined with the per-point uncompress (~52.9M) is the worst-case
/// per-point CPU. Requires the pinned aiken fork exposing this builtin.
pub fn msm(scalars: List<Int>, points: List<G1Element>) -> G1Element {
  builtin.bls12_381_g1_multi_scalar_mul(scalars, points)
}
