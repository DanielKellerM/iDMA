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
- **Step 4** ⏳ end-to-end single-tile transpose verification. IN PROGRESS:
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
  hand-built multi-burst jobs (Step 5+). Decide explicitly at Step 4.
- **G4 — data-plane splice pending:** engine instantiation, `clear_i` pulse,
  `strb_o→wstrb`, per-transfer `decouple_rw`, last-response-on-write, busy
  aggregation. None may be silently skipped (Steps 2–4).
- **G5 — `transp_mode == 2'b11` unguarded** (→ E=8, invalid geometry). Add an
  assertion (engine or legalizer) `transp_mode != 2'b11 when transpose_en`, or
  document the reserved encoding. Address when wiring the engine.
- **G6 — frontends not wired.** Transpose is reachable ONLY via the backend-TB
  `opt` drive, never from reg/desc64/inst64. Acceptable while the goal is
  backend-TB verification. Plan §2 lists insertion points; includes the M/N
  derivation obligation (esp. desc64) and the driver-side stride program.
- **G7 — backend_synth wrappers** assign `idma_req.opt` field-by-field with no
  `'0` base and omit the 4 fields (latent X if a synth wrapper is simulated;
  not in the sim compile path today). Fix in the synth-wrapper template.

See `doc/transpose-engine-routing-plan.md` for the full routing/signaling design.
