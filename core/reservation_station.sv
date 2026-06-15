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



module reservation_station
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg       = config_pkg::cva6_cfg_empty,
    parameter int unsigned           DATA_WIDTH    = 32,
    parameter int unsigned           NR_READ_PORTS = 2,
    parameter int unsigned           ADDR_WIDTH    = 5,
    parameter int unsigned           NR_RS_ENTRIES = 4,
    parameter int unsigned           FPR_ENABLED   = 0,
    parameter type scoreboard_entry_t = logic
) (
    input logic                                               clk_i,
    input logic                                               rst_ni,
    input logic [CVA6Cfg.NrIssuePorts-1:0]                    we_i,
    input fu_op                                               rm_op_i, // op of the entry to remove
    input logic                                               rm_i, // do we remove the entry
    input logic [CVA6Cfg.GlobalRsIdWidth-1:0]                 rm_id_i, // id of the entry to remove

    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_i,
    input  logic              [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_ack_i,
    output scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_o, //instructions found ready
    input  logic              [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_valid_o, //is instruction valid
);

  localparam NUM_REG = 2 ** ADDR_WIDTH;

  typedef struct packed {
    scoreboard_entry_t [NR_RS_ENTRIES-1:0] rs_table;
    logic [NR_RS_ENTRIES-1:0] free_entries;
    logic [NR_RS_ENTRIES-1:0][NR_READ_PORTS-1:0] valid_regs;
  } reservation_station_t;

  logic [NUM_REG-1:0] is_result_available_gpr_n, is_result_available_gpr_q;

  //some operations might use gpr and fpr register as operands or destination
  if (FPR_ENABLED) begin
    logic [NUM_REG-1:0] is_result_available_fpr_n, is_result_available_fpr_q;
  end

  logic [NR_RS_ENTRIES-1:0] free_entries_masked [CVA6Cfg.NrIssuePorts:0];
  logic [$clog2(NR_RS_ENTRIES):0] alloc_idx    [CVA6Cfg.NrIssuePorts-1:0];

  assign free_entries_masked[0] = rs_q.free_entries;

  //priority encoder cascade to get free index in RS
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : g_alloc
      lzc #(
          .WIDTH(NUM_REG),
          .MODE(1'b0))
      i_lzc (
          .in_i   (free_entries_masked[i]),
          .cnt_o  (alloc_idx[i]),
          .empty_o()
      );

      assign free_entries_masked[i+1] = (we_i[i] && decoded_instr_ack_i[i] && (decoded_instr_i[i].rd != '0)) ?
        (free_entries_masked[i] & ~(NR_RS_ENTRIES'(1) << alloc_idx[i])) :
        free_entries_masked[i];
  end

  logic [NR_RS_ENTRIES-1:0] tournament_valid;
  logic [NR_RS_ENTRIES-1:0][CVA6Cfg.GlobalRsIdWidth-1:0] tournament_seq_num;
  logic [NR_RS_ENTRIES-1:0][$clog2(NR_RS_ENTRIES)-1:0] tournament_id;

  for (genvar i = 0 ; i < NR_RS_ENTRIES ; i++) begin
    assign tournament_valid[i] = rs_q.valid_regs[i] == '1 ? 1'b1 : 1'b0;
    assign tournament_seq_num[i] = rs_q.rs_table[i].global_rs_id;
    assign tournament_id[i] = i;
  end

  tournament_tree #(
      .ID_SIZE(CVA6Cfg.GlobalRsIdWidth),
      .NR_PLAYER(NR_RS_ENTRIES)
  i_tournament_tree (
      .valid_i    (tournament_valid),
      .seq_num_i  (tournament_seq_num),
      .id_i       (tournament_id),
      .winner_o,
      .winner_valid_o
  );

  assign decoded_instr_o = rs_q.rs_table[winner_o];
  assign decoded_instr_valid_o = winner_valid_o;

  reservation_station_t rs_n, rs_q;

  always_comb begin : updating_rs
    rs_n = rs_q;
    is_result_available_gpr_n = is_result_available_gpr_q;

    if (FPR_ENABLED) begin
      is_result_available_fpr_n = is_result_available_fpr_q;
    end

    //adding instr
    for (int i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      if (we_i[i] && decoded_instr_ack_i[i] && (decoded_instr_i[i].rd != '0)) begin
        rs_n.rs_table[alloc_idx[i]] = decoded_instr_i[i];
      end

      //always update dependency
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


      // In case of superscalar config, we check RAW hazard.
      // Current method only work up to 2 issue port

    for

    //removing instr after it was sent to ex stage or because of rollback
    rs_n.free_entries = free_entries_masked[CVA6Cfg.NrIssuePorts];
    for (int i = 0; i < NR_RS_ENTRIES; i++) begin
      if (rm_i && rm_id_i == rs_q.rs_table[i].global_rs_id) begin
        rs_n.free_entries[i] = 1'b1;
        if (FPR_ENABLED) begin
          if (is_rd_fpr(rm_op_i)) begin
            is_result_available_fpr_n[rs_q.rs_table[i].rd] = 1'b1;
          end else begin
            is_result_available_gpr_n[rs_q.rs_table[i].rd] = 1'b1;
          end
        end else begin
          is_result_available_gpr_n[rs_q.rs_table[i].rd] = 1'b1;
        end
      end

      //in case of newly added instruction we need to check
      //RAW hazard if 2 instruction are added the same cycle
      //Current method only work for 2 issue ports

      if (we_i == '1) begin
        for (int j = 0; j < CVA6Cfg.NrIssuePorts; i++) begin
          if (!FPR_ENABLED) begin
            rs_n.valid_regs[i][0] = (i == alloc_idx[j] && j > 0) ? ((decoded_instr_i[j].rs1 == decoded_instr_i[j-1].rd) ? 1'b0) : is_result_available_gpr_q[decoded_instr_i[j].rs1];
            rs_n.valid_regs[i][1] = (i == alloc_idx[j] && j > 0) ? ((decoded_instr_i[j].rs2 == decoded_instr_i[j-1].rd) ? 1'b0) : is_result_available_gpr_q[decoded_instr_i[j].rs2];
            if (NR_READ_PORTS == 3 && !decoded_instr_i[j].use_imm) begin
              rs_n.valid_regs[i][0] = (i == alloc_idx[j] && j > 0) ? ((decoded_instr_i[j].result == decoded_instr_i[j-1].rd) ? 1'b0) : is_result_available_gpr_q[decoded_instr_i[j].result];
            end
          end else begin
            rs_n.valid_regs[i][0] = (i == alloc_idx[j] && j > 0) ? ((decoded_instr_i[j].rd == decoded_instr_i[j-1].rd && is_rs1_fpr(decoded_instr_i[j].op) && is_rd_fpr(decoded_instr_i[j-1])) ? 1'b0)
            : is_rs1_fpr(decoded_instr_i[j].op) ? is_result_available_fpr_q[decoded_instr_i[j].rs1] : is_result_available_gpr_q[decoded_instr_i[i].rs1];
            rs_n.valid_regs[i][1] = (i == alloc_idx[j] && j > 0) ? ((decoded_instr_i[j].rs2 == decoded_instr_i[j-1].rd && is_rs2_fpr(decoded_instr_i[j].op) && is_rd_fpr(decoded_instr_i[j-1])) ? 1'b0)
            : is_rs2_fpr(decoded_instr_i[j].op) ? is_result_available_fpr_q[decoded_instr_i[j].rs2] : is_result_available_gpr_q[decoded_instr_i[i].rs2];
            if (NR_READ_PORTS == 3 && !decoded_instr_i[j].use_imm) begin
              rs_n.valid_regs[i][2] = (i == alloc_idx[j] && j > 0) ? ((decoded_instr_i[j].result == decoded_instr_i[j-1].rd && is_imm_fpr(decoded_instr_i[j].op) && is_rd_fpr(decoded_instr_i[j-1])) ? 1'b0)
              : is_imm_fpr(decoded_instr_i[j].op) ? is_result_available_fpr_q[decoded_instr_i[j].result] : is_result_available_gpr_q[decoded_instr_i[i].result];
          end
        end
      end else if (we_i != '0) begin
        for (int j = 0; j < CVA6Cfg.NrIssuePorts; i++) begin
          if (!FPR_ENABLED) begin
            rs_n.valid_regs[i][0] = (i == alloc_idx[j]) ? is_result_available_gpr_q[decoded_instr_i[j].rs1] : is_result_available_gpr_q[rs_q.rs_table[i].rs1];
            rs_n.valid_regs[i][1] = (i == alloc_idx[j]) ? is_result_available_gpr_q[decoded_instr_i[j].rs2] : is_result_available_gpr_q[rs_q.rs_table[i].rs2];
            if (NR_READ_PORTS == 3 && !decoded_instr_i[j].use_imm) begin
              rs_n.valid_regs[i][2] = (i == alloc_idx[j]) ? is_result_available_gpr_q[decoded_instr_i[j].result] : is_result_available_gpr_q[rs_q.rs_table[i].result];
            end
          end else begin
            rs_n.valid_regs[i][0] = (i == alloc_idx[j]) ? (is_rs1_fpr(decoded_instr_i[j].rs1) ? is_result_available_fpr_q[decoded_instr_i[j].rs1] : is_result_available_gpr_q[decoded_instr_i[i].rs1])
            : is_rs1_fpr(rs_q.rs_table[i].rs1) ? is_result_available_fpr_q[rs_q.rs_table[i].rs1] : is_result_available_gpr_q[rs_q.rs_table[i].rs1];
            rs_n.valid_regs[i][1] = (i == alloc_idx[j]) ? (is_rs2_fpr(decoded_instr_i[j].rs2) ? is_result_available_fpr_q[decoded_instr_i[j].rs2] : is_result_available_gpr_q[decoded_instr_i[i].rs1])
            : is_rs2_fpr(rs_q.rs_table[i].rs1) ? is_result_available_fpr_q[rs_q.rs_table[i].rs1] : is_result_available_gpr_q[rs_q.rs_table[i].rs1];
            if (NR_READ_PORTS == 3 && !decoded_instr_i[j].use_imm) begin
              rs_n.valid_regs[i][0] = (i == alloc_idx[j]) ? (is_imm_fpr(decoded_instr_i[j].result) ? is_result_available_fpr_q[decoded_instr_i[j].result] : is_result_available_gpr_q[decoded_instr_i[i].rs1])
              : is_imm_fpr(rs_q.rs_table[i].rs1) ? is_result_available_fpr_q[rs_q.rs_table[i].result] : is_result_available_gpr_q[rs_q.rs_table[i].result];
            end
          end
        end
      end
    end


    end

    if (rs_restore_en_i) begin
      rs_n.free_entries = '1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rs_q.free_entries <= '1;
      if (FPR_ENABLED) begin
        is_result_available_fpr_q <= '1;
      end
      is_result_available_gpr_q <= '1;
    end else begin
      rs_q <= rs_n;
      is_result_available_gpr_q <= is_result_available_gpr_n;
      if (FPR_ENABLED) begin
        is_result_available_fpr_q <= is_result_available_fpr_n;
      end
    end
  end
endmodule
