// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Daniel Keller <dankeller@iis.ee.ethz.ch>

// Recycled from the vidma inst64 verification harness
// (idma_alu_vec/test/frontend/idma_inst64_tb_pkg.sv). Kept faithful. The
// transpose imposes no NumAxInFlight>=NE constraint (the engine self-buffers a
// tile); verified down to NumAxInFlight=3 at NE=64.

`include "axi/typedef.svh"

package idma_inst64_tb_pkg;

    localparam int unsigned AxiDataWidth    = 512;
    localparam int unsigned AxiAddrWidth    = 64;
    localparam int unsigned AxiUserWidth    = 1;
    localparam int unsigned AxiIdWidth      = 3;
    localparam int unsigned NumAxInFlight   = 3;    // default
    localparam int unsigned DMAReqFifoDepth = 3;
    localparam int unsigned NumChannels     = 1;
    localparam int unsigned NumHeads        = 1;
    localparam int unsigned DMATracing      = 0;
    localparam int unsigned Seed            = 1337;

    localparam time Period     = 10ns;
    localparam time ApplDelay  = Period / 4;
    localparam time AcqDelay   = Period * 3 / 4;
    localparam integer ResetCycles = 10;

    // Type definitions
    typedef logic [AxiAddrWidth-1:0] addr_t;
    typedef logic [AxiIdWidth-1:0]   axi_id_t;
    typedef logic [31:0]             data_t;
    typedef logic [31:0]             tf_id_t;

    // AXI Types
    typedef logic [AxiAddrWidth-1:0]     axi_addr_t;
    typedef logic [AxiDataWidth-1:0]     axi_data_t;
    typedef logic [AxiDataWidth/8-1:0]   axi_strb_t;
    typedef logic [AxiUserWidth-1:0]     axi_user_t;

    `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, axi_addr_t, axi_id_t, axi_user_t)
    `AXI_TYPEDEF_W_CHAN_T(axi_w_chan_t, axi_data_t, axi_strb_t, axi_user_t)
    `AXI_TYPEDEF_B_CHAN_T(axi_b_chan_t, axi_id_t, axi_user_t)
    `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, axi_addr_t, axi_id_t, axi_user_t)
    `AXI_TYPEDEF_R_CHAN_T(axi_r_chan_t, axi_data_t, axi_id_t, axi_user_t)
    `AXI_TYPEDEF_REQ_T(axi_req_t, axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
    `AXI_TYPEDEF_RESP_T(axi_resp_t, axi_b_chan_t, axi_r_chan_t)

    // Accelerator request/response types (simplified Snitch accelerator interface)
    typedef struct packed {
        logic [31:0] id;
        logic [31:0] data_op;
        logic [63:0] data_arga;
        logic [63:0] data_argb;
    } acc_req_t;

    typedef struct packed {
        logic [31:0] id;
        logic [63:0] data;
        logic        error;
    } acc_res_t;

    // DMA events (simplified)
    typedef struct packed {
        // aw
        logic                aw_valid;
        logic                aw_ready;
        logic                aw_done;
        logic                aw_stall;
        axi_pkg::len_t       aw_len;
        axi_pkg::size_t      aw_size;
        // ar
        logic                ar_valid;
        logic                ar_ready;
        logic                ar_done;
        logic                ar_stall;
        axi_pkg::len_t       ar_len;
        axi_pkg::size_t      ar_size;
        // r
        logic                r_valid;
        logic                r_ready;
        logic                r_done;
        logic                r_bw;
        logic                r_stall;
        // w
        logic                w_valid;
        logic                w_ready;
        logic                w_done;
        logic                w_stall;
        logic [31:0]         num_bytes_written;
        // b
        logic                b_valid;
        logic                b_ready;
        logic                b_done;
        // busy
        logic                dma_busy;
    } dma_events_t;

    // Golden reference for validation
    typedef struct {
        addr_t   src_addr;
        addr_t   dst_addr;
        addr_t   length;
        logic [5:0] alu_opcode;
        logic [31:0] src_strides;
        logic [31:0] dst_strides;
        logic [31:0] reps;
        logic        twod;
        int unsigned channel;
        tf_id_t expected_id;
    } transfer_t;

endpackage
