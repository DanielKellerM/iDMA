# idma_nd_midend — back-to-back ND transfer stale-address corruption

**Status:** flagged, NOT fixed. Pre-existing defect in the shared `src/midend/idma_nd_midend.sv`
(not introduced by the transpose work). Surfaced by the transpose gap-closure
multi-agent run; RTL-consistent, but fix + a dedicated regression are a separate
task because the module is used by every ND transfer (blast radius).

## Symptom
The **second** of two back-to-back ND transfers reads/writes the wrong bytes: the
second transfer reuses the address pointers left over from the first instead of
reloading its own `burst_req.src_addr` / `burst_req.dst_addr`. Observed (agent
repro, two back-to-back ND transposes via an extended `tb_idma_transpose_nd`):
the second transfer's data is off by a constant `src`/`dst` base delta (e.g. T2
`src_addr_q=0x01107` instead of `0x01000` for an 8×8; reproduced for 8×8, 16×16,
13×19) and the write address can **underflow below the dst base** (`AW addr=0x03ff8`
for `dst=0x04000`). Affects any two back-to-back ND transfers — transpose is just
the natural trigger (the transpose flow drives the ND midend directly).

## Root cause (RTL)
`idma_nd_midend.sv`:
- `src_addr_calc` / `dst_addr_calc` (`:164-186`) reload the base address from
  `nd_req_i.burst_req.{src,dst}_addr` **only** when `stride_sel_q == NumDim-1`;
  otherwise they accumulate `+= d_req[stride_sel_q].strides` (or hold).
- `stride_sel_q`, `src_addr_q`, `dst_addr_q` (`FFL`, `:233-235`) are clock-enabled
  by `nd_req_valid_i` and **freeze (not reset) between transfers**.
- `stride_sel_q = popcount(stage_clear)`. At the first beat of a *new* request it
  is not guaranteed to be `NumDim-1`, so the base reload is skipped and the new
  transfer keeps walking from the previous transfer's stale pointer.

The base-reload condition (`stride_sel_q == NumDim-1`) is a proxy for "transfer
boundary" that holds for a single transfer from reset (the reset value is
`NumDim-1`) and at a transfer's own last burst, but is **not** a reliable
"first burst of a new request" signal under continuous/back-to-back `nd_req_valid`.

## Proposed fix (for a separate, verified change)
Reload `src_addr_q`/`dst_addr_q` (and reset `stride_sel_q`) on the **first burst of
each new request** rather than gating on `stride_sel_q == NumDim-1`. E.g. derive a
per-transfer "first burst" flag from the `nd_req` handshake (`nd_req_ready_o` /
the transition into a new request) and use it to force the base reload, or reset
`stride_sel_q`/`src_addr_q`/`dst_addr_q` at the `nd_req_ready_o` handshake.
Add a back-to-back regression to `test/midend/tb_idma_nd_midend.sv` (two ND
requests with no idle gap; assert the second transfers the correct bytes and the
addresses never underflow the base). This is a root-cause fix, **not** a
workaround — do not "fix" it by mandating an idle gap between ND requests or by
resetting only on the transpose path.

## Impact on the transpose work
None for what is verified today: every transpose test issues a **single** ND
request per simulation, so the stale-address path is not exercised. A real
deployment that streams back-to-back ND transposes (or any back-to-back ND
copies) would hit it. Flag here so it is fixed in the midend before that.
