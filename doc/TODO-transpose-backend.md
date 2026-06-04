# Transpose backend bring-up — tracked gaps & step status

Goal: a working rw_axi iDMA with `idma_otf_transpose` routed end-to-end, verified
on the jobs infrastructure. Prototype in **generated** `target/rtl/` first;
templatize once verified. Cadence: route → verify (jobs) → 3-agent audit per step.
No workarounds; every gap below is tracked, not silently accepted.

## Step status
- **Step 0** ✅ baseline: `simple.txt`/`medium.txt` pass on stock rw_axi.
- **Step 1** ✅ control-plane plumbing: `{transpose_en, transp_mode, tensor_m,
  tensor_n}` added to `options_t` (typedef.svh) and threaded
  `req.opt → opt_tf → w_dp_req` (legalizer) → transport seam. Regression clean.
  3-agent audit: **PROCEED** (no correctness defect, no workaround). Prototype RTL
  committed + tracked (target/rtl/.gitignore un-ignores the rw_axi trio).
- **Step 2** ✅ spliced `idma_otf_transpose` into `idma_transport_layer_rw_axi`
  behind `EnableTranspose` (hardcoded 1 in the backend transport instance for the
  prototype), with a runtime `transpose_en` bypass + beat↔per-lane handshake
  adapter; engine added to Bender.yml. Regression `simple/medium/large` clean
  (engine present, copies bypass it). Commit `0c095ae`.
- **Step 3** (folded into Step 5) `strb_o → wstrb` AND into `mask_out`
  (idma_axi_write.sv) — only needed for PARTIAL tiles; full single tiles have
  `strb_o='1` so the existing `buffer_out_valid_i` gating suffices.
## 3-agent integration audit (verdict: single-tile PoC sound; multi-tile NOT)
The single-tile (NE×NE, aligned, int8) transpose is genuinely working and
NON-vacuously verified (3 independent negative controls each flip PASS→FAIL:
bypass, copy-expectation, redirected write). Build mechanism (split_rtl) sound;
copies regression-clean. BUT the auditors empirically showed (reusing the harness)
that the integration is **single-tile-only** because the legalizer feeds a LINEAR
row-major byte stream while the engine expects (col-tile,row-tile,row) tiled order
with no tiling address-gen:
- **B2** multi-tile (M or N > NE) → **silent data corruption** (8×8 → 62/64 wrong, B-response still arrives).
- **B3** partial/edge tiles & non-StrbWidth-multiple lengths → **deadlock** (strb_o not reconciled with axi_write `mask_out`; `&buffer_out_valid` stalls on partial final beat).

Real fixes done (NOT assertions): forced `decouple_rw|aw` on transpose_en in the
legalizer (engine ping-pong needs full-duplex); transpose test FAIL is now `$fatal`.
Workaround-assertions were explicitly rejected — the real fix is the address plane.

## UPDATE — multi-tile address plane IMPLEMENTED + verified (aligned dims)
`test/tb_idma_transpose_nd.sv`: idma_nd_midend (NumDim=4, **incremental** transposed
strides) → idma_backend_rw_axi (engine) → axi_sim_mem. The ND midend generates the
tiled read order + transposed-placed writes the engine needs; the engine+midend
compose with no deadlock. PASS (no assertions, real data check vs golden):
int8 8×8/16×16/16×8/8×16/32×24, fp16 8×8/8×16. Single-tile + copies still green.
KEY FIX: ND strides are INCREMENTAL deltas (added on dim roll-over, inner dims
reset), NOT absolute — transpose needs negative jumps. Formulas (aligned M=YT·NE,
N=NT·NE): src[N·E, N·E, NE·E−(M−1)·N·E]; dst[M·E, NE·E−(NE−1)·M·E, M·E−(YT−1)·NE·E].
Commit 8fa7247.

## UPDATE — edge tiles IMPLEMENTED + verified (M or N not a multiple of NE)
`strb_o → wstrb` is now wired through the shared `idma_axi_write.sv` (new
`mask_ext_i` ANDed into `mask_out`, new strobe-independent `w_beat_done_o` to
retire all-padding beats) and the rw_axi transport (presence=all-ones, engine
strobe shifted in parallel as `mask_ext_shifted`, engine retired on `w_beat_done`).
KEY ADDRESS-PLANE FIX: `Aᵀ` uses a PADDED row pitch `MP·E = ceil(M/NE)·StrbWidth`
(not `M·E`) — the engine drains one beat per output row and the write path can't
coalesce a misaligned split beat, so every row must be StrbWidth-aligned. Source
pitch stays `N·E` (misaligned reads coalesce in the pre-engine buffer). Verified
NON-VACUOUSLY (data + padding-sentinel check; disabling the strobe clobbers the
padding → test fails): int8 6×8/8×6/6×6/5×7/10×6/13×19, fp16 5×5/7×3, fp32 9×5,
plus all aligned + copies + in-band single-tile. Negative control confirms the
strobe is load-bearing. Commit pending.

