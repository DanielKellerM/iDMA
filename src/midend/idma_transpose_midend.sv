// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Daniel Keller <dankeller@iis.ee.ethz.ch>

/// Transpose geometry expander. For a request carrying opt.compute = TRANSPOSE,
/// derives the NumDim=4 tiled ND walk (row / row-tile / col-tile) from the
/// logical tensor shape (M, N, element mode) and the bus StrbWidth, leaving the
/// generic idma_nd_midend to walk it. Non-transpose requests pass through
/// untouched. The ceil-divisions are by NE = StrbWidth>>mode (a power of two),
/// so they reduce to shifts; only the stride products are multiplies.
module idma_transpose_midend #(
    /// Number of ND dimensions (must be >= 4 to express the tiled walk)
    parameter int unsigned NumDim    = 32'd4,
    /// Write data-path width in bytes (tile side NE = StrbWidth / element bytes)
    parameter int unsigned StrbWidth = 32'd64,
    /// Address type
    parameter type addr_t        = logic,
    /// ND request type
    parameter type idma_nd_req_t = logic
)(
    input  idma_nd_req_t nd_req_i,
    input  logic         valid_i,
    output logic         ready_o,
    output idma_nd_req_t nd_req_o,
    output logic         valid_o,
    input  logic         ready_i
);

    localparam int unsigned Log2Strb = $clog2(StrbWidth);
    localparam int unsigned LenW     = $bits(nd_req_o.burst_req.length);
    localparam int unsigned RepW     = $bits(nd_req_o.d_req[0].reps);
    localparam int unsigned ModeW    = $bits(nd_req_o.burst_req.opt.compute.params.transpose.mode);
    localparam int unsigned TensorW  =
        $bits(nd_req_o.burst_req.opt.compute.params.transpose.tensor_m);
    localparam int unsigned AddrW    = $bits(addr_t);
    // Working width: largest term is (YT*N)<<Log2Strb -> 2*TensorW+Log2Strb bits,
    // +1 for the signed rewind subtraction; never narrower than the cast target.
    localparam int unsigned ProdW    = 2*TensorW + Log2Strb + 1;
    localparam int unsigned WorkW    = (ProdW > AddrW) ? ProdW : AddrW;

    // Combinational stage: handshake passes straight through.
    assign valid_o = valid_i;
    assign ready_o = ready_i;

    logic is_transpose;
    assign is_transpose = nd_req_i.burst_req.opt.compute.enable &
                          (nd_req_i.burst_req.opt.compute.op == idma_pkg::COMPUTE_TRANSPOSE);

    // Strength-reduced geometry (matches the golden exactly). NE and E are powers
    // of two, so NE*E == StrbWidth (constant), MP*E == YT<<Log2Strb and N*E ==
    // N<<mode are shifts, and (NE-1)*MPE / (YT-1)*NEE fold to shift+sub. Only YT*N
    // is a genuine (12x12) multiply — shallow enough to stay combinational, in line
    // with the multiplier-free style of the legalizer / nd_midend / engine.
    always_comb begin : proc_expand
        logic [ModeW-1:0]        mode;
        logic [TensorW-1:0]      tm, tn;
        logic signed [WorkW-1:0] m, n, log2ne, ne, yt, nt, nxe, mpe;
        logic signed [WorkW-1:0] strb_c;   // NE*E == StrbWidth (mode cancels)

        nd_req_o = nd_req_i;   // passthrough (addresses, opt.compute, protocol, ...)

        if (is_transpose) begin
            mode = nd_req_i.burst_req.opt.compute.params.transpose.mode;
            tm   = nd_req_i.burst_req.opt.compute.params.transpose.tensor_m;
            tn   = nd_req_i.burst_req.opt.compute.params.transpose.tensor_n;
            // zero-extend bounded dims into the signed working width
            m      = $signed({{(WorkW-TensorW){1'b0}}, tm});   // M
            n      = $signed({{(WorkW-TensorW){1'b0}}, tn});   // N
            log2ne = $signed(WorkW'(Log2Strb)) - $signed({{(WorkW-ModeW){1'b0}}, mode});
            ne     = $signed(WorkW'(1)) <<< log2ne;            // tile side (elements)
            yt     = (m + ne - 1) >>> log2ne;                  // ceil(M/NE)
            nt     = (n + ne - 1) >>> log2ne;                  // ceil(N/NE)
            nxe    = n  <<< mode;                              // N*E  (E = 1<<mode)
            mpe    = yt <<< Log2Strb;                          // MP*E = YT*NE*E = YT*StrbWidth
            strb_c = $signed(WorkW'(StrbWidth));               // NE*E (one tile-row = StrbWidth B)

            nd_req_o.burst_req.length     = LenW'(StrbWidth);

            // d_req[0] = local row within tile (reps NE)
            nd_req_o.d_req[0].reps        = ne[RepW-1:0];
            nd_req_o.d_req[0].src_strides = addr_t'(nxe);
            nd_req_o.d_req[0].dst_strides = addr_t'(mpe);
            // d_req[1] = row-tile (reps YT). (NE-1)*MPE = (MPE<<log2ne) - MPE.
            nd_req_o.d_req[1].reps        = yt[RepW-1:0];
            nd_req_o.d_req[1].src_strides = addr_t'(nxe);
            nd_req_o.d_req[1].dst_strides = addr_t'(strb_c - (mpe <<< log2ne) + mpe);
            // d_req[2] = col-tile (reps NT). (YT*NE-1)*NXE = ((YT*N)<<Log2Strb) - NXE;
            //            the dst rewind MPE-(YT-1)*StrbWidth collapses to StrbWidth.
            nd_req_o.d_req[2].reps        = nt[RepW-1:0];
            nd_req_o.d_req[2].src_strides = addr_t'(strb_c - ((yt * n) <<< Log2Strb) + nxe);
            nd_req_o.d_req[2].dst_strides = addr_t'(strb_c);
        end
    end

`ifndef SYNTHESIS
    initial assert (NumDim >= 4) else
        $fatal(1, "idma_transpose_midend requires NumDim >= 4 (got %0d)", NumDim);
    // reps must hold tile counts (<= 2^TensorW) and ne (<= StrbWidth); length StrbWidth.
    initial assert (RepW >= TensorW && RepW > Log2Strb) else
        $fatal(1, "idma_transpose_midend: reps field %0d b too narrow (need >= %0d)",
               RepW, (TensorW > Log2Strb+1) ? TensorW : Log2Strb+1);
    initial assert (LenW > Log2Strb) else
        $fatal(1, "idma_transpose_midend: length field %0d b cannot hold StrbWidth", LenW);
    // Reserved element size (mode 3 => EB=8) and zero-size tensors are out of
    // contract: flag them rather than silently fabricating a geometry.
    always_comb begin : check_domain
        if (is_transpose) begin
            assert (nd_req_i.burst_req.opt.compute.params.transpose.mode != 2'd3) else
                $error("idma_transpose_midend: reserved element mode 3 (EB=8)");
            assert (nd_req_i.burst_req.opt.compute.params.transpose.tensor_m != '0 &&
                    nd_req_i.burst_req.opt.compute.params.transpose.tensor_n != '0) else
                $error("idma_transpose_midend: zero-size tensor (M or N == 0)");
        end
    end
`endif

endmodule
