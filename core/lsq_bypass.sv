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
    parameter int unsigned           NR_ENTRIES    = 4,
    parameter int unsigned           FALLTHROUGH  = 0,
    parameter type scoreboard_entry_t = logic,
    parameter type lsq_data_t = logic
) (
    input  logic                                                         clk_i,
    input  logic                                                         rst_ni,
    input  logic                                                         flush_i, // id of the entry to remove
    output logic [CVA6Cfg.NrIssuePorts-1:0]                              full_o,

    input  logic [CVA6Cfg.NrIssuePorts-1:0]                              rm_i, // do we remove the entry
    input  logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.GlobalRsIdWidth-1:0] rm_id_i, // id of the entry to remove
    input  fu_op [CVA6Cfg.NrIssuePorts-1:0]                              rm_op_i, // op of the entry to remove
    input  logic [CVA6Cfg.NrIssuePorts-1:0][ADDR_WIDTH-1:0]              rm_rd_i, // dest reg addr of the entry to remove

    input  logic [CVA6Cfg.NrWbPorts-1:0]                                 wb_valid_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0][ADDR_WIDTH-1:0]                 wb_rd_i, // dest reg of the entry to remove
    input  fu_op [CVA6Cfg.NrWbPorts-1:0]                                 wb_op_i, // op of the entry to remove
    input  logic [CVA6Cfg.RollbackWidth-1:0]                             rollback_en_i, // is rollback enabled

    input  logic [CVA6Cfg.RollbackWidth-1:0][ADDR_WIDTH-1:0]             rollback_rd_i, // architectural register to rollback
    input  fu_op [CVA6Cfg.RollbackWidth-1:0]                             rollback_op_i, // op of the instr to rollback
    input  logic [CVA6Cfg.RollbackWidth-1:0][CVA6Cfg.GlobalRsIdWidth-1:0]rollback_id_i, // id of the entry to rollback

    output scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]                 dispatch_instr_o,
    output lsq_data_t [CVA6Cfg.NrIssuePorts-1:0]                         dispatch_instr_data_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0]                              dispatch_instr_valid_o,

    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0]    vaddr_trans_id_i,
    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0]    data_trans_id_i,
    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]                 decoded_instr_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]                              decoded_instr_ack_i,
    input logic [CVA6Cfg.NrIssuePorts-1:0]                               decoded_instr_valid_i
);

  localparam NUM_REG = CVA6Cfg.NrPhysReg;

  logic [NUM_REG-1:0] is_result_available_gpr_n, is_result_available_gpr_q;
  //some operations might use gpr and fpr register as operands or destination
  logic [NUM_REG-1:0] is_result_available_fpr_n, is_result_available_fpr_q;

  typedef struct packed {
    scoreboard_entry_t [NR_ENTRIES-1:0] instr;
    logic [NR_ENTRIES-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] vaddr_trans_id;
    logic [NR_ENTRIES-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] data_trans_id;
    logic [NR_ENTRIES-1:0] free;
  } instr_queue_t;

  logic [$clog2(NR_ENTRIES)-1:0] issue_pointer_n, issue_pointer_q;
  logic [$clog2(NR_ENTRIES)-1:0] dispatch_pointer_n, dispatch_pointer_q;

  instr_queue_t instr_queue_n, instr_queue_q;

  logic [CVA6Cfg.NrIssuePorts-1:0] full;
  logic [CVA6Cfg.NrIssuePorts-1:0] we;

  assign full_o = full;

  logic [CVA6Cfg.NrIssuePorts-1:0] decoded_used;
  logic [CVA6Cfg.NrIssuePorts-1:0] fallthrough_out;
  logic [CVA6Cfg.NrIssuePorts-1:0][$clog2(CVA6Cfg.NrIssuePorts)-1:0] fallthrough_src;

  always_comb begin : full_logic

    automatic logic [$clog2(NR_ENTRIES)-1:0] issue_pointer;

    issue_pointer = issue_pointer_q;

    for (int unsigned i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
      full[i] = we[i] && !instr_queue_q.free[issue_pointer];
      if (we[i] && decoded_instr_valid_i[i] && !full[i]) begin
        issue_pointer = issue_pointer + 1'b1;
      end
    end
  end


  for (genvar i = 0; i<CVA6Cfg.NrIssuePorts ; i++) begin
    assign we[i] = (decoded_instr_i[i].fu == LOAD || decoded_instr_i[i].fu == STORE) & decoded_instr_valid_i[i];
  end


  always_comb begin : update_queue

    automatic logic [$clog2(NR_ENTRIES)-1:0] issue_pointer;
    automatic logic [$clog2(NR_ENTRIES)-1:0] rm_ptr;
    issue_pointer = issue_pointer_q;

    instr_queue_n = instr_queue_q;
    issue_pointer_n = issue_pointer_q;

    if (!FALLTHROUGH) begin
      for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts ; i++) begin
        if (we[i] & instr_queue_q.free[issue_pointer] & decoded_instr_ack_i[i]) begin
          instr_queue_n.instr[issue_pointer] = decoded_instr_i[i];
          instr_queue_n.vaddr_trans_id[issue_pointer] = vaddr_trans_id_i[i];
          instr_queue_n.data_trans_id[issue_pointer] = data_trans_id_i[i];
          instr_queue_n.free[issue_pointer] = 1'b0;
          issue_pointer = issue_pointer + 1'b1;
        end
      end
    end else begin
      for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts ; i++) begin
        if (we[i] & instr_queue_q.free[issue_pointer] & decoded_instr_ack_i[i]) begin
            instr_queue_n.instr[issue_pointer] = decoded_instr_i[i];
            instr_queue_n.vaddr_trans_id[issue_pointer] = vaddr_trans_id_i[i];
            instr_queue_n.data_trans_id[issue_pointer] = data_trans_id_i[i];
            instr_queue_n.free[issue_pointer] = 1'b0;
            issue_pointer = issue_pointer + 1'b1;
          for (int unsigned j = 0; j<CVA6Cfg.NrIssuePorts ; j++) begin
            if (rm_i[j] & rm_id_i[j] == decoded_instr_i[i].global_rs_id) begin
              issue_pointer = issue_pointer - 1'b1;
              instr_queue_n.free[issue_pointer] = 1'b1;
            end
          end
        end
      end
    end

    rm_ptr = dispatch_pointer_q;

    for (int j = 0; j < CVA6Cfg.NrIssuePorts; j++) begin
      if (rm_i[j] && !instr_queue_q.free[rm_ptr] && rm_id_i[j] == instr_queue_q.instr[rm_ptr].global_rs_id) begin
        instr_queue_n.free[rm_ptr] = 1'b1;
        rm_ptr = rm_ptr + 1'b1;
      end
    end

    dispatch_pointer_n = rm_ptr;

    for (int unsigned i = 0; i<NR_ENTRIES ; i++) begin
      for (int unsigned j = 0; j<CVA6Cfg.RollbackWidth ; j++) begin
        if(rollback_en_i[j] & rollback_id_i[j] == instr_queue_q.instr[i].global_rs_id & !instr_queue_q.free[i]) begin
          instr_queue_n.free[i] = 1'b1;
          issue_pointer = issue_pointer - 1'b1;
        end
      end
    end

    issue_pointer_n = issue_pointer;

    if (flush_i) begin
      instr_queue_n.free = '1;
      issue_pointer_n    = '0;
      dispatch_pointer_n = '0;
    end


  end


  always_comb begin : dispatch_instr_data

    automatic logic [CVA6Cfg.NrIssuePorts-1:0] is_queue_dispatch;
    automatic logic [$clog2(NR_ENTRIES)-1:0] ptr;

    is_queue_dispatch = '0;
    decoded_used = '0;
    fallthrough_out = '0;
    fallthrough_src = '0;


    ptr = dispatch_pointer_q;

    for (int i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
        dispatch_instr_o[i] = instr_queue_q.instr[ptr];
        dispatch_instr_valid_o[i] = !instr_queue_q.free[ptr];
        dispatch_instr_data_o[i].vaddr_trans_id = instr_queue_q.vaddr_trans_id[ptr];
        dispatch_instr_data_o[i].data_trans_id = instr_queue_q.data_trans_id[ptr];
        is_queue_dispatch[i] = !instr_queue_q.free[ptr];
        ptr = ptr + 1'b1;
    end


    if (FALLTHROUGH) begin
      for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts ; i++) begin
        if (!is_queue_dispatch[i]) begin
          for (int unsigned j = 0; j<CVA6Cfg.NrIssuePorts ; j++) begin
            if (we[j] & decoded_instr_ack_i[j] & !is_queue_dispatch[i] & !decoded_used[j]) begin
              dispatch_instr_o[i] = decoded_instr_i[j];
              dispatch_instr_valid_o[i] = decoded_instr_valid_i[j];
              dispatch_instr_data_o[i].vaddr_trans_id = vaddr_trans_id_i[j];
              dispatch_instr_data_o[i].data_trans_id = data_trans_id_i[j];
              decoded_used[j] = 1'b1;
              is_queue_dispatch[i] = 1'b1;
              fallthrough_out[i] = 1'b1;
              fallthrough_src[i] = j;
            end
          end
        end
      end
    end

    if (!FPR_ENABLED) begin
      for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts ; i++) begin
        dispatch_instr_data_o[i].data_valid = is_result_available_gpr_q[dispatch_instr_o[i].rs2];
        dispatch_instr_data_o[i].vaddr_valid = is_result_available_gpr_q[dispatch_instr_o[i].rs1];

        // check RAW dependencies
        for (int unsigned k = 0; k < i; k++) begin
          if (dispatch_instr_o[k].rd == dispatch_instr_o[i].rs2 && dispatch_instr_o[k].rd != '0 && dispatch_instr_valid_o[i]) begin
            dispatch_instr_data_o[i].data_valid = 1'b0;
          end

          if (dispatch_instr_o[k].rd == dispatch_instr_o[i].rs1 && dispatch_instr_o[k].rd != '0 && dispatch_instr_valid_o[i]) begin
            dispatch_instr_data_o[i].vaddr_valid = 1'b0;
          end
        end

        if (FALLTHROUGH) begin
          if (fallthrough_out[i]) begin
            for (int unsigned k = 0; k < CVA6Cfg.NrIssuePorts; k++) begin
              if (k < fallthrough_src[i] && decoded_instr_ack_i[k]) begin
                if (decoded_instr_i[k].rd == dispatch_instr_o[i].rs1 && decoded_instr_i[k].rd != '0) begin
                  dispatch_instr_data_o[i].vaddr_valid = 1'b0;
                end

                if (decoded_instr_i[k].rd == dispatch_instr_o[i].rs2 && decoded_instr_i[k].rd != '0) begin
                  dispatch_instr_data_o[i].data_valid = 1'b0;
                end
              end
            end
          end
        end

      end
    end else begin
      for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts ; i++) begin
        dispatch_instr_data_o[i].data_valid = is_rs2_fpr(dispatch_instr_o[i].op) ? is_result_available_fpr_q[dispatch_instr_o[i].rs2] : is_result_available_gpr_q[dispatch_instr_o[i].rs2];
        dispatch_instr_data_o[i].vaddr_valid = is_rs1_fpr(dispatch_instr_o[i].op) ? is_result_available_fpr_q[dispatch_instr_o[i].rs1] : is_result_available_gpr_q[dispatch_instr_o[i].rs1];

        // check RAW dependencies
        for (int unsigned k = 0; k < i; k++) begin
          if (is_rd_fpr(dispatch_instr_o[k].op) == is_rs2_fpr(dispatch_instr_o[i].op) &&
            dispatch_instr_o[k].rd == dispatch_instr_o[i].rs2 && dispatch_instr_o[k].rd != '0 && dispatch_instr_valid_o[i]) begin
            dispatch_instr_data_o[i].data_valid = 1'b0;
          end

          if (is_rd_fpr(dispatch_instr_o[k].op) == is_rs1_fpr(dispatch_instr_o[i].op) &&
            dispatch_instr_o[k].rd == dispatch_instr_o[i].rs1 && dispatch_instr_o[k].rd != '0 && dispatch_instr_valid_o[i]) begin
            dispatch_instr_data_o[i].vaddr_valid = 1'b0;
          end
        end
      end
    end
  end

  always_comb begin : updating_result_available
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

    if (flush_i) begin
      is_result_available_gpr_n = '1;
      if (FPR_ENABLED) begin
        is_result_available_fpr_n = '1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instr_queue_q.free <= '1;
      issue_pointer_q <= '0;
      dispatch_pointer_q <= '0;
      if (FPR_ENABLED) begin
        is_result_available_fpr_q <= '1;
      end
      is_result_available_gpr_q <= '1;
    end else begin
      instr_queue_q <= instr_queue_n;
      issue_pointer_q <= issue_pointer_n;
      dispatch_pointer_q <= dispatch_pointer_n;
      is_result_available_gpr_q <= is_result_available_gpr_n;
      if (FPR_ENABLED) begin
        is_result_available_fpr_q <= is_result_available_fpr_n;
      end
    end
  end

  //pragma translate_off

  // for (int j = 0; j < CVA6Cfg.NrIssuePorts; j++) begin
  //   if (rm_i[j]) begin
  //       for (int k = 0; k < NR_ENTRIES; k++) begin
  //           if (!instr_queue_q.free[k] &&
  //               rm_id_i[j] == instr_queue_q.instr[k].global_rs_id) begin
  //
  //               assert (k == rm_ptr)
  //               else $fatal(
  //                   1,
  //                   "LSQ bypass out-of-order remove: rm_gid=%0d head_gid=%0d",
  //                   rm_id_i[j],
  //                   instr_queue_q.instr[rm_ptr].global_rs_id
  //               );
  //           end
  //       end
  //   end
  // end

  // pragma translate_on

endmodule
