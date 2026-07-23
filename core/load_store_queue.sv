
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright 2024 - PlanV Technologies for additionnal contribution.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Engineer:       Fieux Telmo - fieuxtelmo@gmail.com
//
// Description:

module load_store_queue
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg       = config_pkg::cva6_cfg_empty,
    parameter int unsigned           ADDR_WIDTH    = 32,
    parameter int unsigned           LSQ_DEPTH     = 4,
    parameter type lsu_ctrl_t = logic
) (
    input logic                                               clk_i,
    input logic                                               rst_ni,
    output logic [1:0]                                        full_o, // 1 bit for stores and the other for loads
    input logic                                               commit_i, //commit latest store

    input logic                                               rollback_i, // architectural register to rollback
    input logic [CVA6Cfg.TRANS_ID_BITS-1:0]                   rollback_trans_id_i, // rollback is enabled

    input logic [CVA6Cfg.NrIssuePorts-1:0][1:0]               we_i, // 0 for store and 1 for load
    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.GlobalRsIdWidth-1:0]global_id_i,
    output logic [CVA6Cfg.NrIssuePorts-1:0][$clog2(LSQ_DEPTH)-1:0] lsq_id_o,

    input logic [$clog2(LSQ_DEPTH)-1:0]                       lsq_id_i,
    // Physical address - MMU
    input logic [CVA6Cfg.PLEN-1:0]                            paddr_i,

    input lsu_ctrl_t                                          dispatched_instr_i,
    input logic                                               dispatched_instr_valid_i,

    // reserved id - ISSUE_STAGE
    output logic lsu_ctrl_t                                   dispatched_instr_o,
    output logic                                              dispatched_instr_vaild_o,
    input logic                                               load_ready_i,
    input logic                                               store_ready_i,
);

  typedef struct packed {
    lsu_ctrl_t instr [LSQ_DEPTH-1:0];
    logic [LSQ_DEPTH-1:0]  valid;
    logic [LSQ_DEPTH-1:0]  reserved;
    logic [LSQ_DEPTH-1:0][CVA6Cfg.PLEN-1:0] paddr;
  } queue_t;

  assign full_o[0] = st_commit_pointer_q == st_reservation_pointer_q;
  assign full_o[1] = ld_empty;

  queue_t st_queue_n, st_queue_q;
  queue_t ld_queue_n, ld_queue_q;

  logic [$clog2(LSQ_DEPTH)-1:0] st_reservation_pointer_n, st_reservation_pointer_q;
  logic [$clog2(LSQ_DEPTH)-1:0] st_commit_pointer_n, st_commit_pointer_q;


  logic [$clog2(LSQ_DEPTH)-1:0] alloc_idx;
  logic ld_empty;

  logic [LSQ_DEPTH-1:0] match_addr;
  logic [LSQ_DEPTH-1:0] partial_match_addr;

  always_comb begin : check_matching_addr

    if (dispatched_instr_i.fu == STORE) begin
      for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
        match_addr = paddr_i == ld_queue_q.instr[i].paddr;
        partial_match_addr = paddr_i == ld_queue_q.instr[i].paddr;
      end
    end else begin
      for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
        match_addr = paddr_i == st_queue_q.instr[i].paddr;
      end
    end

  end

  //priority encoder cascade to get free entrie for load queue
  //only necessary for load since store are reserved and committed in order
  lzc #(
      .WIDTH(LSQ_DEPTH),
      .MODE(1'b0))
  i_lzc (
      .in_i   (ld_queue_q.reserved),
      .cnt_o  (alloc_idx),
      .empty_o(ld_empty)
  );

  assign ld_queue_n.reserved = (we_i[1] && !ld_empty) ?
    (ld_queue_q.reserved & ~(LSQ_DEPTH'(1) << alloc_idx)) :
    ld_queue_q.reserved;

  // Reserving an entry in the LSQ
  always_comb begin : updating_reservation
    for (int unsigned i = 0 ; i < CVA6Cfg.NrIssuePorts ; i++) begin
      if (we_i[i][0] && !full_o[0]) begin
        st_queue_n.reserved[st_queue_q.reservation_pointer] = 1'b1;
        st_queue_n.instr[st_queue_q.reservation_pointer].global_id = global_id_i[i];
        lsq_id_o[i] = st_reservation_pointer_q;
        st_reservation_pointer_n = st_reservation_pointer_q + 1'b1;
      end else if (we_i[i][1] && !full_o[1]) begin
        lsq_id_o[i] = alloc_idx;
        ld_queue_n.instr[ld_queue_q.reservation_pointer].global_id = global_id_i[i];
      end
    end
  end


  // Occupying the space reserved
  always_comb begin : updating_reserved_entry
    if (dispatched_instr_valid_i) begin
      if (dispatched_instr_i.fu == STORE) begin
        st_queue_n.instr[lsq_id_i] = dispatched_instr_i;
        st_queue_n.valid[lsq_id_i] = 1'b1;
        st_queue_n.paddr[lsq_id_i] = paddr_i;
      end else begin
        ld_queue_n.instr[lsq_id_i] = dispatched_instr_i;
        ld_queue_n.paddr[lsq_id_i] = paddr_i;
      end
    end
  end

  // Update dependencies
  always_comb begin : updating dependencies
    if (dispatched_instr_valid_i) begin
      if (dispatched_instr_i.fu == STORE) begin

      end

    end
  end

  // Issuing instruction and store to load forwarding

  // Commit store

  // Rollback

  // Flush


  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // rat_q.free_regs <= NUM_REG'('1) << 32;
      rat_q.free_regs <= '1;
      for (int i = 0; i < 32; i++) begin
        rat_q.rat[i] <= ADDR_WIDTH'(i);
      end
    end else begin
      rat_q <= rat_n;
    end
  end
endmodule
