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
// Date: 16.05.2017
// Description: Instruction Tracer Main Class

`ifndef VERILATOR
//pragma translate_off
`include "ex_trace_item.svh"
`include "instr_trace_item.svh"

module instr_tracer #(
  parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
  parameter type bp_resolve_t = logic,
  parameter type scoreboard_entry_t = logic[303:0], // Fix for xcelium bug at runtime: does not have enough memory space reserved for scoreboard_entry
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
  input logic                    issue_ack, // issue acknowledged
  input scoreboard_entry_t       issue_sbe, // issue scoreboard entry
  input logic [1:0][CVA6Cfg.RegAddrWidth-1:0] waddr, // WB stage
  input logic [1:0][63:0]        wdata,
  input logic [1:0]              we_gpr,
  input logic [1:0]              we_fpr,
  input scoreboard_entry_t [1:0] commit_instr, // commit instruction
  input logic [1:0]              commit_ack,
  input logic                    st_valid,   // stores - address translation
  input logic [CVA6Cfg.PLEN-1:0] st_paddr,
  input logic                    ld_valid, // loads
  input logic                    ld_kill,
  input logic [CVA6Cfg.PLEN-1:0] ld_paddr,
  input bp_resolve_t             resolve_branch, // misprediction
  input exception_t              commit_exception,
  input riscv::priv_lvl_t        priv_lvl, // current privilege level
  input logic                    debug_mode,

  input logic[CVA6Cfg.XLEN-1:0] hart_id_i
);

  int f;
  longint unsigned clk_ticks;
  longint unsigned commit_count;

  int f_arch;
  int f_debug;


  function void create_file(logic [63:0] hart_id);

      string fn_arch;
      string fn_debug;

      $sformat(
          fn_arch,
          "trace_hart_%0.0f_arch.log",
          hart_id
      );

      $sformat(
          fn_debug,
          "trace_hart_%0.0f_debug.log",
          hart_id
      );

      $display("[TRACER] Arch trace : %s", fn_arch);
      $display("[TRACER] Debug trace: %s", fn_debug);

      f_arch  = $fopen(fn_arch,  "w");
      f_debug = $fopen(fn_debug, "w");

  endfunction

  function automatic void printCommit(
      input int unsigned port,
      input scoreboard_entry_t sbe
  );

      // -------------------------------------------------------
      // Architectural trace
      //
      // Ne pas mettre :
      // - time
      // - cycle
      // - trans_id
      // - global_rs_id
      // - physical registers
      //
      // afin de pouvoir faire un diff direct entre deux runs.
      // -------------------------------------------------------

      if (sbe.arch_rd != '0) begin
          $fwrite(
              f_arch,
              "%0d pc=%h fu=%0d op=%0d arch_rd=%0d result=%h ex=%0b\n",
              commit_count,
              sbe.pc,
              sbe.fu,
              sbe.op,
              sbe.arch_rd,
              sbe.result,
              sbe.ex.valid
          );
      end else begin
          $fwrite(
              f_arch,
              "%0d pc=%h fu=%0d op=%0d arch_rd=0 result=00000000 ex=%0b\n",
              commit_count,
              sbe.pc,
              sbe.fu,
              sbe.op,
              sbe.ex.valid
          );
      end


      // -------------------------------------------------------
      // Detailed microarchitectural trace
      // -------------------------------------------------------

      $fwrite(
          f_debug,
          "ord=%0d time=%0t cycle=%0d port=%0d pc=%h valid=%0b fu=%0d op=%0d arch_rd=%0d rd=%0d old_phys=%0d rs1=%0d rs2=%0d tid=%0d gid=%0d result=%h ex_valid=%0b ex_cause=%0d ex_tval=%h SBE=%p\n",

          commit_count,
          $time,
          clk_ticks,
          port,

          sbe.pc,
          sbe.valid,

          sbe.fu,
          sbe.op,

          sbe.arch_rd,

          sbe.rd,
          sbe.old_phys,

          sbe.rs1,
          sbe.rs2,

          sbe.trans_id,
          sbe.global_rs_id,

          sbe.result,

          sbe.ex.valid,
          sbe.ex.cause,
          sbe.ex.tval,

          sbe
      );

  endfunction

  task trace();

    clk_ticks    = 0;
    commit_count = 0;

    forever begin

        @(posedge pck);

        if (rstn !== 1'b1) begin
            clk_ticks = 0;
            continue;
        end

        clk_ticks++;

        for (int unsigned i = 0; i < 2; i++) begin

            if (commit_ack[i]) begin

                printCommit(
                    i,
                    scoreboard_entry_t'(commit_instr[i])
                );

                commit_count++;

            end
        end


        if (
            commit_exception.valid &&
            !(debug_mode &&
              commit_exception.cause == riscv::BREAKPOINT)
        ) begin

            $fwrite(
                f_debug,
                "EXCEPTION time=%0t cycle=%0d pc=%h cause=%0d tval=%h\n",
                $time,
                clk_ticks,
                commit_instr[0].pc,
                commit_exception.cause,
                commit_exception.tval
            );

        end

    end

  endtask

  function void close();

      if (f_arch)
          $fclose(f_arch);

      if (f_debug)
          $fclose(f_debug);

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
