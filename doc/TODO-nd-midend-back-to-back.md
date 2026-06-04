# Back-to-back ND transfers — root cause was the TB handshake, NOT a midend bug

**Status:** RESOLVED. The reported "idma_nd_midend back-to-back stale-address
corruption" was reproduced, root-caused, fixed, and regressed. The fix is in the
**testbench handshake**, not the shared `idma_nd_midend.sv` RTL — the midend is
correct for protocol-compliant producers.

## What was reported
A gap-closure agent extended `tb_idma_transpose_nd` to two back-to-back ND
transposes and saw the second transpose land at the wrong destination / read the
wrong source bytes, with a trace showing `stride_sel_q=0` / a stale `src_addr_q`
at the second request. It attributed this to `idma_nd_midend`.

## What actually happens (reproduced both ways)
- `test/tb_idma_transpose_b2b.sv` (two transposes to **different** dst bases)
  **FAILS** (xfer 2's dst stays the 0xCC sentinel, 48 mismatches) when the driver
  holds `nd_req_valid` one cycle past `nd_req_ready`, and **PASSES** when the
  driver drops `nd_req_valid` the cycle the accept is seen.
- `test/midend/tb_idma_nd_midend_b2b.sv` drives the midend directly (with
  backpressure) and golden-checks the burst-address sequence: back-to-back AND
  gapped transfers each walk from their own base — **PASS**. The midend reloads
  correctly for compliant driving.
- The canonical ND driver `idma_test::idma_nd_driver::launch_nd_tf`
  (`test/idma_test.sv:881-895`) drops `req_valid` the cycle `req_ready` is seen —
  i.e. it is compliant, which is why the stock `tb_idma_nd_midend` never hit this.

## Root cause
`burst_req_valid_o = nd_req_valid_i & !zero` (`idma_nd_midend.sv:98`): the midend
keeps issuing bursts while `nd_req_valid_i` is high. The ND request is *accepted*
on its last burst (`nd_req_ready_o` pulses), but if the producer holds the SAME
request valid for one more cycle, the midend begins a **spurious re-walk** of it.
If the producer then drops valid mid-re-walk, the address state
(`stride_sel_q`/`src_addr_q`/`dst_addr_q`, `:233-235`) is frozen mid-walk
(`stride_sel_q != NumDim-1`), so the base-reload condition is not met for the
NEXT request → it walks from the stale pointer. The transpose testbenches
hand-rolled a handshake that held `nd_req_valid` one cycle past `nd_req_ready`
(an `@(posedge clk)` too many), triggering exactly this.

This is a producer-contract issue: **hold `nd_req_valid` until `nd_req_ready`, then
drop it (or present a new payload) the same cycle — do not hold a consumed request
valid.** The midend is protocol-correct; the hand-rolled TB handshake was not.

## Fix
- `test/tb_idma_transpose_nd.sv`: drop `nd_req_valid` the cycle `nd_req_ready` is
  seen (matches the canonical driver) — removes the spurious re-walk. Full
  aligned+edge matrix still PASSes.
- `test/tb_idma_transpose_b2b.sv` (new): end-to-end regression — two back-to-back
  transposes to different dst bases, both checked. Non-vacuous: it FAILS on the
  old non-compliant handshake.
- `test/midend/tb_idma_nd_midend_b2b.sv` (new): focused midend regression — a
  stream of back-to-back + gapped ND transfers with backpressure, golden-checking
  that each walks from its own base.

## Not changed (and why)
`idma_nd_midend.sv` is left as-is: it is correct under the standard producer
contract, and it is a shared module used by every ND transfer. A defensive
hardening (latch "request consumed" so a held-valid request is not re-walked, or
reload the base on the first burst of each request regardless of prior state)
would make it robust to non-compliant producers, but is a separate, blast-radius
change to be weighed on its own — it is NOT required to make back-to-back ND
transfers work, which they do with a compliant producer.
