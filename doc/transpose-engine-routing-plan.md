# Transpose Engine — Design Routing & Signaling Plan

Status: design doc (no frontend/midend RTL yet). The transpose **engine**
(`src/backend/idma_otf_transpose.sv`) is implemented and standalone-verified
(full-duplex ping-pong, runtime int8/fp16/fp32, DPI golden). This document plans
how it is **routed through the whole design** — frontend → midend → legalizer →
backend → transport → engine, and the response path back.

It is grounded in a re-read of the viDMA fork (the prior OTF work) and is
deliberately **adversarial about viDMA's signaling approach** (§3). Anchors are
`file:line` against this repo unless prefixed `vidma:`
(`/home/dankeller/Projects/pulp_rs/vidma_rtl/src/`).

---

## 1. Three-plane framing

The engine reorders the **data stream** only — it has **no address ports**.
Routing therefore splits into three planes of very uneven difficulty:

| Plane | Difficulty | What it needs |
|-------|-----------|---------------|
| **Control** | easy | deliver `{transpose_en, E, M, N}` per transfer to the engine *and* the address generator |
| **Data** | mostly done | splice the engine `valid/ready/strb_o` into the transport `buffer_out → write-shifter` seam behind `EnableTranspose`; engine self-drains |
| **Address** | the crux | generate read + write address streams so the bytes land transposed, with `strb_o` masking edge tiles |

The central insight that makes the address plane tractable:

> **The engine transposes *inside* each `NE×NE` tile. Read and write therefore
> walk the *same* tile-visitation order — they differ only in stride
> *magnitude*, not iteration *order*.** A full matrix transpose is expressed as
> an ND transfer whose `dst_strides` encode the N×M output pitch while
> `src_strides` encode the M×N input pitch, over one shared iteration space.

This matters because the ND midend (`src/midend/idma_nd_midend.sv`) advances
`src_addr` and `dst_addr` from a **single shared iteration counter**
(`stride_sel_q`, `burst_sent_q`, `:153-186`) — it *cannot* make read and write
visit a different order, but it *can* give them independent strides. The
engine-internal transpose is exactly what lets us live within that constraint.

```
        CONTROL: {transpose_en, E, M, N} as typed, request-scoped idma_req_t.opt fields
        ADDRESS: NumDim=4 ND descriptor; src_strides (M×N) + transposed dst_strides (N×M)
  ┌──────────┐  idma_nd_req_t   ┌─────────┐  idma_req_t   ┌───────────┐
  │ FRONTEND │ ───────────────► │ ND      │ ────────────► │ LEGALIZER │
  │ reg/desc │ burst_req.opt.*  │ MIDEND  │ src_addr /    │ opt_tf_q  │
  │ /inst64  │ + d_req[].reps,  │ shared  │ dst_addr      │ r_tf_q    │ AR/AW
  │          │ src/dst_strides  │ counter │ (per-dim      │ w_tf_q    ├──────►
  └──────────┘                  │ walks   │  strides)     └─────┬─────┘ meta
       ▲                        │ both    │                    │ r_dp_req / w_dp_req
       │ done_id (idma_rsp_t)   │ ptrs    │                    │ (+ transp_*)
       │  on WRITE of last tile └────┬────┘                    ▼
       │                            │ nd_rsp_o (on .last)  ┌────────────────────┐
       │                            ▼                      │   BACKEND TOP       │
       └────────────────────────────────────────────────  │ legalizer↔transport │
                                                           └─────────┬───────────┘
                                                                     │ w_dp_req.transp_*, shift
   DATA: ┌────────┐ data ┌───────────┐ data ┌──────────┐ data ┌──────────┐
         │ buffer │ ───► │ TRANSPOSE │ ───► │ write     │ ───► │ axi_write│ ─► W.strb =
         │ _out   │ ◄─── │ ENGINE    │ ◄─── │ barrel    │strb_o│ mask_out │   align_mask
         └────────┘ rdy  │(EnTranspose)│rdy │ shift     │  &&  │ & strb   │   & engine_strb
                         └───────────┘      └──────────┘      └──────────┘
         strb_o ─────────────────(shift by w_dp_req.shift)──────────► (new AND term)
```

