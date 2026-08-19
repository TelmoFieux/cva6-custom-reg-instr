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
// Author: Florian Zaruba, ETH Zurich
// Date: 22.05.2017
// Description: Store Unit, takes care of all store requests and atomic memory operations (AMOs)


module store_unit
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
    // Flush - CONTROLLER
    input logic flush_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic stall_st_pending_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output logic no_st_pending_o,
    // Store instruction is valid - ISSUE_STAGE
    input logic valid_i,
    // Data input - ISSUE_STAGE
    input lsu_ctrl_t lsu_ctrl_i,
    // Physical address - LOAD_STORE_QUEUE
    input logic [CVA6Cfg.PLEN-1:0] paddr_i,
    // Instruction commit - TO_BE_COMPLETED
    input logic commit_i,
    // is store ready to commit - LOAD_STORE_QUEUE
    input logic st_valid_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output logic commit_ready_o,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic amo_valid_commit_i,
    // Store result is valid - ISSUE_STAGE
    // RVFI information - RVFI
    output logic [CVA6Cfg.PLEN-1:0] rvfi_mem_paddr_o,
    // a store request has been sent to the cache - LOAD_STORE_QUEUE
    output logic sent_to_cache_o,
    // AMO request - CACHES
    output amo_req_t amo_req_o,
    // AMO response - CACHES
    input amo_resp_t amo_resp_i,
    // Data cache request - CACHES
    input dcache_req_o_t req_port_i,
    // Data cache response - CACHES
    output dcache_req_i_t req_port_o
);

  // align data to address e.g.: shift data to be naturally 64
  function automatic [CVA6Cfg.XLEN-1:0] data_align(logic [2:0] addr, logic [63:0] data);
    // Set addr[2] to 1'b0 when 32bits
    logic [ 2:0] addr_tmp = {(addr[2] && CVA6Cfg.IS_XLEN64), addr[1:0]};
    logic [63:0] data_tmp = {64{1'b0}};
    case (addr_tmp)
      3'b000: data_tmp[CVA6Cfg.XLEN-1:0] = {data[CVA6Cfg.XLEN-1:0]};
      3'b001:
      data_tmp[CVA6Cfg.XLEN-1:0] = {data[CVA6Cfg.XLEN-9:0], data[CVA6Cfg.XLEN-1:CVA6Cfg.XLEN-8]};
      3'b010:
      data_tmp[CVA6Cfg.XLEN-1:0] = {data[CVA6Cfg.XLEN-17:0], data[CVA6Cfg.XLEN-1:CVA6Cfg.XLEN-16]};
      3'b011:
      data_tmp[CVA6Cfg.XLEN-1:0] = {data[CVA6Cfg.XLEN-25:0], data[CVA6Cfg.XLEN-1:CVA6Cfg.XLEN-24]};
      default:
      if (CVA6Cfg.IS_XLEN64) begin
        case (addr_tmp)
          3'b100:  data_tmp = {data[31:0], data[63:32]};
          3'b101:  data_tmp = {data[23:0], data[63:24]};
          3'b110:  data_tmp = {data[15:0], data[63:16]};
          3'b111:  data_tmp = {data[7:0], data[63:8]};
          default: data_tmp = {data[63:0]};
        endcase
      end
    endcase
    return data_tmp[CVA6Cfg.XLEN-1:0];
  endfunction



  // store buffer control signals
  logic st_valid;
  logic st_valid_without_flush;
  logic instr_is_amo;
  assign instr_is_amo = is_amo(lsu_ctrl_i.operation);
  // keep the data and the byte enable for the second cycle (after address translation)
  logic [CVA6Cfg.XLEN-1:0] st_data;
  logic [(CVA6Cfg.XLEN/8)-1:0] st_be;
  logic [1:0] st_data_size;
  amo_t amo_op;

  // -----------
  // Re-aligner
  // -----------
  // re-align the write data to comply with the address offset
  always_comb begin
    st_be = lsu_ctrl_i.be;
    // don't shift the data if we are going to perform an AMO as we still need to operate on this data
    st_data = (CVA6Cfg.RVA && instr_is_amo) ? lsu_ctrl_i.data[CVA6Cfg.XLEN-1:0] :
        data_align(lsu_ctrl_i.vaddr[2:0], {{64 - CVA6Cfg.XLEN{1'b0}}, lsu_ctrl_i.data});
    st_data_size = extract_transfer_size(lsu_ctrl_i.operation);
    // save AMO op for next cycle
    if (CVA6Cfg.RVA) begin
      case (lsu_ctrl_i.operation)
        AMO_LRW, AMO_LRD:     amo_op = AMO_LR;
        AMO_SCW, AMO_SCD:     amo_op = AMO_SC;
        AMO_SWAPW, AMO_SWAPD: amo_op = AMO_SWAP;
        AMO_ADDW, AMO_ADDD:   amo_op = AMO_ADD;
        AMO_ANDW, AMO_ANDD:   amo_op = AMO_AND;
        AMO_ORW, AMO_ORD:     amo_op = AMO_OR;
        AMO_XORW, AMO_XORD:   amo_op = AMO_XOR;
        AMO_MAXW, AMO_MAXD:   amo_op = AMO_MAX;
        AMO_MAXWU, AMO_MAXDU: amo_op = AMO_MAXU;
        AMO_MINW, AMO_MIND:   amo_op = AMO_MIN;
        AMO_MINWU, AMO_MINDU: amo_op = AMO_MINU;
        default:              amo_op = AMO_NONE;
      endcase
    end else begin
      amo_op = AMO_NONE;
    end
  end

  logic store_buffer_valid, amo_buffer_valid;

  // multiplex between store unit and amo buffer
  assign store_buffer_valid = st_valid_i & (!CVA6Cfg.RVA || (amo_op == AMO_NONE));
  assign amo_buffer_valid = st_valid_i & (CVA6Cfg.RVA && (amo_op != AMO_NONE));

  // ---------------
  // Store Queue
  // ---------------
  store_buffer #(
      .CVA6Cfg(CVA6Cfg),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t)
  ) store_buffer_i (
      .clk_i,
      .rst_ni,
      .flush_i,
      .stall_st_pending_i,
      .no_st_pending_o,
      .commit_i,
      .store_buffer_valid_i (store_buffer_valid),
      .commit_ready_o,
      .paddr_i,
      .rvfi_mem_paddr_o     (rvfi_mem_paddr_o),
      .data_i               (st_data),
      .be_i                 (st_be),
      .data_size_i          (st_data_size),
      .sent_to_cache_o,
      .req_port_i           (req_port_i),
      .req_port_o           (req_port_o)
  );

  if (CVA6Cfg.RVA) begin
    amo_buffer #(
        .CVA6Cfg(CVA6Cfg)
    ) i_amo_buffer (
        .clk_i,
        .rst_ni,
        .flush_i,
        .valid_i           (amo_buffer_valid),
        .ready_o           (),
        .paddr_i           (paddr_i),
        .amo_op_i          (amo_op),
        .data_i            (st_data),
        .data_size_i       (st_data_size),
        .amo_req_o         (amo_req_o),
        .amo_resp_i        (amo_resp_i),
        .amo_valid_commit_i(amo_valid_commit_i),
        .no_st_pending_i   (no_st_pending_o)
    );
  end else begin
    assign amo_req_o        = '0;
  end

endmodule
