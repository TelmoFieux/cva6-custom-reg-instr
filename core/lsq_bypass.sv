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
    parameter type decoded_instr_early_t = logic,
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

    input logic [CVA6Cfg.NrPhysReg-1:0]                                  is_result_available_gpr_i,
    input logic [CVA6Cfg.NrPhysReg-1:0]                                  is_result_available_fpr_i,

    input  logic [CVA6Cfg.NrWbPorts-1:0]                                 wb_valid_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0][ADDR_WIDTH-1:0]                 wb_rd_i, // dest reg of the entry to remove
    input  fu_op [CVA6Cfg.NrWbPorts-1:0]                                 wb_op_i, // op of the entry to remove
    input  logic [CVA6Cfg.RollbackWidth-1:0]                             rollback_en_i, // is rollback enabled

    input  logic [CVA6Cfg.RollbackWidth-1:0][ADDR_WIDTH-1:0]             rollback_rd_i, // architectural register to rollback
    input  fu_op [CVA6Cfg.RollbackWidth-1:0]                             rollback_op_i, // op of the instr to rollback
    input  logic [CVA6Cfg.RollbackWidth-1:0][CVA6Cfg.GlobalRsIdWidth-1:0]rollback_id_i, // id of the entry to rollback

    output fu_t [CVA6Cfg.NrIssuePorts-1:0]                               dispatch_instr_fu_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0]   dispatch_instr_trans_id_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.GlobalRsIdWidth-1:0] dispatch_instr_global_id_o,
    output decoded_instr_early_t [CVA6Cfg.NrIssuePorts-1:0]              decoded_instr_early_o,
    output lsq_data_t [CVA6Cfg.NrIssuePorts-1:0]                         dispatch_instr_data_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0]                              dispatch_instr_valid_o,

    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0]    vaddr_trans_id_i,
    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0]    data_trans_id_i,
    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]                 decoded_instr_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]                              decoded_instr_ack_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]                              decoded_instr_ready_i,
    input logic [CVA6Cfg.NrIssuePorts-1:0]                               decoded_instr_valid_i
);

  localparam NUM_REG = CVA6Cfg.NrPhysReg;

  typedef struct packed {
    logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;
    logic [CVA6Cfg.GlobalRsIdWidth-1:0] global_id;
    fu_op op;
    logic [CVA6Cfg.RegAddrWidth-1:0] rs1;
    logic [CVA6Cfg.RegAddrWidth-1:0] rs2;
    logic [CVA6Cfg.RegAddrWidth-1:0] rd;
    fu_t fu;
    logic use_imm;
  } lsq_bypass_entry_t;

  typedef struct packed {
    lsq_bypass_entry_t [NR_ENTRIES-1:0] instr;
    logic [NR_ENTRIES-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] vaddr_trans_id;
    logic [NR_ENTRIES-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] data_trans_id;
  } instr_queue_t;


  logic [NR_ENTRIES-1:0] free_n, free_q;
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
      full[i] = we[i] && !free_q[issue_pointer];
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
    free_n = free_q;
    instr_queue_n = instr_queue_q;
    issue_pointer_n = issue_pointer_q;

    if (!FALLTHROUGH) begin
      for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts ; i++) begin
        if (we[i] & free_q[issue_pointer] & decoded_instr_ack_i[i]) begin
          instr_queue_n.instr[issue_pointer] =
            {
            decoded_instr_i[i].trans_id,
            decoded_instr_i[i].global_rs_id,
            decoded_instr_i[i].op,
            decoded_instr_i[i].rs1,
            decoded_instr_i[i].rs2,
            decoded_instr_i[i].rd,
            decoded_instr_i[i].fu,
            decoded_instr_i[i].use_imm
            };
          instr_queue_n.vaddr_trans_id[issue_pointer] = vaddr_trans_id_i[i];
          instr_queue_n.data_trans_id[issue_pointer] = data_trans_id_i[i];
          free_n[issue_pointer] = 1'b0;
          issue_pointer = issue_pointer + 1'b1;
        end
      end
    end else begin
      for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts ; i++) begin
        if (we[i] & free_q[issue_pointer] & decoded_instr_ack_i[i]) begin
            instr_queue_n.instr[issue_pointer] =
              {
              decoded_instr_i[i].trans_id,
              decoded_instr_i[i].global_rs_id,
              decoded_instr_i[i].op,
              decoded_instr_i[i].rs1,
              decoded_instr_i[i].rs2,
              decoded_instr_i[i].rd,
              decoded_instr_i[i].fu,
              decoded_instr_i[i].use_imm
              };
            instr_queue_n.vaddr_trans_id[issue_pointer] = vaddr_trans_id_i[i];
            instr_queue_n.data_trans_id[issue_pointer] = data_trans_id_i[i];
            free_n[issue_pointer] = 1'b0;
            issue_pointer = issue_pointer + 1'b1;
          for (int unsigned j = 0; j<CVA6Cfg.NrIssuePorts ; j++) begin
            if (rm_i[j] & rm_id_i[j] == decoded_instr_i[i].global_rs_id) begin
              issue_pointer = issue_pointer - 1'b1;
              free_n[issue_pointer] = 1'b1;
            end
          end
        end
      end
    end

    rm_ptr = dispatch_pointer_q;

    for (int j = 0; j < CVA6Cfg.NrIssuePorts; j++) begin
      if (rm_i[j] && !free_q[rm_ptr] && rm_id_i[j] == instr_queue_q.instr[rm_ptr].global_id) begin
        free_n[rm_ptr] = 1'b1;
        rm_ptr = rm_ptr + 1'b1;
      end
    end

    dispatch_pointer_n = rm_ptr;

    for (int unsigned i = 0; i<NR_ENTRIES ; i++) begin
      for (int unsigned j = 0; j<CVA6Cfg.RollbackWidth ; j++) begin
        if(rollback_en_i[j] & rollback_id_i[j] == instr_queue_q.instr[i].global_id & !free_q[i]) begin
          free_n[i] = 1'b1;
          issue_pointer = issue_pointer - 1'b1;
        end
      end
    end

    issue_pointer_n = issue_pointer;

    if (flush_i) begin
      free_n = '1;
      issue_pointer_n    = '0;
      dispatch_pointer_n = '0;
    end


  end

  lsq_bypass_entry_t [CVA6Cfg.NrIssuePorts-1:0] dispatch_instr;

  for (genvar i = 0 ; i<CVA6Cfg.NrIssuePorts ; i++ ) begin
    assign dispatch_instr_trans_id_o[i] = dispatch_instr[i].trans_id;
    assign dispatch_instr_global_id_o[i] = dispatch_instr[i].global_id;
    assign dispatch_instr_fu_o[i] = dispatch_instr[i].fu;
    assign decoded_instr_early_o[i] = '{
      rs1:     dispatch_instr[i].rs1,
      rs2:     dispatch_instr[i].rs2,
      rd:      dispatch_instr[i].rd,
      fu:      dispatch_instr[i].fu,
      op:      dispatch_instr[i].op,
      use_imm: dispatch_instr[i].use_imm
    };
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
        dispatch_instr[i] = instr_queue_q.instr[ptr];
        dispatch_instr_valid_o[i] = !free_q[ptr];
        dispatch_instr_data_o[i].vaddr_trans_id = instr_queue_q.vaddr_trans_id[ptr];
        dispatch_instr_data_o[i].data_trans_id = instr_queue_q.data_trans_id[ptr];
        is_queue_dispatch[i] = !free_q[ptr];
        ptr = ptr + 1'b1;
    end


    if (FALLTHROUGH) begin
      for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts ; i++) begin
        if (!is_queue_dispatch[i]) begin
          for (int unsigned j = 0; j<CVA6Cfg.NrIssuePorts ; j++) begin
            if (we[j] & decoded_instr_ready_i[j] & !is_queue_dispatch[i] & !decoded_used[j]) begin
              dispatch_instr[i] =
                {
                decoded_instr_i[j].trans_id,
                decoded_instr_i[j].global_rs_id,
                decoded_instr_i[j].op,
                decoded_instr_i[j].rs1,
                decoded_instr_i[j].rs2,
                decoded_instr_i[j].rd,
                decoded_instr_i[j].fu,
                decoded_instr_i[j].use_imm
                };
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
        dispatch_instr_data_o[i].data_valid = is_result_available_gpr_i[dispatch_instr[i].rs2];
        dispatch_instr_data_o[i].vaddr_valid = is_result_available_gpr_i[dispatch_instr[i].rs1];

        // check RAW dependencies
        for (int unsigned k = 0; k < i; k++) begin
          if (dispatch_instr[k].rd == dispatch_instr[i].rs2 && dispatch_instr[k].rd != '0 && dispatch_instr_valid_o[i] && dispatch_instr_valid_o[k]) begin
            dispatch_instr_data_o[i].data_valid = 1'b0;
          end

          if (dispatch_instr[k].rd == dispatch_instr[i].rs1 && dispatch_instr[k].rd != '0 && dispatch_instr_valid_o[i] && dispatch_instr_valid_o[k]) begin
            dispatch_instr_data_o[i].vaddr_valid = 1'b0;
          end
        end

        if (FALLTHROUGH) begin
          if (fallthrough_out[i]) begin
            for (int unsigned k = 0; k < CVA6Cfg.NrIssuePorts; k++) begin
              if (k < fallthrough_src[i] && decoded_instr_ready_i[k]) begin
                if (decoded_instr_i[k].rd == dispatch_instr[i].rs1 && decoded_instr_i[k].rd != '0) begin
                  dispatch_instr_data_o[i].vaddr_valid = 1'b0;
                end

                if (decoded_instr_i[k].rd == dispatch_instr[i].rs2 && decoded_instr_i[k].rd != '0) begin
                  dispatch_instr_data_o[i].data_valid = 1'b0;
                end
              end
            end
          end
        end

      end
    end else begin
      for (int unsigned i = 0; i<CVA6Cfg.NrIssuePorts ; i++) begin
        dispatch_instr_data_o[i].data_valid = is_rs2_fpr(dispatch_instr[i].op) ? is_result_available_fpr_i[dispatch_instr[i].rs2] : is_result_available_gpr_i[dispatch_instr[i].rs2];
        dispatch_instr_data_o[i].vaddr_valid = is_rs1_fpr(dispatch_instr[i].op) ? is_result_available_fpr_i[dispatch_instr[i].rs1] : is_result_available_gpr_i[dispatch_instr[i].rs1];

        // check RAW dependencies
        for (int unsigned k = 0; k < i; k++) begin
          if (is_rd_fpr(dispatch_instr[k].op) == is_rs2_fpr(dispatch_instr[i].op) &&
            dispatch_instr[k].rd == dispatch_instr[i].rs2 && dispatch_instr[k].rd != '0 && dispatch_instr_valid_o[i]) begin
            dispatch_instr_data_o[i].data_valid = 1'b0;
          end

          if (is_rd_fpr(dispatch_instr[k].op) == is_rs1_fpr(dispatch_instr[i].op) &&
            dispatch_instr[k].rd == dispatch_instr[i].rs1 && dispatch_instr[k].rd != '0 && dispatch_instr_valid_o[i]) begin
            dispatch_instr_data_o[i].vaddr_valid = 1'b0;
          end
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      free_q <= '1;
      issue_pointer_q <= '0;
      dispatch_pointer_q <= '0;
    end else begin
      instr_queue_q <= instr_queue_n;
      free_q <= free_n;
      issue_pointer_q <= issue_pointer_n;
      dispatch_pointer_q <= dispatch_pointer_n;
    end
  end

endmodule
