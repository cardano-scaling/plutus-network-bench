//// io_ref — a trivial parameterised *withdraw* (stake) validator used purely to
//// induce phase-1 disk IO. It is compiled once and applied (`aiken blueprint
//// apply`) with N distinct ~16 KB `ByteArray` params => N distinct script hashes,
//// each a ~16 KB reference script. The worst-case tx does one withdraw-0 per
//// script via reference, forcing the node to read each ~16 KB script off disk
//// and run it (trivially).
////
//// The param MUST be observed or the optimiser drops it and the script shrinks.
//// `length_of_bytearray(tag) > 0` reads the whole constant and is always true
//// for a non-empty tag, but cannot be constant-folded before the tag is applied.

use aiken/builtin
use cardano/address.{Credential}
use cardano/transaction.{Transaction}

validator io_ref(tag: ByteArray) {
  withdraw(_redeemer: Data, _account: Credential, _self: Transaction) {
    builtin.length_of_bytearray(tag) > 0
  }

  // Trivial certificate handler so the script stake credential can be
  // registered/deregistered (registration of a script cred requires the script
  // to witness the certificate). Registration must stay cheap — not the withdraw
  // path — so this just succeeds.
  publish(_redeemer: Data, _certificate: Data, _self: Transaction) {
    True
  }
}
