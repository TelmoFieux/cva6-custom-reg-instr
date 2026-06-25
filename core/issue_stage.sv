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

  // In superscalar mode they are doubled so we divide it by two to get the number of operand max
  // per instr
  localparam int unsigned NR_READ_PORTS = CVA6Cfg.NrRgprPorts / 2;

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
  logic [CVA6Cfg.GlobalRsIdWidth-1:0] global_rs_id_n, global_rs_id_q;
  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] renamed_instr_i;
  rat_table_t                                   gpr_commit_rat, fpr_commit_rat;
  logic [CVA6Cfg.RegAddrWidth-1:0]              rollback_rd_i;
  logic [CVA6Cfg.RegAddrWidth-1:0]              rollback_old_phys_i;
  logic                                         rollback_we_i;
  fu_op                                         rollback_op_i;
  logic                                         gpr_rollback_we_i;
  logic [CVA6Cfg.NrIssuePorts-1:0]              issue_instr_ack;

  assign rollback_en_o = rollback_we_i;

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
        .NR_READ_PORTS(NR_READ_PORTS),
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
        .decoded_instr_ack_i     (decoded_instr_ack_o),
        .renamed_instr_o         (gpr_renamed_instr_i),
        .rat_state_o             (),
        .rat_restore_state_i     (gpr_commit_rat),
        .rat_restore_en_i        (flush_i)
  );

  register_allocation_table #(
        .CVA6Cfg      (CVA6Cfg),
        .DATA_WIDTH   (CVA6Cfg.XLEN),
        .NR_READ_PORTS(NR_READ_PORTS),
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
        .decoded_instr_ack_i     (decoded_instr_ack_o),
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
          .NR_READ_PORTS(NR_READ_PORTS),
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
          .decoded_instr_ack_i     (decoded_instr_ack_o),
          .renamed_instr_o         (fpr_renamed_instr_i),
          .rat_state_o             (),
          .rat_restore_state_i     (fpr_commit_rat),
          .rat_restore_en_i        (flush_i)
    );


    register_allocation_table #(
          .CVA6Cfg      (CVA6Cfg),
          .DATA_WIDTH   (CVA6Cfg.XLEN),
          .NR_READ_PORTS(NR_READ_PORTS),
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
          .decoded_instr_ack_i     (decoded_instr_ack_o),
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
    for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts; i++) begin
      renamed_instr_i[i].global_rs_id = global_rs_id_q + i;
    end
  end

  // ---------------------------------------------------------
  // 2. Manage instructions in reservation stations
  // ---------------------------------------------------------

  localparam int unsigned NR_WB = 5;
  localparam int unsigned RS_SIZE = CVA6Cfg.NR_SB_ENTRIES / (NR_WB -1); //NR_WB -1 because ACCEL and CVXIF are incompatible
  logic [CVA6Cfg.GlobalRsIdWidth-1:0] rollback_id_o;
  fu_op                               wb_op_o;

  scoreboard_entry_t [NR_WB-1:0] rs_results;
  logic [NR_WB-1:0] rs_valid;
  logic [NR_WB-1:0][CVA6Cfg.NrIssuePorts-1:0] rs_full;

  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] tree_results;
  logic [CVA6Cfg.NrIssuePorts-1:0] tree_valid;


  for (genvar i = 0; i < NR_WB; i++) begin : gen_rs_blocks
    localparam fu_phys fu = fu_phys'(i);

    localparam logic is_rs_instanciated =
        (fu == FPU_ALU2) ? (CVA6Cfg.SuperscalarEn || CVA6Cfg.FpPresent) :
        (fu == F_CVXIF)  ? CVA6Cfg.CvxifEn :
        (fu == F_ACCEL)  ? 1'b0 : //not yet supported in superscalar mode
        1'b1;

    if (is_rs_instanciated) begin : rs_instance
      logic [CVA6Cfg.NrIssuePorts-1:0] we_i;
      logic fu_ready;

      scoreboard_entry_t               decoded_instr_o;
      logic                            decoded_instr_valid_o;
      logic [CVA6Cfg.NrIssuePorts-1:0] rs_full_o;

      logic [CVA6Cfg.NrIssuePorts-1:0] rm_i;
      logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.GlobalRsIdWidth-1:0] rm_id_i;

      for (genvar j = 0; j< CVA6Cfg.NrIssuePorts; j++ ) begin : g_write_enable
        case (fu)
          LOAD_STORE :
            assign we_i[j] = (decoded_instr_i[j].fu == LOAD || decoded_instr_i[j].fu == STORE) && !rollback_we_i;

          FLU :
            assign we_i[j] = (((decoded_instr_i[0].fu == ALU || decoded_instr_i[0].fu == CSR || decoded_instr_i[0].fu == MULT || decoded_instr_i[0].fu == CTRL_FLOW)
                  && decoded_instr_i[1].fu == ALU) ?
                  ((j == 0) ? 1'b1 : 1'b0) :
              decoded_instr_i[j].fu == ALU
              || decoded_instr_i[j].fu == CSR || decoded_instr_i[j].fu == MULT
              || decoded_instr_i[j].fu == CTRL_FLOW || decoded_instr_i[j].fu == NONE) && !rollback_we_i;

          // Since ALU2 and FPU share the same Wb port we only write instr to this rs if
          // it is an fpu instr or it is an alu instruction and we already wrote one flu instr in
          // the flu RS. That way we can try to dipacth as most as possible 2 instr to each alu when
          // possible
          FPU_ALU2 :
            assign we_i[j] = (((decoded_instr_i[0].fu == ALU || decoded_instr_i[0].fu == CSR || decoded_instr_i[0].fu == MULT || decoded_instr_i[0].fu == CTRL_FLOW)
            && decoded_instr_i[1].fu == ALU ) ?
            ((j == 1) ? 1'b1 : 1'b0) : decoded_instr_i[j].fu == FPU || decoded_instr_i[j].fu == FPU_VEC) && !rollback_we_i;

          F_CVXIF :
            assign we_i[j] = decoded_instr_i[j].fu == CVXIF && !rollback_we_i;

          default :
            assign we_i[j] = '0;
        endcase
      end

      for (genvar j = 0; j< CVA6Cfg.NrIssuePorts; j++ ) begin
        assign rm_i[j] = tree_valid[j];
        assign rm_id_i[j] = tree_results[j].global_rs_id;
      end

      case (fu)
        FLU :
          assign fu_ready = flu_ready_i;

        FPU_ALU2 :
          assign fu_ready = fpu_ready_i;

        LOAD_STORE :
          assign fu_ready = lsu_ready_i;

        F_CVXIF :
          assign fu_ready = xfu_ready_i;

        default :
          assign fu_ready = 1'b0;
      endcase

      // if fpu not activated then only alu2 will use the FPU wb port
      // so no need to check for fpr register dependency
      localparam logic en_fpr =
        (fu == FPU_ALU2) ? (CVA6Cfg.FpPresent) :
        is_fpr_used(fu);

      reservation_station #(
        .CVA6Cfg            (CVA6Cfg),
        .DATA_WIDTH         (CVA6Cfg.XLEN),
        .NR_READ_PORTS      (NR_READ_PORTS),
        .ADDR_WIDTH         (CVA6Cfg.RegAddrWidth),
        .NR_RS_ENTRIES      (RS_SIZE),
        .FPR_ENABLED        (en_fpr),
        .scoreboard_entry_t (scoreboard_entry_t)
      ) i_reservation_station (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .full_o                 (rs_full_o),
        .we_i                   (we_i),
        .rm_i                   (rm_i),
        .rm_id_i                (rm_id_i),
        .wb_valid_i             (wt_valid_i),
        .wb_rd_i                (waddr_i),
        .wb_op_i                (wb_op_o),
        .rollback_id_i          (rollback_id_o),
        .rollback_en_i          (rollback_we_i),
        .rs_restore_en_i        (flush_i),
        .decoded_instr_i        (renamed_instr_i),
        .decoded_instr_ack_i    (issue_instr_ack),
        .decoded_instr_o        (decoded_instr_o),
        .decoded_instr_valid_o  (decoded_instr_valid_o)
      );
      assign rs_results[i] = decoded_instr_o;
      assign rs_valid[i] = decoded_instr_valid_o && fu_ready;
      assign rs_full[i] = rs_full_o & we_i;
    end else begin
      assign rs_results[i] = '0;
      assign rs_valid[i] = '0;
      assign rs_full[i] = '0;
    end
  end

  // represent if instructions have been accepted by th rs
  logic [CVA6Cfg.NrIssuePorts-1:0] final_rs_full;

  always_comb begin
    final_rs_full = '0;
    for (int i = 0; i < NR_WB; i++) begin
      final_rs_full |= rs_full[i];
    end
  end

  //if rs and scoreboard succesfully added the instr we validate the Handshake
  assign decoded_instr_ack_o = issue_instr_ack & ~final_rs_full;

  logic [CVA6Cfg.NrIssuePorts:0][NR_WB-1:0]         tournament_valid_masked;
  logic [NR_WB-1:0][CVA6Cfg.GlobalRsIdWidth-1:0]    tournament_seq_num;
  logic [NR_WB-1:0][$clog2(NR_WB)-1:0]              tournament_id;

  assign tournament_valid_masked [0] = rs_valid;

  for (genvar i = 0 ; i < NR_WB ; i++) begin
    assign tournament_seq_num[i] = rs_results[i].global_rs_id;
    assign tournament_id[i] = i;
  end

  //cascade of tournament_tree in order to extract 2 instructions to issue
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : g_alloc
    logic [$clog2(NR_WB)-1:0] winner_o;
    logic winner_valid_o;

    tournament_tree #(
        .ID_SIZE(CVA6Cfg.GlobalRsIdWidth),
        .NR_PLAYER(NR_WB)
      ) i_tournament_tree (
        .valid_i    (tournament_valid_masked[i]),
        .seq_num_i  (tournament_seq_num),
        .id_i       (tournament_id),
        .winner_o   (winner_o),
        .winner_valid_o (winner_valid_o)
    );

    assign tree_results[i] = rs_results[winner_o];
    assign tree_valid[i] = winner_valid_o;

    assign tournament_valid_masked[i+1] = tournament_valid_masked[i] & ~(NR_WB'(1) << winner_o);

  end

  //Finally we reorder instruction for 2 reasons
  //1. issue port 2 cannot execute CSR or CVXIF operations
  //2. CSR instruction forbids issuing 2 instuction at the same time

  if (tree_results[0].fu == CSR) begin
    assign issue_instr_sb_iro[0] = tree_results[0];
    assign issue_instr_sb_iro[1] = tree_results[1];
    assign issue_instr_valid_sb_iro[0] = tree_valid[0];
    assign issue_instr_valid_sb_iro[1] = 1'b0;
  end else if (tree_results[1].fu == CSR) begin
    assign issue_instr_sb_iro[0] = tree_results[1];
    assign issue_instr_sb_iro[1] = tree_results[0];
    assign issue_instr_valid_sb_iro[0] = tree_valid[1];
    assign issue_instr_valid_sb_iro[1] = 1'b0;
  end else if (tree_results[1].fu == CVXIF) begin
    assign issue_instr_sb_iro[0] = tree_results[1];
    assign issue_instr_sb_iro[1] = tree_results[0];
    assign issue_instr_valid_sb_iro[0] = tree_valid[1];
    assign issue_instr_valid_sb_iro[1] = tree_valid[0];
  end else begin
    assign issue_instr_sb_iro[0] = tree_results[0];
    assign issue_instr_sb_iro[1] = tree_results[1];
    assign issue_instr_valid_sb_iro[0] = tree_valid[0];
    assign issue_instr_valid_sb_iro[1] = tree_valid[1];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni || flush_i) begin
      global_rs_id_q <= '0;
    end else begin
      global_rs_id_q <= global_rs_id_q + CVA6Cfg.NrIssuePorts;
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
      .decoded_instr_ack_i     (decoded_instr_ack_o),
      .issue_instr_o           (),//j'ai enlevé cette valeur qui est drivé par les rs)
      .orig_instr_o            (orig_instr_sb_iro),
      .issue_instr_valid_o     (issue_instr_ack),//aussi drivé par les rs
      .issue_ack_i             (),
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
      .rollback_id_o,
      .rollback_old_phys_o     (rollback_old_phys_i),
      .rollback_op_o           (rollback_op_i),
      .rollback_we_o           (rollback_we_i),
      .wb_op_o
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
