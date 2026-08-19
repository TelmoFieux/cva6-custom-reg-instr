// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba    <zarubaf@iis.ee.ethz.ch>, ETH Zurich
//         Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
// Date: 15.08.2018
// Description: Load Unit, takes care of all load requests
//
// Contributor: Cesar Fuguet <cesar.fuguettortolero@cea.fr>, CEA List
// Date: August 29, 2023
// Modification: add support for multiple outstanding load operations
//               to the data cache

module load_unit
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter type exception_t = logic,
    parameter type lsu_ctrl_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Flush signal - CONTROLLER
    input logic flush_i,
    // Is ldbuf full - LOAD_STORE_QUEUE
    output logic ldbuf_full_o,
    // do we need to rollback lsu buffer or squash load instr ? - SCOREBOARD
    input logic [CVA6Cfg.RollbackWidth-1:0] rollback_i,
    // trans if of instruction to rollback - SCOREBOARD
    input logic [CVA6Cfg.RollbackWidth-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rollback_trans_id_i,
    // Load request is valid - LSU_BYPASS
    input logic valid_i,
    // Load request input - LSU_BYPASS
    input lsu_ctrl_t lsu_ctrl_i,
    // index of the load instr in the load queue - LOAD_UNIT
    input logic [$clog2(CVA6Cfg.NrLSQEntries)-1:0] ld_unit_idx_i,
    // Pop the load request from the LSU bypass FIFO - LSU_BYPASS
    output logic pop_ld_o,
    // Load unit result is valid - ISSUE_STAGE
    output logic valid_o,
    // index of the load instr that finished - LOAD_STORE_QUEUE
    output logic [$clog2(CVA6Cfg.NrLSQEntries)-1:0] ld_unit_idx_o,
    // Load result - LOAD_STORE_QUEUE
    output logic [CVA6Cfg.XLEN-1:0] result_o,
    // Physical address - LOAD_STORE_QUEUE
    input logic [CVA6Cfg.PLEN-1:0] paddr_i,
    // Data cache request out - CACHES
    input dcache_req_o_t req_port_i,
    // Data cache request in - CACHES
    output dcache_req_i_t req_port_o
);
  enum logic [3:0] {
    IDLE,
    WAIT_GNT,
    SEND_TAG,
    WAIT_FLUSH
  }
      state_d, state_q;

  // in order to decouple the response interface from the request interface,
  // we need a a buffer which can hold all inflight memory load requests
  typedef struct packed {
    logic [CVA6Cfg.TRANS_ID_BITS-1:0]    trans_id;        // scoreboard identifier
    logic [CVA6Cfg.NrLSQEntries-1:0]     ldq_idx;         // load queue index
    logic [CVA6Cfg.XLEN_ALIGN_BYTES-1:0] address_offset;  // least significant bits of the address
    fu_op                                operation;       // type of load
  } ldbuf_t;


  // to support a throughput of one load per cycle, if the number of entries
  // of the load buffer is 1, implement a fall-through mode. This however
  // adds a combinational path between the request and response interfaces
  // towards the cache.
  localparam logic LDBUF_FALLTHROUGH = (CVA6Cfg.NrLoadBufEntries == 1);
  localparam int unsigned REQ_ID_BITS = CVA6Cfg.NrLoadBufEntries > 1 ? $clog2(
      CVA6Cfg.NrLoadBufEntries
  ) : 1;

  localparam logic USE_HPDCACHE =
    CVA6Cfg.DCacheType inside {
        config_pkg::HPDCACHE_WT,
        config_pkg::HPDCACHE_WB,
        config_pkg::HPDCACHE_WT_WB
    };

  typedef logic [REQ_ID_BITS-1:0] ldbuf_id_t;

  logic [CVA6Cfg.NrLoadBufEntries-1:0] ldbuf_valid_q, ldbuf_valid_d;
  logic [CVA6Cfg.NrLoadBufEntries-1:0] ldbuf_flushed_q, ldbuf_flushed_d;
  ldbuf_t [CVA6Cfg.NrLoadBufEntries-1:0] ldbuf_q;
  logic ldbuf_empty, ldbuf_full;
  ldbuf_id_t ldbuf_free_index;
  logic      ldbuf_w;
  ldbuf_t    ldbuf_wdata;
  ldbuf_id_t ldbuf_windex;
  logic      ldbuf_r;
  ldbuf_t    ldbuf_rdata;
  ldbuf_id_t ldbuf_rindex;
  ldbuf_id_t ldbuf_last_id_q;
  logic accept_req;

  assign ldbuf_full = &ldbuf_valid_q;
  assign ldbuf_full_o = ldbuf_full;

  //
  //  buffer of outstanding loads

  //  write in the first available slot
  generate
    if (CVA6Cfg.NrLoadBufEntries > 1) begin : ldbuf_free_index_multi_gen
      lzc #(
          .WIDTH(CVA6Cfg.NrLoadBufEntries),
          .MODE (1'b0)                       // Count leading zeros
      ) lzc_windex_i (
          .in_i   (~ldbuf_valid_q),
          .cnt_o  (ldbuf_free_index),
          .empty_o(ldbuf_empty)
      );
    end else begin : ldbuf_free_index_single_gen
      assign ldbuf_free_index = 1'b0;
    end
  endgenerate

  assign ldbuf_windex = (LDBUF_FALLTHROUGH && ldbuf_r) ? ldbuf_rindex : ldbuf_free_index;

  always_comb begin : ldbuf_comb
    ldbuf_flushed_d = ldbuf_flushed_q;
    ldbuf_valid_d   = ldbuf_valid_q;

    //  In case of flush, raise the flushed flag in all slots.
    if (flush_i) begin
      ldbuf_flushed_d = '1;
    end

    //  Free read entry (in the case of fall-through mode, free the entry
    //  only if there is no pending load)
    if (ldbuf_r && (!LDBUF_FALLTHROUGH || !ldbuf_w)) begin
      ldbuf_valid_d[ldbuf_rindex] = 1'b0;
    end
    //  Track a new outstanding operation in the load buffer
    if (ldbuf_w) begin
      ldbuf_flushed_d[ldbuf_windex] = 1'b0;
      ldbuf_valid_d[ldbuf_windex]   = 1'b1;
    end

    // squash entry on rollback
    for (int unsigned i = 0; i < CVA6Cfg.NrLoadBufEntries; i++) begin
      for (int unsigned j = 0 ; j<CVA6Cfg.RollbackWidth ; j++) begin
        if (ldbuf_valid_q[i] && ldbuf_q[i].trans_id == rollback_trans_id_i[j] && rollback_i[j]) begin
          ldbuf_flushed_d[i] = '1;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : ldbuf_ff
    if (!rst_ni) begin
      ldbuf_flushed_q <= '0;
      ldbuf_valid_q   <= '0;
      ldbuf_last_id_q <= '0;
      ldbuf_q         <= '0;
    end else begin
      ldbuf_flushed_q <= ldbuf_flushed_d;
      ldbuf_valid_q   <= ldbuf_valid_d;
      if (ldbuf_w) begin
        ldbuf_last_id_q       <= ldbuf_windex;
        ldbuf_q[ldbuf_windex] <= ldbuf_wdata;
      end
    end
  end

  assign req_port_o.data_we = 1'b0;
  assign req_port_o.data_wdata = '0;
  // compose the load buffer write data, control is handled in the FSM
  assign ldbuf_wdata = {
    lsu_ctrl_i.trans_id, ld_unit_idx_i, lsu_ctrl_i.vaddr[CVA6Cfg.XLEN_ALIGN_BYTES-1:0], lsu_ctrl_i.operation
  };
  // output address
  assign req_port_o.address_index = paddr_i[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
  assign req_port_o.address_tag   = paddr_i[CVA6Cfg.DCACHE_TAG_WIDTH     +
                                              CVA6Cfg.DCACHE_INDEX_WIDTH-1 :
                                              CVA6Cfg.DCACHE_INDEX_WIDTH];
  // request id = index of the load buffer's entry
  assign req_port_o.data_id = ldbuf_windex;

  // ---------------
  // Load Control
  // ---------------
  always_comb begin : load_control

    // default assignments
    state_d              = state_q;
    req_port_o.data_req  = 1'b0;
    // tag control
    req_port_o.kill_req  = 1'b0;
    req_port_o.tag_valid = 1'b0;
    req_port_o.data_be   = lsu_ctrl_i.be;
    req_port_o.data_size = extract_transfer_size(lsu_ctrl_i.operation);

    // In IDLE and SEND_TAG states, this unit can accept a new load request
    // when the load buffer is not full or if there is a response and the
    // load buffer is in fall-through mode
    accept_req = (valid_i && !flush_i && (!ldbuf_full || (LDBUF_FALLTHROUGH && ldbuf_r)));

    for (int unsigned i = 0 ; i<CVA6Cfg.RollbackWidth ; i++) begin
      if (rollback_i[i] && rollback_trans_id_i[i] == lsu_ctrl_i.trans_id) begin
        accept_req = 1'b0;
      end
    end


    case (state_q)
      IDLE: begin
        if (accept_req) begin
          if (req_port_i.data_gnt) begin
            if (USE_HPDCACHE)
              state_d = IDLE;
            else
              state_d = SEND_TAG;
          end else begin
            state_d = WAIT_GNT;
          end
        end
      end

      WAIT_GNT: begin
        // keep the request up
        req_port_o.data_req = 1'b1;
        // when using hpd cache we can skip the send_tag step
        if(req_port_i.data_gnt) begin
          state_d = USE_HPDCACHE ? IDLE : SEND_TAG;
        end
      end
      // we know for sure that the tag we want to send is valid
      SEND_TAG: begin
        req_port_o.tag_valid = 1'b1;
        state_d = IDLE;
      end

      WAIT_FLUSH: begin
        // the D$ arbiter will take care of presenting this to the memory only in case we
        // have an outstanding request
        req_port_o.kill_req = 1'b1;
        req_port_o.tag_valid = 1'b1;
        // we've killed the current request so we can go back to idle
        state_d = IDLE;
      end

      default: begin
        state_d = IDLE;
      end
    endcase

    // In case of rollback we change the FSM state
    for (int unsigned i = 0 ; i<CVA6Cfg.RollbackWidth ; i++) begin
      if (rollback_i[i] && rollback_trans_id_i[i] == lsu_ctrl_i.trans_id && lsu_ctrl_i.valid) begin
        unique case (state_q)
          WAIT_GNT : begin
            state_d = IDLE;
            req_port_o.data_req = 1'b0;
          end
          SEND_TAG : begin
            state_d = IDLE;
          end
          default: ;
        endcase
      end
    end

    // if we just flushed and the queue is not empty or we are getting an rvalid this cycle wait in a extra stage
    // with hpdcache in OoO we can't cancel a load
    if (flush_i && USE_HPDCACHE) begin
      if (state_q == WAIT_GNT) begin
        req_port_o.data_req = 1'b0;
        state_d = IDLE;
      end
    end

    if (flush_i && !USE_HPDCACHE) begin
      state_d = WAIT_FLUSH;
    end
  end

  // track the load data for later usage
  assign ldbuf_w = req_port_o.data_req & req_port_i.data_gnt;
  assign pop_ld_o = ldbuf_w;

  // ---------------
  // Retire Load
  // ---------------
  assign ldbuf_rindex = (CVA6Cfg.NrLoadBufEntries > 1) ? ldbuf_id_t'(req_port_i.data_rid) : 1'b0,
      ldbuf_rdata = ldbuf_q[ldbuf_rindex];

  // decoupled rvalid process
  always_comb begin : rvalid_output
    //  read the pending load buffer
    ldbuf_r    = req_port_i.data_rvalid;
    valid_o    = 1'b0;
    ld_unit_idx_o = ldbuf_q[ldbuf_rindex].ldq_idx;

    // we got an rvalid and it's corresponding request was not flushed
    if (req_port_i.data_rvalid && !ldbuf_flushed_q[ldbuf_rindex]) begin
      // if the response corresponds to the last request, check that we are not killing it
      if ((ldbuf_last_id_q != ldbuf_rindex) || !req_port_o.kill_req) valid_o = 1'b1;
    end
  end


  // latch physical address for the tag cycle (one cycle after applying the index)
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      state_q <= IDLE;
    end else begin
      state_q <= state_d;
    end
  end

  // ---------------
  // Sign Extend
  // ---------------
  logic [CVA6Cfg.XLEN-1:0] shifted_data;

  // realign as needed
  assign shifted_data = req_port_i.data_rdata >> {ldbuf_rdata.address_offset, 3'b000};

  /*  // result mux (leaner code, but more logic stages.
    // can be used instead of the code below (in between //result mux fast) if timing is not so critical)
    always_comb begin
        unique case (ldbuf_rdata.operation)
            LWU:        result_o = shifted_data[31:0];
            LHU:        result_o = shifted_data[15:0];
            LBU:        result_o = shifted_data[7:0];
            LW:         result_o = 64'(signed'(shifted_data[31:0]));
            LH:         result_o = 64'(signed'(shifted_data[15:0]));
            LB:         result_o = 64'(signed'(shifted_data[ 7:0]));
            default:    result_o = shifted_data;
        endcase
    end  */

  // result mux fast
  logic [        (CVA6Cfg.XLEN/8)-1:0] rdata_sign_bits;
  logic [CVA6Cfg.XLEN_ALIGN_BYTES-1:0] rdata_offset;
  logic rdata_sign_bit, rdata_is_signed, rdata_is_fp_signed;


  // prepare these signals for faster selection in the next cycle
  assign rdata_is_signed    =   ldbuf_rdata.operation inside {ariane_pkg::LW,  ariane_pkg::LH,  ariane_pkg::LB, ariane_pkg::HLV_W, ariane_pkg::HLV_H, ariane_pkg::HLV_B};
  assign rdata_is_fp_signed =   ldbuf_rdata.operation inside {ariane_pkg::FLW, ariane_pkg::FLH, ariane_pkg::FLB};
  assign rdata_offset       = ((ldbuf_rdata.operation inside {ariane_pkg::LW,  ariane_pkg::FLW, ariane_pkg::HLV_W}) & CVA6Cfg.IS_XLEN64) ? ldbuf_rdata.address_offset + 3 :
                                ( ldbuf_rdata.operation inside {ariane_pkg::LH,  ariane_pkg::FLH, ariane_pkg::HLV_H})                     ? ldbuf_rdata.address_offset + 1 :
                                                                                                                         ldbuf_rdata.address_offset;

  for (genvar i = 0; i < (CVA6Cfg.XLEN / 8); i++) begin : gen_sign_bits
    assign rdata_sign_bits[i] = req_port_i.data_rdata[(i+1)*8-1];
  end


  // select correct sign bit in parallel to result shifter above
  // pull to 0 if unsigned
  assign rdata_sign_bit = rdata_is_signed & rdata_sign_bits[rdata_offset] | (CVA6Cfg.FpPresent && rdata_is_fp_signed);

  // result mux
  always_comb begin
    unique case (ldbuf_rdata.operation)
      ariane_pkg::LW, ariane_pkg::LWU, ariane_pkg::HLV_W, ariane_pkg::HLV_WU, ariane_pkg::HLVX_WU:
      result_o = {{CVA6Cfg.XLEN - 32{rdata_sign_bit}}, shifted_data[31:0]};
      ariane_pkg::LH, ariane_pkg::LHU, ariane_pkg::HLV_H, ariane_pkg::HLV_HU, ariane_pkg::HLVX_HU:
      result_o = {{CVA6Cfg.XLEN - 32 + 16{rdata_sign_bit}}, shifted_data[15:0]};
      ariane_pkg::LB, ariane_pkg::LBU, ariane_pkg::HLV_B, ariane_pkg::HLV_BU:
      result_o = {{CVA6Cfg.XLEN - 32 + 24{rdata_sign_bit}}, shifted_data[7:0]};
      default: begin
        // FLW, FLH and FLB have been defined here in default case to improve Code Coverage
        if (CVA6Cfg.FpPresent) begin
          unique case (ldbuf_rdata.operation)
            ariane_pkg::FLW: begin
              result_o = {{CVA6Cfg.XLEN - 32{rdata_sign_bit}}, shifted_data[31:0]};
            end
            ariane_pkg::FLH: begin
              result_o = {{CVA6Cfg.XLEN - 32 + 16{rdata_sign_bit}}, shifted_data[15:0]};
            end
            ariane_pkg::FLB: begin
              result_o = {{CVA6Cfg.XLEN - 32 + 24{rdata_sign_bit}}, shifted_data[7:0]};
            end
            default: begin
              result_o = shifted_data[CVA6Cfg.XLEN-1:0];
            end
          endcase
        end else begin
          result_o = shifted_data[CVA6Cfg.XLEN-1:0];
        end
      end
    endcase
  end
  // end result mux fast

  ///////////////////////////////////////////////////////
  // assertions
  ///////////////////////////////////////////////////////

  //pragma translate_off
  initial
    assert (CVA6Cfg.DcacheIdWidth >= REQ_ID_BITS)
    else $fatal(1, "DcacheIdWidth parameter is not wide enough to encode pending loads");
  // check invalid offsets, but only issue a warning as these conditions actually trigger a load address misaligned exception
  addr_offset0 :
  assert property (@(posedge clk_i) disable iff (~rst_ni)
        ldbuf_w |->  (ldbuf_wdata.operation inside {ariane_pkg::LW, ariane_pkg::LWU}) |-> ldbuf_wdata.address_offset < 5)
  else $fatal(1, "invalid address offset used with {LW, LWU}");
  addr_offset1 :
  assert property (@(posedge clk_i) disable iff (~rst_ni)
        ldbuf_w |->  (ldbuf_wdata.operation inside {ariane_pkg::LH, ariane_pkg::LHU}) |-> ldbuf_wdata.address_offset < 7)
  else $fatal(1, "invalid address offset used with {LH, LHU}");
  addr_offset2 :
  assert property (@(posedge clk_i) disable iff (~rst_ni)
        ldbuf_w |->  (ldbuf_wdata.operation inside {ariane_pkg::LB, ariane_pkg::LBU}) |-> ldbuf_wdata.address_offset < 8)
  else $fatal(1, "invalid address offset used with {LB, LBU}");
  //pragma translate_on

endmodule
