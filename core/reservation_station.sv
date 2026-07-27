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
    parameter int unsigned           LSU_EN        = 0, // does this RS contains LOAD or STORE instr
    parameter int unsigned           CSR_EN        = 0, // does this RS contains CSR instr
    parameter type scoreboard_entry_t = logic
) (
    input  logic                                                         clk_i,
    input  logic                                                         rst_ni,
    output logic [CVA6Cfg.NrIssuePorts-1:0]                              full_o, // is rs full
    input  logic [CVA6Cfg.NrIssuePorts-1:0]                              we_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]                              rm_i, // do we remove the entry
    input  logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.GlobalRsIdWidth-1:0] rm_id_i, // id of the entry to remove
    input  logic [CVA6Cfg.NrWbPorts-1:0]                                 wb_valid_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0][ADDR_WIDTH-1:0]                 wb_rd_i, // dest reg of the entry to remove
    input  fu_op [CVA6Cfg.NrWbPorts-1:0]                                 wb_op_i, // op of the entry to remove
    input  logic [CVA6Cfg.GlobalRsIdWidth-1:0]                           rollback_id_i, // id of the entry to rollback
    input  logic                                                         rollback_en_i, // is rollback enabled
    input  logic [ADDR_WIDTH-1:0]                                        rollback_rd_i, // architectural register to rollback
    input  fu_op                                                         rollback_op_i, // architectural register to rollback
    input  logic                                                         rs_restore_en_i, // id of the entry to remove

    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_i,
    input  logic              [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_ack_i,
    output [CVA6Cfg.TRANS_ID_BITS-1:0]                                  decoded_instr_trans_id_o, //instructions found ready
    output [CVA6Cfg.GlobalRsIdWidth-1:0]                                decoded_instr_global_id_o, //instructions found ready
    output logic                                                        decoded_instr_valid_o //is instruction valid
);

  localparam NUM_REG = 2 ** ADDR_WIDTH;

  // stripped down version of scoreboard_entry_t in order to store only needed data
  typedef struct packed {
      logic [CVA6Cfg.GlobalRsIdWidth-1:0] global_rs_id;
      logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;
      fu_t fu;
      fu_op op;
      logic [CVA6Cfg.RegAddrWidth-1:0] rs1;
      logic [CVA6Cfg.RegAddrWidth-1:0] rs2;
      logic [CVA6Cfg.RegAddrWidth-1:0] rd;
      logic [CVA6Cfg.XLEN-1:0] result;
      logic use_imm;
      logic ex_valid; // an exception has occurred during frontend
  } rs_entry_t;

  typedef struct packed {
    rs_entry_t [NR_RS_ENTRIES-1:0] rs_table;
    logic [NR_RS_ENTRIES-1:0] free_entries;
    logic [NR_RS_ENTRIES-1:0][NR_READ_PORTS-1:0] valid_regs;
  } reservation_station_t;

  logic [NUM_REG-1:0] is_result_available_gpr_n, is_result_available_gpr_q;
  //some operations might use gpr and fpr register as operands or destination
  logic [NUM_REG-1:0] is_result_available_fpr_n, is_result_available_fpr_q;
  logic lsu_used_n, lsu_used_q;

  reservation_station_t rs_n, rs_q;


  logic [CVA6Cfg.NrIssuePorts:0][NR_RS_ENTRIES-1:0] free_entries_masked;
  logic [CVA6Cfg.NrIssuePorts-1:0] empty_mask;
  logic [CVA6Cfg.NrIssuePorts-1:0][$clog2(NR_RS_ENTRIES):0] alloc_idx;

  assign free_entries_masked[0] = rs_q.free_entries;

  //priority encoder cascade to get free index in RS
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : g_alloc
      lzc #(
          .WIDTH(NR_RS_ENTRIES),
          .MODE(1'b0))
      i_lzc (
          .in_i   (free_entries_masked[i]),
          .cnt_o  (alloc_idx[i]),
          .empty_o(empty_mask[i])
      );

      assign free_entries_masked[i+1] = (we_i[i] && decoded_instr_ack_i[i] && empty_mask[i] == 1'b0) ?
        (free_entries_masked[i] & ~(NR_RS_ENTRIES'(1) << alloc_idx[i])) :
        free_entries_masked[i];
  end

  assign full_o = empty_mask;

  logic [NR_RS_ENTRIES-1:0] tournament_valid, tournament_oldest_valid;
  logic [NR_RS_ENTRIES-1:0][CVA6Cfg.GlobalRsIdWidth-1:0] tournament_seq_num;
  logic [NR_RS_ENTRIES-1:0][$clog2(NR_RS_ENTRIES)-1:0] tournament_id;

  logic [NR_RS_ENTRIES-1:0][NR_READ_PORTS-1:0] RAW_updated_regs;
  logic [NR_RS_ENTRIES-1:0][NR_READ_PORTS-1:0] updated_regs;
  logic [NR_RS_ENTRIES-1:0][NR_READ_PORTS-1:0] forwarding_updated_regs;

  for (genvar i = 0 ; i < NR_RS_ENTRIES ; i++) begin
    // lsu instr must be strictly issued in order so we label all of them as valid
    // to ensure the tournament_tree output de oldest one
    if (LSU_EN) begin
      assign tournament_valid[i] = (rs_q.free_entries[i] == 1'b0);
    end else begin
      assign tournament_valid[i] = rs_q.free_entries[i] == 1'b0 ?
        (rs_q.valid_regs[i] == '1 || rs_q.rs_table[i].fu == CSR ? 1'b1 : 1'b0)
      : 1'b0;
      assign tournament_oldest_valid[i] = (rs_q.free_entries[i] == 1'b0);
    end
    assign tournament_seq_num[i] = rs_q.rs_table[i].global_rs_id;
    assign tournament_id[i] = i;
  end

  logic [$clog2(NR_RS_ENTRIES)-1:0] winner_o, winner_oldest_o;
  logic winner_valid_o;

  tournament_tree #(
      .ID_SIZE(CVA6Cfg.GlobalRsIdWidth),
      .NR_PLAYER(NR_RS_ENTRIES)
    ) i_tournament_tree_oldest_valid (
      .valid_i    (tournament_valid),
      .seq_num_i  (tournament_seq_num),
      .id_i       (tournament_id),
      .winner_o   (winner_o),
      .winner_valid_o (winner_valid_o)
  );

  // returns the oldest instr wheather it's valid or not
  if (CSR_EN) begin
    tournament_tree #(
        .ID_SIZE(CVA6Cfg.GlobalRsIdWidth),
        .NR_PLAYER(NR_RS_ENTRIES)
      ) i_tournament_tree_oldest (
        .valid_i    (tournament_oldest_valid),
        .seq_num_i  (tournament_seq_num),
        .id_i       (tournament_id),
        .winner_o   (winner_oldest_o),
        .winner_valid_o ()
    );
  end

  if (LSU_EN) begin
    // now that we have the oldest one we check it's validity
    assign decoded_instr_valid_o = (lsu_used_q && !wb_valid_i[STORE_WB] && !wb_valid_i[LOAD_WB]) ? 1'b0 : rs_q.free_entries[winner_o] == 1'b0 ?
        (rs_q.valid_regs[winner_o] == '1 ? 1'b1 : 1'b0)
      : 1'b0;
  end else if (CSR_EN) begin
    assign decoded_instr_valid_o = rs_q.rs_table[winner_o].fu == CSR ?
        (winner_valid_o && rs_q.valid_regs[winner_o] == '1 && rs_q.rs_table[winner_o] == rs_q.rs_table[winner_oldest_o])
      : winner_valid_o ;
  end else begin
    assign decoded_instr_valid_o = winner_valid_o;
  end

  assign decoded_instr_trans_id_o = rs_q.rs_table[winner_o].trans_id;
  assign decoded_instr_global_id_o = rs_q.rs_table[winner_o].global_rs_id;

  always_comb begin : updating_rs
    logic allocated_by_p0;
    logic allocated_by_p1;
    rs_n = rs_q;
    lsu_used_n = lsu_used_q;
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

        // memory operations release the lock when the last one finished
        if (LSU_EN) begin
          if (i == STORE_WB || i == LOAD_WB) begin
            lsu_used_n = 1'b0;
          end
        end
      end
    end

    for (int i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      if (decoded_instr_ack_i[i]) begin
        if (we_i[i] && empty_mask[i] == 1'b0) begin
          rs_n.rs_table[alloc_idx[i]] =
            {
            decoded_instr_i[i].global_rs_id,
            decoded_instr_i[i].trans_id,
            decoded_instr_i[i].fu,
            decoded_instr_i[i].op,
            decoded_instr_i[i].rs1,
            decoded_instr_i[i].rs2,
            decoded_instr_i[i].rd,
            decoded_instr_i[i].result,
            decoded_instr_i[i].use_imm,
            decoded_instr_i[i].ex.valid
            };
        end

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
    if (rollback_en_i) begin
      if (FPR_ENABLED) begin
        if (is_rd_fpr(rollback_op_i)) begin
          is_result_available_fpr_n[rollback_rd_i] = 1'b1;
        end else begin
          is_result_available_gpr_n[rollback_rd_i] = 1'b1;
        end
      end else begin
        is_result_available_gpr_n[rollback_rd_i] = 1'b1;
      end
    end

    RAW_updated_regs = rs_q.valid_regs;
    updated_regs = rs_q.valid_regs;
    forwarding_updated_regs = '0;

    //removing instr after it was selected to be executed
    //or because of rollback triggered by exception or branch miss.
    rs_n.free_entries = free_entries_masked[CVA6Cfg.NrIssuePorts];
    for (int i = 0; i < NR_RS_ENTRIES; i++) begin
      allocated_by_p0 = (CVA6Cfg.NrIssuePorts > 0) && (i == alloc_idx[0]) && we_i[0] && decoded_instr_ack_i[0] && empty_mask[0] == 1'b0;
      allocated_by_p1 = (CVA6Cfg.NrIssuePorts > 1) && (i == alloc_idx[1]) && we_i[1] && decoded_instr_ack_i[1] && empty_mask[1] == 1'b0;

      for (int j = 0; j < CVA6Cfg.NrIssuePorts; j++) begin
        // instr has been issued
        if (rm_i[j] && rm_id_i[j] == rs_q.rs_table[i].global_rs_id && !rs_q.free_entries[i]) begin
            rs_n.free_entries[i] = 1'b1;
            if (LSU_EN) begin
                lsu_used_n = 1'b1; // locking lsu
            end
        end
        // rollback
        else if (rollback_en_i && rollback_id_i == rs_q.rs_table[i].global_rs_id) begin
            rs_n.free_entries[i] = 1'b1;
            if (LSU_EN) begin
                lsu_used_n = 1'b0; // unlocking lsu
            end
        end
      end

      //First we check RAW hazard between the 2 newly fetched instr
      if (decoded_instr_ack_i == '1) begin
        if (!FPR_ENABLED) begin
          RAW_updated_regs[i][0] = (decoded_instr_i[1].rs1 == decoded_instr_i[0].rd && decoded_instr_i[0].rd != '0) ? 1'b0 : 1'b1;
          RAW_updated_regs[i][1] = (decoded_instr_i[1].rs2 == decoded_instr_i[0].rd && decoded_instr_i[0].rd != '0) ? 1'b0 : 1'b1;
          if (NR_READ_PORTS == 3 && !decoded_instr_i[1].use_imm) begin
            RAW_updated_regs[i][2] = (decoded_instr_i[1].result == decoded_instr_i[0].rd && decoded_instr_i[0].rd != '0) ? 1'b0 : 1'b1;
          end
        end else begin
          RAW_updated_regs[i][0] = is_rd_fpr(decoded_instr_i[0].op) && is_rs1_fpr(decoded_instr_i[1].op) && decoded_instr_i[1].rs1 == decoded_instr_i[0].rd ? 1'b0 : 1'b1;
          RAW_updated_regs[i][1] = is_rd_fpr(decoded_instr_i[0].op) && is_rs2_fpr(decoded_instr_i[1].op) && decoded_instr_i[1].rs2 == decoded_instr_i[0].rd ? 1'b0 : 1'b1;
          if (NR_READ_PORTS == 3 && !decoded_instr_i[1].use_imm) begin
            RAW_updated_regs[i][2] = is_rd_fpr(decoded_instr_i[0].op) && is_imm_fpr(decoded_instr_i[1].op) && decoded_instr_i[1].result == decoded_instr_i[0].rd ? 1'b0 : 1'b1;
          end
        end
      end else begin
        RAW_updated_regs[i] = '1;
      end

      //Then we update based on the retired instr that finished executing
      //because otherwise dependencies would take 1 cycle to update
      for (int k = 0; k < CVA6Cfg.NrWbPorts; k++) begin
        if (wb_valid_i[k]) begin
          if (!FPR_ENABLED) begin
            if (allocated_by_p0) begin
              if (wb_rd_i[k] == decoded_instr_i[0].rs1) forwarding_updated_regs[i][0] = 1'b1;
              if (wb_rd_i[k] == decoded_instr_i[0].rs2) forwarding_updated_regs[i][1] = 1'b1;
              if (NR_READ_PORTS == 3 && !decoded_instr_i[0].use_imm) begin
                if (wb_rd_i[k] == decoded_instr_i[0].result) forwarding_updated_regs[i][2] = 1'b1;
              end
            end else if (allocated_by_p1) begin
              if (wb_rd_i[k] == decoded_instr_i[1].rs1) forwarding_updated_regs[i][0] = 1'b1;
              if (wb_rd_i[k] == decoded_instr_i[1].rs2) forwarding_updated_regs[i][1] = 1'b1;
              if (NR_READ_PORTS == 3 && !decoded_instr_i[1].use_imm) begin
                if (wb_rd_i[k] == decoded_instr_i[1].result) forwarding_updated_regs[i][2] = 1'b1;
              end
            end else begin
              if (wb_rd_i[k] == rs_q.rs_table[i].rs1) forwarding_updated_regs[i][0] = 1'b1;
              if (wb_rd_i[k] == rs_q.rs_table[i].rs2) forwarding_updated_regs[i][1] = 1'b1;
              if (NR_READ_PORTS == 3 && !rs_q.rs_table[i].use_imm) begin
                if (wb_rd_i[k] == rs_q.rs_table[i].result) forwarding_updated_regs[i][2] = 1'b1;
              end
            end
          end else begin
            if (allocated_by_p0) begin
              if (is_rd_fpr(wb_op_i[k]) == is_rs1_fpr(decoded_instr_i[0].op)) begin
                if (wb_rd_i[k] == decoded_instr_i[0].rs1) forwarding_updated_regs[i][0] = 1'b1;
              end
              if (is_rd_fpr(wb_op_i[k]) == is_rs2_fpr(decoded_instr_i[0].op)) begin
                if (wb_rd_i[k] == decoded_instr_i[0].rs2) forwarding_updated_regs[i][1] = 1'b1;
              end
              if (NR_READ_PORTS == 3 && !decoded_instr_i[0].use_imm) begin
                if (is_rd_fpr(wb_op_i[k]) == is_imm_fpr(decoded_instr_i[0].op)) begin
                  if (wb_rd_i[k] == decoded_instr_i[0].result) forwarding_updated_regs[i][2] = 1'b1;
                end
              end
            end else if (allocated_by_p1) begin
              if (is_rd_fpr(wb_op_i[k]) == is_rs1_fpr(decoded_instr_i[1].op)) begin
                if (wb_rd_i[k] == decoded_instr_i[1].rs1) forwarding_updated_regs[i][0] = 1'b1;
              end
              if (is_rd_fpr(wb_op_i[k]) == is_rs2_fpr(decoded_instr_i[1].op)) begin
                if (wb_rd_i[k] == decoded_instr_i[1].rs2) forwarding_updated_regs[i][1] = 1'b1;
              end
              if (NR_READ_PORTS == 3 && !decoded_instr_i[1].use_imm) begin
                if (is_rd_fpr(wb_op_i[k]) == is_imm_fpr(decoded_instr_i[1].op)) begin
                  if (wb_rd_i[k] == decoded_instr_i[1].result) forwarding_updated_regs[i][2] = 1'b1;
                end
              end
            end else begin
              if (is_rd_fpr(wb_op_i[k]) == is_rs1_fpr(rs_q.rs_table[i].op)) begin
                if (wb_rd_i[k] == rs_q.rs_table[i].rs1) forwarding_updated_regs[i][0] = 1'b1;
              end
              if (is_rd_fpr(wb_op_i[k]) == is_rs2_fpr(rs_q.rs_table[i].op)) begin
                if (wb_rd_i[k] == rs_q.rs_table[i].rs2) forwarding_updated_regs[i][1] = 1'b1;
              end
              if (NR_READ_PORTS == 3 && !rs_q.rs_table[i].use_imm) begin
                if (is_rd_fpr(wb_op_i[k]) == is_imm_fpr(rs_q.rs_table[i].op)) begin
                  if (wb_rd_i[k] == rs_q.rs_table[i].result) forwarding_updated_regs[i][2] = 1'b1;
                end
              end
            end
          end
        end else begin
          forwarding_updated_regs[i] = '0;
        end
      end

      //Finally we define the default behavior
      if (!FPR_ENABLED) begin
        if (allocated_by_p0) begin
          updated_regs[i][0] = is_result_available_gpr_q[decoded_instr_i[0].rs1];
          updated_regs[i][1] = is_result_available_gpr_q[decoded_instr_i[0].rs2];
          if (NR_READ_PORTS == 3 && !decoded_instr_i[0].use_imm)
            updated_regs[i][2] = is_result_available_gpr_q[decoded_instr_i[0].result];
        end else if (allocated_by_p1) begin
          updated_regs[i][0] = is_result_available_gpr_q[decoded_instr_i[1].rs1];
          updated_regs[i][1] = is_result_available_gpr_q[decoded_instr_i[1].rs2];
          if (NR_READ_PORTS == 3 && !decoded_instr_i[1].use_imm)
            updated_regs[i][2] = is_result_available_gpr_q[decoded_instr_i[1].result];
        end else begin
          updated_regs[i][0] =  is_result_available_gpr_q[rs_q.rs_table[i].rs1];
          updated_regs[i][1] = is_result_available_gpr_q[rs_q.rs_table[i].rs2];
          if (NR_READ_PORTS == 3 && !rs_q.rs_table[i].use_imm)
            updated_regs[i][2] = is_result_available_gpr_q[rs_q.rs_table[i].result];
        end
      end else begin
        if (allocated_by_p0) begin
          updated_regs[i][0] = is_rs1_fpr(decoded_instr_i[0].op) ? is_result_available_fpr_q[decoded_instr_i[0].rs1] : is_result_available_gpr_q[decoded_instr_i[0].rs1];
          updated_regs[i][1] = is_rs2_fpr(decoded_instr_i[0].op) ? is_result_available_fpr_q[decoded_instr_i[0].rs2] : is_result_available_gpr_q[decoded_instr_i[0].rs2];
          if (NR_READ_PORTS == 3 && !decoded_instr_i[0].use_imm)
            updated_regs[i][2] = is_imm_fpr(decoded_instr_i[0].op) ? is_result_available_fpr_q[decoded_instr_i[0].result] : is_result_available_gpr_q[decoded_instr_i[0].result];
        end else if (allocated_by_p1) begin
          updated_regs[i][0] = is_rs1_fpr(decoded_instr_i[1].op) ? is_result_available_fpr_q[decoded_instr_i[1].rs1] : is_result_available_gpr_q[decoded_instr_i[1].rs1];
          updated_regs[i][1] = is_rs2_fpr(decoded_instr_i[1].op) ? is_result_available_fpr_q[decoded_instr_i[1].rs2] : is_result_available_gpr_q[decoded_instr_i[1].rs2];
          if (NR_READ_PORTS == 3 && !decoded_instr_i[1].use_imm)
            updated_regs[i][2] = is_imm_fpr(decoded_instr_i[1].op) ? is_result_available_fpr_q[decoded_instr_i[1].result] : is_result_available_gpr_q[decoded_instr_i[1].result];
        end else begin
          updated_regs[i][0] = is_rs1_fpr(rs_q.rs_table[i].op) ? is_result_available_fpr_q[rs_q.rs_table[i].rs1] : is_result_available_gpr_q[rs_q.rs_table[i].rs1];
          updated_regs[i][1] = is_rs2_fpr(rs_q.rs_table[i].op) ? is_result_available_fpr_q[rs_q.rs_table[i].rs2] : is_result_available_gpr_q[rs_q.rs_table[i].rs2];
          if (NR_READ_PORTS == 3 && !rs_q.rs_table[i].use_imm)
            updated_regs[i][2] = is_imm_fpr(rs_q.rs_table[i].op) ? is_result_available_fpr_q[rs_q.rs_table[i].result] : is_result_available_gpr_q[rs_q.rs_table[i].result];
        end
      end


      //In the end we select the right calculated value for valid_regs
      //First we check select RAW result if valid then forwarding result and finally default result
      if (!rs_restore_en_i) begin
        if (allocated_by_p1) begin
          rs_n.valid_regs[i][0] = RAW_updated_regs[i][0] == 1'b1 ? (forwarding_updated_regs[i][0] == 1'b0 ? updated_regs[i][0] : forwarding_updated_regs[i][0]) : RAW_updated_regs[i][0];
          rs_n.valid_regs[i][1] = RAW_updated_regs[i][1] == 1'b1 ? (forwarding_updated_regs[i][1] == 1'b0 ? updated_regs[i][1] : forwarding_updated_regs[i][1]) : RAW_updated_regs[i][1];
          if (NR_READ_PORTS == 3)
            rs_n.valid_regs[i][2] = RAW_updated_regs[i][2] == 1'b1 ? (forwarding_updated_regs[i][2] == 1'b0 ? updated_regs[i][2] : forwarding_updated_regs[i][2]) : RAW_updated_regs[i][2];
        end else begin
          rs_n.valid_regs[i][0] = forwarding_updated_regs[i][0] == 1'b0 ? updated_regs[i][0] : forwarding_updated_regs[i][0];
          rs_n.valid_regs[i][1] = forwarding_updated_regs[i][1] == 1'b0 ? updated_regs[i][1] : forwarding_updated_regs[i][1];
          if (NR_READ_PORTS == 3)
            rs_n.valid_regs[i][2] = forwarding_updated_regs[i][2] == 1'b0 ? updated_regs[i][2] : forwarding_updated_regs[i][2];
        end
      end else begin
        rs_n.valid_regs[i][0] = updated_regs[i][0];
        rs_n.valid_regs[i][1] = updated_regs[i][1];
        if (NR_READ_PORTS == 3)
          rs_n.valid_regs[i][2] = updated_regs[i][2];
      end

      //ultimately we check immediate state
      if (NR_READ_PORTS == 3) begin
        if (allocated_by_p0) begin
          if (decoded_instr_i[0].use_imm == 1'b1)
            rs_n.valid_regs[i][2] = 1'b1;
        end else if (allocated_by_p1) begin
          if (decoded_instr_i[1].use_imm == 1'b1)
            rs_n.valid_regs[i][2] = 1'b1;
        end else begin
          if (rs_q.rs_table[i].use_imm == 1'b1)
            rs_n.valid_regs[i][2] = 1'b1;
        end
      end

      //exception were triggered in the earlier stages of the pipeline
      if (allocated_by_p0) begin
        if (decoded_instr_i[0].ex.valid || decoded_instr_i[0].fu == NONE)
          rs_n.valid_regs[i] = '1;
      end else if (allocated_by_p1) begin
        if (decoded_instr_i[1].ex.valid || decoded_instr_i[1].fu == NONE)
          rs_n.valid_regs[i] = '1;
      end else begin
        if (rs_q.rs_table[i].ex_valid || rs_q.rs_table[i].fu == NONE)
          rs_n.valid_regs[i] = '1;
      end
    end

    is_result_available_gpr_n[0] = '1;

    if (rs_restore_en_i) begin
      rs_n.free_entries = '1;
      rs_n.valid_regs = '0;
      rs_n.rs_table = '0;
      is_result_available_gpr_n = '1;
      lsu_used_n = 1'b0;
      if (FPR_ENABLED) begin
        is_result_available_fpr_n = '1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rs_q.free_entries <= '1;
      rs_q.valid_regs   <= '0;
      rs_q.rs_table     <= '0;
      lsu_used_q        <= '0;
      if (FPR_ENABLED) begin
        is_result_available_fpr_q <= '1;
      end
      is_result_available_gpr_q <= '1;
    end else begin
      rs_q <= rs_n;
      lsu_used_q <= lsu_used_n;
      //lsu_used_q <= '0;
      is_result_available_gpr_q <= is_result_available_gpr_n;
      if (FPR_ENABLED) begin
        is_result_available_fpr_q <= is_result_available_fpr_n;
      end
    end
  end
endmodule
