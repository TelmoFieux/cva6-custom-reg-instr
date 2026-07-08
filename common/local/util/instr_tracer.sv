// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License");
// you may not use this file except in
// compliance with the License.
// You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51.
// Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied.
// See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 16.05.2017
// Description: Instruction Tracer Main Class (Modified for OoO Execution)

`ifndef VERILATOR
//pragma translate_off
`include "ex_trace_item.svh"
`include "instr_trace_item.svh"

module instr_tracer #(
  parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
  parameter type bp_resolve_t = logic,
  parameter type scoreboard_entry_t = logic[303:0], 
  parameter type interrupts_t = logic,
  parameter type exception_t = logic,
  parameter interrupts_t INTERRUPTS = '0
)(
  input logic                    pck,
  input logic                    rstn,
  input logic                    flush_unissued,
  input logic                    flush_all,
  input logic [31:0]             instruction,
  input logic                    fetch_valid,
  input logic                    fetch_ack,
  input logic                    issue_ack, 
  input scoreboard_entry_t       issue_sbe, 
  input logic [1:0][CVA6Cfg.RegAddrWidth-1:0] waddr, 
  input logic [1:0][63:0]        wdata,
  input logic [1:0]              we_gpr,
  input logic [1:0]              we_fpr,
  input scoreboard_entry_t [1:0] commit_instr, 
  input logic [1:0]              commit_ack,
  
  input logic                    st_valid,   
  input logic [CVA6Cfg.PLEN-1:0] st_paddr,
  input logic [CVA6Cfg.TRANS_ID_BITS-1:0] st_trans_id, // NEW: trans_id for stores

  input logic                    ld_valid, 
  input logic                    ld_kill,
  input logic [CVA6Cfg.PLEN-1:0] ld_paddr,
  input logic [CVA6Cfg.TRANS_ID_BITS-1:0] ld_trans_id, // NEW: trans_id for loads
  
  input bp_resolve_t             resolve_branch, 
  input logic [CVA6Cfg.TRANS_ID_BITS-1:0] bp_trans_id, // NEW: trans_id for branches

  input exception_t              commit_exception,
  input riscv::priv_lvl_t        priv_lvl, 
  input logic                    debug_mode,
  input logic[CVA6Cfg.XLEN-1:0]  hart_id_i
);

  // keep the decoded instructions in a queue (Fetch is still in-order)
  logic [31:0] decode_queue [$];

  // Inflight Data Structures (Indexed by trans_id to support OoO)
  logic [31:0]             inflight_instr [int];
  scoreboard_entry_t       inflight_sbe   [int];
  logic [CVA6Cfg.PLEN-1:0] inflight_paddr [int];
  bp_resolve_t             inflight_bp    [int];

  // shadow copy of the register files
  logic [63:0] gp_reg_file [2 ** CVA6Cfg.RegAddrWidth];
  logic [63:0] fp_reg_file [2 ** CVA6Cfg.RegAddrWidth];

  // 64 bit clock tick count
  longint unsigned clk_ticks;
  int f, commit_log;

  function void create_file(logic [63:0] hart_id);
    string fn, fn_commit_log;
    $sformat(fn, "trace_hart_%0.0f.log", hart_id);
    $sformat(fn_commit_log, "trace_hart_%0.0f_commit.log", hart_id);
    $display("[TRACER] Output filename is: %s", fn);

    f = $fopen(fn,"w");
    if (ariane_pkg::ENABLE_SPIKE_COMMIT_LOG) commit_log = $fopen(fn_commit_log, "w");
  endfunction : create_file

  task trace();
    automatic logic [31:0] decode_instruction, issue_instruction, issue_commit_instruction;
    automatic scoreboard_entry_t commit_instruction;
    automatic scoreboard_entry_t issue_sbe_item;
    automatic logic [CVA6Cfg.PLEN-1:0] address_mapping;

    // initialize register 0
    gp_reg_file  = '{default:0};
    fp_reg_file  = '{default:0};

    forever begin
      automatic bp_resolve_t bp_instruction = '0;

      // new cycle, we are only interested if reset is de-asserted
      @(pck) if (rstn !== 1'b1) begin
        flush();
        continue;
      end

      clk_ticks++;

      // -------------------
      // Instruction Decode
      // -------------------
      if (fetch_valid && fetch_ack) begin
        decode_instruction = instruction;
        decode_queue.push_back(decode_instruction);
      end

      // -------------------
      // Instruction Issue
      // -------------------
      if (issue_ack && !flush_unissued) begin
        issue_instruction = decode_queue.pop_front();
        // Save using the transaction ID instead of pushing to a FIFO
        inflight_instr[int'(issue_sbe.trans_id)] = issue_instruction;
        inflight_sbe[int'(issue_sbe.trans_id)]   = scoreboard_entry_t'(issue_sbe);
      end

      // --------------------
      // Address Translation (Out of Order)
      // --------------------
      if (st_valid) begin
        inflight_paddr[int'(st_trans_id)] = st_paddr;
      end

      if (ld_valid && !ld_kill) begin
        inflight_paddr[int'(ld_trans_id)] = ld_paddr;
      end

      // ----------------------
      // Store predictions (Out of Order)
      // ----------------------
      if (resolve_branch.valid) begin
        inflight_bp[int'(bp_trans_id)] = resolve_branch;
      end

      // --------------
      //  Commit (In Order)
      // --------------
      for (int i = 0; i < 2; i++) begin
        if (commit_ack[i] && commit_instr[i].valid) begin
          automatic int tid = int'(commit_instr[i].trans_id);
          commit_instruction = scoreboard_entry_t'(commit_instr[i]);
          
          // Retrieve data dynamically based on trans_id
          issue_commit_instruction = inflight_instr.exists(tid) ? inflight_instr[tid] : '0;
          issue_sbe_item = inflight_sbe.exists(tid) ? inflight_sbe[tid] : '0;
          
          address_mapping = '0;
          if (commit_instr[i].fu == ariane_pkg::LOAD || commit_instr[i].fu == ariane_pkg::STORE) begin
             address_mapping = inflight_paddr.exists(tid) ? inflight_paddr[tid] : '0;
          end

          if (commit_instr[i].fu == ariane_pkg::CTRL_FLOW) begin
             bp_instruction = inflight_bp.exists(tid) ? inflight_bp[tid] : '0;
          end

          if (we_gpr[i] || we_fpr[i]) begin
            printInstr(issue_sbe_item, issue_commit_instruction, wdata[i], address_mapping, priv_lvl, debug_mode, bp_instruction);
          end else if (ariane_pkg::is_rd_fpr(commit_instruction.op)) begin
            printInstr(issue_sbe_item, issue_commit_instruction, fp_reg_file[commit_instruction.rd], address_mapping, priv_lvl, debug_mode, bp_instruction);
          end else begin
            printInstr(issue_sbe_item, issue_commit_instruction, gp_reg_file[commit_instruction.rd], address_mapping, priv_lvl, debug_mode, bp_instruction);
          end

          // Clean up the dictionary entries
          inflight_instr.delete(tid);
          inflight_sbe.delete(tid);
          inflight_paddr.delete(tid);
          inflight_bp.delete(tid);
        end
      end

      // --------------
      // Exceptions
      // --------------
      if (commit_exception.valid && !(debug_mode && commit_exception.cause == riscv::BREAKPOINT)) begin
        printException(commit_instr[0].pc, commit_exception.cause, commit_exception.tval);
      end

      // ----------------------
      // Commit Registers
      // ----------------------
      for (int i = 0; i < 2; i++) begin
        if (we_gpr[i] && waddr[i] != '0) begin
          gp_reg_file[waddr[i]] = wdata[i];
        end else if (we_fpr[i]) begin
          fp_reg_file[waddr[i]] = wdata[i];
        end
      end

      // --------------
      // Flush Signals
      // --------------
      if (flush_unissued) begin
        flushDecode();
      end
      
      if (flush_all) begin
        flush();
      end
    end
  endtask

  function void flushDecode ();
    decode_queue = {};
  endfunction

  function void flush ();
    flushDecode();
    inflight_instr.delete();
    inflight_sbe.delete();
    inflight_paddr.delete();
    inflight_bp.delete();
  endfunction

  function automatic void printInstr(scoreboard_entry_t sbe, logic [31:0] instr, logic [63:0] result, logic [CVA6Cfg.PLEN-1:0] paddr, riscv::priv_lvl_t priv_lvl, logic debug_mode, bp_resolve_t bp);
    instr_trace_item #(
      .CVA6Cfg(CVA6Cfg),
      .bp_resolve_t(bp_resolve_t),
      .scoreboard_entry_t(scoreboard_entry_t)
    ) iti;
    string print_instr;

    iti = new ($time, clk_ticks, sbe, instr, gp_reg_file, fp_reg_file, result, paddr, priv_lvl, debug_mode, bp);
    print_instr = iti.printInstr();
    if (ariane_pkg::ENABLE_SPIKE_COMMIT_LOG && !debug_mode) begin
      $fwrite(commit_log, riscv::spikeCommitLog(sbe.pc, priv_lvl, instr, sbe.arch_rd, result, ariane_pkg::is_rd_fpr(sbe.op)));
    end
    $fwrite(f, {print_instr, "\n"});
  endfunction

  function automatic void printException(logic [CVA6Cfg.VLEN-1:0] pc, logic [63:0] cause, logic [63:0] tval);
    ex_trace_item #(
      .CVA6Cfg(CVA6Cfg),
      .interrupts_t(interrupts_t),
      .INTERRUPTS(INTERRUPTS)
    ) eti;
    string print_ex;

    eti = new (pc, cause, tval);
    print_ex = eti.printException();
    $fwrite(f, {print_ex, "\n"});
  endfunction

  function void close();
    if (f) $fclose(f);
    if (ariane_pkg::ENABLE_SPIKE_COMMIT_LOG && commit_log) $fclose(commit_log);
  endfunction

  initial begin
    #15ns;
    create_file(hart_id_i);
    trace();
  end

  final begin
    close();
  end

endmodule : instr_tracer
//pragma translate_on
`endif