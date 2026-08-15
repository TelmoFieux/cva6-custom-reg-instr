
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
    parameter type fu_data_t = logic,
    parameter type lsu_ctrl_t = logic
) (
    input logic                                                       clk_i,
    input logic                                                       rst_ni,
    output logic [CVA6Cfg.NrCommitPorts-1:0]                          full_o,
    input logic                                                       commit_i, //commit latest store
    input logic [CVA6Cfg.TRANS_ID_BITS-1:0]                           commit_trans_id_i,

    input logic                                                       rollback_i, // architectural register to rollback
    input logic [CVA6Cfg.TRANS_ID_BITS-1:0]                           rollback_trans_id_i, // rollback is enabled


    input logic [CVA6Cfg.NrIssuePorts-1:0]                            ld_we_i,
    input logic [CVA6Cfg.NrIssuePorts-1:0]                            st_we_i,
    // instr issued to the scoreboard this cycle - ISSUE_READ_OPERAND
    input fu_data_t [CVA6Cfg.NrIssuePorts-1:0]                        fu_data_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic [CVA6Cfg.NrIssuePorts-1:0][31:0]                      tinst_i,
    // is instr valid - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0]                            decoded_instr_valid_i,
    // Handshake with decode stage - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0]                            decoded_instr_ack_i,
    // Register adress of the store data - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.RegAddrWidth-1:0]  data_reg_addr_i,
    // Register adress of the adress for load and stores - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.RegAddrWidth-1:0]  vaddr_reg_addr_i,
    // Store data valid - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0]                            st_data_valid_i,
    // Adress of the load or store valid - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0]                            vaddr_valid_i,


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


    // Destination register in register file - EX_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.RegAddrWidth-1:0] waddr_i,
    // Results to write back - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.XLEN-1:0] wbdata_i,
    // Indicates valid results - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0] wt_valid_i,



    // reserved id - ISSUE_STAGE
    output logic lsu_ctrl_t                                           ld_lsu_ctrl_o,
    output logic lsu_ctrl_t                                           st_lsu_ctrl_o,
    output logic                                                      dispatched_instr_vaild_o,
    input logic                                                       load_ready_i,
    input logic                                                       store_ready_i,



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
    logic signed [ID_SIZE-1:0] diff;
    diff = $signed(tag_b) - $signed(tag_a);
    return (diff[ID_SIZE-1] == 1'b0) && (diff != '0);
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
    lsu_ctrl_t instr [LSQ_DEPTH-1:0];
    logic [LSQ_DEPTH-1:0] ready; // data and paddr are valid
    logic [LSQ_DEPTH-1:0] reserved; // instr has been accepted by the rob
    logic [LSQ_DEPTH-1:0][CVA6Cfg.RegAddrWidth-1:0] vaddr_reg_addr;
    logic [LSQ_DEPTH-1:0] vaddr_valid; // vaddr is valid
    logic [LSQ_DEPTH-1:0][CVA6Cfg.RegAddrWidth-1:0] data_reg_addr;
    logic [LSQ_DEPTH-1:0] data_valid; // vaddr is valid
    logic [LSQ_DEPTH-1:0][CVA6Cfg.PLEN-1:0] paddr;
    logic [LSQ_DEPTH-1:0] paddr_valid; // vaddr has been translated
    logic [LSQ_DEPTH-1:0][LSQ_DEPTH-1:0] matching_addr;
    logic [LSQ_DEPTH-1:0][LSQ_DEPTH-1:0] partial_matching_addr;
    logic [LSQ_DEPTH-1:0][CVA6Cfg.XLEN-1:0] result; // store imm value to compute vaddr
    exception_t [LSQ_DEPTH-1:0] ex;
  } st_queue_t;

  typedef struct packed {
    lsu_ctrl_t instr [LSQ_DEPTH-1:0];
    logic [LSQ_DEPTH-1:0] ready; // data and paddr are valid
    logic [LSQ_DEPTH-1:0] reserved; // instr has been accepted by the rob
    logic [LSQ_DEPTH-1:0][CVA6Cfg.RegAddrWidth-1:0] vaddr_reg_addr;
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

  assign full_o[0] = ld_we_i[0] ? ld_full[0] : st_full[0];
  assign full_o[1] = ld_we_i[1] ? ld_full[1] : st_full[1];

  st_queue_t st_queue_n, st_queue_q;
  ld_queue_t ld_queue_n, ld_queue_q;

  logic [$clog2(LSQ_DEPTH)-1:0] st_commit_pointer_n, st_commit_pointer_q;

  logic [$clog2(LSQ_DEPTH)-1:0] translation_pointer_n, translation_pointer_q;
  logic translation_pointer_valid_n, translation_pointer_valid_q;
  logic translation_pointer_type_n, translation_pointer_type_q;
  logic translation_data_valid_n, translation_data_valid_q;


  logic ld_full, st_full;

  lsu_ctrl_t [CVA6Cfg.NrIssuePorts-1:0] decoded_req;

  logic      [CVA6Cfg.NrIssuePorts-1:0][    CVA6Cfg.VLEN-1:0] vaddr;
  logic      [CVA6Cfg.NrIssuePorts-1:0][    CVA6Cfg.XLEN-1:0] vaddr_xlen;
  logic      [CVA6Cfg.NrIssuePorts-1:0]                       overflow;
  logic      [CVA6Cfg.NrIssuePorts-1:0]                       g_overflow;
  logic      [CVA6Cfg.NrIssuePorts-1:0][(CVA6Cfg.XLEN/8)-1:0] be;
  logic      [CVA6Cfg.NrCommitPorts-1:0]                      hs_ld_st_inst;
  logic      [CVA6Cfg.NrCommitPorts-1:0]                      hlvx_inst;
  logic      [CVA6Cfg.NrIssuePorts-1:0][    CVA6Cfg.XLEN-1:0] st_data;


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


  // ---------------
  // LSQ Queue updates
  // ---------------

  logic [CVA6Cfg.NrIssuePorts:0][LSQ_DEPTH-1:0] ld_free_entries_masked, st_free_entries_masked;
  logic [CVA6Cfg.NrIssuePorts-1:0] ld_empty_mask, st_empty_mask;
  logic [CVA6Cfg.NrIssuePorts-1:0][$clog2(LSQ_DEPTH):0] ld_alloc_idx, st_alloc_idx;

  assign ld_free_entries_masked[0] = ld_queue_q.reserved;
  assign st_free_entries_masked[0] = st_queue_q.reserved;

  //priority encoder cascade to get free index in load queue
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : g_alloc
      lzc #(
          .WIDTH(NR_RS_ENTRIES),
          .MODE(1'b0))
      i_lzc (
          .in_i   (ld_free_entries_masked[i]),
          .cnt_o  (ld_alloc_idx[i]),
          .empty_o(ld_empty_mask[i])
      );

      assign ld_free_entries_masked[i+1] = (ld_we_i[i] && decoded_instr_valid_i[i] && ld_empty_mask[i] == 1'b0) ?
        (ld_free_entries_masked[i] & ~(NR_RS_ENTRIES'(1) << ld_alloc_idx[i])) :
        ld_free_entries_masked[i];
  end

  //priority encoder cascade to get free index in store queue
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : g_alloc
      lzc #(
          .WIDTH(NR_RS_ENTRIES),
          .MODE(1'b0))
      i_lzc (
          .in_i   (st_free_entries_masked[i]),
          .cnt_o  (st_alloc_idx[i]),
          .empty_o(st_empty_mask[i])
      );

      assign st_free_entries_masked[i+1] = (st_we_i[i] && decoded_instr_valid_i[i] && st_empty_mask[i] == 1'b0) ?
        (st_free_entries_masked[i] & ~(NR_RS_ENTRIES'(1) << st_alloc_idx[i])) :
        st_free_entries_masked[i];
  end

  assign ld_full = ld_empty_mask;
  assign st_full = st_empty_mask;

  logic [LSQ_DEPTH-1:0] forwarding_tournament_valid;
  logic [LSQ_DEPTH-1:0][CVA6Cfg.GlobalRsIdWidth-1:0] forwarding_tournament_seq_num;
  logic [LSQ_DEPTH-1:0][$clog2(LSQ_DEPTH)-1:0] forwarding_tournament_id;

  for (genvar i = 0 ; i < LSQ_DEPTH ; i++) begin
    assign forwarding_tournament_seq_num[i] = st_queue_q.instr[i].global_rs_id;
    assign forwarding_tournament_valid[i] = st_queue_q.reserved[i] && st_queue_q.vaddr_valid[i] && st_queue_q.paddr_valid[i];
    assign forwarding_tournament_id[i] = i;
  end

  logic [$clog2(LSQ_DEPTH)-1:0] forwarding_translation_pointer;
  logic forwarding_translation_pointer_valid;

  tournament_tree #(
      .ID_SIZE(CVA6Cfg.GlobalRsIdWidth),
      .NR_PLAYER(LSQ_DEPTH)
    ) i_forwarding_tournament_tree (
      .valid_i    (forwarding_tournament_valid),
      .seq_num_i  (forwarding_tournament_seq_num),
      .id_i       (forwarding_tournament_id),
      .winner_o   (forwarding_translation_pointer),
      .winner_valid_o (forwarding_translation_pointer_valid)
  );

  always_comb begin : updating_queues

    automatic logic [CVA6Cfg.NrIssuePorts-1:0] vaddr_is_valid;
    automatic logic [CVA6Cfg.NrIssuePorts-1:0] data_is_valid;

    vaddr_is_valid = '0;
    data_is_valid = '0;
    st_data = '0;

    for (int unsigned i = 0 ; i < CVA6Cfg.NrIssuePorts ; i++) begin
      if (vaddr_valid_i[i]) begin
        vaddr_xlen[i] = $unsigned($signed(fu_data_i[i].imm) + $signed(fu_data_i[i].operand_a));
        vaddr_is_valid[i] = 1'b1;
      end else begin
        for (int unsigned j = 0 ; j < CVA6Cfg.NrWbPorts ; j++) begin
          if (wt_valid_i[j] && waddr_i[j] == vaddr_reg_addr_i[i]) begin
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
          if (wt_valid_i[j] && waddr_i[j] == data_reg_addr_i[i]) begin
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
        decoded_instr_valid_i[i] && ld_we_i[i] | st_we_i[i],
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

    // Load queue initialisation
    // TODO : check "dcache_wbuffer_not_ni_i" comme signal qui est le seul qu'in a pas traité de la
    // load unit. il faut voir si il m'est utile
    for (int i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      if (ld_we_i[i] && decoded_instr_ack_i[i] && !ld_full[i]) begin
        ld_queue_n.reserved = ld_free_entries_masked[i+1];
        ld_queue_n.instr[ld_alloc_idx[i]] = decoded_req[i];
        ld_queue_n.ready[ld_alloc_idx[i]] = '0;
        ld_queue_n.vaddr_reg_addr[ld_alloc_idx[i]] = vaddr_reg_addr_i[i];
        ld_queue_n.vaddr_valid[ld_alloc_idx[i]] = vaddr_is_valid[i];
        ld_queue_n.result[ld_alloc_idx[i]] = fu_data_i[i].imm;
      end
    end

    //store queue initialisation
    //TODO: Il faut probablement rappasser la store queue en buffer circulaire, pour le write back
    //on fera juste en sorte de ne pas rendre la place disponible de toute façon ça n'impacte pas
    //les perf puisqu'un flush arrivera. ça évite d'instancier des arbre de tournoi pour rien
    //TODO : Il manque des info pour les store regarder les entrées du store buffer. y'a des
    //histoire de réalignement.
    for (int unsigned i = 0 ; i < CVA6Cfg.NrIssuePorts ; i++) begin
      if (st_we_i[i] && !st_full[i] && decoded_instr_ack_i[i]) begin
        st_queue_n.reserved = st_free_entries_masked[i+1];
        st_queue_n.instr[st_alloc_idx[i]] = decoded_req[i];
        st_queue_n.ready[st_alloc_idx[i]] = '0;
        st_queue_n.result[st_alloc_idx[i]] = fu_data_i[i].imm;
        st_queue_n.data_valid[st_alloc_idx[i]] = data_is_valid[i];
        st_queue_n.vaddr_valid[st_alloc_idx[i]] = vaddr_is_valid[i];
        st_queue_n.vaddr_reg_addr[st_alloc_idx[i]] = vaddr_reg_addr_i[i];
        st_queue_n.data_reg_addr[st_alloc_idx[i]] = data_reg_addr_i[i];
        st_alloc_idx[i] = st_alloc_idx[i] + 1'b1;
      end
    end

    automatic logic [1:0][CVA6Cfg.VLEN-1:0]     snooped_vaddr;
    automatic logic [1:0][CVA6Cfg.XLEN-1:0]     snooped_vaddr_xlen;
    automatic logic [1:0]                       snooped_overflow;
    automatic logic [1:0]                       snooped_g_overflow;
    automatic logic [1:0][(CVA6Cfg.XLEN/8)-1:0] snooped_be;
    automatic logic [1:0]                       we;

    // Snooping CDB in case we miss some data
    for ( int unsigned i = 0 ; i < LSQ_DEPTH ; i++) begin
      we = '0;
      snooped_vaddr_xlen = '0;
      for (int unsigned j = 0 ; j < CVA6Cfg.NrWbPorts ; j++) begin
        if (wt_valid_i[j] && waddr_i[j] == st_queue_q.vaddr_reg_addr[i]) begin
          snooped_vaddr_xlen[1] = $unsigned($signed(st_queue_q.result[i]) + $signed(wbdata_i[j]));
          we[1] = 1'b1;
        end else if (wt_valid_i[j] && waddr_i[j] == ld_queue_q.vaddr_reg_addr[i]) begin
          snooped_vaddr_xlen[0] = $unsigned($signed(ld_queue_q.result[i]) + $signed(wbdata_i[j]));
          we[0] = 1'b1;
        end
      end

      for (int unsigned k = 0; k < 2; k++) begin
        automatic fu_op op;

        op = k ? st_queue_q.instr[i].operation
         : ld_queue_q.instr[i].operation;

        snooped_vaddr[k] = snooped_vaddr_xlen[k][CVA6Cfg.VLEN-1:0];
        snooped_overflow[k] = (CVA6Cfg.IS_XLEN64 && (!((&snooped_vaddr_xlen[k][CVA6Cfg.XLEN-1:CVA6Cfg.SV-1]) == 1'b1 || (|snooped_vaddr_xlen[k][CVA6Cfg.XLEN-1:CVA6Cfg.SV-1]) == 1'b0)));
        if (CVA6Cfg.RVH) begin : gen_g_overflow_hyp
          snooped_g_overflow[k] = (CVA6Cfg.IS_XLEN64 && (!((|snooped_vaddr_xlen[k][CVA6Cfg.XLEN-1:CVA6Cfg.SVX]) == 1'b0)));
        end else begin : gen_g_overflow_no_hyp
          snooped_g_overflow[k] = 1'b0;
        end

        if (CVA6Cfg.IS_XLEN64) begin : gen_8b_be
          snooped_be[k] = be_gen(snooped_vaddr[k][2:0], extract_transfer_size(op));
        end else begin : gen_4b_be
          snooped_be[k] = be_gen_32(snooped_vaddr[k][1:0], extract_transfer_size(op));
        end
      end


      if (we[1]) begin
        st_queue_n.instr[i].vaddr = snooped_vaddr[1];
        st_queue_n.instr[i].overflow = snooped_overflow[1];
        st_queue_n.instr[i].g_overflow = snooped_g_overflow[1];
        st_queue_n.instr[i].be = snooped_be[1];
        st_queue_n.vaddr_valid[i] = 1'b1;
        end

      end else if (we[0]) begin
        ld_queue_n.instr[i].vaddr = snooped_vaddr[0];
        ld_queue_n.instr[i].overflow = snooped_overflow[0];
        ld_queue_n.instr[i].g_overflow = snooped_g_overflow[0];
        ld_queue_n.instr[i].be = snooped_be[0];
        ld_queue_n.vaddr_valid[i] = 1'b1;
      end
    end

    automatic logic [LSQ_DEPTH-1:0][CVA6Cfg.XLEN-1] data_snooped;
    automatic logic [LSQ_DEPTH-1:0] data_snooped_valid;

    data_snooped_valid = '0;

    for ( int unsigned i = 0 ; i < LSQ_DEPTH ; i++) begin
      for (int unsigned j = 0 ; j < CVA6Cfg.NrWbPorts ; j++) begin
        if (wt_valid_i[j] && waddr_i[j] == st_queue_q.data_reg_addr[i]) begin
          data_snooped_valid[i] = 1'b1;
          data_snooped[i] = wbdata_i[j];
          st_queue_n.instr[i].data = wbdata_i[j];
          st_queue_n.data_valid = 1'b1;
        end
      end
    end

    //Updating paddr
    if (translation_data_valid_q && (CVA6Cfg.MmuPresent || CVA6Cfg.NonIdemPotenceEn)) begin
      if (translation_pointer_type_q == 1'b1) begin
        st_queue_n.instr[translation_pointer_q].paddr = paddr_i;
        st_queue_n.paddr_valid[translation_pointer_q] = 1'b1;
      end else begin
        ld_queue_n.paddr[translation_pointer_q] = paddr_i;
        ld_queue_n.paddr_valid[translation_pointer_q] = 1'b1;
        ld_queue_n.paddr_ni[translation_pointer_q] = config_pkg::is_inside_nonidempotent_regions
        (
          CVA6Cfg,
          {{52 - CVA6Cfg.PPNW{1'b0}}, dtlb_ppn_i, 12'd0}
        ) && CVA6Cfg.NonIdemPotenceEn;
      end
    end else if (!(CVA6Cfg.MmuPresent || CVA6Cfg.NonIdemPotenceEn)) begin
      for ( int unsigned i = 0 ; i < LSQ_DEPTH ; i++) begin
        st_queue_n.instr[i].paddr = st_queue_q.instr[i].vaddr;
        st_queue_n.instr[i].paddr_valid = st_queue_q.vaddr_valid[i];
        ld_queue_n.instr[i].paddr = ld_queue_q.instr[i].vaddr;
        ld_queue_n.instr[i].paddr_valid = ld_queue_q.vaddr_valid[i];
      end
    end

    // load exception
    if (ex_i.valid && translation_pointer_type_q == 1'b0) begin
      ld_queue_n.ex[translation_pointer_q]= ex_i;
      ld_queue_n.result_valid[translation_pointer_q]= 1'b1;
      ld_queue_n.ex[translation_pointer_q].cause = ex_i.cause;
      ld_queue_n.ex[translation_pointer_q].tval = ex_i.tval;
      ld_queue_n.ex[translation_pointer_q].tval2 = CVA6Cfg.RVH ? ex_i.tval2 : '0;
      ld_queue_n.ex[translation_pointer_q].tinst = CVA6Cfg.RVH ? ex_i.tinst : '0;
      ld_queue_n.ex[translation_pointer_q].gva = CVA6Cfg.RVH ? ex_i.gva : 1'b0;
    end

    // store exception
    if (ex_i.valid && translation_pointer_type_q == 1'b1) begin
      st_trans_id_o = st_queue_q.instr[translation_pointer_q].trans_id;
      st_ex_o = ex_i;
      st_valid_o = 1'b1;
    end

    // ---------------
    // Checking adress dependencies
    // ---------------

    automatic logic [LSQ_DEPTH-1:0][CVA6Cfg.PLEN-1] ld_paddr, st_paddr;
    automatic logic [LSQ_DEPTH-1:0][CVA6Cfg.PLEN-1] ld_paddr_valid, st_paddr_valid;

    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      ld_paddr_valid[i] = ld_queue_q.paddr_valid[i] || (translation_pointer_type_q == 1'b0 && translation_data_valid_q && translation_pointer_q == i);
      ld_paddr[i] = ld_queue_q.paddr_valid[i] ? ld_queue_q.paddr[i] : paddr_i;
      st_paddr_valid[i] = st_queue_q.paddr_valid[i] || (translation_pointer_type_q == 1'b0 && translation_data_valid_q && translation_pointer_q == i);
      st_paddr[i] = st_queue_q.paddr_valid[i] ? st_queue_q.paddr[i] : paddr_i;
    end


    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      if(ld_paddr_valid[i]) begin
        for (int unsigned j = 0; j<LSQ_DEPTH; j ++) begin
          if(st_paddr_valid[j]) begin
            if (ld_paddr[i] == st_paddr[j]) begin
              st_queue_n.matching_addr[i][j] = 1'b1;
              ld_queue_n.matching_addr[j][i] = 1'b1;
            end else if (overlap_check(ld_queue_q.instr[i].operation, ld_paddr, st_queue_q.instr[i].operation, st_paddr)) begin
              st_queue_n.partial_matching_addr[i][j] = 1'b1;
              ld_queue_n.partial_matching_addr[j][i] = 1'b1;
            end
          end else begin
            st_queue_n.matching_addr[i][j] = 1'b0;
            ld_queue_n.matching_addr[j][i] = 1'b0;
            st_queue_n.partial_matching_addr[i][j] = 1'b0;
            ld_queue_n.partial_matching_addr[j][i] = 1'b0;
          end
        end
      end else begin
        for (int unsigned j = 0; j<LSQ_DEPTH; j ++) begin
          st_queue_n.matching_addr[i][j] = 1'b0;
          st_queue_n.partial_matching_addr[i][j] = 1'b0;
        end
        ld_queue_n.matching_addr[j] = 1'b0;
        ld_queue_n.partial_matching_addr[j] = 1'b0;
      end
    end

    // ---------------
    // Updating readyness
    // ---------------

    automatic logic [LSQ_DEPTH-1:0][CVA6Cfg.XLEN-1] data;
    automatic logic [LSQ_DEPTH-1:0] data_valid;

    automatic logic [LSQ_DEPTH-1:0][LSQ_DEPTH-1:0] st_older; // all valid store older than 1 load
    automatic logic [LSQ_DEPTH-1:0] st_older_all_valid // all valid precedent store have valid data and paddr
    automatic logic [LSQ_DEPTH-1:0] st_older_paddr_valid // all valid precedent store have valid paddr
    st_older = '0;
    st_older_paddr_valid = '1;
    st_older_all_valid = '1;

    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      for (int unsigned j = 0; j<LSQ_DEPTH; j ++) begin
        if (is_older(st_queue_q.instr[j].global_rs_id,ld_queue_q.instr[i].global_rs_id)) begin
          st_older[i][j] = 1'b1;
          if (!st_queue_q.paddr_valid[j]) begin
            st_older_paddr_valid = 1'b0;
            st_older_all_valid = 1'b0;
          end
          if (!st_queue_q.data_valid[j]) st_older_all_valid = 1'b0;
        end
      end
    end


    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      data_valid = st_queue_q.data_valid[i] || data_snooped_valid;
      data = st_queue_q.data_valid[i] ? st_queue_q.instr[i].data : data_snooped;
    end

    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      if(st_queue_q.paddr_valid[i] && data_valid[i] && st_queue_q.reserved[i]) begin
        st_queue_n.ready[i] = 1'b1;
      end

      // load is not ready if :
      // - all previous store did not receive their paddr (we cannot verify dependencies)
      // - it is a non idempotent load
      // - we match with an older load adress
      if(ld_queue_q.paddr_valid[i] && ld_queue_q.reserved[i]) begin
        ld_queue_n.ready[i] = 1'b1;
        if (ld_queue_q.paddr_ni[i]) begin
          ld_queue_n.ready[i] = ld_queue_q.ready[i] || commit_trans_id_i == ld_queue_q.instr[i].trans_id;
        end else begin
          if (|st_older) begin
            if (~|(st_older & st_older_paddr_valid)) begin
              ld_queue_n.ready[i] = 1'b0;
            end else begin
              for (int unsigned j = 0; j<LSQ_DEPTH; j ++) begin
                if(st_older[i][j] && (ld_queue_q.matching_addr[i][j] || ld_queue_q.partial_matching_addr[i][j])) begin
                  ld_queue_n.ready[i] = 1'b0;
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


    //TODO: Faire le store to load forwarding. Voir comment obtenir l'instruction la plus récente
    //qui prrécède un load de façon efficace.

    for (int unsigned i = 0; i<LSQ_DEPTH; i ++) begin
      if(st_queue_q.paddr_valid[i] && data_valid[i] && st_queue_q.reserved[i]) begin
        for (int unsigned j = 0; j<LSQ_DEPTH; j ++) begin
          if(st_queue_q.matching_addr[i][j]) begin
            if (is_older(st_queue_q.instr[i].global_id, ld_queue_q.instr[j].global_id)
                && !ld_queue_q.paddr_ni[j]
                && extract_transfer_size(st_queue_q.instr[i].operation) == extract_transfer_size(ld_queue_q.instr[j].operation)) begin
                ld_queue_n.result[j] = data[i];
                ld_queue_n.result_valid[j] = 1'b1;
              end
            end
          end
        end
      end
    end


  end

  // ---------------
  // Translating vaddr
  // ---------------

  logic [LSQ_DEPTH-1:0] ld_tournament_valid;
  logic [LSQ_DEPTH-1:0][CVA6Cfg.GlobalRsIdWidth-1:0] ld_tournament_seq_num;
  logic [LSQ_DEPTH-1:0][$clog2(LSQ_DEPTH)-1:0] ld_tournament_id;

  for (genvar i = 0 ; i < LSQ_DEPTH ; i++) begin
    assign ld_tournament_seq_num[i] = ld_queue_q.instr[i].global_rs_id;
    assign ld_tournament_valid[i] = ld_queue_q.reserved[i] && ld_queue_q.vaddr_valid[i] && !ld_queue_q.paddr_valid[i];
    assign ld_tournament_id[i] = i;
  end

  logic [$clog2(LSQ_DEPTH)-1:0] ld_translation_pointer;
  logic ld_translation_pointer_valid;

  tournament_tree #(
      .ID_SIZE(CVA6Cfg.GlobalRsIdWidth),
      .NR_PLAYER(LSQ_DEPTH)
    ) i_ld_tournament_tree (
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
    assign st_tournament_seq_num[i] = st_queue_q.instr[i].global_rs_id;
    assign st_tournament_valid[i] = st_queue_q.reserved[i] && st_queue_q.vaddr_valid[i] && !st_queue_q.paddr_valid[i];
    assign st_tournament_id[i] = i;
  end

  logic [$clog2(LSQ_DEPTH)-1:0] st_translation_pointer;
  logic st_translation_pointer_valid;

  tournament_tree #(
      .ID_SIZE(CVA6Cfg.GlobalRsIdWidth),
      .NR_PLAYER(LSQ_DEPTH)
    ) i_st_tournament_tree (
      .valid_i    (st_tournament_valid),
      .seq_num_i  (st_tournament_seq_num),
      .id_i       (st_tournament_id),
      .winner_o   (st_translation_pointer),
      .winner_valid_o (st_translation_pointer_valid)
  );

  // Virtual adress translation data
  assign hs_ld_st_inst_o = CVA6Cfg.RVH ? (translation_pointer_type_q ? st_queue_q.instr[translation_pointer_q].hs_ld_st_inst : ld_queue_q.instr[translation_pointer_q].hs_ld_st_inst) : 1'b0;
  assign hlvx_inst_o = CVA6Cfg.RVH ? (translation_pointer_type_q ? st_queue_q.instr[translation_pointer_q].hlvx_inst : ld_queue_q.instr[translation_pointer_q].hlvx_inst) : 1'b0;
  assign tinst_o = CVA6Cfg.RVH ? (translation_pointer_type_q ? st_queue_q.instr[translation_pointer_q].tinst : ld_queue_q.instr[translation_pointer_q].tinst) : 1'b0;
  assign vaddr_o = translation_pointer_type_q ? st_queue_q.instr[translation_pointer_q].vaddr : ld_queue_q.instr[translation_pointer_q].vaddr;
  assign translation_req_o = translation_pointer_valid_q;


  always_comb begin : updating_translation_pointer

    translation_pointer_n = translation_pointer_q;
    translation_pointer_valid_n = translation_pointer_valid_q;
    translation_pointer_type_n = translation_pointer_type_q;
    translation_data_valid_n = '0;

    if ((translation_data_valid_q || !translation_pointer_valid_q) && (CVA6Cfg.MmuPresent || CVA6Cfg.NonIdemPotenceEn)) begin
      translation_pointer_valid_n = '0;
      if (is_older(ld_queue_q.instr[ld_translation_pointer].global_id, st_queue_q.instr[st_translation_pointer].global_id)) begin
        translation_pointer_n = ld_translation_pointer;
        translation_pointer_valid_n = ld_translation_pointer_valid;
        translation_ctrl_n = ld_queue_q[ld_translation_pointer];
        translation_pointer_type_n = 0;
        translation_data_valid_n = ld_translation_pointer_valid;
      end else begin
        translation_pointer_n = st_translation_pointer;
        translation_pointer_valid_n = st_translation_pointer_valid;
        translation_ctrl_n = st_queue_q[st_translation_pointer];
        translation_pointer_type_n = 1;
        translation_data_valid_n = st_translation_pointer_valid;
      end
    end
  end

  // Check readyness and store to load forwarding

  // choose instruction to issue to each unit and retrieve result

  // Manage write back and commit for stores

  // Rollback




  // ---------------
  // store to load forwarding
  // ---------------

  // We need to take into account :
  // - dependencies based on

  // Issuing instruction and store to load forwarding

  // Commit store

  // Rollback

  // Flush


  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_queue_q <= '0;
      ld_queue_q <= '0;
      translation_pointer_q = '0;
      translation_pointer_valid_q = '0;
      translation_data_valid_q = '0;
      translation_pointer_type_q = '0;
    end else begin
      st_queue_q <= st_queue_n;
      ld_queue_q <= ld_queue_n;
      translation_data_valid_q = translation_data_valid_n;
      translation_pointer_q = translation_pointer_n;
      translation_pointer_valid_q = translation_pointer_valid_n;
      translation_pointer_type_q = translation_pointer_type_n;
    end
  end
endmodule