**GAP-4 discharged (liveness): `NumAxInFlight >= NE`.** The engine buffers a whole
NE-beat tile before its first write; the backend holds a transaction slot per
single-beat burst until B, so NE bursts sit read-done/write-pending. Below the
threshold (empirically NE−1) the write channel deadlocks. With runtime E, the
synth-time requirement is `NumAxInFlight >= StrbWidth` (E=1 worst case). TB
auto-sizes `NumAxInFlight = StrbWidth`; documented in routing-plan §4.2.

B1 RESOLVED for reproducibility: the idma.mk build-flow change (`-t split_rtl` on
the compile.tcl rule + idma_sim_tb_idma_{otf_transpose,transpose_nd} targets) is
committed on the `fix/rt-midend-choice-fifo-tests` branch (commit be94333) — it
was dependency-locked there (de194023 also edits idma.mk). Implication: the routed
transpose build flow now lives on that branch, so building transpose requires it
applied/merged alongside `explore/transpose-engine`.
REMAINING: templatize the generated-RTL edits into src/backend/tpl/*.tpl (final step).

**(superseded — aligned multi-tile now works) earlier note:** the address plane —
tiled strided source reads in (col-tile,row-tile,row) order + transposed-stride
destination writes (routing-plan §4, NumDim=4 ND program; needs the ND midend in
the backend flow or strided legalizer addressing) + `strb_o→wstrb` edge masking
(idma_axi_write `mask_out`) + read padding to tile boundaries. This makes
multi-tile/edge actually work; single-tile is the verified subset.
Also: B1 idma.mk `-t split_rtl` still UNCOMMITTED (dependency-locked to rt) → fresh
`make` builds the bundle without routing — must be resolved for reproducibility.

- **Step 4** ✅ single-tile only. IN PROGRESS toward multi-tile:
  `launch_tf` extended with defaulted transpose params (idma_test.sv) — compiles,
  regression clean. REMAINING: in the rw_axi TB module of `tb_idma_generated.sv`
  (lines ~336-630; init_mem/compare_mem from `test/include/tb_tasks.svh`), add a
  single-tile transpose job — `init_mem` a known NE×NE src tile, `drv.launch_tf`
  with `transpose_en=1, transp_mode=0, tensor_m=tensor_n=StrbWidth,
  length=StrbWidth²`, write the transpose golden into `model.mem[dst]`
  (`out[c*NE+r]=in[r*NE+c]`), then `compare_mem`. Then 3-agent audit.
- **Step 5+** ⏳ multi-tile via ND descriptor (NumDim=4 strides); partial-tile.
- **Final** ⏳ port all generated-RTL edits back into the Mako templates.

## Tracked gaps (from Step 1 3-agent audit)
- **B1 — regen wipes the prototype.** The 4 fields live only in generated
  `idma_backend_rw_axi.sv` / `idma_legalizer_rw_axi.sv`; the templates
  (`src/backend/tpl/idma_backend.sv.tpl`, `idma_legalizer.sv.tpl`) do NOT have
  them. `make idma_hw_all` would silently revert the routing.
  Mitigation: prototype RTL is committed (survives `git clean`); **do NOT run
  `make idma_hw_all` during bring-up.** Closed when templatized (Final step).
- **G1 — bypass-legalizer w_dp_req literal** (`idma_backend_rw_axi.sv:401`,
  `gen_no_hw_legalizer`) lacked the 4 fields → X under `HardwareLegalizer=0`.
  ✅ **FIXED** (now driven from `idma_req_i.opt`). Carry into the template.
- **G2 — routing proven by construction only.** Fields are tied to 0 in the one
  active path, so regression cannot tell correctly-routed from stuck/swapped.
  Discharge at Step 4 (engine consumes them; transposed compare_mem proves
  un-corrupted arrival).
- **G3 — address plane (the crux) not testable by flat 1D backend jobs.** The
  backend TB has no ND midend; `jobs/backend_rw_axi/*.txt` are 1D triples. A
  single `NE×NE` tile transpose (contiguous src→dst) IS backend-verifiable
  (Step 4); multi-tile needs the NumDim=4 stride program → ND-midend in the TB or
  hand-built multi-burst jobs (Step 5+). ✅ discharged via `tb_idma_transpose_nd`.
  NOTE (GAP-1, audit C): the stock jobs golden `idma_model.transfer()`
  (`test/idma_test.sv`) is a LINEAR-COPY model — it takes only length/src/dst/
  protocol/burst and **structurally cannot represent a transpose**. So transpose
  is verified with transpose-specific goldens (in-band `+transpose_test` single
  tile; `tb_idma_transpose_nd` multi-tile/edge), reusing the jobs *driver* + AXI
  sim-mem plumbing, NOT the stock job-file + model-golden pipeline. Honest scope:
  "verified on the sim infrastructure with a transpose golden", not "via stock
  job files".
- **G4 — data-plane splice pending:** engine instantiation, `clear_i` pulse,
  `strb_o→wstrb`, per-transfer `decouple_rw`, last-response-on-write, busy
  aggregation. None may be silently skipped (Steps 2–4).
- **G5 — `transp_mode == 2'b11` (E=8) RESERVED.** ✅ HARDENED. Valid iff
  `E ≤ StrbWidth` (`mode ≤ LaneW`; mode 3 only meaningful for `StrbWidth ≥ 8`).
  For `mode > LaneW` the 32-bit **unsigned** `LaneW−mode` WRAPS (not a negative
  shift — the engine header/this note are corrected) → silently-wrong geometry +
  out-of-range readout (X). FIX: the engine saturates the effective mode at LaneW
  (`eff_mode`, `idma_otf_transpose.sv`) so an out-of-contract mode degrades to a
  defined `NE=1` pass-through instead of X. This is defensive RTL (handles the
  whole input space), NOT a guard-assertion-as-substitute. `eff_mode == mode` for
  every valid mode (matrix re-verified). The descriptor/CSR layer should still
  clamp/reject `mode > LaneW` once a frontend exposes the field.
- **G8 — all-padding-row `AW`s to out-of-range addresses.** ✅ contract now TESTED.
  For `N % NE != 0` the engine drains `NT·NE` rows; the all-padding rows
  `[N, NT·NE)` issue real `AW`s with `wstrb = 0`. A permissive slave writes
  nothing; a strict slave may `DECERR` on the address decode. `dst` must be
  allocated for the full `NT·NE × MP` extent (hard requirement, routing-plan §4.2).
  `tb_idma_transpose_nd` now asserts every `AW` lands within `[db, db+NT·NE·MP·EB)`
  (non-vacuous — a real-region bound trips on the row-6 padding AW). Future
  hardening: suppress `AW` issuance for all-padding rows so under-allocation is safe.
- **G6 — frontends not wired.** Transpose is reachable ONLY via the backend-TB
  `opt` drive, never from reg/desc64/inst64. Acceptable while the goal is
  backend-TB verification. Plan §2 lists insertion points; includes the M/N
  derivation obligation (esp. desc64) and the driver-side stride program.
- **G7 — backend_synth wrappers** assign `idma_req.opt` field-by-field with no
  `'0` base and omit the 4 fields (latent X if a synth wrapper is simulated;
  not in the sim compile path today). Fix in the synth-wrapper template.
- **G9 — regen drops the AXI-write mask ports → latent X on every wstrb.** The
  shared `idma_axi_write` now has required `mask_ext_i`/`w_beat_done_o`, connected
  only in the hand-patched generated transports. The YAML `write_template`
  (`src/db/idma_axi.yml`) lacked them, so `make idma_hw_all` regenerated transports
  that leave `mask_ext_i` floating (`'z` AND into `mask_out` → `wstrb = 'x` on EVERY
  AXI write, transpose or not; Questa flags missing ports as warnings, not errors).
  ✅ MITIGATED: the `write_template` now emits `.mask_ext_i('1)` / `.w_beat_done_o()`
  tie-offs so regen is X-safe for all variants. (The rw_axi transpose seam override
  is still hand-patched until full templatization — Final step.)

## Gap-closure multi-agent run (outcomes)
Seven verification-flagged gaps probed in isolated builds (repo untouched):
- **CLOSED-BENIGN/NOT-A-RISK:** geometry fuzz (~1996 random+exhaustive-boundary
  geometries, 0 breaks); ping-pong engine (back-to-back self-reset, degenerate
  single-tile, mid-transfer clear/abort, max skew — all correct via DPI golden);
  EB=2/4 liveness (boundary `NE−1` as predicted, always a loud watchdog) + EB=2/4
  strobed-lane X (0 leaks); `MaskInvalidData=0` (X only on AXI-legal non-strobed
  lanes, memory never corrupted — recommend `MaskInvalidData=1` for transpose
  configs to keep the bus X-free); synth/formal = maturity gap, not a bug (design
  already cut the worst comb path with the registered output stage).
- **FIXED THIS STEP:** G5 (mode saturation), G8 (AW-bounds test), G9 (YAML regen
  X-safety), engine-header comment correction.
- **RESOLVED — was a TB handshake bug, not a midend RTL bug:** the reported
  `idma_nd_midend` back-to-back "stale-address corruption" root-caused to the
  transpose testbenches holding `nd_req_valid` one cycle past `nd_req_ready`,
  which makes the midend spuriously re-walk a consumed request and leaves stale
  address state for the next one. Fixed the handshake in `tb_idma_transpose_nd`
  (drop valid on accept, like the canonical driver); the midend is correct for
  protocol-compliant producers. Added regressions `test/tb_idma_transpose_b2b.sv`
  (two end-to-end transposes to distinct dst) and `test/midend/tb_idma_nd_midend_b2b.sv`
  (midend burst-address sequence under backpressure). See
  `doc/TODO-nd-midend-back-to-back.md`.

See `doc/transpose-engine-routing-plan.md` for the full routing/signaling design.
