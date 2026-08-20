
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
    parameter int unsigned           LSQ_DEPTH     = 4,
    parameter type fu_data_t = logic,
    parameter type lsu_ctrl_t = logic,
    parameter type exception_t = logic
) (
    input logic                                                       clk_i,
    input logic                                                       rst_ni,
    input logic                                                       flush_i,
    output logic [CVA6Cfg.NrIssuePorts-1:0]                           full_o,
    input logic                                                       commit_i, //commit latest store
    input logic [CVA6Cfg.TRANS_ID_BITS-1:0]                           commit_trans_id_i,
    // Presence of non-idempotent operations in the D$ write buffer - CACHES
    input logic                                                       dcache_wbuffer_not_ni_i,
    // Is ldbuf full - LOAD_UNIT
    input logic                                                       ldbuf_full_i,
    // pop ld queue - LOAD_UNIT
    input logic                                                       ld_pop_i,

    input logic [CVA6Cfg.RollbackWidth-1:0]                                                      rollback_i, // architectural register to rollback
    input logic [CVA6Cfg.RollbackWidth-1:0][CVA6Cfg.TRANS_ID_BITS-1:0]                           rollback_trans_id_i, // rollback is enabled
    // Store dispatched trans_id - SCOREBOARD
    output logic [CVA6Cfg.TRANS_ID_BITS-1:0]                          store_dispatched_id_o, // je pense que c'est plus nécessaire dans ce design



    input logic [CVA6Cfg.NrIssuePorts-1:0]                            ld_we_i,
    input logic [CVA6Cfg.NrIssuePorts-1:0]                            st_we_i,
    // instr issued to the scoreboard this cycle - ISSUE_READ_OPERAND
    input fu_data_t [CVA6Cfg.NrIssuePorts-1:0]                        fu_data_i,
    // TO_BE_COMPLETED - ISSUE_READ_OPERAND
    input logic [CVA6Cfg.NrIssuePorts-1:0][31:0]                      tinst_i,
    // is instr valid - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0]                            decoded_instr_valid_i,
    // Handshake with decode stage - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0]                            decoded_instr_ack_i,
    // dest reg of the vaddr needed by a store - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0]  data_trans_id_i,
    // dest reg of the vaddr needed by a store or a load - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0]  vaddr_trans_id_i,
    // Store data valid - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0]                            st_data_valid_i,
    // Adress of the load or store valid - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0]                            vaddr_valid_i,


    // instr to be translated - MMU
    output lsu_ctrl_t                                                lsu_ctrl_o,
    // vaddr to be translated - MMU
    output logic [CVA6Cfg.VLEN-1:0]                                   vaddr_o,
    // Transformed trap instruction out - MMU
    output logic [31:0]                                               tinst_o,
    // Instruction is a hyp load store instruction - MMU
    output logic                                                      hs_ld_st_inst_o,
    // Hyp load store with execute permissions - MMU
    output logic                                                      hlvx_inst_o,
    // valid request - MMU
    output logic                                                      translation_req_o,
    // Physical address - MMU
    input logic [CVA6Cfg.PLEN-1:0]                                    paddr_i,
    // Exception raised before store - MMU
    input exception_t                                                 ex_i,
    // Data TLB hit - lsu
    input logic                                                       dtlb_hit_i,
    // Physical page number from the DTLB - MMU
    input logic [CVA6Cfg.PPNW-1:0]                                    dtlb_ppn_i,



    // Destination register in register file - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0]    wb_trans_id_i,
    // Results to write back - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.XLEN-1:0]             wbdata_i,
    // Indicates valid results - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0]                               wt_valid_i,



    // Data sent to store buffer
    output lsu_ctrl_t                                                 st_buf_lsu_ctrl_o,
    output logic                                                      st_buf_valid_o,
    output logic [CVA6Cfg.PLEN-1:0]                                   st_buf_paddr_o,
    // store sent to cache
    input logic                                                       st_sent_to_cache_i,

    output lsu_ctrl_t                                                 ld_unit_lsu_ctrl_o,
    output logic                                                      ld_unit_valid_o,
    output logic [CVA6Cfg.PLEN-1:0]                                   ld_unit_paddr_o,
    // index of the load instr in the load queue - LOAD_UNIT
    output logic [$clog2(LSQ_DEPTH)-1:0]                              ld_unit_idx_o,

    // is load unit result valid - LOAD_UNIT
    input logic                                                       ld_result_valid_i,
    // result of the load unit - LOAD_UNIT
    input logic [CVA6Cfg.XLEN-1:0]                                    ld_result_i,
    // index of the load that finished - LOAD_UNIT
    input logic [$clog2(LSQ_DEPTH)-1:0]                               ld_unit_idx_i,




    // Load unit result is valid - ISSUE_STAGE
    output logic ld_valid_o,
    // Load transaction ID - ISSUE_STAGE
    output logic [CVA6Cfg.TRANS_ID_BITS-1:0] ld_trans_id_o,
    // Load Global ID - ISSUE_STAGE
    output logic [CVA6Cfg.GlobalRsIdWidth-1:0] ld_global_id_o,
    // Load result - ISSUE_STAGE
    output logic [CVA6Cfg.XLEN-1:0] ld_result_o,
    // Load exception - ISSUE_STAGE
    output exception_t ld_ex_o,
    // Store unit result is valid - ISSUE_STAGE
    output logic st_valid_o,
    // Store transaction ID - ISSUE_STAGE
    output logic [CVA6Cfg.TRANS_ID_BITS-1:0] st_trans_id_o,
    // Store result - ISSUE_STAGE
    output logic [CVA6Cfg.XLEN-1:0] st_result_o,
    // Store exception - ISSUE_STAGE
    output exception_t st_ex_o
);

  // Return 1 if tag_a is strictly older than tag b taking into account wrap around
  // same as in tournament tree
  function automatic logic is_older(logic [CVA6Cfg.GlobalRsIdWidth-1:0] tag_a, logic [CVA6Cfg.GlobalRsIdWidth-1:0] tag_b);
    logic signed [CVA6Cfg.GlobalRsIdWidth-1:0] diff;
    diff = $signed(tag_b) - $signed(tag_a);
    return (diff[CVA6Cfg.GlobalRsIdWidth-1] == 1'b0) && (diff != '0);
  endfunction


  function automatic logic overlap_check(fu_op op_a, logic [CVA6Cfg.PLEN-1:0] paddr_a, fu_op op_b, logic [CVA6Cfg.PLEN-1:0] paddr_b);
      logic [1:0] data_size_a;
      logic [1:0] data_size_b;

      logic [CVA6Cfg.PLEN:0] end_a;
      logic [CVA6Cfg.PLEN:0] end_b;

      data_size_a = extract_transfer_size(op_a);
      data_size_b = extract_transfer_size(op_b);

      // Bornes exclusives
      end_a = {1'b0, paddr_a} + (1 << data_size_a);
      end_b = {1'b0, paddr_b} + (1 << data_size_b);

      return ({1'b0, paddr_a} < end_b) &&
            ({1'b0, paddr_b} < end_a);
  endfunction

  typedef struct packed {
    lsu_ctrl_t [LSQ_DEPTH-1:0] instr;
    logic [LSQ_DEPTH-1:0] ready; // data and paddr are valid
    logic [LSQ_DEPTH-1:0] reserved; // instr has been accepted by the rob
    logic [LSQ_DEPTH-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] vaddr_trans_id;
    logic [LSQ_DEPTH-1:0] vaddr_valid; // vaddr is valid
    logic [LSQ_DEPTH-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] data_trans_id;
    logic [LSQ_DEPTH-1:0] data_valid; // vaddr is valid
    logic [LSQ_DEPTH-1:0][CVA6Cfg.PLEN-1:0] paddr;
    logic [LSQ_DEPTH-1:0] paddr_valid; // vaddr has been translated
    logic [LSQ_DEPTH-1:0][CVA6Cfg.XLEN-1:0] result; // store imm value to compute vaddr
    logic [LSQ_DEPTH-1:0] ex_valid;
  } st_queue_t;

  typedef struct packed {
    lsu_ctrl_t [LSQ_DEPTH-1:0] instr;
    logic [LSQ_DEPTH-1:0] ready; // data and paddr are valid
    logic [LSQ_DEPTH-1:0] reserved; // instr has been accepted by the rob
    logic [LSQ_DEPTH-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] vaddr_trans_id;
    logic [LSQ_DEPTH-1:0] vaddr_valid; // vaddr is valid
    logic [LSQ_DEPTH-1:0][CVA6Cfg.PLEN-1:0] paddr;
    logic [LSQ_DEPTH-1:0] paddr_valid; // vaddr has been translated
    logic [LSQ_DEPTH-1:0] paddr_ni; // vaddr has been translated
    logic [LSQ_DEPTH-1:0][CVA6Cfg.XLEN-1:0] result; // holds both result and temporarly imm value to compute vaddr
    logic [LSQ_DEPTH-1:0] result_valid; // data and paddr are valid
    logic [LSQ_DEPTH-1:0][LSQ_DEPTH-1:0] matching_addr;
    logic [LSQ_DEPTH-1:0][LSQ_DEPTH-1:0] partial_matching_addr;
    exception_t [LSQ_DEPTH-1:0] ex;
  } ld_queue_t;


  // current cycle updated readyness to allow for immediately issue instruction
  // as soon as we got the translation
  logic [LSQ_DEPTH-1:0] ld_unit_ready;

  st_queue_t st_queue_n, st_queue_q;
  ld_queue_t ld_queue_n, ld_queue_q;

  logic [$clog2(LSQ_DEPTH)-1:0] st_commit_pointer_n, st_commit_pointer_q;
  logic [$clog2(LSQ_DEPTH)-1:0] st_issue_pointer_n, st_issue_pointer_q;
  logic [$clog2(LSQ_DEPTH)-1:0] st_drain_pointer_n, st_drain_pointer_q;
  logic [$clog2(LSQ_DEPTH+1)-1:0] st_status_cnt_n, st_status_cnt_q;

  logic [$clog2(LSQ_DEPTH)-1:0] translation_pointer_n, translation_pointer_q;
  logic [$clog2(LSQ_DEPTH)-1:0] previous_translation_pointer_n, previous_translation_pointer_q;
  logic previous_translation_pointer_type_n, previous_translation_pointer_type_q;
  logic translation_pointer_valid_n, translation_pointer_valid_q;
  logic translation_pointer_type_n, translation_pointer_type_q;
  logic translation_data_valid_n, translation_data_valid_q;

  // issuing signal
  lsu_ctrl_t [LSQ_DEPTH-1:0]              st_comb_lsu_ctrl_o, ld_comb_lsu_ctrl_o;
  logic [LSQ_DEPTH-1:0][CVA6Cfg.VLEN-1:0] st_comb_vaddr_o, ld_comb_vaddr_o;
  logic [LSQ_DEPTH-1:0][31:0]             st_comb_tinst_o, ld_comb_tinst_o;
  logic [LSQ_DEPTH-1:0]                   st_comb_hs_ld_st_inst_o, ld_comb_hs_ld_st_inst_o;
  logic [LSQ_DEPTH-1:0]                   st_comb_hlvx_inst_o, ld_comb_hlvx_inst_o;


  logic [$clog2(LSQ_DEPTH)-1:0]           comb_translation_pointer;
  logic                                   comb_translation_pointer_type;
  logic                                   comb_translation_pointer_valid;

  // comb match addr signals
  logic [LSQ_DEPTH-1:0][LSQ_DEPTH-1:0] comb_matching_addr;
  logic [LSQ_DEPTH-1:0][LSQ_DEPTH-1:0] comb_partial_matching_addr;

  // adress dependencies signals
  logic [LSQ_DEPTH-1:0][CVA6Cfg.PLEN-1:0] ld_paddr, st_paddr;
  logic [LSQ_DEPTH-1:0]                   ld_paddr_valid, st_paddr_valid;

  // readyness/forwarding signals
  logic [LSQ_DEPTH-1:0][CVA6Cfg.XLEN-1:0] data;
  logic [LSQ_DEPTH-1:0] data_valid;

  logic [LSQ_DEPTH-1:0][LSQ_DEPTH-1:0] st_older; // all valid store older than 1 load
  logic [LSQ_DEPTH-1:0] st_older_all_valid; // all valid precedent store have valid data and paddr
  logic [LSQ_DEPTH-1:0] st_older_paddr_valid; // all valid precedent store have valid paddr

  //store to load forwarding signals
  logic [LSQ_DEPTH-1:0][$clog2(LSQ_DEPTH)-1:0] full_match_winner_k, partial_match_winner_k;
  logic [LSQ_DEPTH-1:0] full_no_match, partial_no_match;
  logic [LSQ_DEPTH-1:0][$clog2(LSQ_DEPTH)-1:0] full_match_winner_idx, partial_match_winner_idx;
  logic [LSQ_DEPTH-1:0][LSQ_DEPTH-1:0] full_match_rotated_mask;
  logic [LSQ_DEPTH-1:0][LSQ_DEPTH-1:0] partial_match_rotated_mask;

  logic [CVA6Cfg.NrIssuePorts-1:0] ld_full, st_full;

  for (genvar i = 0; i<CVA6Cfg.NrIssuePorts; i++) begin
    assign st_full[i] = ((st_status_cnt_q + i) >= LSQ_DEPTH) && st_we_i[i];
  end

  for (genvar i = 0; i<CVA6Cfg.NrIssuePorts; i++) begin
    assign full_o[i] = ld_we_i[i] ? ld_full[i] : st_full[i];
  end

  // Data sent to store buffer for execution
  assign st_buf_lsu_ctrl_o = st_queue_q.instr[st_commit_pointer_q];
  assign st_buf_paddr_o = st_queue_q.paddr[st_commit_pointer_q];
  assign st_buf_valid_o = st_queue_q.reserved[st_commit_pointer_q]
    && st_queue_q.ready[st_commit_pointer_q]
    && st_queue_q.paddr_valid[st_commit_pointer_q]
    && st_queue_q.data_valid[st_commit_pointer_q]
    && !st_queue_q.ex_valid[st_commit_pointer_q];

  lsu_ctrl_t [CVA6Cfg.NrIssuePorts-1:0] decoded_req;

  logic      [CVA6Cfg.NrIssuePorts-1:0][    CVA6Cfg.VLEN-1:0] vaddr;
  logic      [CVA6Cfg.NrIssuePorts-1:0][    CVA6Cfg.XLEN-1:0] vaddr_xlen;
  logic      [CVA6Cfg.NrIssuePorts-1:0]                       overflow;
  logic      [CVA6Cfg.NrIssuePorts-1:0]                       g_overflow;
  logic      [CVA6Cfg.NrIssuePorts-1:0][(CVA6Cfg.XLEN/8)-1:0] be;
  logic      [CVA6Cfg.NrCommitPorts-1:0]                      hs_ld_st_inst;
  logic      [CVA6Cfg.NrCommitPorts-1:0]                      hlvx_inst;
  logic      [CVA6Cfg.NrIssuePorts-1:0][    CVA6Cfg.XLEN-1:0] st_data;

  logic [LSQ_DEPTH-1:0] wb_valid;
  logic [LSQ_DEPTH-1:0][CVA6Cfg.XLEN-1:0] wb_data;
  exception_t [LSQ_DEPTH-1:0] wb_ex;

  logic [LSQ_DEPTH-1:0] ld_ready_tournament_valid;
  logic [LSQ_DEPTH-1:0][CVA6Cfg.GlobalRsIdWidth-1:0] ld_ready_tournament_seq_num;
  logic [LSQ_DEPTH-1:0][$clog2(LSQ_DEPTH)-1:0] ld_ready_tournament_id;

  for (genvar i = 0 ; i < LSQ_DEPTH ; i++) begin
    assign ld_ready_tournament_seq_num[i] = ld_queue_q.instr[i].global_id;
    // in theory should not select a forwardable load (in theory...)
    assign ld_ready_tournament_valid[i] = ld_unit_ready[i];
    assign ld_ready_tournament_id[i] = i;
  end

  logic [$clog2(LSQ_DEPTH)-1:0] ld_ready_pointer;
  logic ld_ready_pointer_valid;

  tournament_tree #(
      .ID_SIZE(CVA6Cfg.GlobalRsIdWidth),
      .NR_PLAYER(LSQ_DEPTH)
    ) i_ld_ready_tournament_tree (
      .valid_i    (ld_ready_tournament_valid),
      .seq_num_i  (ld_ready_tournament_seq_num),
      .id_i       (ld_ready_tournament_id),
      .winner_o   (ld_ready_pointer),
      .winner_valid_o (ld_ready_pointer_valid)
  );

  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : decoded_req_alloc
    // ------------------------
    // Hypervisor Load/Store
    // ------------------------
    // determine whether this is a hypervisor load or store
    if (CVA6Cfg.RVH) begin
      always_comb begin : hyp_ld_st
        // check the operator to activate the right functional unit accordingly
        hs_ld_st_inst[i] = 1'b0;
        hlvx_inst[i]     = 1'b0;
        case (fu_data_i[i].operation)
          // all loads go here
          HLV_B, HLV_BU, HLV_H, HLV_HU, HLV_W, HSV_B, HSV_H, HSV_W, HLV_WU, HLV_D, HSV_D: begin
            hs_ld_st_inst[i] = 1'b1;
          end
          HLVX_WU, HLVX_HU: begin
            hs_ld_st_inst[i] = 1'b1;
            hlvx_inst[i]     = 1'b1;
          end
          default: ;
        endcase
      end
    end else begin
      assign hs_ld_st_inst[i] = 1'b0;
      assign hlvx_inst[i]     = 1'b0;
    end
  end


  // ------------------------------
  // Request creation
  // ------------------------------


  logic [CVA6Cfg.NrIssuePorts-1:0] vaddr_is_valid;
  logic [CVA6Cfg.NrIssuePorts-1:0] data_is_valid;

  always_comb begin : lsu_req_creation

    vaddr_is_valid = '0;
    data_is_valid = '0;
    st_data = '0;

    vaddr_xlen = '0;
    vaddr      = '0;
    overflow   = '0;
    g_overflow = '0;
    be         = '0;
    decoded_req = '0;

    for (int unsigned i = 0 ; i < CVA6Cfg.NrIssuePorts ; i++) begin
      if (vaddr_valid_i[i]) begin
        vaddr_xlen[i] = $unsigned($signed(fu_data_i[i].imm) + $signed(fu_data_i[i].operand_a));
        vaddr_is_valid[i] = 1'b1;
      end else begin
        for (int unsigned j = 0 ; j < CVA6Cfg.NrWbPorts ; j++) begin
          if (wt_valid_i[j] && wb_trans_id_i[j] == vaddr_trans_id_i[i]) begin
            vaddr_xlen[i] = $unsigned($signed(fu_data_i[i].imm) + $signed(wbdata_i[j]));
            vaddr_is_valid[i] = 1'b1;
          end
        end
      end
      if (st_data_valid_i[i]) begin
        data_is_valid[i] = 1'b1;
        st_data[i] = fu_data_i[i].operand_b;
      end else begin
        for (int unsigned j = 0 ; j < CVA6Cfg.NrWbPorts ; j++) begin
          if (wt_valid_i[j] && wb_trans_id_i[j] == data_trans_id_i[i]) begin
            data_is_valid[i] = 1'b1;
            st_data[i] = wbdata_i[j];
          end
        end
      end

      // ------------------------------
      // Address Generation Unit (AGU)
      // ------------------------------
      // virtual address as calculated by the AGU in the first cycle
      vaddr[i] = vaddr_xlen[i][CVA6Cfg.VLEN-1:0];
      // we work with SV39 or SV32, so if VM is enabled, check that all bits [XLEN-1:38] or [XLEN-1:31] are equal
      overflow[i] = (CVA6Cfg.IS_XLEN64 && (!((&vaddr_xlen[i][CVA6Cfg.XLEN-1:CVA6Cfg.SV-1]) == 1'b1 || (|vaddr_xlen[i][CVA6Cfg.XLEN-1:CVA6Cfg.SV-1]) == 1'b0)));
      if (CVA6Cfg.RVH) begin : gen_g_overflow_hyp
        g_overflow[i] = (CVA6Cfg.IS_XLEN64 && (!((|vaddr_xlen[i][CVA6Cfg.XLEN-1:CVA6Cfg.SVX]) == 1'b0)));
      end else begin : gen_g_overflow_no_hyp
        g_overflow[i] = 1'b0;
      end

      // ---------------
      // Byte Enable
      // ---------------
      // we can generate the byte enable from the virtual address since the last
      // 12 bit are the same anyway
      // and we can always generate the byte enable from the address at hand

      if (CVA6Cfg.IS_XLEN64) begin : gen_8b_be
        be[i] = be_gen(vaddr[i][2:0], extract_transfer_size(fu_data_i[i].operation));
      end else begin : gen_4b_be
        be[i] = be_gen_32(vaddr[i][1:0], extract_transfer_size(fu_data_i[i].operation));
      end

      decoded_req[i] = {
        decoded_instr_valid_i[i] && (ld_we_i[i] | st_we_i[i]),
        vaddr[i],
        tinst_i[i],
        hs_ld_st_inst[i],
        hlvx_inst[i],
        overflow[i],
        g_overflow[i],
        st_data[i],
        be[i],
        fu_data_i[i].fu,
        fu_data_i[i].operation,
        fu_data_i[i].trans_id,
        fu_data_i[i].global_id
      };
    end
  end


  // ---------------
  // CBD snooping
  // ---------------


  logic [LSQ_DEPTH-1:0][CVA6Cfg.VLEN-1:0]     st_snooped_vaddr, ld_snooped_vaddr;
  logic [LSQ_DEPTH-1:0][CVA6Cfg.XLEN-1:0]     st_snooped_vaddr_xlen, ld_snooped_vaddr_xlen;
  logic [LSQ_DEPTH-1:0]                       st_snooped_overflow, ld_snooped_overflow;
  logic [LSQ_DEPTH-1:0]                       st_snooped_g_overflow, ld_snooped_g_overflow;
  logic [LSQ_DEPTH-1:0][(CVA6Cfg.XLEN/8)-1:0] st_snooped_be, ld_snooped_be;
  logic [LSQ_DEPTH-1:0]                       st_snooped_we, ld_snooped_we;

  always_comb begin : data_snooping

    st_snooped_we         = '0;
    st_snooped_vaddr      = '0;
    st_snooped_vaddr_xlen = '0;
    st_snooped_overflow   = '0;
    st_snooped_g_overflow = '0;
    st_snooped_be         = '0;

    ld_snooped_we         = '0;
    ld_snooped_vaddr      = '0;
    ld_snooped_vaddr_xlen = '0;
    ld_snooped_overflow   = '0;
    ld_snooped_g_overflow = '0;
    ld_snooped_be         = '0;


    // Snooping CDB in case we are missing some data
    for ( int unsigned i = 0 ; i < LSQ_DEPTH ; i++) begin
      for (int unsigned j = 0 ; j < CVA6Cfg.NrWbPorts ; j++) begin
        if (wt_valid_i[j] && wb_trans_id_i[j] == st_queue_q.vaddr_trans_id[i] && st_queue_q.reserved[i] && !st_queue_q.vaddr_valid[i]) begin
          st_snooped_vaddr_xlen[i] = $unsigned($signed(st_queue_q.result[i]) + $signed(wbdata_i[j]));
          st_snooped_we[i] = 1'b1;
          st_snooped_vaddr[i] = st_snooped_vaddr_xlen[i][CVA6Cfg.VLEN-1:0];
          st_snooped_overflow[i] = (CVA6Cfg.IS_XLEN64 && (!((&st_snooped_vaddr_xlen[i][CVA6Cfg.XLEN-1:CVA6Cfg.SV-1]) == 1'b1 || (|st_snooped_vaddr_xlen[i][CVA6Cfg.XLEN-1:CVA6Cfg.SV-1]) == 1'b0)));
          if (CVA6Cfg.RVH) begin : st_gen_g_overflow_hyp
            st_snooped_g_overflow[i] = (CVA6Cfg.IS_XLEN64 && (!((|st_snooped_vaddr_xlen[i][CVA6Cfg.XLEN-1:CVA6Cfg.SVX]) == 1'b0)));
          end else begin : st_gen_g_overflow_no_hyp
            st_snooped_g_overflow[i] = 1'b0;
          end

          if (CVA6Cfg.IS_XLEN64) begin : st_gen_8b_be
            st_snooped_be[i] = be_gen(st_snooped_vaddr[i][2:0], extract_transfer_size(st_queue_q.instr[i].operation));
          end else begin : st_gen_4b_be
            st_snooped_be[i] = be_gen_32(st_snooped_vaddr[i][1:0], extract_transfer_size(st_queue_q.instr[i].operation));
          end
        end

        if (wt_valid_i[j] && wb_trans_id_i[j] == ld_queue_q.vaddr_trans_id[i] && ld_queue_q.reserved[i] && !ld_queue_q.vaddr_valid[i]) begin
          ld_snooped_vaddr_xlen[i] = $unsigned($signed(ld_queue_q.result[i]) + $signed(wbdata_i[j]));
          ld_snooped_we[i] = 1'b1;
          ld_snooped_vaddr[i] = ld_snooped_vaddr_xlen[i][CVA6Cfg.VLEN-1:0];
          ld_snooped_overflow[i] = (CVA6Cfg.IS_XLEN64 && (!((&ld_snooped_vaddr_xlen[i][CVA6Cfg.XLEN-1:CVA6Cfg.SV-1]) == 1'b1 || (|ld_snooped_vaddr_xlen[i][CVA6Cfg.XLEN-1:CVA6Cfg.SV-1]) == 1'b0)));
          if (CVA6Cfg.RVH) begin : ld_gen_g_overflow_hyp
            ld_snooped_g_overflow[i] = (CVA6Cfg.IS_XLEN64 && (!((|ld_snooped_vaddr_xlen[i][CVA6Cfg.XLEN-1:CVA6Cfg.SVX]) == 1'b0)));
          end else begin : ld_gen_g_overflow_no_hyp
            ld_snooped_g_overflow[i] = 1'b0;
          end

          if (CVA6Cfg.IS_XLEN64) begin : ld_gen_8b_be
            ld_snooped_be[i] = be_gen(ld_snooped_vaddr[i][2:0], extract_transfer_size(ld_queue_q.instr[i].operation));
          end else begin : ld_gen_4b_be
            ld_snooped_be[i] = be_gen_32(ld_snooped_vaddr[i][1:0], extract_transfer_size(ld_queue_q.instr[i].operation));
          end
        end
      end
    end


    // Rollback
    for (int unsigned i = 0; i < LSQ_DEPTH; i++) begin
      for (int unsigned j = 0 ; j<CVA6Cfg.RollbackWidth ; j++) begin
        if ((ld_queue_q.instr[i].trans_id == rollback_trans_id_i[j]) && rollback_i[j]) begin
          ld_snooped_we[i] = '0;
        end
        if ((st_queue_q.instr[i].trans_id == rollback_trans_id_i[j]) && rollback_i[j]) begin
          st_snooped_we[i] = '0;
        end
      end
    end

    if (flush_i) begin
      st_snooped_we = '0;
      ld_snooped_we = '0;
    end

  end


  // ---------------
  // LSQ Queue updates
  // ---------------

  logic [CVA6Cfg.NrIssuePorts:0][LSQ_DEPTH-1:0] ld_free_entries_masked;
  logic [CVA6Cfg.NrIssuePorts-1:0] ld_empty_mask;
  logic [CVA6Cfg.NrIssuePorts-1:0][$clog2(LSQ_DEPTH)-1:0] ld_alloc_idx;

  assign ld_free_entries_masked[0] = ~ld_queue_q.reserved;

  //priority encoder cascade to get free index in load queue
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : ld_alloc_tree
      lzc #(
          .WIDTH(LSQ_DEPTH),
          .MODE(1'b0))
      i_lzc (
          .in_i   (ld_free_entries_masked[i]),
          .cnt_o  (ld_alloc_idx[i]),
          .empty_o(ld_empty_mask[i])
      );

      assign ld_free_entries_masked[i+1] = (ld_we_i[i] && decoded_instr_valid_i[i] && ld_empty_mask[i] == 1'b0) ?
        (ld_free_entries_masked[i] & ~(LSQ_DEPTH'(1) << ld_alloc_idx[i])) :
        ld_free_entries_masked[i];
  end

  assign ld_full = ld_empty_mask;

  logic [LSQ_DEPTH-1:0] ld_wb_tournament_valid;
  logic [LSQ_DEPTH-1:0][CVA6Cfg.GlobalRsIdWidth-1:0] ld_wb_tournament_seq_num;
  logic [LSQ_DEPTH-1:0][$clog2(LSQ_DEPTH)-1:0] ld_wb_tournament_id;

  for (genvar i = 0 ; i < LSQ_DEPTH ; i++) begin
    assign ld_wb_tournament_seq_num[i] = ld_queue_q.instr[i].global_id;
    assign ld_wb_tournament_valid[i] = wb_valid[i];
    assign ld_wb_tournament_id[i] = i;
  end

  logic [$clog2(LSQ_DEPTH)-1:0] ld_wb_pointer;
  logic ld_wb_pointer_valid;

  tournament_tree #(
      .ID_SIZE(CVA6Cfg.GlobalRsIdWidth),
      .NR_PLAYER(LSQ_DEPTH)
    ) i_ld_wb_tournament_tree (
      .valid_i    (ld_wb_tournament_valid),
      .seq_num_i  (ld_wb_tournament_seq_num),
      .id_i       (ld_wb_tournament_id),
      .winner_o   (ld_wb_pointer),
      .winner_valid_o (ld_wb_pointer_valid)
  );


  logic [LSQ_DEPTH-1:0][CVA6Cfg.XLEN-1:0] data_snooped;
  logic [LSQ_DEPTH-1:0] data_snooped_valid;
  logic [LSQ_DEPTH-1:0] ld_is_forwarded;

  always_comb begin : updating_queues

    automatic logic [$clog2(LSQ_DEPTH)-1:0] st_issue_pointer;
    automatic logic [$clog2(LSQ_DEPTH+1)-1:0] st_status_cnt;

    ld_is_forwarded = '0;

    ld_queue_n = ld_queue_q;
    st_queue_n = st_queue_q;

    st_valid_o    = 1'b0;
    st_trans_id_o = '0;
    st_result_o   = '0;
    st_ex_o       = '0;

    // Load queue initialisation
    for (int i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      if (ld_we_i[i] && decoded_instr_ack_i[i] && !ld_full[i]) begin
        ld_queue_n.reserved[ld_alloc_idx[i]] = 1'b1;
        ld_queue_n.instr[ld_alloc_idx[i]] = decoded_req[i];
        ld_queue_n.ready[ld_alloc_idx[i]] = '0;
        ld_queue_n.vaddr_trans_id[ld_alloc_idx[i]] = vaddr_trans_id_i[i];
        ld_queue_n.vaddr_valid[ld_alloc_idx[i]] = vaddr_is_valid[i];
        ld_queue_n.result[ld_alloc_idx[i]] = fu_data_i[i].imm;
      end
    end

    //store queue initialisation
    st_issue_pointer = st_issue_pointer_q;
    st_status_cnt = st_status_cnt_q;

    for (int unsigned i = 0 ; i < CVA6Cfg.NrIssuePorts ; i++) begin
      if (st_we_i[i] && !st_full[i] && decoded_instr_ack_i[i]) begin
        st_queue_n.reserved[st_issue_pointer] = 1'b1;
        st_queue_n.instr[st_issue_pointer] = decoded_req[i];
        st_queue_n.ready[st_issue_pointer] = '0;
        st_queue_n.result[st_issue_pointer] = fu_data_i[i].imm;
        st_queue_n.data_valid[st_issue_pointer] = data_is_valid[i];
        st_queue_n.vaddr_valid[st_issue_pointer] = vaddr_is_valid[i];
        st_queue_n.vaddr_trans_id[st_issue_pointer] = vaddr_trans_id_i[i];
        st_queue_n.data_trans_id[st_issue_pointer] = data_trans_id_i[i];
        st_issue_pointer = st_issue_pointer + 1'b1;
        st_status_cnt = st_status_cnt + 1'b1;
      end
    end

    // Adding snooped data to the queues
    for ( int unsigned i = 0 ; i < LSQ_DEPTH ; i++) begin
      if (st_snooped_we[i]) begin
        st_queue_n.instr[i].vaddr = st_snooped_vaddr[i];
        st_queue_n.instr[i].overflow = st_snooped_overflow[i];
        st_queue_n.instr[i].g_overflow = st_snooped_g_overflow[i];
        st_queue_n.instr[i].be = st_snooped_be[i];
        st_queue_n.vaddr_valid[i] = 1'b1;
        end

      if (ld_snooped_we[i]) begin
        ld_queue_n.instr[i].vaddr = ld_snooped_vaddr[i];
        ld_queue_n.instr[i].overflow = ld_snooped_overflow[i];
        ld_queue_n.instr[i].g_overflow = ld_snooped_g_overflow[i];
        ld_queue_n.instr[i].be = ld_snooped_be[i];
        ld_queue_n.vaddr_valid[i] = 1'b1;
      end
    end

    data_snooped_valid = '0;
    data_snooped = '0;

    for ( int unsigned i = 0 ; i < LSQ_DEPTH ; i++) begin
      for (int unsigned j = 0 ; j < CVA6Cfg.NrWbPorts ; j++) begin
        if (wt_valid_i[j] && wb_trans_id_i[j] == st_queue_q.data_trans_id[i] && st_queue_q.reserved[i] && !st_queue_q.data_valid[i]) begin
          data_snooped_valid[i] = 1'b1;
          data_snooped[i] = wbdata_i[j];
          st_queue_n.instr[i].data = wbdata_i[j];
          st_queue_n.data_valid[i] = 1'b1;
        end
      end
    end

    //Updating paddr
    if (translation_data_valid_q && (CVA6Cfg.MmuPresent || CVA6Cfg.NonIdemPotenceEn)) begin
      if (previous_translation_pointer_type_q == 1'b1) begin
        if (!ex_i.valid) begin
          st_queue_n.paddr[previous_translation_pointer_q] = paddr_i;
          st_queue_n.paddr_valid[previous_translation_pointer_q] = 1'b1;
        end
      end else begin
        if (!ex_i.valid) begin
          ld_queue_n.paddr[previous_translation_pointer_q] = paddr_i;
          ld_queue_n.paddr_valid[previous_translation_pointer_q] = 1'b1;
        end
      end
    end else if (!(CVA6Cfg.MmuPresent || CVA6Cfg.NonIdemPotenceEn)) begin
      for ( int unsigned i = 0 ; i < LSQ_DEPTH ; i++) begin
        st_queue_n.paddr[i] = CVA6Cfg.PLEN'(st_queue_q.instr[i].vaddr);
        st_queue_n.paddr_valid[i] = st_queue_q.vaddr_valid[i];
        ld_queue_n.paddr[i] = CVA6Cfg.PLEN'(ld_queue_q.instr[i].vaddr);
        ld_queue_n.paddr_valid[i] = ld_queue_q.vaddr_valid[i];
      end
    end

    // updating non idempotent state
    if (CVA6Cfg.MmuPresent && dtlb_hit_i && comb_translation_pointer_type == 1'b0) begin
      if (dtlb_hit_i) begin
        if (translation_pointer_valid_q) begin
          // update based on register
          ld_queue_n.paddr_ni[translation_pointer_valid_q] = config_pkg::is_inside_nonidempotent_regions
            (
              CVA6Cfg,
              {{52 - CVA6Cfg.PPNW{1'b0}}, dtlb_ppn_i, 12'd0}
            ) && CVA6Cfg.NonIdemPotenceEn;
        end else begin
          // update based on combinatory signals
          ld_queue_n.paddr_ni[comb_translation_pointer] = config_pkg::is_inside_nonidempotent_regions
            (
              CVA6Cfg,
              {{52 - CVA6Cfg.PPNW{1'b0}}, dtlb_ppn_i, 12'd0}
            ) && CVA6Cfg.NonIdemPotenceEn;
        end
      end
    end else if (CVA6Cfg.NonIdemPotenceEn && translation_req_o && comb_translation_pointer_type == 1'b0) begin
      ld_queue_n.paddr_ni[comb_translation_pointer] = config_pkg::is_inside_nonidempotent_regions
        (
          CVA6Cfg,
          {{52 - CVA6Cfg.PPNW{1'b0}}, dtlb_ppn_i, 12'd0}
        ) && CVA6Cfg.NonIdemPotenceEn;
    end



    // load exception
    if (translation_data_valid_q && ex_i.valid && previous_translation_pointer_type_q == 1'b0) begin
      ld_queue_n.ex[previous_translation_pointer_q]= ex_i;
      ld_queue_n.result_valid[previous_translation_pointer_q]= 1'b1;
      ld_queue_n.ex[previous_translation_pointer_q].cause = ex_i.cause;
      ld_queue_n.ex[previous_translation_pointer_q].tval = ex_i.tval;
      ld_queue_n.ex[previous_translation_pointer_q].tval2 = CVA6Cfg.RVH ? ex_i.tval2 : '0;
      ld_queue_n.ex[previous_translation_pointer_q].tinst = CVA6Cfg.RVH ? ex_i.tinst : '0;
      ld_queue_n.ex[previous_translation_pointer_q].gva = CVA6Cfg.RVH ? ex_i.gva : 1'b0;
    end


    // store write back
    if (translation_data_valid_q && previous_translation_pointer_type_q == 1'b1) begin
      st_trans_id_o = st_queue_q.instr[previous_translation_pointer_q].trans_id;
      st_ex_o = ex_i;
      st_valid_o = 1'b1;
      if (ex_i.valid) begin
        st_queue_n.ex_valid[previous_translation_pointer_q] = 1'b1;
      end
    end


    //updating load queus with adress match info
    ld_queue_n.matching_addr = comb_matching_addr;
    ld_queue_n.partial_matching_addr = comb_partial_matching_addr;


    // ---------------
    // Updating readyness
    // ---------------

    ld_unit_ready = '0;

    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      if(st_paddr_valid[i] && data_valid[i] && st_queue_q.reserved[i]) begin
        st_queue_n.ready[i] = 1'b1;
      end

      // load is not ready if :
      // - all previous store did not receive their paddr (we cannot verify dependencies)
      // - it is a non idempotent load
      // - we match with an older store adress
      if(ld_paddr_valid[i] && ld_queue_q.reserved[i]) begin
        ld_queue_n.ready[i] = 1'b1;
        ld_unit_ready[i] = 1'b1;
        if (ld_queue_q.paddr_ni[i]) begin
          ld_queue_n.ready[i] = ld_queue_q.ready[i] || (commit_trans_id_i == ld_queue_q.instr[i].trans_id & dcache_wbuffer_not_ni_i);
          ld_unit_ready[i] = ld_queue_q.ready[i] || (commit_trans_id_i == ld_queue_q.instr[i].trans_id & dcache_wbuffer_not_ni_i);
        end else begin
          if (|st_older[i]) begin
            if (!st_older_paddr_valid[i]) begin
              ld_queue_n.ready[i] = 1'b0;
              ld_unit_ready[i] = 1'b0;
            end else begin
              for (int unsigned j = 0; j<LSQ_DEPTH; j ++) begin
                if(st_older[i][j] && (ld_queue_q.matching_addr[i][j] || ld_queue_q.partial_matching_addr[i][j])) begin
                  ld_queue_n.ready[i] = 1'b0;
                  ld_unit_ready[i] = 1'b0;
                end
              end
            end
          end
        end
      end
    end


    // ---------------
    // Store to Load forwarding
    // ---------------

    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      if(ld_paddr_valid[i] & ld_queue_q.reserved[i] & !ld_queue_q.paddr_ni[i]) begin
        // only forward if all data is available
        if (st_older_all_valid[i]) begin
          if (!full_no_match[i]) begin
            if (!partial_no_match[i]) begin
              if (!is_older(st_queue_q.instr[full_match_winner_idx[i]].global_id, st_queue_q.instr[partial_match_winner_idx[i]].global_id)) begin
                ld_queue_n.result_valid[i] = 1'b1;
                ld_queue_n.result[i] = data[i];
                ld_is_forwarded[i] = 1'b1;
              end
            end else begin
              ld_queue_n.result_valid[i] = 1'b1;
              ld_queue_n.result[i] = data[i];
              ld_is_forwarded[i] = 1'b1;
            end
          end
        end
      end
    end

    // ---------------
    // Issuing to store and load unit
    // ---------------

    //store unit

    st_commit_pointer_n = st_commit_pointer_q;
    st_drain_pointer_n = st_drain_pointer_q;

    if (st_queue_q.ready[st_commit_pointer_q] & !st_queue_q.ex_valid[st_commit_pointer_q]
        & commit_i & (commit_trans_id_i == st_queue_q.instr[st_commit_pointer_q].trans_id)) begin
      st_commit_pointer_n = st_commit_pointer_n + 1'b1;
    end

    if(st_sent_to_cache_i) begin
      st_queue_n.ready[st_drain_pointer_q] = '0;
      st_queue_n.reserved[st_drain_pointer_q] = '0;
      st_queue_n.vaddr_valid[st_drain_pointer_q] = '0;
      st_queue_n.data_valid[st_drain_pointer_q] = '0;
      st_queue_n.paddr_valid[st_drain_pointer_q] = '0;
      st_queue_n.ex_valid[st_drain_pointer_q] = '0;
      st_drain_pointer_n = st_drain_pointer_n + 1'b1;
      st_status_cnt = st_status_cnt - 1'b1;
    end


    //load unit
    if (ld_pop_i) begin
      ld_queue_n.ready[ld_ready_pointer] = '0;
    end

    if (ld_result_valid_i) begin
      ld_queue_n.result_valid[ld_unit_idx_i] = 1'b1;
      ld_queue_n.result[ld_unit_idx_i] = ld_result_i;
    end

    // free entrie only when wb is done
    if (ld_valid_o) begin
      ld_queue_n.ready[ld_wb_pointer] = '0;
      ld_queue_n.result_valid[ld_wb_pointer] = '0;
      ld_queue_n.reserved[ld_wb_pointer] = '0;
      ld_queue_n.vaddr_valid[ld_wb_pointer] = '0;
      ld_queue_n.paddr_valid[ld_wb_pointer] = '0;
      ld_queue_n.matching_addr[ld_wb_pointer] = '0;
      ld_queue_n.partial_matching_addr[ld_wb_pointer] = '0;
      ld_queue_n.ex[ld_wb_pointer].valid = '0;
    end

    for (int unsigned i = 0; i < LSQ_DEPTH; i++) begin
      for (int unsigned j = 0 ; j<CVA6Cfg.RollbackWidth ; j++) begin
        if (ld_queue_q.reserved[i] && ld_queue_q.instr[i].trans_id == rollback_trans_id_i[j] && rollback_i[j]) begin
          ld_queue_n.reserved[i] = 1'b0;
          ld_queue_n.ready[i] = 1'b0;
          ld_queue_n.vaddr_valid[i] = 1'b0;
          ld_queue_n.paddr_valid[i] = 1'b0;
          ld_queue_n.result_valid[i] = 1'b0;
          ld_queue_n.ex[i] = '0;
        end
        if (st_queue_q.reserved[i] && st_queue_q.instr[i].trans_id == rollback_trans_id_i[j] && rollback_i[j]) begin
          st_queue_n.reserved[i] = 1'b0;
          st_queue_n.ready[i] = 1'b0;
          st_queue_n.vaddr_valid[i] = 1'b0;
          st_queue_n.paddr_valid[i] = 1'b0;
          st_queue_n.data_valid[i] = 1'b0;
          st_queue_n.ex_valid[i] = '0;
          st_status_cnt = st_status_cnt - 1'b1;
          st_issue_pointer = st_issue_pointer -1'b1;
        end
      end
    end

    if (flush_i) begin
      ld_queue_n = '0;

      // Maybe we should not erase the store not yet sent to the cache
      // but i can't imagine a scenario where is causes au problem
      st_queue_n = '0;
      st_drain_pointer_n = '0;
      st_commit_pointer_n = '0;
      st_issue_pointer = '0;
      st_status_cnt = '0;

    end

    //update store count
    st_status_cnt_n = st_status_cnt;
    st_issue_pointer_n = st_issue_pointer;

  end


  logic [CVA6Cfg.NrIssuePorts-1:0][$clog2(LSQ_DEPTH)-1:0] st_alloc_idx;

  always_comb begin : st_alloc
    automatic logic [$clog2(LSQ_DEPTH)-1:0] ptr;

    ptr = st_issue_pointer_q;

    for (int i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      st_alloc_idx[i] = ptr;

      if (st_we_i[i] && decoded_instr_ack_i[i] && !st_full[i]) begin
        ptr = ptr + 1'b1;
      end
    end
  end


  // ---------------
  // Translating vaddr
  // ---------------

  logic [LSQ_DEPTH-1:0] st_comb_vaddr_valid;
  logic [LSQ_DEPTH-1:0] ld_comb_vaddr_valid;

  logic [LSQ_DEPTH-1:0] ld_tournament_valid;
  logic [LSQ_DEPTH-1:0][CVA6Cfg.GlobalRsIdWidth-1:0] ld_tournament_seq_num;
  logic [LSQ_DEPTH-1:0][$clog2(LSQ_DEPTH)-1:0] ld_tournament_id;

  for (genvar i = 0 ; i < LSQ_DEPTH ; i++) begin
    assign ld_tournament_seq_num[i] = ld_comb_lsu_ctrl_o[i].global_id;
    assign ld_tournament_valid[i] = ld_comb_vaddr_valid[i];
    assign ld_tournament_id[i] = i;
  end

  logic [$clog2(LSQ_DEPTH)-1:0] ld_translation_pointer;
  logic ld_translation_pointer_valid;

  tournament_tree #(
      .ID_SIZE(CVA6Cfg.GlobalRsIdWidth),
      .NR_PLAYER(LSQ_DEPTH)
    ) i_ld_translation_tournament_tree (
      .valid_i    (ld_tournament_valid),
      .seq_num_i  (ld_tournament_seq_num),
      .id_i       (ld_tournament_id),
      .winner_o   (ld_translation_pointer),
      .winner_valid_o (ld_translation_pointer_valid)
  );

  logic [LSQ_DEPTH-1:0] st_tournament_valid;
  logic [LSQ_DEPTH-1:0][CVA6Cfg.GlobalRsIdWidth-1:0] st_tournament_seq_num;
  logic [LSQ_DEPTH-1:0][$clog2(LSQ_DEPTH)-1:0] st_tournament_id;

  for (genvar i = 0 ; i < LSQ_DEPTH ; i++) begin
    assign st_tournament_seq_num[i] = st_comb_lsu_ctrl_o[i].global_id;
    assign st_tournament_valid[i] = st_comb_vaddr_valid[i];
    assign st_tournament_id[i] = i;
  end

  logic [$clog2(LSQ_DEPTH)-1:0] st_translation_pointer;
  logic st_translation_pointer_valid;

  tournament_tree #(
      .ID_SIZE(CVA6Cfg.GlobalRsIdWidth),
      .NR_PLAYER(LSQ_DEPTH)
    ) i_st_translation_tournament_tree (
      .valid_i    (st_tournament_valid),
      .seq_num_i  (st_tournament_seq_num),
      .id_i       (st_tournament_id),
      .winner_o   (st_translation_pointer),
      .winner_valid_o (st_translation_pointer_valid)
  );


  // Virtual adress translation data
  assign hs_ld_st_inst_o = CVA6Cfg.RVH ?
    translation_pointer_valid_q & CVA6Cfg.MmuPresent ?
      (translation_pointer_type_q ? st_queue_q.instr[translation_pointer_q].hs_ld_st_inst : ld_queue_q.instr[translation_pointer_q].hs_ld_st_inst)
    : (comb_translation_pointer_type ? st_comb_hs_ld_st_inst_o[comb_translation_pointer] : ld_comb_hs_ld_st_inst_o[comb_translation_pointer])
  : 1'b0;
  assign hlvx_inst_o = CVA6Cfg.RVH ?
    translation_pointer_valid_q & CVA6Cfg.MmuPresent ?
      (translation_pointer_type_q ? st_queue_q.instr[translation_pointer_q].hlvx_inst : ld_queue_q.instr[translation_pointer_q].hlvx_inst)
    : (comb_translation_pointer_type ? st_comb_hlvx_inst_o[comb_translation_pointer] : ld_comb_hlvx_inst_o[comb_translation_pointer])
  : 1'b0;
  assign tinst_o = CVA6Cfg.RVH ?
    translation_pointer_valid_q & CVA6Cfg.MmuPresent ?
      (translation_pointer_type_q ? st_queue_q.instr[translation_pointer_q].tinst : ld_queue_q.instr[translation_pointer_q].tinst)
    : (comb_translation_pointer_type ? st_comb_tinst_o[comb_translation_pointer] : ld_comb_tinst_o[comb_translation_pointer])
  : 1'b0;
  assign vaddr_o = translation_pointer_valid_q & CVA6Cfg.MmuPresent ?
      (translation_pointer_type_q ? st_queue_q.instr[translation_pointer_q].vaddr : ld_queue_q.instr[translation_pointer_q].vaddr)
    : (comb_translation_pointer_type ? st_comb_vaddr_o[comb_translation_pointer] : ld_comb_vaddr_o[comb_translation_pointer]);
  assign lsu_ctrl_o = translation_pointer_valid_q & CVA6Cfg.MmuPresent ?
      (translation_pointer_type_q ? st_queue_q.instr[translation_pointer_q] : ld_queue_q.instr[translation_pointer_q])
    : (comb_translation_pointer_type ? st_comb_lsu_ctrl_o[comb_translation_pointer] : ld_comb_lsu_ctrl_o[comb_translation_pointer]);
  assign translation_req_o = CVA6Cfg.MmuPresent ?
      (translation_pointer_valid_q || comb_translation_pointer_valid)
    : comb_translation_pointer_valid;

  always_comb begin : comb_translation_data


    automatic logic [LSQ_DEPTH-1:0] st_is_translating;
    automatic logic [LSQ_DEPTH-1:0] ld_is_translating;

    for (int unsigned i = 0 ; i < LSQ_DEPTH ; i++) begin
      st_is_translating[i] = (CVA6Cfg.MmuPresent && translation_pointer_valid_q && translation_pointer_type_q == 1'b1 && translation_pointer_q == i);
      ld_is_translating[i] = (CVA6Cfg.MmuPresent && translation_pointer_valid_q && translation_pointer_type_q == 1'b0 && translation_pointer_q == i);
    end

    st_comb_vaddr_valid = '0;
    st_comb_lsu_ctrl_o = '0;
    st_comb_vaddr_o = '0;
    st_comb_tinst_o = '0;
    st_comb_hs_ld_st_inst_o = '0;
    st_comb_hlvx_inst_o = '0;

    ld_comb_vaddr_valid = '0;
    ld_comb_lsu_ctrl_o = '0;
    ld_comb_vaddr_o = '0;
    ld_comb_tinst_o = '0;
    ld_comb_hs_ld_st_inst_o = '0;
    ld_comb_hlvx_inst_o = '0;

    //update current cycle vaddr validity
    for (int unsigned i = 0 ; i < LSQ_DEPTH ; i++) begin

      // validity updated from st_queue_q and current paddr state
      if (st_queue_q.reserved[i] && st_queue_q.vaddr_valid[i] && !st_paddr_valid[i] && !st_is_translating[i]) begin
        st_comb_vaddr_valid[i] = 1'b1;
        st_comb_lsu_ctrl_o[i] = st_queue_q.instr[i];
        st_comb_vaddr_o[i] = st_queue_q.instr[i].vaddr;
        st_comb_tinst_o[i] = st_queue_q.instr[i].tinst;
        st_comb_hs_ld_st_inst_o[i] = st_queue_q.instr[i].hs_ld_st_inst;
        st_comb_hlvx_inst_o[i] = st_queue_q.instr[i].hlvx_inst;
      end

      // validity updated from currently reserved instr
      for (int unsigned j = 0 ; j < CVA6Cfg.NrIssuePorts ; j++) begin
        if (vaddr_is_valid[j] & st_alloc_idx[j] == i & st_we_i[j] & decoded_instr_ack_i[j] & !st_full[j]) begin
          st_comb_vaddr_valid[i] = 1'b1;
          st_comb_lsu_ctrl_o[i] = decoded_req[j];
          st_comb_vaddr_o[i] = vaddr[j];
          st_comb_tinst_o[i] = tinst_i[j];
          st_comb_hs_ld_st_inst_o[i] = hs_ld_st_inst[j];
          st_comb_hlvx_inst_o[i] = hlvx_inst[j];
        end
      end

      // validity updated from snooping after reserving an entry
      if (st_snooped_we[i]) begin
        st_comb_vaddr_valid[i] = 1'b1;
        st_comb_lsu_ctrl_o[i] = st_queue_q.instr[i];
        st_comb_lsu_ctrl_o[i].overflow = st_snooped_overflow[i];
        st_comb_lsu_ctrl_o[i].g_overflow = st_snooped_g_overflow[i];
        st_comb_lsu_ctrl_o[i].be = st_snooped_be[i];
        st_comb_vaddr_o[i] = st_snooped_vaddr[i];
        st_comb_tinst_o[i] = st_queue_q.instr[i].tinst;
        st_comb_hs_ld_st_inst_o[i] = st_queue_q.instr[i].hs_ld_st_inst;
        st_comb_hlvx_inst_o[i] = st_queue_q.instr[i].hlvx_inst;
      end


      // validity updated from st_queue_q and current paddr state
      if (ld_queue_q.reserved[i] && ld_queue_q.vaddr_valid[i] && !ld_paddr_valid[i] && !ld_is_translating[i]) begin
        ld_comb_vaddr_valid[i] = 1'b1;
        ld_comb_lsu_ctrl_o[i] = ld_queue_q.instr[i];
        ld_comb_vaddr_o[i] = ld_queue_q.instr[i].vaddr;
        ld_comb_tinst_o[i] = ld_queue_q.instr[i].tinst;
        ld_comb_hs_ld_st_inst_o[i] = ld_queue_q.instr[i].hs_ld_st_inst;
        ld_comb_hlvx_inst_o[i] = ld_queue_q.instr[i].hlvx_inst;
      end

      // validity updated from currently reserved instr
      for (int unsigned j = 0 ; j < CVA6Cfg.NrIssuePorts ; j++) begin
        if (vaddr_is_valid[j] & ld_alloc_idx[j] == i & ld_we_i[j] & decoded_instr_ack_i[j] & !ld_full[j]) begin
          ld_comb_vaddr_valid[i] = 1'b1;
          ld_comb_lsu_ctrl_o[i] = decoded_req[j];
          ld_comb_vaddr_o[i] = vaddr[j];
          ld_comb_tinst_o[i] = tinst_i[j];
          ld_comb_hs_ld_st_inst_o[i] = hs_ld_st_inst[j];
          ld_comb_hlvx_inst_o[i] = hlvx_inst[j];
        end
      end

      // validity updated from snooping after reserving an entry
      if (ld_snooped_we[i]) begin
        ld_comb_vaddr_valid[i] = 1'b1;
        ld_comb_lsu_ctrl_o[i] = ld_queue_q.instr[i];
        ld_comb_lsu_ctrl_o[i].overflow = ld_snooped_overflow[i];
        ld_comb_lsu_ctrl_o[i].g_overflow = ld_snooped_g_overflow[i];
        ld_comb_lsu_ctrl_o[i].be = ld_snooped_be[i];
        ld_comb_vaddr_o[i] = ld_snooped_vaddr[i];
        ld_comb_tinst_o[i] = ld_queue_q.instr[i].tinst;
        ld_comb_hs_ld_st_inst_o[i] = ld_queue_q.instr[i].hs_ld_st_inst;
        ld_comb_hlvx_inst_o[i] = ld_queue_q.instr[i].hlvx_inst;
      end
    end

    // I dont think this part needs Rollback

    // not necessary but just to be secure
    if (flush_i) begin
      st_comb_vaddr_valid = '0;
      ld_comb_vaddr_valid = '0;
    end

  end

  always_comb begin : updating_translation_pointer

    translation_pointer_n = translation_pointer_q;
    previous_translation_pointer_n = previous_translation_pointer_q;
    previous_translation_pointer_type_n = previous_translation_pointer_type_q;
    translation_pointer_valid_n = translation_pointer_valid_q;
    translation_pointer_type_n = translation_pointer_type_q;
    translation_data_valid_n = '0;
    comb_translation_pointer = '0;
    comb_translation_pointer_type = 1'b0;
    comb_translation_pointer_valid = '0;

    // with MMU enable as soon as a page hit is received, prepare the next translation
    if (CVA6Cfg.MmuPresent) begin

      translation_data_valid_n = dtlb_hit_i;

      if (!translation_pointer_valid_q || dtlb_hit_i) begin

        // by default no new request
        translation_pointer_valid_n = '0;

        if (ld_translation_pointer_valid &&
          (!st_translation_pointer_valid ||
          is_older(ld_comb_lsu_ctrl_o[ld_translation_pointer].global_id, st_comb_lsu_ctrl_o[st_translation_pointer].global_id)))
        begin
          comb_translation_pointer = ld_translation_pointer;
          comb_translation_pointer_type = 1'b0;
          comb_translation_pointer_valid = ld_translation_pointer_valid;

          if (!dtlb_hit_i) begin
            translation_pointer_n = ld_translation_pointer;
            translation_pointer_valid_n = ld_translation_pointer_valid;
            translation_pointer_type_n = 1'b0;
          end
        end else if (st_translation_pointer_valid) begin
          comb_translation_pointer = st_translation_pointer;
          comb_translation_pointer_type = 1'b1;
          comb_translation_pointer_valid = st_translation_pointer_valid;

          if (!dtlb_hit_i) begin
            translation_pointer_n = st_translation_pointer;
            translation_pointer_valid_n = st_translation_pointer_valid;
            translation_pointer_type_n = 1'b1;
          end
        end

      end

      if (translation_pointer_valid_q) begin
        previous_translation_pointer_n = translation_pointer_q;
        previous_translation_pointer_type_n = translation_pointer_type_q;
      end else if (comb_translation_pointer_valid) begin
        previous_translation_pointer_n = comb_translation_pointer;
        previous_translation_pointer_type_n = comb_translation_pointer_type;
      end

    // without mmu translation always takes 1 cycle so prepare next translation as soon as the
    // previous one is sent
    end else if (CVA6Cfg.NonIdemPotenceEn) begin

      translation_data_valid_n = translation_req_o;

      if (ld_translation_pointer_valid &&
        (!st_translation_pointer_valid ||
        is_older(ld_comb_lsu_ctrl_o[ld_translation_pointer].global_id, st_comb_lsu_ctrl_o[st_translation_pointer].global_id)))
      begin
        comb_translation_pointer = ld_translation_pointer;
        comb_translation_pointer_type = 1'b0;
        comb_translation_pointer_valid = ld_translation_pointer_valid;
      end else if (st_translation_pointer_valid) begin
        comb_translation_pointer = st_translation_pointer;
        comb_translation_pointer_type = 1'b1;
        comb_translation_pointer_valid = st_translation_pointer_valid;
      end

      //keep the translation info for the next cycle when we receive mmu data
      //necessary because we compute new value on page hit or req sent
      previous_translation_pointer_type_n = comb_translation_pointer_type;
      previous_translation_pointer_n = comb_translation_pointer;

    end

    // Rollback
    for (int unsigned i = 0 ; i<CVA6Cfg.RollbackWidth ; i++) begin

      if (rollback_i[i] && translation_pointer_valid_q) begin
        if ((translation_pointer_type_q == 1'b0 && ld_queue_q.instr[translation_pointer_q].trans_id == rollback_trans_id_i[i]) ||
          (translation_pointer_type_q == 1'b1 && st_queue_q.instr[translation_pointer_q].trans_id == rollback_trans_id_i[i]))
        begin
          translation_pointer_valid_n = 1'b0;
          translation_data_valid_n = '0;
        end
      end

      if (rollback_i[i] && translation_req_o) begin
        if (lsu_ctrl_o.trans_id == rollback_trans_id_i[i]) begin
          translation_pointer_valid_n = 1'b0;
          translation_data_valid_n = '0;
        end
      end

      if (comb_translation_pointer_valid &&
        ((comb_translation_pointer_type == 1'b0 && ld_comb_lsu_ctrl_o[comb_translation_pointer].trans_id == rollback_trans_id_i[i])
        || (comb_translation_pointer_type == 1'b1 && st_comb_lsu_ctrl_o[comb_translation_pointer].trans_id == rollback_trans_id_i[i])) && rollback_i[i])
      begin
        comb_translation_pointer_valid = 1'b0;
      end

    end

    if (flush_i) begin
      comb_translation_pointer_valid = 1'b0;
      translation_pointer_n = '0;
      previous_translation_pointer_n = '0;
      previous_translation_pointer_type_n = '0;
      translation_pointer_valid_n = '0;
      translation_pointer_type_n = '0;
      translation_data_valid_n = '0;
    end

  end

  // ---------------
  // Checking adress dependencies
  // ---------------

  // Data sent to load unit for execution
  assign ld_unit_lsu_ctrl_o = ld_queue_q.instr[ld_ready_pointer];
  assign ld_unit_paddr_o = ld_paddr[ld_ready_pointer];
  assign ld_unit_valid_o = ld_ready_pointer_valid & !ldbuf_full_i;
  assign ld_unit_idx_o = ld_ready_pointer;

  always_comb begin : adress_dependencies

    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      ld_paddr_valid[i] = ld_queue_q.paddr_valid[i] ||
        (previous_translation_pointer_type_q == 1'b0 && translation_data_valid_q && previous_translation_pointer_q == i && !ex_i.valid);
      ld_paddr[i] = ld_queue_q.paddr_valid[i] ? ld_queue_q.paddr[i] : paddr_i;
      st_paddr_valid[i] = st_queue_q.paddr_valid[i] ||
        (previous_translation_pointer_type_q == 1'b1 && translation_data_valid_q && previous_translation_pointer_q == i && !ex_i.valid);
      st_paddr[i] = st_queue_q.paddr_valid[i] ? st_queue_q.paddr[i] : paddr_i;
    end

    for (int unsigned i = 0; i < LSQ_DEPTH; i++) begin
      for (int unsigned j = 0 ; j<CVA6Cfg.RollbackWidth ; j++) begin

        if (ld_queue_q.instr[i].trans_id == rollback_trans_id_i[j] && rollback_i[j]) begin
          ld_paddr_valid[i] = '0;
        end

        if (st_queue_q.instr[i].trans_id == rollback_trans_id_i[j] && rollback_i[j]) begin
          st_paddr_valid[i] = '0;
        end

      end
    end

    if (flush_i) begin
      st_paddr_valid = '0;
      ld_paddr_valid = '0;
    end

  end

  // ---------------
  // Updating address match
  // ---------------

  always_comb begin : adress_match

    comb_matching_addr = '0;
    comb_partial_matching_addr = '0;

    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      if(ld_paddr_valid[i]) begin
        for (int unsigned j = 0; j<LSQ_DEPTH; j ++) begin
          if(st_paddr_valid[j]) begin
            if (ld_paddr[i] == st_paddr[j] && extract_transfer_size(st_queue_q.instr[j].operation) == extract_transfer_size(ld_queue_q.instr[i].operation)) begin
              comb_matching_addr[i][j] = 1'b1;
            end else if (overlap_check(ld_queue_q.instr[i].operation, ld_paddr[i], st_queue_q.instr[j].operation, st_paddr[j])) begin
              comb_partial_matching_addr[i][j] = 1'b1;
            end
          end else begin
            comb_matching_addr[i][j] = 1'b0;
            comb_partial_matching_addr[i][j] = 1'b0;
          end
        end
      end else begin
        comb_matching_addr[i] = 1'b0;
        comb_partial_matching_addr[i] = 1'b0;
      end
    end
  end


  for (genvar i = 0 ; i < LSQ_DEPTH ; i++) begin
    assign full_match_rotated_mask[i] = {comb_matching_addr[i], comb_matching_addr[i]} >> st_commit_pointer_q;
    assign partial_match_rotated_mask[i] = {comb_partial_matching_addr[i], comb_partial_matching_addr[i]} >> st_commit_pointer_q;
  end

  for (genvar i = 0 ; i < LSQ_DEPTH ; i++) begin

    lzc #(.WIDTH(LSQ_DEPTH), .MODE(1'b1)) i_youngest_full_match (
        .in_i   (full_match_rotated_mask[i]),
        .cnt_o  (full_match_winner_k[i]),
        .empty_o(full_no_match[i])
    );

    lzc #(.WIDTH(LSQ_DEPTH), .MODE(1'b1)) i_youngest_partial_match (
        .in_i   (partial_match_rotated_mask[i]),
        .cnt_o  (partial_match_winner_k[i]),
        .empty_o(partial_no_match[i])
    );

    // only works if depth is a power of 2
    assign full_match_winner_idx[i] = st_commit_pointer_q + (LSQ_DEPTH - 1 - full_match_winner_k[i]);
    assign partial_match_winner_idx[i] = st_commit_pointer_q + ( LSQ_DEPTH - 1 - partial_match_winner_k[i]);
  end

  always_comb begin : forwarding_readyness_data

    st_older = '0;
    st_older_paddr_valid = '1;
    st_older_all_valid = '1;

    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      data_valid[i] = st_queue_q.data_valid[i] || data_snooped_valid[i];
      data[i] = st_queue_q.data_valid[i] ? st_queue_q.instr[i].data : data_snooped[i];
    end


    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      for (int unsigned j = 0; j<LSQ_DEPTH; j ++) begin
        if (is_older(st_queue_q.instr[j].global_id, ld_queue_q.instr[i].global_id) && st_queue_q.reserved[j]) begin
          st_older[i][j] = 1'b1;
          if (!st_paddr_valid[j]) begin
            st_older_paddr_valid[i] = 1'b0;
            st_older_all_valid[i] = 1'b0;
          end
          if (!data_valid[j]) st_older_all_valid[i] = 1'b0;
        end
      end
    end


    // squash entry on rollback
    for (int unsigned i = 0; i < LSQ_DEPTH; i++) begin
      for (int unsigned j = 0 ; j<CVA6Cfg.RollbackWidth ; j++) begin
        if (ld_queue_q.instr[i].trans_id == rollback_trans_id_i[j] && rollback_i[j]) begin
          st_older[i] = '0;
          st_older_paddr_valid[i] = '0;
          st_older_all_valid[i] = '0;
          data_valid[i] = '0;
        end
      end
    end

    if (flush_i) begin
      st_older = '0;
      st_older_paddr_valid = '0;
      st_older_all_valid = '0;
      data_valid = '0;
    end

  end


  // ---------------
  // Load write back
  // ---------------

  //assign load write back info
  assign ld_result_o = wb_data[ld_wb_pointer];
  assign ld_ex_o = wb_ex[ld_wb_pointer];
  assign ld_valid_o = ld_wb_pointer_valid;
  assign ld_global_id_o = ld_queue_q.instr[ld_wb_pointer].global_id;
  assign ld_trans_id_o = ld_queue_q.instr[ld_wb_pointer].trans_id;

  always_comb begin : ld_write_back

    wb_ex = '0;
    wb_data = '0;
    wb_ex= '0;

    //determine wich load is ready to write back
    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      // data or ex from queue
      if (ld_queue_q.result_valid[i] || ld_queue_q.ex[i].valid) begin
        wb_valid[i] = 1'b1;
        wb_data[i] = ld_queue_q.result[i];
        wb_ex[i] = ld_queue_q.ex[i];
      end else if (ld_result_valid_i & i == ld_unit_idx_i) begin
      // data from load unit this cycle
        wb_valid[i] = 1'b1;
        wb_data[i] = ld_result_i;
        wb_ex[i] = ld_queue_q.ex[i];
      end else if (translation_data_valid_q & previous_translation_pointer_q == i & ex_i.valid & previous_translation_pointer_type_q == 1'b0) begin
      // ex data from this cycle
        wb_valid[i] = 1'b1;
        wb_data[i] = '0; // does not matter
        wb_ex[i] = ex_i;
      end else if (ld_is_forwarded[i]) begin
      // data from store forwarding this cycle
        wb_valid[i] = 1'b1;
        wb_data[i] = data[i];
        wb_ex[i] = ld_queue_q.ex[i];
      end else begin
      // no write back available
        wb_valid[i] = 1'b0;
        wb_data[i] = '0;
        wb_ex[i] = '0;
      end
    end

    // squash entry on rollback
    for (int unsigned i = 0; i < LSQ_DEPTH; i++) begin
      for (int unsigned j = 0 ; j<CVA6Cfg.RollbackWidth ; j++) begin
        if (ld_queue_q.instr[i].trans_id == rollback_trans_id_i[j] && rollback_i[j]) begin
          wb_data[i] = '0;
          wb_ex[i] = '0;
          wb_valid[i] = '0;
        end
      end
    end

    if (flush_i) begin
      wb_data = '0;
      wb_ex = '0;
      wb_valid = '0;
    end

  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_queue_q <= '0;
      ld_queue_q <= '0;
      st_status_cnt_q <= '0;
      st_issue_pointer_q <= '0;
      st_drain_pointer_q <= '0;
      st_commit_pointer_q <= '0;
      translation_pointer_q <= '0;
      previous_translation_pointer_q <= '0;
      translation_pointer_valid_q <= '0;
      translation_data_valid_q <= '0;
      translation_pointer_type_q <= '0;
      previous_translation_pointer_type_q <= '0;
    end else begin
      st_queue_q <= st_queue_n;
      ld_queue_q <= ld_queue_n;
      st_status_cnt_q <= st_status_cnt_n;
      st_issue_pointer_q <= st_issue_pointer_n;
      st_drain_pointer_q <= st_drain_pointer_n;
      st_commit_pointer_q <= st_commit_pointer_n;
      translation_data_valid_q <= translation_data_valid_n;
      translation_pointer_q <= translation_pointer_n;
      previous_translation_pointer_q <= previous_translation_pointer_n;
      previous_translation_pointer_type_q <= previous_translation_pointer_type_n;
      translation_pointer_valid_q <= translation_pointer_valid_n;
      translation_pointer_type_q <= translation_pointer_type_n;
    end
  end

  //pragma translate_off

  assert property (
  @(posedge clk_i) disable iff (!rst_ni)
  st_status_cnt_q == $countones(st_queue_q.reserved)
  )
  else begin
    $display(
      "SQ COUNT DESYNC: cnt=%0d reserved=%b drain=%0d commit=%0d issue=%0d sent=%b",
      st_status_cnt_q,
      st_queue_q.reserved,
      st_drain_pointer_q,
      st_commit_pointer_q,
      st_issue_pointer_q,
      st_sent_to_cache_i
    );
    $fatal(1);
  end

  assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    st_buf_valid_o |-> st_queue_q.reserved[st_commit_pointer_q]
  )
  else $error(
    "ST BUF INVALID RESERVED: ptr=%0d ready=%b reserved=%b paddr_valid=%b paddr=%h",
    $sampled(st_commit_pointer_q),
    $sampled(st_queue_q.ready[st_commit_pointer_q]),
    $sampled(st_queue_q.reserved[st_commit_pointer_q]),
    $sampled(st_queue_q.paddr_valid[st_commit_pointer_q]),
    $sampled(st_queue_q.paddr[st_commit_pointer_q])
  );

  assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    st_buf_valid_o |-> st_queue_q.paddr_valid[st_commit_pointer_q]
  )
  else $error(
    "ST BUF INVALID PADDR_VALID: ptr=%0d paddr=%h",
    $sampled(st_commit_pointer_q),
    $sampled(st_queue_q.paddr[st_commit_pointer_q])
  );

  assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    st_buf_valid_o |-> !$isunknown(st_queue_q.paddr[st_commit_pointer_q])
  )
  else $error(
    "ST BUF X PADDR: ptr=%0d tid=%0d paddr=%h",
    $sampled(st_commit_pointer_q),
    $sampled(st_queue_q.instr[st_commit_pointer_q].trans_id),
    $sampled(st_queue_q.paddr[st_commit_pointer_q])
  );

  for (genvar i = 0; i < LSQ_DEPTH; i++) begin
  assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    st_queue_q.ready[i]
    |->
    (
      st_queue_q.reserved[i] &&
      st_queue_q.paddr_valid[i] &&
      st_queue_q.data_valid[i]
    )
  )
  else $error(
    "SQ READY CORRUPTED: idx=%0d ready=%b reserved=%b paddr_valid=%b data_valid=%b",
    i,
    $sampled(st_queue_q.ready[i]),
    $sampled(st_queue_q.reserved[i]),
    $sampled(st_queue_q.paddr_valid[i]),
    $sampled(st_queue_q.data_valid[i])
  );
  end

  //pragma translate_on

endmodule