Response semantics are unchanged: **one transfer = one `done_id`** — but it must
fire on **write** completion of the last tile (§5.3).

---

## 2. Control plane — which fields travel where

Four control items: `transpose_en` (1b), `transp_mode`/E (2b), `M` (12b, rows in
elements), `N` (12b, cols in elements). Decision: carry the small per-transfer
items as **typed fields in `options_t`**; `M`/`N` ride the ND geometry but are
*also* surfaced as explicit `opt` fields because the engine needs them at the
transport seam.

### 2.1 The struct of record

`IDMA_TYPEDEF_OPTIONS_T(options_t, axi_id_t)` (`src/include/idma/typedef.svh:21-30`)
is the request-scoped options struct embedded in every `idma_req_t` (`:37-44`,
the `opt` field). Add:

```systemverilog
logic        transpose_en;   // engine on/off for this transfer
logic [1:0]  transp_mode;    // E selector: 00=1B, 01=2B, 10=4B
logic [11:0] tensor_m;       // rows in ELEMENTS
logic [11:0] tensor_n;       // cols in ELEMENTS
```

It rides through the ND midend bypass for free — `idma_nd_midend.sv:194` copies
`burst_req_o = nd_req_i.burst_req` wholesale, overwriting only `src_addr`/
`dst_addr`/`opt.last` (`:196-198`) — and through every request FIFO/fork. It is
then mirrored into the legalizer's mutable options and into `w_dp_req_t` to reach
the engine (§5).

### 2.2 Per-frontend insertion of `transpose_en` + `E`

