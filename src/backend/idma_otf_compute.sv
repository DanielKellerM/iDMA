// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>
//
// On-the-fly compute dispatcher for the iDMA transport write seam. Owns all
// compute sub-units, latches the per-transfer `compute_options_t` (first-beat
// bypass), and runtime-dispatches one op per transfer based on `compute.op`.
// Presents a single beat-level stream interface to the transport so the seam
// stays a thin latch+instance+mux regardless of how many ops exist.
//
// Adding an op: instantiate its sub-unit behind an `Enable<op>` parameter, add
// its `compute.op` case to the output mux, and read its params from
// `eff_compute.params.<op>` — the transport, legalizer and request types are
// untouched (they thread `compute_options_t` whole).
//
// Sub-units must honour the uniform contract: byte-granular `data`/`strb`,
// `valid_i`/`ready_o` on the (single-head) input beat, `valid_o`/`ready_i` on
// the output beat, and `clear_i` to reset when not selected. Two-operand ops
// belong to a 2-read backend variant (a second input head added there).

module idma_otf_compute #(
  /// Byte lanes per beat (= DataWidth/8)
  parameter int unsigned StrbWidth       = 32'd8,
  /// Compile-time per-op enables (only enabled sub-units are instantiated)
  parameter bit          EnableTranspose = 1'b1
) (
  input  logic clk_i,
  input  logic rst_ni,

  /// Per-transfer compute config; valid only while `cfg_valid_i`
  input  idma_pkg::compute_options_t compute_i,
  input  logic                       cfg_valid_i,
  /// A supported compute op is armed for this transfer (transport muxes the seam)
  output logic                       active_o,

  /// Input beat stream (from the dataflow buffer)
  input  logic [StrbWidth-1:0][7:0] data_i,
  input  logic                      valid_i,
  output logic                      in_ready_o,

  /// Output beat stream (computed) with per-byte strobe for edge masking
  output logic [StrbWidth-1:0][7:0] data_o,
  output logic [StrbWidth-1:0]      strb_o,
  output logic                      valid_o,
  input  logic                      ready_i
);

  // ── Per-transfer config latch (first-beat bypass) ──
  // compute_i is only valid while cfg_valid_i; the upstream FIFO output is X
  // between transfers. Reset/hold so the seam is cleanly bypassed at idle.
  idma_pkg::compute_options_t latched_q, eff_compute;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)          latched_q <= '0;
    else if (cfg_valid_i) latched_q <= compute_i;
  end
  assign eff_compute = cfg_valid_i ? compute_i : latched_q;

  // ── Per-op select (a sub-unit is selectable only if compiled in) ──
  logic sel_transpose;
  assign sel_transpose = eff_compute.enable &
                         (eff_compute.op == idma_pkg::COMPUTE_TRANSPOSE) & EnableTranspose;

  assign active_o = sel_transpose /* | sel_<future op> ... */;

  // ── Transpose sub-unit ──
  logic [StrbWidth-1:0][7:0] tp_data;
  logic [StrbWidth-1:0]      tp_strb;
  logic                      tp_valid, tp_in_ready;

  if (EnableTranspose) begin : gen_transpose
    idma_otf_transpose #(
      .StrbWidth ( StrbWidth )
    ) i_idma_otf_transpose (
      .clk_i,
      .rst_ni,
      .clear_i         ( ~sel_transpose                          ),
      .transp_mode_i   ( eff_compute.params.transpose.mode       ),
      .tensor_size_m_i ( eff_compute.params.transpose.tensor_m   ),
      .tensor_size_n_i ( eff_compute.params.transpose.tensor_n   ),
      .data_i          ( data_i                                  ),
      .valid_i         ( valid_i & sel_transpose                 ),
      .ready_o         ( tp_in_ready                             ),
      .data_o          ( tp_data                                 ),
      .strb_o          ( tp_strb                                 ),
      .valid_o         ( tp_valid                                ),
      .ready_i         ( ready_i & sel_transpose                 )
    );
  end else begin : gen_no_transpose
    assign tp_data = '0; assign tp_strb = '0; assign tp_valid = 1'b0; assign tp_in_ready = 1'b0;
  end

  // ── Output dispatch (one op per transfer) ──
  always_comb begin
    data_o     = '0;
    strb_o     = '0;
    valid_o    = 1'b0;
    in_ready_o = 1'b0;
    unique case (1'b1)
      sel_transpose: begin
        data_o     = tp_data;
        strb_o     = tp_strb;
        valid_o    = tp_valid;
        in_ready_o = tp_in_ready;
      end
      default: /* no compute armed: transport bypasses this block */ ;
    endcase
  end

endmodule : idma_otf_compute
