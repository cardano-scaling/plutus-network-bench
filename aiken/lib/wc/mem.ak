//// Cheap, tunable ExMem filler (native replicateByte path).
////
//// `replicateByte(count, byte)` allocates a `count`-byte ByteString in one call.
//// Its ExMem cost is ~= count and its ExStep cost is ~= 180194 + 159·count, so
//// it has the best mem-per-step ratio of any builtin (~1/159). This is why the
//// tool assumes the 350-entry PlutusV3 cost model where replicateByte is priced:
//// filling the whole per-tx ExMem budget costs only a small slice of the ExStep
//// budget, leaving the rest for the MSM CPU dial. One tx can sit near BOTH the
//// mem and steps ceilings at once.
////
//// `fill(m)` runs M iterations, each replicating a `chunk`-byte blob whose fill
//// byte is perturbed by the loop index so successive calls are not
//// common-subexpressions and cannot be hoisted. It folds one byte of each blob
//// into an accumulator so the work is observed (not pruned). Calibration measures
//// the true (m)->(mem,steps) map; on-chain calculate-plutus-script-cost is
//// authoritative.

use aiken/builtin

/// Bytes replicated per iteration. 8192 is the maximum a single replicateByte
/// call may produce (larger errors at runtime / fails aiken's shrinker), and it
/// amortises the ~180k step intercept toward the ~1/159 mem/step ratio.
pub const chunk: Int = 8192

/// Fill memory with M replicateByte chunks; returns an Int witness so the caller
/// can fold it into the success gate and stop the optimiser eliminating the loop.
pub fn fill(m: Int) -> Int {
  fill_loop(m, 0)
}

fn fill_loop(m: Int, acc: Int) -> Int {
  if m <= 0 {
    acc
  } else {
    // fill byte varies with m so the call is not loop-invariant
    let blob = builtin.replicate_byte(chunk, m % 256)
    let witness = builtin.index_bytearray(blob, 0)
    fill_loop(m - 1, acc + witness)
  }
}