| Frontend | Carrier | Anchor |
|---|---|---|
| **reg** | new `conf` CSR bits (bits 0:16 used; **17:31 free**): `transpose_en`=17, `transp_mode`=19:18 | fields `target/rtl/idma_reg64_2d.hjson:31-66`; template `src/frontend/reg/tpl/idma_reg.hjson.tpl:23-64`; wire in `proc_hw_req_conv`, `src/frontend/reg/tpl/idma_reg.sv.tpl` (~124-141) |
| **desc64** | descriptor `flags[31:24]` reserved → `flags[24]=transpose_en`, `flags[26:25]=transp_mode` | `src/frontend/desc64/idma_desc64_top.sv:114-115`; assign in reshaper opt block `src/frontend/desc64/idma_desc64_reshaper.sv:27-60` |
| **inst64** | new instruction `DMTRANSP` in the `casez (acc_req_i.data_op)`, **request-scoped** write to `burst_req.opt.transpose_en/.transp_mode` (contrast viDMA's sticky `otf_opcode_q`) | casez `src/frontend/inst64/idma_inst64_top.sv:386`; opt defaults `:343-364` |

### 2.3 Matrix dims M, N

M, N are **redundant with the ND geometry** (they equal the descriptor's
element extents — see §4) but the engine still needs them as explicit ports
(`tensor_size_m_i`/`tensor_size_n_i`) at the transport seam to drive its tile
counters and edge `strb_o`. Decision: surface them as explicit `opt.tensor_m`/
`opt.tensor_n` (24 b of flops), forwarded to `w_dp_req`, rather than
reconstructing them from byte counts at the seam.

- **reg / inst64**: drivers already program the dims/strides CSRs (length, reps,
  strides); add two small writes for `tensor_m/tensor_n` (or compute them in the
  reg HWIF from `length`/`reps`).
- **desc64**: `flags` has no spare 24-bit budget — desc64 should **derive** M/N
  from `length`/`reps`/strides in the reshaper rather than carry them literally.

---

## 3. Signaling decision — adversarial critique of viDMA, chosen alternative

### 3.1 What viDMA does

viDMA signals OTF compute with a **single sticky 8-bit `otf_opcode_q` register**,
written by a custom RISC-V instruction `DMOPC` (`vidma:idma_inst64_top.sv:571-602`,
`otf_opcode_q <= acc_req_i.data_arga[7:0]`, reset to passthrough `0x08`), passed
as a **side-band port** `otf_opcode_i` into the backend
(`vidma:idma_backend_rw_axi.sv:89`) — parallel to `idma_req_i`, bypassing the
request descriptor and the ND midend — latched per-transfer into
`opt_tf_q.otf_opcode` at legalizer refill (`vidma:idma_legalizer_rw_axi.sv:403-442`),
copied into `r_dp_req`/`w_dp_req.otf_opcode`, and consumed in the transport layer
via a **same-cycle "effective opcode" bypass** plus MX/FP **drain FSMs**
(`vidma:idma_transport_layer_rw_axi.sv:231-243`). Element sizes and the write
length are **derived from the opcode** by hard-coded tables
(`vidma:vidma_otf_pkg.sv`: `otf_element_sizes`, `otf_write_length = r_len/in*out`).

### 3.2 Critique — reject this model for transpose

1. **Sticky + global desyncs config from the transfer.** One register feeds every
   backend channel, but each channel has its own `nd_req` FIFO. `DMOPC` then
   `DMCPY` is non-atomic; an interrupt or a second `DMOPC` re-tags a pending
   transfer. The legalizer accept-time latch only *partially* masks this. For a
   transpose interleaved with plain copies this is a correctness hazard.
2. **8 bits cannot carry geometry.** The opcode is a pure op selector with
   hard-coded element sizes and a scalar length ratio. Transpose needs runtime
   `E ∈ {1,2,4}` plus 12-bit `M` and `N` (≥26 b). Extending viDMA means adding
   sticky `DMSIZE`-class registers — reintroducing hazard (1) plus multi-register
   atomicity.
3. **viDMA never remaps addresses — the disqualifying gap.** Its `w_addr` is
   monotonic; `otf_write_length`/`otf_coordinated_r_bytes` assume a *scalar
   length ratio on a linear stream* (`vidma:vidma_otf_pkg.sv`). Transpose is 1:1
   in bytes (ratio = identity) but needs a **tile-strided write address program**.
   The opcode/ratio model has no concept of it.
4. **Transport bloat is avoidable.** The same-cycle effective-opcode bypass is a
   timing smell; the MX/FP drain FSMs and expansion bypass are viDMA-op-specific.
   The transpose engine **self-drains via `exec_done`**, so integration needs
   zero drain FSMs, zero opcode mux, zero bypass.

### 3.3 Chosen alternative

**Carry `{transpose_en, transp_mode, tensor_m, tensor_n}` as typed,
request-scoped `idma_req_t.opt` fields, and express the address remap as an ND
transfer (transposed `dst_strides`), not a legalizer ratio function.**

| Layer | viDMA cost | Chosen cost | Why better |
|---|---|---|---|
| frontend | sticky `otf_opcode_q` + `DMOPC` | a few `opt` assigns | request-scoped; no cross-transfer leak |
| port | side-band `otf_opcode_i` hand-synced | none — rides `opt` through existing FIFOs/forks | no global wire, no manual sync |
| midend | bypassed | bypassed; **remap reuses `src/dst_strides`** | remap is native, not bolted on |
| legalizer | latch + `otf_write_length` ratio | latch + forward; **no ratio math** (W==R) | identity length is correct as-is |
| transport | effective-opcode bypass + drain FSMs | splice `valid/ready/strb_o`, pulse `clear_i` | engine self-drains |

**Decision: adopt it.** Strictly cheaper and strictly more composable than the
viDMA side-band.

---

## 4. Address plane — the corrected model

### 4.1 Routing model

Both `AR` and `AW` walk the **same** tile order (matching the engine's identical
fill/drain walkers, `idma_otf_transpose.sv:172-201`). The transpose lives
**entirely inside the engine** (intra-tile element swap, the readout at `:224-231`).
The destination **strides** encode the N×M output pitch. This is realizable with
the ND midend's existing logic **unchanged** — it already advances independent
`src_addr`/`dst_addr` per dimension (`:169` src, `:181` dst) over one shared
iteration order. The only cost is a **NumDim bump** (synth-time config), not new
midend logic.

> ⚠️ This corrects an earlier framing that described "transposed *write
> sequence* / scattered tiles." The midend **cannot** reorder tiles between read
> and write (single `stride_sel_q`/`burst_sent_q`, `:153-186`). It does not need
> to: same tile order, **transposed dst strides**, engine does the element swap.

### 4.2 The descriptor (NumDim = 4) and the exact stride program

Let `E` = element bytes, `NE = StrbWidth/E` (tile side in elements,
= beat in elements), `SW = StrbWidth` (bytes/beat), `YT = ceil(M/NE)`,
`NT = ceil(N/NE)`. Iteration order (outer→inner): `nt` (col-tile) → `rt`
(row-tile) → `j` (row/beat within tile). Each 1D run = one tile-row = `NE`
elements = `SW` bytes, contiguous on **both** src and dst.

Source `A` is M×N row-major at `src`; transposed `Aᵀ` is N×M row-major at `dst`.
For iteration `(nt, rt, j)`:

```
src_addr = src + j·(N·E)     + rt·(NE·N·E) + nt·(NE·E)     // reads A[rt·NE+j][nt·NE .. +NE)
dst_addr = dst + j·(M·E)     + rt·(NE·E)   + nt·(NE·M·E)    // writes Aᵀ[nt·NE+j][rt·NE .. +NE)
```

As an `idma_nd_req_t` (`typedef.svh:75-85`):

| Level | reps | `src_strides` | `dst_strides` |
|------|------|---------------|---------------|
| 1D burst | `length = NE·E (= SW B)` | contiguous | contiguous |
| `d_req[0]` = j (row in tile) | `NE` | `N·E` | `M·E` |
| `d_req[1]` = rt (row-tile) | `YT` | `NE·N·E` | `NE·E` |
| `d_req[2]` = nt (col-tile) | `NT` | `NE·E` | `NE·M·E` |

⇒ **NumDim = 4** (1D + 3 `d_req`). The driver computes this program from
`(src, dst, M, N, E)`; no new midend RTL. Pairing is positional: the engine
fills with read beats `j=0..NE-1` of a tile, then drains output beats
`j=0..NE-1` (columns); write iteration `j` consumes output beat `j`. `decouple_rw`
lets the read machine run a tile ahead while the engine buffers (§5.2).

### 4.3 `strb_o → wstrb` — the one load-bearing RTL change

`wstrb` is today born **solely** from address-alignment masks in
`src/backend/idma_axi_write.sv`: `w_first_mask = '1 << offset` (`:118`),
`w_last_mask = '1 >> (StrbWidth - tailer)` (`:119`), combined into `mask_out`
(`proc_out_mask_generator`, `:135-144`), then driven onto `write_req_o.w.strb`
(`:197`) **and** used to pop the buffer `buffer_out_ready_o = mask_out` (`:174`).
There is **no input port for an engine mask**.

Change:
1. Add an engine-strobe input to the write manager and **AND** it into `mask_out`:
   `mask_out = (alignment masks) & engine_strb_q`. This is the single deciding
   modification — without it, edge-tile padding cannot be dropped on writes.
   Anchor `idma_axi_write.sv:135-144, 174, 197`.
2. Shift `strb_o` by `w_dp_req_i.shift` **identically** to the data in the write
   barrel shifter, so the mask stays byte-aligned to the destination address. The
   transport layer already shifts `buffer_out`/`buffer_out_valid`/`buffer_out_ready`
   (`idma_transport_layer_rw_axi.sv:210-213`); add a parallel shift of `strb_o`.

`strb_o` is **already byte-granular** — `strb_int[p] = em[p >> transp_mode_i]`
(`idma_otf_transpose.sv:244-245`) expands the per-element mask to one bit per
byte — so it maps directly onto byte-granular `wstrb` for E ∈ {1,2,4}. No
expansion needed.

### 4.4 INCR-only — respected

The legalizer hard-asserts `BURST_INCR` (`target/rtl/idma_legalizer_rw_axi.sv:417-419`)
and a 1D run is one contiguous burst. Model §4.1 respects this: every 1D run is a
contiguous tile-row; all tiling/scatter is expressed **above** the legalizer as
ND per-dimension steps. The legalizer never sees a tile — it only page-splits a
contiguous INCR run. Transpose is 1:1 bytes, so the legalizer's identical src/dst
`length` (`:262, :271`, both `req_i.length`) is correct **as-is** — no
`otf_write_length` hack.

---

## 5. Data plane — transport wiring

### 5.1 Engine placement

Behind `EnableTranspose`, route `buffer_out` (`idma_transport_layer_rw_axi.sv:201-203`)
→ engine `data_i`; engine `data_o` → write barrel-shifter input (`:210-213`).
Passthrough keeps today's direct path. Selection = static `EnableTranspose`
**AND** per-transfer `w_dp_req_i.transpose_en` (mirrors viDMA's passthrough mux
but **without** the opcode machinery). Geometry ports come from
`w_dp_req_i.transp_mode/tensor_m/tensor_n`; `clear_i` is pulsed on the first beat
of a transpose transfer.

### 5.2 decouple_rw / decouple_aw

Transpose **requires** `decouple_rw = 1`: the engine's ping-pong overlaps the
write of tile k-1 with the read of tile k (`idma_otf_transpose.sv:19-23`).
`decouple_aw = 1` so AWs trail the first R by the one-tile fill latency. Set them
**per-transfer** (only when `transpose_en`) via `opt.beo.decouple_rw/decouple_aw`
— do **not** copy viDMA's blanket unconditional `decouple_rw` workaround
(`vidma:vidma_otf_pkg.sv` `needs_force_decouple_rw`). Keep the coupled path for
plain copies. The package warns `decouple_rw` "can cause deadlocks"
(`src/idma_pkg.sv:76`) — see §6 risk.

### 5.3 Response / meta path

No new fields: one transfer = one `done_id`. `idma_rsp_t` (`typedef.svh:45-50`)
flows backend → error handler → ND midend (`nd_rsp_o` valid on `burst_rsp_i.last`,
`idma_nd_midend.sv:208`) → frontend counters (inst64 `completed_id`/`next_id`
`:140-141`; reg `done_id`/`next_id`; desc64 IRQ from `flags[0]`
`idma_desc64_reshaper.sv:22`). **Must-fix:** with `decouple_rw` and a tile drained
*after* its read, the last response must be gated on **write** completion of the
last tile, not read completion — otherwise `done_id` rises before the transposed
data is committed. The engine's ping-pong/drain busy must also feed the existing
busy aggregation (`src/idma_pkg.sv` `idma_busy_t`) so frontend polling stays
correct.

---

## 6. Per-layer change checklist

- **typedef** — add `transpose_en`(1b), `transp_mode`(2b), `tensor_m`(12b),
  `tensor_n`(12b) to `IDMA_TYPEDEF_OPTIONS_T` (`src/include/idma/typedef.svh:21-30`).
  Req/ND/response macros unchanged.
- **frontend/reg** — `conf` bits 17/19:18; wire in `proc_hw_req_conv`
  (`src/frontend/reg/tpl/idma_reg.{hjson,sv}.tpl`). M/N via existing length/reps.
- **frontend/desc64** — `flags[24]`/`flags[26:25]`
  (`idma_desc64_top.sv:114`, reshaper `:27-60`); derive M/N.
- **frontend/inst64** — `DMTRANSP` arm (`idma_inst64_top.sv:386`); default new
  opt fields to 0 (`:343-364`); reuse DMREP/DMSTR for reps/strides.
- **midend** — **no RTL logic change**; needs **NumDim = 4** backend config
  (`RepWidth`/`NumDim` are synth params, `idma_nd_midend.sv:16,26`). Independent
  walk (`:164-186`) + bypass (`:194-198`) carry it.
- **legalizer** — mirror the new opt fields into `idma_mut_tf_opt_t`, latch in the
  `opt_tf_d` literal (`target/rtl/idma_legalizer_rw_axi.sv:267-301`; template
  `src/backend/tpl/idma_legalizer.sv.tpl`), forward into `w_dp_req`. **No**
  `otf_write_length` math. INCR asserts (`:417-419`) stay valid.
- **backend** — add `transpose_en/transp_mode/tensor_m/tensor_n` to `w_dp_req_t`;
  add `EnableTranspose` param gating the transport instantiation; populate fields
  from `opt_tf_q`.
- **transport** — instantiate engine at the `buffer_out → shifter` seam behind
  `EnableTranspose && w_dp_req_i.transpose_en` (`target/rtl/idma_transport_layer_rw_axi.sv:201-213`);
  wire `clear_i`, geometry, `valid/ready`; shift `strb_o` by `w_dp_req_i.shift`.
- **backend/axi_write** — **the one load-bearing change**: AND engine `strb_o`
  into `mask_out` (`src/backend/idma_axi_write.sv:135-144`); flows to `w.strb`
  (`:197`) and pop (`:174`). Define fully-masked-beat behavior (§7.1).
- **pkg** — ensure engine busy contributes to `busy_o` (`src/idma_pkg.sv`).

---

## 7. Open questions & risks (be explicit — no silent gaps)

1. **Partial-tile edge reads + phantom write beats (highest).** For M,N not
   multiples of `NE` the engine still consumes/produces **full padded NE-beat
   tiles** (`idma_otf_transpose.sv` contract). Two consequences:
   - the last partial **row**-tile read may touch **out-of-bounds source**
     addresses (writes are safe — masked by `strb_o`);
   - the last partial **col**-tile produces **fully-masked phantom write beats**
     (`strb_o == 0`). In `idma_axi_write.sv`, `mask_out == 0` makes
     `ready_to_write` vacuously true (`:159`) and would emit a zero-strobe `W`
     or stall the pop (`:174`) — **undefined today**.
   Decide explicitly, do **not** let edge tiles read OOB or emit junk W:
   (a) require NE-aligned M,N for the first cut (no OOB, no phantom); or
   (b) add a transport-seam pad/drop block: zero-pad reads at the source edge and
       drop fully-masked W beats (and shorten the AW length accordingly); or
   (c) rely on an SoC contract that source/dest are allocated tile-padded.
   Recommended: (a) first, (b) as the productized path.
2. **`strb_o → wstrb` merge must be exact.** Shift by `w_dp_req_i.shift` identically
   to data; **AND** (not replace) with the alignment masks so it composes with
   address misalignment. Verify a fully-masked beat does not deadlock the
   buffer-pop path (`idma_axi_write.sv:174`).
3. **Last-response timing.** Gate `nd_rsp_o.last` / `done_id` on **write**
   completion of the final tile under `decouple_rw` (§5.3), not read completion.
   Guaranteed to bite given the ping-pong latency — a resolved design point, not
   a "verify later".
4. **Deadlock.** `decouple_rw = 1` is required but the package warns it can
   deadlock (`idma_pkg.sv:76`; cf. `doc/TODO-rw-decoupled-deadlock.md`). Set it
   **per-transfer**, keep coupled path for copies, and write a directed test that
   the engine's full-tile buffer filling while the write side backpressures does
   **not** form a buffer-full ↔ engine-stall ↔ write-stall cycle.
5. **AW/AR id ordering.** All bursts use one `opt_tf_q.axi_id`
   (`idma_legalizer_rw_axi.sv:314, 340`). With `NE` fragmented short bursts per
   tile and `decouple_rw`, same-ID ordering forces correctness but the fragmented
   multi-burst-per-tile W-to-AW pairing under the engine's drain is unanalyzed —
   confirm before relying on it.
6. **NumDim = 4 cost.** A NumDim bump widens the ND CSR/descriptor footprint
   (reps/strides per dimension) across reg/desc64/inst64. Quantify the CSR-map and
   descriptor-size impact per frontend; small SoCs may want a transpose-only
   reduced-width ND variant.
7. **Burst efficiency.** Each 1D run is one tile-row (`SW` bytes ⇒ one beat), so
   AR/AW issue at one (short) burst per tile-row. This is inherent to the tiled
   walk; if AR/AW issue-rate bottlenecks, coalesce contiguous tile-rows when
   `N == NE` (single col-tile makes a tile's rows contiguous) as a special case.

---

## 8. Net

- **Control**: typed, request-scoped `idma_req_t.opt` fields — reject viDMA's
  sticky global opcode side-band.
- **Address**: same tile-visitation order on AR and AW; transpose lives in the
  engine; **transposed `dst_strides`** over a NumDim=4 ND program (midden logic
  untouched, config bump only). Stride table in §4.2.
- **Data**: engine spliced at the `buffer_out` seam behind `EnableTranspose`,
  self-draining; **one load-bearing new RTL primitive**: AND the shifted engine
  `strb_o` into `mask_out` in `idma_axi_write.sv`.
- **Largest unresolved items**: partial-tile edge reads / phantom write beats
  (§7.1), last-response-on-write timing (§7.3), `decouple_rw` deadlock test (§7.4).
