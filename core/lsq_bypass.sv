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
// Additional contributions by:
//                 Markus Wegmann - markus.wegmann@technokrat.ch
//                 Noam Gallmann - gnoam@live.com
//                 Felipe Lisboa Malaquias
//                 Henry Suzukawa
//                 Angela Gonzalez - PlanV Technologies
//
// Description:    This register file is optimized for implementation on



module lsq_bypass
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg       = config_pkg::cva6_cfg_empty,
    parameter int unsigned           ADDR_WIDTH    = 5,
    parameter int unsigned           FPR_ENABLED   = 0,
    parameter type scoreboard_entry_t = logic
) (
    input  logic                                                         clk_i,
    input  logic                                                         rst_ni,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]                              rm_i, // do we remove the entry
    input  fu_op [CVA6Cfg.NrIssuePorts-1:0]                              rm_op_i, // op of the entry to remove
    input  logic [CVA6Cfg.NrIssuePorts-1:0][ADDR_WIDTH-1:0]              rm_rd_i, // dest reg addr of the entry to remove
    input  logic [CVA6Cfg.NrWbPorts-1:0]                                 wb_valid_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0][ADDR_WIDTH-1:0]                 wb_rd_i, // dest reg of the entry to remove
    input  fu_op [CVA6Cfg.NrWbPorts-1:0]                                 wb_op_i, // op of the entry to remove
    input  logic [CVA6Cfg.RollbackWidth-1:0]                             rollback_en_i, // is rollback enabled
    input  logic [CVA6Cfg.RollbackWidth-1:0][ADDR_WIDTH-1:0]             rollback_rd_i, // architectural register to rollback
    input  fu_op [CVA6Cfg.RollbackWidth-1:0]                             rollback_op_i, // op of the instr to rollback
    input  logic                                                         rs_restore_en_i, // id of the entry to remove


    output logic [CVA6Cfg.NrIssuePorts-1:0]                              st_data_valid_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0]                              vaddr_valid_o,

    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]                 decoded_instr_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]                              decoded_instr_ack_i
);

  localparam NUM_REG = CVA6Cfg.NrPhysReg;

  logic [NUM_REG-1:0] is_result_available_gpr_n, is_result_available_gpr_q;
  //some operations might use gpr and fpr register as operands or destination
  logic [NUM_REG-1:0] is_result_available_fpr_n, is_result_available_fpr_q;

  // rs1 should be addr and rs2 data but i am not 100% sure about this
  for (genvar i = 0; i<CVA6Cfg.NrIssuePorts ; i++) begin
    if (!FPR_ENABLED) begin
      assign st_data_valid_o[i] = is_result_available_gpr_q[decoded_instr_i[i].rs2];
      assign vaddr_valid_o[i] = is_result_available_gpr_q[decoded_instr_i[i].rs1];
    end else begin
      assign st_data_valid_o[i] = is_rs2_fpr(decoded_instr_i[i].op) ? is_result_available_fpr_q[decoded_instr_i[i].rs2] : is_result_available_gpr_q[decoded_instr_i[i].rs2];
      assign vaddr_valid_o[i] = is_rs1_fpr(decoded_instr_i[i].op) ? is_result_available_fpr_q[decoded_instr_i[i].rs1] : is_result_available_gpr_q[decoded_instr_i[i].rs1];
    end
  end


  always_comb begin : updating_rs
    is_result_available_gpr_n = is_result_available_gpr_q;

    if (FPR_ENABLED) begin
      is_result_available_fpr_n = is_result_available_fpr_q;
    end

    //updating based on write back
    for (int i = 0; i < CVA6Cfg.NrWbPorts; i++) begin
      if (wb_valid_i[i]) begin
        if (FPR_ENABLED) begin
          if (is_rd_fpr(wb_op_i[i])) begin
            is_result_available_fpr_n[wb_rd_i[i]] = 1'b1;
          end else begin
            is_result_available_gpr_n[wb_rd_i[i]] = 1'b1;
          end
        end else begin
          is_result_available_gpr_n[wb_rd_i[i]] = 1'b1;
        end
      end
    end

    //updating based on speculative wakeup
    for (int i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      if (rm_i[i] && instr_cycle_count(rm_op_i[i]) == 1'b1) begin
        if (FPR_ENABLED) begin
          if (is_rd_fpr(rm_op_i[i])) begin
            is_result_available_fpr_n[rm_rd_i[i]] = 1'b1;
          end else begin
            is_result_available_gpr_n[rm_rd_i[i]] = 1'b1;
          end
        end else begin
          is_result_available_gpr_n[rm_rd_i[i]] = 1'b1;
        end
      end
    end

    for (int i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      if (decoded_instr_ack_i[i]) begin
        //always update dependency based on newly issued instr
        if (FPR_ENABLED) begin
          if (is_rd_fpr(decoded_instr_i[i].op)) begin
            is_result_available_fpr_n[decoded_instr_i[i].rd] = 1'b0;
          end else begin
            is_result_available_gpr_n[decoded_instr_i[i].rd] = 1'b0;
          end
        end else begin
          is_result_available_gpr_n[decoded_instr_i[i].rd] = 1'b0;
        end
      end
    end

    // updating dependencies during rollback
    for (int unsigned i = 0; i<CVA6Cfg.RollbackWidth ; i++) begin
      if (rollback_en_i[i]) begin
        if (FPR_ENABLED) begin
          if (is_rd_fpr(rollback_op_i[i])) begin
            is_result_available_fpr_n[rollback_rd_i[i]] = 1'b1;
          end else begin
            is_result_available_gpr_n[rollback_rd_i[i]] = 1'b1;
          end
        end else begin
          is_result_available_gpr_n[rollback_rd_i[i]] = 1'b1;
        end
      end
    end


    is_result_available_gpr_n[0] = '1;

    if (rs_restore_en_i) begin
      is_result_available_gpr_n = '1;
      if (FPR_ENABLED) begin
        is_result_available_fpr_n = '1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      if (FPR_ENABLED) begin
        is_result_available_fpr_q <= '1;
      end
      is_result_available_gpr_q <= '1;
    end else begin
      is_result_available_gpr_q <= is_result_available_gpr_n;
      if (FPR_ENABLED) begin
        is_result_available_fpr_q <= is_result_available_fpr_n;
      end
    end
  end
endmodule
