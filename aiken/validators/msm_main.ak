//// msm_main — the worst-case CPU/mem *withdraw* (stake) validator.
////
//// Parameterised by `index: Int` so that applying distinct indices yields
//// distinct script hashes => distinct registered stake credentials => many
//// parallel worst-case txs with no in-block reward-account contention.
////
//// Redeemer `{ k, m, nonce }` (kept tiny — the bulk random points come from
//// reference-input datums, not here):
////   k     — CPU dial: number of (uncompress-all-points -> MSM) passes.
////   m     — MEM dial: number of replicateByte filler chunks.
////   nonce — folded into the success gate so otherwise-identical redeemers
////           produce distinct tx bytes/witnesses when building a corpus.
////
//// Handler: K passes of BLS work, then M mem chunks, then succeed. The final
//// Bool depends on BOTH witnesses (and the nonce) so neither the CPU loop nor
//// the mem loop can be pruned as dead code. Both witnesses are small integers
//// at runtime, so the gate is always satisfied.

use aiken/builtin
use cardano/address.{Credential}
use cardano/transaction.{Transaction}
use wc/mem
use wc/points

pub type Redeemer {
  k: Int,
  m: Int,
  nonce: ByteArray,
}

validator msm_main(index: Int) {
  withdraw(redeemer: Redeemer, _account: Credential, self: Transaction) {
    let Redeemer { k, m, nonce } = redeemer

    // CPU: read points from reference-input datums, run K MSM passes.
    let pts = points.collect(self.reference_inputs)
    let cpu_witness = points.run_passes(pts, k, index)

    // MEM: M replicateByte filler chunks.
    let mem_witness = mem.fill(m)

    // Salt from the nonce so distinct nonces => distinct compiled redeemer bytes,
    // and so the gate references the nonce (kept live). Always satisfiable.
    let salt =
      if builtin.length_of_bytearray(nonce) > 0 {
        builtin.index_bytearray(nonce, 0)
      } else {
        0
      }

    // Gate depends on all three => nothing above can be eliminated. Runtime
    // values are small non-negative ints, so the sum is always < the bound.
    cpu_witness + mem_witness + salt < 4611686018427387904
  }

  // Trivial certificate handler so this script stake credential can be
  // registered (deposit-registration of a script cred requires the script to
  // witness the cert). Kept cheap — the heavy work is only on `withdraw`.
  publish(_redeemer: Data, _certificate: Data, _self: Transaction) {
    True
  }
}
