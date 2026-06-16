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
// Date: 21.05.2017
// Description: Issue stage dispatches instructions to the FUs and keeps track of them
//              in a scoreboard like data-structure.


module issue_stage
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type branchpredict_sbe_t = logic,
    parameter type exception_t = logic,
    parameter type fu_data_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter type writeback_t = logic,
    parameter type x_issue_req_t = logic,
    parameter type x_issue_resp_t = logic,
    parameter type x_register_t = logic,
    parameter type x_commit_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Is scoreboard full - PERF_COUNTERS
    output logic sb_full_o,
    // Prevent from issuing - CONTROLLER
    input logic flush_unissued_instr_i,
    // Flush whole scoreboard - CONTROLLER
    input logic flush_i,
    // Stall inserted by Acc dispatcher - ACC_DISPATCHER
    input logic stall_i,
    // Handshake's data with decode stage - ID_STAGE
    input scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_i,
    input scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_i_prev,
    // instruction value - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_i,
    // Handshake's valid with decode stage - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_valid_i,
    // Is instruction a control flow instruction - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] is_ctrl_flow_i,
    // Handshake's acknowlege with decode stage - ID_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_ack_o,
    // rs1 forwarding - EX_STAGE
    output [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.VLEN-1:0] rs1_forwarding_o,
    // rs2 forwarding - EX_STAGE
    output [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.VLEN-1:0] rs2_forwarding_o,
    // FU data useful to execute instruction - EX_STAGE
    output fu_data_t [CVA6Cfg.NrIssuePorts-1:0] fu_data_o,
    // Program Counter - EX_STAGE
    output logic [CVA6Cfg.VLEN-1:0] pc_o,
    // Is zcmt instruction - EX_STAGE
    output logic is_zcmt_o,
    // Is compressed instruction - EX_STAGE
    output logic is_compressed_instr_o,
    // Transformed trap instruction - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0][31:0] tinst_o,
    // Fixed Latency Unit is ready - EX_STAGE
    input logic flu_ready_i,
    // ALU output is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] alu_valid_o,
    // Branch unit is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] branch_valid_o,
    // Information of branch prediction - EX_STAGE
    output branchpredict_sbe_t branch_predict_o,
    // Signaling that we resolved the branch - EX_STAGE
    input logic resolve_branch_i,
    // Load store unit FU is ready - EX_STAGE
    input logic lsu_ready_i,
    // Load store unit FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] lsu_valid_o,
    // Mult FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] mult_valid_o,
    // FPU FU is ready - EX_STAGE
    input logic fpu_ready_i,
    // FPU FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] fpu_valid_o,
    // FPU fmt field - EX_STAGE
    output logic [1:0] fpu_fmt_o,
    // FPU rm field - EX_STAGE
    output logic [2:0] fpu_rm_o,
    // ALU2 FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] alu2_valid_o,
    // CSR is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] csr_valid_o,
    // CVXIF FU is valid - EX_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] xfu_valid_o,
    // CVXIF is FU ready - EX_STAGE
    input logic xfu_ready_i,
    // CVXIF offloader instruction value - EX_STAGE
    output logic [31:0] x_off_instr_o,
    // CVA6 Hart ID - SUBSYSTEM
    input logic [CVA6Cfg.XLEN-1:0] hart_id_i,
    // CVXIF Issue interface - EX_STAGE
    input logic x_issue_ready_i,
    // TO_BE_COMPLETED - EX_STAGE
    input x_issue_resp_t x_issue_resp_i,
    // TO_BE_COMPLETED - EX_STAGE
    output logic x_issue_valid_o,
    // TO_BE_COMPLETED - EX_STAGE
    output x_issue_req_t x_issue_req_o,
    // CVXIF Register interface - EX_STAGE
    input logic x_register_ready_i,
    // TO_BE_COMPLETED - EX_STAGE
    output logic x_register_valid_o,
    // TO_BE_COMPLETED - EX_STAGE
    output x_register_t x_register_o,
    // CVXIF Commit interface - EX_STAGE
    output logic x_commit_valid_o,
    // TO_BE_COMPLETED - EX_STAGE
    output x_commit_t x_commit_o,
    // CVXIF Transaction rejected -> instruction is illegal - EX_STAGE
    output logic x_transaction_rejected_o,
    // Issue scoreboard entry - ACC_DISPATCHER
    output scoreboard_entry_t issue_instr_o,
    // TO_BE_COMPLETED - ACC_DISPATCHER
    output logic issue_instr_hs_o,
    // Transaction ID - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] trans_id_i,
    // Result from branch unit - EX_STAGE
    input bp_resolve_t resolved_branch_i,
    // Results to write back - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.XLEN-1:0] wbdata_i,
    // exception from execute stage or CVXIF - EX_STAGE
    input exception_t [CVA6Cfg.NrWbPorts-1:0] ex_ex_i,
    // Indicates valid results - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0] wt_valid_i,
    // CVXIF write enable - EX_STAGE
    input logic x_we_i,
    // CVXIF destination register - EX_STAGE
    input logic [4:0] x_rd_i,
    // Destination register in register file - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.RegAddrWidth-1:0] waddr_i,
    // Value to write to register file - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.XLEN-1:0] wdata_i,
    // GPR write enable - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0] we_gpr_i,
    // FPR write enable - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0] we_fpr_i,
    // Instructions to commit - COMMIT_STAGE
    output scoreboard_entry_t [CVA6Cfg.NrCommitPorts-1:0] commit_instr_o,
    // Instruction is cancelled - COMMIT_STAGE
    output logic [CVA6Cfg.NrCommitPorts-1:0] commit_drop_o,
    // Commit acknowledge - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0] commit_ack_i,
    // old physical register of committed instr - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.RegAddrWidth-1:0] commit_old_phys_i,
    // new physical register of committed instr - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.RegAddrWidth-1:0] commit_new_phys_i,
    // architectural destination register of committed instr - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.RegAddrWidth-1:0] commit_rd_i,
    // operation of committed instr - COMMIT_STAGE
    input fu_op [CVA6Cfg.NrCommitPorts-1:0] commit_op_i,
    // Issue stall - PERF_COUNTERS
    output logic stall_issue_o,
    // Information dedicated to RVFI - RVFI
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rvfi_issue_pointer_o,
    // Information dedicated to RVFI - RVFI
    output logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rvfi_commit_pointer_o,
    // Information dedicated to RVFI - RVFI
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] rvfi_rs1_o,
    // Information dedicated to RVFI - RVFI
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] rvfi_rs2_o,
    // Is rollback active
    output logic                                              rollback_en_o
);
  // ---------------------------------------------------
  // Scoreboard (SB) <-> Issue and Read Operands (IRO)
  // ---------------------------------------------------
  typedef logic [(CVA6Cfg.NrRgprPorts == 3 ? CVA6Cfg.XLEN : CVA6Cfg.FLen)-1:0] rs3_len_t;
  typedef struct packed {
    logic [CVA6Cfg.NR_SB_ENTRIES-1:0] still_issued;
    logic [CVA6Cfg.TRANS_ID_BITS-1:0] issue_pointer;
    writeback_t [CVA6Cfg.NrWbPorts-1:0] wb;
    scoreboard_entry_t [CVA6Cfg.NR_SB_ENTRIES-1:0] sbe;
  } forwarding_t;

  forwarding_t                                        fwd;
  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       issue_instr_sb_iro;
  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_sb_iro;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_instr_valid_sb_iro;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_ack_iro_sb;

  assign issue_instr_o    = issue_instr_sb_iro[0];
  assign issue_instr_hs_o = issue_instr_valid_sb_iro[0] & issue_ack_iro_sb[0];

  logic x_transaction_accepted_iro_sb, x_issue_writeback_iro_sb;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] x_id_iro_sb;

  // ---------------------------------------------------------
  // 1. Renaming instructions
  // ---------------------------------------------------------

  logic [CVA6Cfg.NrIssuePorts-1:0] issue_we_i;
  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] gpr_renamed_instr_i, fpr_renamed_instr_i;
  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] renamed_instr_i;
  rat_table_t                                   gpr_commit_rat, fpr_commit_rat;
  logic [CVA6Cfg.RegAddrWidth-1:0]              rollback_rd_i;
  logic [CVA6Cfg.RegAddrWidth-1:0]              rollback_old_phys_i;
  logic                                         rollback_we_i;
  fu_op                                         rollback_op_i;
  logic                                         gpr_rollback_we_i;
  logic [CVA6Cfg.NrIssuePorts-1:0]              decoded_instr_ack;

  assign rollback_en_o = rollback_we_i;
  assign decoded_instr_ack_o = decoded_instr_ack;


  //We only modify the RAT corrsponding to the correct registers
  always_comb begin : gpr_we
    if (!CVA6Cfg.FpPresent) begin
      issue_we_i = '0;
      gpr_rollback_we_i = rollback_we_i;
    end else begin
      gpr_rollback_we_i = is_rd_fpr(rollback_op_i) ? 1'b0 : rollback_we_i;
      for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts; i++) begin
        issue_we_i[i] = !is_rd_fpr(decoded_instr_i[i].op);
      end
    end
  end

  // ==========================================
  // RAT GENERAL PURPOSE REGISTERS (GPR)
  // ==========================================

  register_allocation_table #(
        .CVA6Cfg      (CVA6Cfg),
        .DATA_WIDTH   (CVA6Cfg.XLEN),
        .NR_READ_PORTS(CVA6Cfg.NrRgprPorts),
        .ADDR_WIDTH   (CVA6Cfg.RegAddrWidth),
        .COMMIT_RAT   (1'b0),
        .FPR_RAT      (1'b0),
        .scoreboard_entry_t ( scoreboard_entry_t )
  ) i_issue_register_allocation_table (
        .clk_i,
        .rst_ni,
        .we_i                    (issue_we_i),
        .commit_valid_i          (commit_ack_i),
        .commit_old_phys_i       (commit_old_phys_i),
        .commit_new_phys_i       (commit_new_phys_i),
        .commit_rd_i             (commit_rd_i),
        .commit_op_i             (commit_op_i),
        .rollback_rd_i           (rollback_rd_i),
        .rollback_old_phys_i     (rollback_old_phys_i),
        .rollback_we_i           (gpr_rollback_we_i),
        .decoded_instr_i         (decoded_instr_i),
        .decoded_instr_ack_i     (decoded_instr_ack),
        .renamed_instr_o         (gpr_renamed_instr_i),
        .rat_state_o             (),
        .rat_restore_state_i     (gpr_commit_rat),
        .rat_restore_en_i        (flush_i)
  );

  register_allocation_table #(
        .CVA6Cfg      (CVA6Cfg),
        .DATA_WIDTH   (CVA6Cfg.XLEN),
        .NR_READ_PORTS(CVA6Cfg.NrRgprPorts),
        .ADDR_WIDTH   (CVA6Cfg.RegAddrWidth),
        .COMMIT_RAT   (1'b1),
        .FPR_RAT      (1'b0),
        .scoreboard_entry_t ( scoreboard_entry_t )
  ) i_commit_register_allocation_table (
        .clk_i,
        .rst_ni,
        .we_i                    ('0),
        .commit_valid_i          (commit_ack_i),
        .commit_old_phys_i       (commit_old_phys_i),
        .commit_new_phys_i       (commit_new_phys_i),
        .commit_rd_i             (commit_rd_i),
        .commit_op_i             (commit_op_i),
        .rollback_rd_i           (rollback_rd_i),
        .rollback_old_phys_i     (rollback_old_phys_i),
        .rollback_we_i           (1'b0),
        .decoded_instr_i         (decoded_instr_i),
        .decoded_instr_ack_i     (decoded_instr_ack),
        .renamed_instr_o         (),
        .rat_state_o             (gpr_commit_rat),
        .rat_restore_state_i     ('0),
        .rat_restore_en_i        ('0)
  );

  if (CVA6Cfg.FpPresent) begin
    logic [CVA6Cfg.NrIssuePorts-1:0] issue_fpr_we_i;
    logic                            fpr_rollback_we_i;


    always_comb begin : fpr_we
      fpr_rollback_we_i = (rollback_we_i && is_rd_fpr(rollback_op_i)) ? 1'b1 : 1'b0;
      for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts; i++) begin
        issue_fpr_we_i[i] = is_rd_fpr(decoded_instr_i[i].op);
      end
    end

    // ==========================================
    // RAT FLOATING POINT REGISTERS (FPR)
    // ==========================================

    register_allocation_table #(
          .CVA6Cfg      (CVA6Cfg),
          .DATA_WIDTH   (CVA6Cfg.XLEN),
          .NR_READ_PORTS(CVA6Cfg.NrRgprPorts),
          .ADDR_WIDTH   (CVA6Cfg.RegAddrWidth),
          .COMMIT_RAT   (1'b0),
          .FPR_RAT      (1'b1),
          .scoreboard_entry_t ( scoreboard_entry_t )
    ) i_issue_fp_register_allocation_table (
          .clk_i,
          .rst_ni,
          .we_i                    (issue_fpr_we_i),
          .commit_valid_i          (commit_ack_i),
          .commit_old_phys_i       (commit_old_phys_i),
          .commit_new_phys_i       (commit_new_phys_i),
          .commit_rd_i             (commit_rd_i),
          .commit_op_i             (commit_op_i),
          .rollback_rd_i           (rollback_rd_i),
          .rollback_old_phys_i     (rollback_old_phys_i),
          .rollback_we_i           (fpr_rollback_we_i),
          .decoded_instr_i         (decoded_instr_i),
          .decoded_instr_ack_i     (decoded_instr_ack),
          .renamed_instr_o         (fpr_renamed_instr_i),
          .rat_state_o             (),
          .rat_restore_state_i     (fpr_commit_rat),
          .rat_restore_en_i        (flush_i)
    );


    register_allocation_table #(
          .CVA6Cfg      (CVA6Cfg),
          .DATA_WIDTH   (CVA6Cfg.XLEN),
          .NR_READ_PORTS(CVA6Cfg.NrRgprPorts),
          .ADDR_WIDTH   (CVA6Cfg.RegAddrWidth),
          .COMMIT_RAT   (1'b1),
          .FPR_RAT      (1'b1),
          .scoreboard_entry_t ( scoreboard_entry_t )
    ) i_commit_fp_register_allocation_table (
          .clk_i,
          .rst_ni,
          .we_i                    ('0),
          .commit_valid_i          (commit_ack_i),
          .commit_old_phys_i       (commit_old_phys_i),
          .commit_new_phys_i       (commit_new_phys_i),
          .commit_rd_i             (commit_rd_i),
          .commit_op_i             (commit_op_i),
          .rollback_rd_i           (rollback_rd_i),
          .rollback_old_phys_i     (rollback_old_phys_i),
          .rollback_we_i           (1'b0),
          .decoded_instr_i         (decoded_instr_i),
          .decoded_instr_ack_i     (decoded_instr_ack),
          .renamed_instr_o         (),
          .rat_state_o             (fpr_commit_rat),
          .rat_restore_state_i     ('0),
          .rat_restore_en_i        ('0)
    );
  end

  always_comb begin : reg_sel
    if (CVA6Cfg.FpPresent) begin
      renamed_instr_i = decoded_instr_i;
      for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts; i++) begin
        renamed_instr_i[i].rd = is_rd_fpr(decoded_instr_i[i].op) ? fpr_renamed_instr_i[i].rd : gpr_renamed_instr_i[i].rd;
        renamed_instr_i[i].old_phys = is_rd_fpr(decoded_instr_i[i].op) ? fpr_renamed_instr_i[i].old_phys : gpr_renamed_instr_i[i].old_phys;
        renamed_instr_i[i].rs1 = is_rs1_fpr(decoded_instr_i[i].op) ? fpr_renamed_instr_i[i].rs1 : gpr_renamed_instr_i[i].rs1;
        renamed_instr_i[i].rs2 = is_rs2_fpr(decoded_instr_i[i].op) ? fpr_renamed_instr_i[i].rs2 : gpr_renamed_instr_i[i].rs2;
        renamed_instr_i[i].result = is_imm_fpr(decoded_instr_i[i].op) ? fpr_renamed_instr_i[i].result : gpr_renamed_instr_i[i].result;
      end
    end else begin
      renamed_instr_i = gpr_renamed_instr_i;
    end
  end

  // ---------------------------------------------------------
  // 2. Manage instructions in reservation stations
  // ---------------------------------------------------------

  for (int i = 0; i < 8; i++) begin
    fu_module fu;
    fu = fu_module'(i); // Le cast magique static    logic [FP_WIDTH-1:0] local_result; // lane-local results

    // Generate instances only if needed, lane 0 always generated
    if ((lane == 0) || EnableVectors) begin : active_lane
      logic in_valid, out_valid, out_ready; // lane-local handshake

      logic [NUM_OPERANDS-1:0][FP_WIDTH-1:0] local_operands; // lane-local operands
      logic [FP_WIDTH-1:0]                   op_result;      // lane-local results
      fpnew_pkg::status_t                    op_status;

      assign in_valid = in_valid_i & ((lane == 0) | vectorial_op); // upper lanes only for vectors
      // Slice out the operands for this lane
      always_comb begin : prepare_input
        for (int i = 0; i < int'(NUM_OPERANDS); i++) begin
          local_operands[i] = operands_i[i][(unsigned'(lane)+1)*FP_WIDTH-1:unsigned'(lane)*FP_WIDTH];
        end
      end

      // Instantiate the operation from the selected opgroup
      if (OpGroup == fpnew_pkg::ADDMUL) begin : lane_instance
        reservation_station #(
          .CVA6Cfg        (CVA6Cfg),
          .DATA_WIDTH     (CVA6Cfg.XLEN),
          .NR_READ_PORTS  (CVA6Cfg.NrRgprPorts),
          .ADDR_WIDTH     (CVA6Cfg.RegAddrWidth),
          .NR_RS_ENTRIES  (),
          .FPR_ENABLED    (is_fpr_used(fu)),
          .scoreboard_entry_t = (scoreboard_entry_t)
        ) i_reservation_station (
          .clk_i   (clk_i),
          .rst_ni  (rst_ni),
          .we_i     ,
          .rm_op_i, // op of the entry to remove
          .rm_i, // do we remove the entry
          .rm_id_i, // id of the entry to remove
          .rm_rd_i, // dest reg of the entry to remove
          .rs_restore_en_i, // id of the entry to remove
          .decoded_instr_i,
          .decoded_instr_ack_i,
          .decoded_instr_o, //instructions found ready
          .decoded_instr_valid_o, //is instruction valid
        );
        assign lane_is_class[lane]   = 1'b0;
        assign lane_class_mask[lane] = fpnew_pkg::NEGINF;
      end else if (OpGroup == fpnew_pkg::DIVSQRT) begin : lane_instance
        // fpnew_divsqrt #(
        //   .FpFormat   (FpFormat),
        //   .NumPipeRegs(NumPipeRegs),
        //   .PipeConfig (PipeConfig),
        //   .TagType    (TagType),
        //   .AuxType    (logic)
        // ) i_divsqrt (
        //   .clk_i,
        //   .rst_ni,
        //   .operands_i      ( local_operands               ),
        //   .is_boxed_i      ( is_boxed_i[NUM_OPERANDS-1:0] ),
        //   .rnd_mode_i,
        //   .op_i,
        //   .op_mod_i,
        //   .tag_i,
        //   .aux_i           ( vectorial_op         ), // Remember whether operation was vectorial
        //   .in_valid_i      ( in_valid             ),
        //   .in_ready_o      ( lane_in_ready[lane]  ),
        //   .flush_i,
        //   .result_o        ( op_result            ),
        //   .status_o        ( op_status            ),
        //   .extension_bit_o ( lane_ext_bit[lane]   ),
        //   .tag_o           ( lane_tags[lane]      ),
        //   .aux_o           ( lane_vectorial[lane] ),
        //   .out_valid_o     ( out_valid            ),
        //   .out_ready_i     ( out_ready            ),
        //   .busy_o          ( lane_busy[lane]      ),
        //   .reg_ena_i
        // );
        // assign lane_is_class[lane] = 1'b0;
      end else if (OpGroup == fpnew_pkg::NONCOMP) begin : lane_instance
        fpnew_noncomp #(
          .FpFormat   (FpFormat),
          .NumPipeRegs(NumPipeRegs),
          .PipeConfig (PipeConfig),
          .TagType    (TagType),
          .AuxType    (logic)
        ) i_noncomp (
          .clk_i,
          .rst_ni,
          .operands_i      ( local_operands               ),
          .is_boxed_i      ( is_boxed_i[NUM_OPERANDS-1:0] ),
          .rnd_mode_i,
          .op_i,
          .op_mod_i,
          .tag_i,
          .mask_i            ( simd_mask_i[lane]     ),
          .aux_i             ( vectorial_op          ), // Remember whether operation was vectorial
          .in_valid_i        ( in_valid              ),
          .in_ready_o        ( lane_in_ready[lane]   ),
          .flush_i,
          .result_o          ( op_result             ),
          .status_o          ( op_status             ),
          .extension_bit_o   ( lane_ext_bit[lane]    ),
          .class_mask_o      ( lane_class_mask[lane] ),
          .is_class_o        ( lane_is_class[lane]   ),
          .tag_o             ( lane_tags[lane]       ),
          .mask_o            ( lane_masks[lane]      ),
          .aux_o             ( lane_vectorial[lane]  ),
          .out_valid_o       ( out_valid             ),
          .out_ready_i       ( out_ready             ),
          .busy_o            ( lane_busy[lane]       ),
          .reg_ena_i,
          .early_out_valid_o ( lane_early_out_valid[lane] )
        );
      end // ADD OTHER OPTIONS HERE

      // Handshakes are only done if the lane is actually used
      assign out_ready            = out_ready_i & ((lane == 0) | result_is_vector);
      assign lane_out_valid[lane] = out_valid   & ((lane == 0) | result_is_vector);

      // Properly NaN-box or sign-extend the slice result if not in use
      assign local_result      = (lane_out_valid[lane] | ExtRegEna) ? op_result : '{default: lane_ext_bit[0]};
      assign lane_status[lane] = (lane_out_valid[lane] | ExtRegEna) ? op_status : '0;

    // Otherwise generate constant sign-extension
    end else begin
      assign lane_out_valid[lane] = 1'b0; // unused lane
      assign lane_in_ready[lane]  = 1'b0; // unused lane
      assign local_result         = '{default: lane_ext_bit[0]}; // sign-extend/nan box
      assign lane_status[lane]    = '0;
      assign lane_busy[lane]      = 1'b0;
      assign lane_is_class[lane]  = 1'b0;
    end

    // Insert lane result into slice result
    assign slice_result[(unsigned'(lane)+1)*FP_WIDTH-1:unsigned'(lane)*FP_WIDTH] = local_result;

    // Create Classification results
    if (TrueSIMDClass && SIMD_WIDTH >= 10) begin : vectorial_true_class // true vectorial class blocks are 10bits in size
      assign slice_vec_class_result[lane*SIMD_WIDTH +: 10] = lane_class_mask[lane];
      assign slice_vec_class_result[(lane+1)*SIMD_WIDTH-1 -: SIMD_WIDTH-10] = '0;
    end else if ((lane+1)*8 <= Width) begin : vectorial_class // vectorial class blocks are 8bits in size
      assign local_sign = (lane_class_mask[lane] == fpnew_pkg::NEGINF ||
                           lane_class_mask[lane] == fpnew_pkg::NEGNORM ||
                           lane_class_mask[lane] == fpnew_pkg::NEGSUBNORM ||
                           lane_class_mask[lane] == fpnew_pkg::NEGZERO);
      // Write the current block segment
      assign slice_vec_class_result[(lane+1)*8-1:lane*8] = {
        local_sign,  // BIT 7
        ~local_sign, // BIT 6
        lane_class_mask[lane] == fpnew_pkg::QNAN, // BIT 5
        lane_class_mask[lane] == fpnew_pkg::SNAN, // BIT 4
        lane_class_mask[lane] == fpnew_pkg::POSZERO
            || lane_class_mask[lane] == fpnew_pkg::NEGZERO, // BIT 3
        lane_class_mask[lane] == fpnew_pkg::POSSUBNORM
            || lane_class_mask[lane] == fpnew_pkg::NEGSUBNORM, // BIT 2
        lane_class_mask[lane] == fpnew_pkg::POSNORM
            || lane_class_mask[lane] == fpnew_pkg::NEGNORM, // BIT 1
        lane_class_mask[lane] == fpnew_pkg::POSINF
            || lane_class_mask[lane] == fpnew_pkg::NEGINF // BIT 0
      };
    end
  end


  // ---------------------------------------------------------
  // 2. Manage instructions in a scoreboard
  // ---------------------------------------------------------
  scoreboard #(
      .CVA6Cfg   (CVA6Cfg),
      .rs3_len_t (rs3_len_t),
      .bp_resolve_t(bp_resolve_t),
      .writeback_t(writeback_t),
      .forwarding_t(forwarding_t),
      .exception_t(exception_t),
      .scoreboard_entry_t(scoreboard_entry_t)
  ) i_scoreboard (
      .clk_i,
      .rst_ni,
      .sb_full_o               (sb_full_o),
      .flush_unissued_instr_i,
      .flush_i,
      .x_transaction_accepted_i(x_transaction_accepted_iro_sb),
      .x_issue_writeback_i     (x_issue_writeback_iro_sb),
      .x_id_i                  (x_id_iro_sb),
      .commit_instr_o,
      .commit_drop_o,
      .commit_ack_i,
      .decoded_instr_i         (renamed_instr_i),
      .orig_instr_i,
      .decoded_instr_valid_i   (decoded_instr_valid_i),
      .decoded_instr_ack_o     (decoded_instr_ack),
      .issue_instr_o           (issue_instr_sb_iro),
      .orig_instr_o            (orig_instr_sb_iro),
      .issue_instr_valid_o     (issue_instr_valid_sb_iro),
      .issue_ack_i             (issue_ack_iro_sb),
      .fwd_o                   (fwd),
      .resolved_branch_i       (resolved_branch_i),
      .trans_id_i              (trans_id_i),
      .wbdata_i                (wbdata_i),
      .ex_i                    (ex_ex_i),
      .wt_valid_i,
      .x_we_i,
      .x_rd_i,
      .rvfi_issue_pointer_o,
      .rvfi_commit_pointer_o,
      .rollback_rd_o           (rollback_rd_i),
      .rollback_old_phys_o     (rollback_old_phys_i),
      .rollback_op_o           (rollback_op_i),
      .rollback_we_o           (rollback_we_i)
  );

  // ---------------------------------------------------------
  // 3. Issue instruction and read operand, also commit
  // ---------------------------------------------------------
  issue_read_operands #(
      .CVA6Cfg(CVA6Cfg),
      .branchpredict_sbe_t(branchpredict_sbe_t),
      .fu_data_t(fu_data_t),
      .scoreboard_entry_t(scoreboard_entry_t),
      .rs3_len_t(rs3_len_t),
      .writeback_t(writeback_t),
      .forwarding_t(forwarding_t),
      .x_issue_req_t(x_issue_req_t),
      .x_issue_resp_t(x_issue_resp_t),
      .x_register_t(x_register_t),
      .x_commit_t(x_commit_t)
  ) i_issue_read_operands (
      .clk_i,
      .rst_ni,
      .flush_i                 (flush_unissued_instr_i),
      .stall_i,
      .issue_instr_i           (issue_instr_sb_iro),
      .issue_instr_i_prev      (decoded_instr_i_prev),
      .orig_instr_i            (orig_instr_sb_iro),
      .issue_instr_valid_i     (issue_instr_valid_sb_iro),
      .issue_ack_o             (issue_ack_iro_sb),
      .fwd_i                   (fwd),
      .fu_data_o               (fu_data_o),
      .rs1_forwarding_o        (rs1_forwarding_o),
      .rs2_forwarding_o        (rs2_forwarding_o),
      .pc_o,
      .is_zcmt_o,
      .is_compressed_instr_o,
      .flu_ready_i             (flu_ready_i),
      .alu_valid_o             (alu_valid_o),
      .branch_valid_o          (branch_valid_o),
      .tinst_o                 (tinst_o),
      .branch_predict_o,
      .lsu_ready_i,
      .lsu_valid_o,
      .mult_valid_o,
      .fpu_ready_i,
      .fpu_valid_o,
      .fpu_fmt_o,
      .fpu_rm_o,
      .alu2_valid_o,
      .csr_valid_o,
      .cvxif_valid_o           (xfu_valid_o),
      .cvxif_ready_i           (xfu_ready_i),
      .cvxif_off_instr_o       (x_off_instr_o),
      .hart_id_i               (hart_id_i),
      .x_issue_ready_i         (x_issue_ready_i),
      .x_issue_resp_i          (x_issue_resp_i),
      .x_issue_valid_o         (x_issue_valid_o),
      .x_issue_req_o           (x_issue_req_o),
      .x_register_ready_i      (x_register_ready_i),
      .x_register_valid_o      (x_register_valid_o),
      .x_register_o            (x_register_o),
      .x_commit_valid_o        (x_commit_valid_o),
      .x_commit_o              (x_commit_o),
      .x_transaction_accepted_o(x_transaction_accepted_iro_sb),
      .x_transaction_rejected_o(x_transaction_rejected_o),
      .x_issue_writeback_o     (x_issue_writeback_iro_sb),
      .x_id_o                  (x_id_iro_sb),
      .waddr_i,
      .wdata_i,
      .we_gpr_i,
      .we_fpr_i,
      .stall_issue_o,
      .rvfi_rs1_o              (rvfi_rs1_o),
      .rvfi_rs2_o              (rvfi_rs2_o)
  );

endmodule
