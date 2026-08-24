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
// Date: 19.04.2017
// Description: Load Store Unit, handles address calculation and memory interface signals


module load_store_unit
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter type exception_t = logic,
    parameter type fu_data_t = logic,
    parameter type icache_areq_t = logic,
    parameter type icache_arsp_t = logic,
    parameter type icache_dreq_t = logic,
    parameter type icache_drsp_t = logic,
    parameter type lsu_ctrl_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic flush_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic stall_st_pending_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    output logic no_st_pending_o,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic amo_valid_commit_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input logic [CVA6Cfg.NrIssuePorts-1:0][31:0] tinst_i,
    // FU data needed to execute instruction - ISSUE_STAGE
    input fu_data_t [CVA6Cfg.NrIssuePorts-1:0] fu_data_i,
    // Load Store Unit is ready - ISSUE_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] lsq_full_o,
    // Load Store Unit instruction is valid - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_valid_i,
    // Load Store Unit instruction is accepted - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] decoded_instr_ack_i,
    // number of store queue entrie freed this cycle - ISSUE_STAGE
    output logic [$clog2(CVA6Cfg.NrLSQEntries + 1)-1:0] st_return_token_o,
    // number of load queue entrie freed this cycle - ISSUE_STAGE
    output logic [$clog2(CVA6Cfg.NrLSQEntries + 1)-1:0] ld_return_token_o,
    // Instr to write to the load queue - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] ld_we_i,
    // Instr to write to the store queue - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] st_we_i,

    // trans id of the producer needed by a store - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] data_trans_id_i,
    // trans id of the producer needed by a store or load - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] vaddr_trans_id_i,
    // data sent by issue stage is already valid - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0]                           st_data_valid_i,
    // vaddr sent by issue stage is already valid - ISSUE_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0]                           vaddr_valid_i,


    // Destination register in register file - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0]    wb_trans_id_i,
    // Results to write back - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.XLEN-1:0]            wbdata_i,
    // Indicates valid results - EX_STAGE
    input logic [CVA6Cfg.NrWbPorts-1:0]                              wt_valid_i,

    // do we need to rollback lsu buffer or squash load instr ? - SCOREBOARD
    input logic [CVA6Cfg.RollbackWidth-1:0] lsu_rollback_i,
    // trans if of instruction to rollback - SCOREBOARD
    input logic [CVA6Cfg.RollbackWidth-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] lsu_rollback_trans_id_i,

    // Load transaction ID - ISSUE_STAGE
    output logic [CVA6Cfg.TRANS_ID_BITS-1:0] load_trans_id_o,
    // Load result - ISSUE_STAGE
    output logic [CVA6Cfg.XLEN-1:0] load_result_o,
    // Load Global ID - ISSUE_STAGE
    output logic [CVA6Cfg.GlobalRsIdWidth-1:0] load_global_id_o,
    // Load result is valid - ISSUE_STAGE
    output logic load_valid_o,
    // Load exception - ISSUE_STAGE
    output exception_t load_exception_o,

    // Store transaction ID - ISSUE_STAGE
    output logic [CVA6Cfg.TRANS_ID_BITS-1:0] store_trans_id_o,
    // Store result - ISSUE_STAGE
    output logic [CVA6Cfg.XLEN-1:0] store_result_o,
    // Store result is valid - ISSUE_STAGE
    output logic store_valid_o,
    // Store exception - ISSUE_STAGE
    output exception_t store_exception_o,
    // do we need to rollback the store buffer - SCOREBOARD
    input logic [CVA6Cfg.RollbackWidth-1:0] store_rollback_i,
    // Has a store been dispatched ? - SCOREBOARD
    output logic store_dispatched_o,
    // Store dispatched trans_id - SCOREBOARD
    output logic [CVA6Cfg.TRANS_ID_BITS-1:0] store_dispatched_id_o,


    // Commit the first pending store - TO_BE_COMPLETED
    input logic commit_i,
    // Commit queue is ready to accept another commit request - TO_BE_COMPLETED
    output logic commit_ready_o,
    // Commit transaction ID - TO_BE_COMPLETED
    input logic [CVA6Cfg.TRANS_ID_BITS-1:0] commit_tran_id_i,

    // Enable virtual memory translation - TO_BE_COMPLETED
    input logic enable_translation_i,
    // Enable G-Stage memory translation - TO_BE_COMPLETED
    input logic enable_g_translation_i,
    // Enable virtual memory translation for load/stores - TO_BE_COMPLETED
    input logic en_ld_st_translation_i,
    // Enable G-Stage memory translation for load/stores - TO_BE_COMPLETED
    input logic en_ld_st_g_translation_i,

    // Instruction cache input request - CACHES
    input  icache_arsp_t icache_areq_i,
    // Instruction cache output request - CACHES
    output icache_areq_t icache_areq_o,

    // Current privilege mode - CSR_REGFILE
    input  riscv::priv_lvl_t                          priv_lvl_i,
    // Current virtualization mode - CSR_REGFILE
    input  logic                                      v_i,
    // Privilege level at which load and stores should happen - CSR_REGFILE
    input  riscv::priv_lvl_t                          ld_st_priv_lvl_i,
    // Virtualization mode at which load and stores should happen - CSR_REGFILE
    input  logic                                      ld_st_v_i,
    // Instruction is a hyp load/store - CSR_REGFILE
    output logic                                      csr_hs_ld_st_inst_o,
    // Supervisor User Memory - CSR_REGFILE
    input  logic                                      sum_i,
    // Virtual Supervisor User Memory - CSR_REGFILE
    input  logic                                      vs_sum_i,
    // Make Executable Readable - CSR_REGFILE
    input  logic                                      mxr_i,
    // Make Executable Readable Virtual Supervisor - CSR_REGFILE
    input  logic                                      vmxr_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [      CVA6Cfg.PPNW-1:0] satp_ppn_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [CVA6Cfg.ASID_WIDTH-1:0] asid_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [      CVA6Cfg.PPNW-1:0] vsatp_ppn_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [CVA6Cfg.ASID_WIDTH-1:0] vs_asid_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [      CVA6Cfg.PPNW-1:0] hgatp_ppn_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [CVA6Cfg.VMID_WIDTH-1:0] vmid_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [CVA6Cfg.ASID_WIDTH-1:0] asid_to_be_flushed_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [CVA6Cfg.VMID_WIDTH-1:0] vmid_to_be_flushed_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [      CVA6Cfg.VLEN-1:0] vaddr_to_be_flushed_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic             [     CVA6Cfg.GPLEN-1:0] gpaddr_to_be_flushed_i,
    // TLB flush - CONTROLLER
    input  logic                                      flush_tlb_i,
    input  logic                                      flush_tlb_vvma_i,
    input  logic                                      flush_tlb_gvma_i,
    // Instruction TLB miss - PERF_COUNTERS
    output logic                                      itlb_miss_o,
    // Data TLB miss - PERF_COUNTERS
    output logic                                      dtlb_miss_o,

    // Data cache request output - CACHES
    input  dcache_req_o_t [2:0] dcache_req_ports_i,
    // Data cache request input - CACHES
    output dcache_req_i_t [2:0] dcache_req_ports_o,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic                dcache_wbuffer_empty_i,
    // TO_BE_COMPLETED - TO_BE_COMPLETED
    input  logic                dcache_wbuffer_not_ni_i,
    // AMO request - CACHE
    output amo_req_t            amo_req_o,
    // AMO response - CACHE
    input  amo_resp_t           amo_resp_i,

    // PMP configuration - CSR_REGFILE
    input riscv::pmpcfg_t [(CVA6Cfg.NrPMPEntries > 0 ? CVA6Cfg.NrPMPEntries-1 : 0):0] pmpcfg_i,
    // PMP address - CSR_REGFILE
    input logic           [(CVA6Cfg.NrPMPEntries > 0 ? CVA6Cfg.NrPMPEntries-1 : 0):0][CVA6Cfg.PLEN-3:0] pmpaddr_i,

    // RVFI inforamtion - RVFI
    output lsu_ctrl_t                    rvfi_lsu_ctrl_o,
    // RVFI information - RVFI
    output logic      [CVA6Cfg.PLEN-1:0] rvfi_mem_paddr_o
);

  // data is misaligned
  logic                             data_misaligned;
  // --------------------------------------
  // 1st register stage - (stall registers)
  // --------------------------------------
  // those are the signals which are always correct
  // e.g.: they keep the value in the stall case
  lsu_ctrl_t                        lsu_ctrl, st_lsq_ctrl, ld_lsq_ctrl;

  logic                             pop_ld;


  logic                    st_valid_i;
  logic                    no_st_pending;
  logic                    ld_valid_i;
  logic [CVA6Cfg.VLEN-1:0] lsq_vaddr;
  logic [            31:0] lsq_tinst;
  logic                    lsq_hs_ld_st_inst;
  logic                    lsq_hlvx_inst;
  logic                    translation_req, lsq_translation_req;
  logic                    translation_valid;

  logic [$clog2(CVA6Cfg.NrLSQEntries)-1:0] ld_lsq_idx_o, ld_lsq_idx_i;



  logic                                     st_sent_to_cache;
  logic [CVA6Cfg.VLEN-1:0] mmu_vaddr;
  logic [CVA6Cfg.PLEN-1:0] mmu_paddr, lsu_paddr, st_lsq_paddr, ld_lsq_paddr;
  logic         [                     31:0] mmu_tinst;
  logic                                     mmu_hs_ld_st_inst;
  logic                                     mmu_hlvx_inst;
  exception_t                               mmu_exception;
  exception_t                               pmp_exception;
  icache_areq_t                             pmp_icache_areq_i;
  logic                                     pmp_translation_valid;
  logic                                     dtlb_hit;
  logic         [         CVA6Cfg.PPNW-1:0] dtlb_ppn;

  logic                                     ld_valid, ld_lsq_result_valid;
  logic         [CVA6Cfg.TRANS_ID_BITS-1:0] ld_trans_id;
  logic       [CVA6Cfg.GlobalRsIdWidth-1:0] ld_global_id;
  logic         [         CVA6Cfg.XLEN-1:0] ld_result, ld_lsq_result;
  logic                                     st_valid;
  logic         [CVA6Cfg.TRANS_ID_BITS-1:0] st_trans_id;
  logic         [         CVA6Cfg.XLEN-1:0] st_result;

  logic         [                     11:0] page_offset;
  logic                                     page_offset_matches;

  exception_t                               misaligned_exception;
  exception_t                               ld_ex;
  exception_t                               st_ex;

  logic                                     st_translation_req;
  logic [CVA6Cfg.VLEN-1:0]                  pmp_lsu_vaddr;
  logic                                     pmp_lsu_is_store;

  logic [CVA6Cfg.VLEN-1:0]                  no_mmu_vaddr_q;
  logic                                     no_mmu_is_store_q;


  logic [1:0] sum, mxr;
  logic [CVA6Cfg.PPNW-1:0] satp_ppn[2:0];
  logic [CVA6Cfg.ASID_WIDTH-1:0] asid[2:0], asid_to_be_flushed[1:0];
  logic [CVA6Cfg.VLEN-1:0] vaddr_to_be_flushed[1:0];
  // -------------------
  // MMU e.g.: TLBs/PTW
  // -------------------

  if (CVA6Cfg.MmuPresent) begin : gen_mmu
    localparam HYP_EXT = CVA6Cfg.RVH ? 1 : 0;

    cva6_mmu #(
        .CVA6Cfg       (CVA6Cfg),
        .exception_t   (exception_t),
        .icache_areq_t (icache_areq_t),
        .icache_arsp_t (icache_arsp_t),
        .icache_dreq_t (icache_dreq_t),
        .icache_drsp_t (icache_drsp_t),
        .dcache_req_i_t(dcache_req_i_t),
        .dcache_req_o_t(dcache_req_o_t),
        .HYP_EXT       (HYP_EXT)
    ) i_cva6_mmu (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .flush_i(flush_i),
        .enable_translation_i(enable_translation_i),
        .enable_g_translation_i(enable_g_translation_i),
        .en_ld_st_translation_i(en_ld_st_translation_i),
        .en_ld_st_g_translation_i(en_ld_st_g_translation_i),
        .icache_areq_i(icache_areq_i),
        .icache_areq_o(pmp_icache_areq_i),
        // misaligned bypass
        .misaligned_ex_i(misaligned_exception),
        .lsu_req_i(translation_req),
        .lsu_vaddr_i(mmu_vaddr),
        .lsu_tinst_i(mmu_tinst),
        .lsu_is_store_i(st_translation_req),
        .csr_hs_ld_st_inst_o(csr_hs_ld_st_inst_o),
        .lsu_dtlb_hit_o(dtlb_hit),  // send in the same cycle as the request
        .lsu_dtlb_ppn_o(dtlb_ppn),  // send in the same cycle as the request

        .lsu_valid_o    (pmp_translation_valid),
        .lsu_paddr_o    (lsu_paddr),
        .lsu_exception_o(pmp_exception),

        .priv_lvl_i      (priv_lvl_i),
        .v_i,
        .ld_st_priv_lvl_i(ld_st_priv_lvl_i),
        .ld_st_v_i,
        .sum_i,
        .vs_sum_i,
        .mxr_i,
        .vmxr_i,

        .hlvx_inst_i    (mmu_hlvx_inst),
        .hs_ld_st_inst_i(mmu_hs_ld_st_inst),
        .satp_ppn_i,
        .vsatp_ppn_i,
        .hgatp_ppn_i,
        .asid_i,
        .vs_asid_i,
        .asid_to_be_flushed_i,
        .vmid_i,
        .vmid_to_be_flushed_i,
        .vaddr_to_be_flushed_i,
        .gpaddr_to_be_flushed_i,
        .flush_tlb_i,
        .flush_tlb_vvma_i,
        .flush_tlb_gvma_i,

        .itlb_miss_o(itlb_miss_o),
        .dtlb_miss_o(dtlb_miss_o),

        .req_port_i(dcache_req_ports_i[0]),
        .req_port_o(dcache_req_ports_o[0]),

        .pmpcfg_i,
        .pmpaddr_i
    );
  end else begin : gen_no_mmu
    // icache request without MMU, virtual and physical address are identical
    assign pmp_icache_areq_i.fetch_valid = icache_areq_i.fetch_req;
    if (CVA6Cfg.VLEN >= CVA6Cfg.PLEN) begin : gen_virtual_physical_address_instruction_vlen_greater
      assign pmp_icache_areq_i.fetch_paddr = icache_areq_i.fetch_vaddr[CVA6Cfg.PLEN-1:0];
    end else begin : gen_virtual_physical_address_instruction_plen_greater
      assign pmp_icache_areq_i.fetch_paddr = CVA6Cfg.PLEN'(icache_areq_i.fetch_vaddr);
    end
    assign pmp_icache_areq_i.fetch_exception = 'h0;

    // dcache request without mmu for load or store,
    // Delay of 1 cycle to match MMU latency giving the address tag
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        lsu_paddr             <= '0;
        pmp_exception         <= '0;
        pmp_translation_valid <= 1'b0;

        no_mmu_vaddr_q        <= '0;
        no_mmu_is_store_q     <= 1'b0;
      end else begin

        if (CVA6Cfg.VLEN >= CVA6Cfg.PLEN) begin : gen_virtual_physical_address_lsu
          lsu_paddr <= mmu_vaddr[CVA6Cfg.PLEN-1:0];
        end else begin
          lsu_paddr <= CVA6Cfg.PLEN'(mmu_vaddr);
        end

        pmp_exception         <= misaligned_exception;
        pmp_translation_valid <= translation_req;

        // Metadata belonging to exactly the same request
        no_mmu_vaddr_q        <= mmu_vaddr;
        no_mmu_is_store_q     <= st_translation_req;
      end
    end

    assign pmp_lsu_vaddr = CVA6Cfg.MmuPresent ? mmu_vaddr : no_mmu_vaddr_q;
    assign pmp_lsu_is_store = CVA6Cfg.MmuPresent ? st_translation_req : no_mmu_is_store_q;

    // dcache interface of PTW not used
    assign dcache_req_ports_o[0].address_index = '0;
    assign dcache_req_ports_o[0].address_tag   = '0;
    assign dcache_req_ports_o[0].data_wdata    = '0;
    assign dcache_req_ports_o[0].data_req      = 1'b0;
    assign dcache_req_ports_o[0].data_be       = '1;
    assign dcache_req_ports_o[0].data_size     = 2'b11;
    assign dcache_req_ports_o[0].data_we       = 1'b0;
    assign dcache_req_ports_o[0].kill_req      = '0;
    assign dcache_req_ports_o[0].tag_valid     = 1'b0;

    assign itlb_miss_o                         = 1'b0;
    assign dtlb_miss_o                         = 1'b0;
    assign dtlb_ppn                            = (CVA6Cfg.VLEN >= CVA6Cfg.PLEN) ?
                                                  mmu_vaddr[CVA6Cfg.PLEN-1:12] :
                                                  {{(CVA6Cfg.PLEN - CVA6Cfg.VLEN){1'b0}}, mmu_vaddr[CVA6Cfg.VLEN-1:12]};
    assign dtlb_hit                            = 1'b1;

  end

  // ------------------
  // PMP
  // ------------------

  pmp_data_if #(
      .CVA6Cfg      (CVA6Cfg),
      .icache_areq_t(icache_areq_t),
      .exception_t  (exception_t)
  ) i_pmp_data_if (
      .clk_i               (clk_i),
      .rst_ni              (rst_ni),
      .icache_areq_i       (pmp_icache_areq_i),
      .icache_areq_o       (icache_areq_o),
      .icache_fetch_vaddr_i(icache_areq_i.fetch_vaddr),
      .lsu_valid_i         (pmp_translation_valid),
      .lsu_paddr_i         (lsu_paddr),
      .lsu_vaddr_i         (pmp_lsu_vaddr),
      .lsu_exception_i     (pmp_exception),
      .lsu_is_store_i      (pmp_lsu_is_store),
      .lsu_valid_o         (translation_valid),
      .lsu_paddr_o         (mmu_paddr),
      .lsu_exception_o     (mmu_exception),
      .priv_lvl_i          (priv_lvl_i),
      .v_i                 (v_i),
      .ld_st_priv_lvl_i    (ld_st_priv_lvl_i),
      .ld_st_v_i           (ld_st_v_i),
      .pmpcfg_i            (pmpcfg_i),
      .pmpaddr_i           (pmpaddr_i)
  );


  assign no_st_pending_o = no_st_pending;
  logic store_buffer_empty;
  // ------------------
  // Store Unit
  // ------------------
  store_unit #(
      .CVA6Cfg(CVA6Cfg),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .exception_t(exception_t),
      .lsu_ctrl_t(lsu_ctrl_t)
  ) i_store_unit (
      .clk_i,
      .rst_ni,
      .flush_i,
      .stall_st_pending_i,
      .no_st_pending_o  (no_st_pending),
      .st_valid_i   (st_valid_i),
      .lsu_ctrl_i(st_lsq_ctrl),
      .paddr_i  (st_lsq_paddr),
      .sent_to_cache_o (st_sent_to_cache),
      .commit_i,
      .commit_ready_o,
      .amo_valid_commit_i,
      .rvfi_mem_paddr_o     (rvfi_mem_paddr_o),
      // AMOs
      .amo_req_o,
      .amo_resp_i,
      // to memory arbiter
      .req_port_i           (dcache_req_ports_i[2]),
      .req_port_o           (dcache_req_ports_o[2])
  );

  // ------------------
  // Load Unit
  // ------------------
  load_unit #(
      .CVA6Cfg(CVA6Cfg),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .exception_t(exception_t),
      .lsu_ctrl_t(lsu_ctrl_t)
  ) i_load_unit (
      .clk_i,
      .rst_ni,
      .flush_i,
      .ldbuf_full_o (ldbuf_full),
      .valid_i   (ld_valid_i),
      .lsu_ctrl_i(ld_lsq_ctrl),
      .paddr_i  (ld_lsq_paddr),
      .pop_ld_o  (pop_ld),
      .rollback_i        (lsu_rollback_i),
      .rollback_trans_id_i  (lsu_rollback_trans_id_i),
      .ld_unit_idx_o     (ld_lsq_idx_o),
      .ld_unit_idx_i     (ld_lsq_idx_i),

      .valid_o           (ld_lsq_result_valid),
      .result_o          (ld_lsq_result),


      // to memory arbiter
      .req_port_i           (dcache_req_ports_i[1]),
      .req_port_o           (dcache_req_ports_o[1])
  );

  // ----------------------------
  // Output Pipeline Register
  // ----------------------------

  // amount of pipeline registers inserted for load/store return path
  // can be tuned to trade-off IPC vs. cycle time

  shift_reg #(
      .dtype(logic [$bits(ld_valid) + $bits(ld_trans_id) + $bits(ld_result) + $bits(ld_ex) + $bits(ld_global_id) - 1:0]),
      .Depth(CVA6Cfg.NrLoadPipeRegs)
  ) i_pipe_reg_load (
      .clk_i,
      .rst_ni,
      .d_i({ld_valid, ld_trans_id, ld_result, ld_ex, ld_global_id}),
      .d_o({load_valid_o, load_trans_id_o, load_result_o, load_exception_o, load_global_id_o})
  );

  shift_reg #(
      .dtype(logic [$bits(st_valid) + $bits(st_trans_id) + $bits(st_result) + $bits(st_ex) - 1:0]),
      .Depth(CVA6Cfg.NrStorePipeRegs)
  ) i_pipe_reg_store (
      .clk_i,
      .rst_ni,
      .d_i({st_valid, st_trans_id, st_result, st_ex}),
      .d_o({store_valid_o, store_trans_id_o, store_result_o, store_exception_o})
  );

  // determine whether this is a load or store
  always_comb begin : which_op

    translation_req   = 1'b0;
    mmu_vaddr         = {CVA6Cfg.VLEN{1'b0}};
    mmu_tinst         = {32{1'b0}};
    mmu_hs_ld_st_inst = 1'b0;
    mmu_hlvx_inst     = 1'b0;

    // check the operation to activate the right functional unit accordingly
    unique case (lsu_ctrl.fu)
      // all loads go here
      LOAD, STORE: begin
        translation_req = lsq_translation_req;
        mmu_vaddr       = lsq_vaddr;
        if (CVA6Cfg.RVH) begin
          mmu_tinst         = lsq_tinst;
          mmu_hs_ld_st_inst = lsq_hs_ld_st_inst;
          mmu_hlvx_inst     = lsq_hlvx_inst;
        end
      end
      // not relevant for the LSU
      default: ;
    endcase
  end

  // ------------------------
  // Misaligned Exception
  // ------------------------
  // we can detect a misaligned exception immediately
  // the misaligned exception is passed to the functional unit via the MMU, which in case
  // can augment the exception if other memory related exceptions like a page fault or access errors
  always_comb begin : data_misaligned_detection
    misaligned_exception = {
      {CVA6Cfg.XLEN{1'b0}}, {CVA6Cfg.XLEN{1'b0}}, {CVA6Cfg.GPLEN{1'b0}}, {32{1'b0}}, 1'b0, 1'b0
    };
    data_misaligned = 1'b0;

    if (lsu_ctrl.valid) begin
      if (CVA6Cfg.IS_XLEN64) begin
        case (lsu_ctrl.operation)
          // double word
          LD, SD, FLD, FSD,
                  AMO_LRD, AMO_SCD,
                  AMO_SWAPD, AMO_ADDD, AMO_ANDD, AMO_ORD,
                  AMO_XORD, AMO_MAXD, AMO_MAXDU, AMO_MIND,
                  AMO_MINDU, HLV_D, HSV_D: begin
            if (lsu_ctrl.vaddr[2:0] != 3'b000) begin
              data_misaligned = 1'b1;
            end
          end
          default: ;
        endcase
      end
      case (lsu_ctrl.operation)
        // word
        LW, LWU, SW, FLW, FSW,
                AMO_LRW, AMO_SCW,
                AMO_SWAPW, AMO_ADDW, AMO_ANDW, AMO_ORW,
                AMO_XORW, AMO_MAXW, AMO_MAXWU, AMO_MINW,
                AMO_MINWU, HLV_W, HLV_WU, HLVX_WU, HSV_W: begin
          if (lsu_ctrl.vaddr[1:0] != 2'b00) begin
            data_misaligned = 1'b1;
          end
        end
        // half word
        LH, LHU, SH, FLH, FSH, HLV_H, HLV_HU, HLVX_HU, HSV_H: begin
          if (lsu_ctrl.vaddr[0] != 1'b0) begin
            data_misaligned = 1'b1;
          end
        end
        // byte -> is always aligned
        default: ;
      endcase
    end

    if (data_misaligned) begin
      case (lsu_ctrl.fu)
        LOAD: begin
          misaligned_exception.cause = riscv::LD_ADDR_MISALIGNED;
          misaligned_exception.valid = 1'b1;
          if (CVA6Cfg.TvalEn)
            misaligned_exception.tval = {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{1'b0}}, lsu_ctrl.vaddr};
          if (CVA6Cfg.RVH) begin
            misaligned_exception.tval2 = '0;
            misaligned_exception.tinst = lsu_ctrl.tinst;
            misaligned_exception.gva   = ld_st_v_i;
          end
        end
        STORE: begin

          misaligned_exception.cause = riscv::ST_ADDR_MISALIGNED;
          misaligned_exception.valid = 1'b1;
          if (CVA6Cfg.TvalEn)
            misaligned_exception.tval = {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{1'b0}}, lsu_ctrl.vaddr};
          if (CVA6Cfg.RVH) begin
            misaligned_exception.tval2 = '0;
            misaligned_exception.tinst = lsu_ctrl.tinst;
            misaligned_exception.gva   = ld_st_v_i;
          end
        end
        default: ;
      endcase
    end

    if (CVA6Cfg.MmuPresent && en_ld_st_translation_i && lsu_ctrl.overflow) begin

      case (lsu_ctrl.fu)
        LOAD: begin
          misaligned_exception.cause = riscv::LOAD_PAGE_FAULT;
          misaligned_exception.valid = 1'b1;
          if (CVA6Cfg.TvalEn)
            misaligned_exception.tval = {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{1'b0}}, lsu_ctrl.vaddr};
          if (CVA6Cfg.RVH) begin
            misaligned_exception.tval2 = '0;
            misaligned_exception.tinst = lsu_ctrl.tinst;
            misaligned_exception.gva   = ld_st_v_i;
          end
        end
        STORE: begin
          misaligned_exception.cause = riscv::STORE_PAGE_FAULT;
          misaligned_exception.valid = 1'b1;
          if (CVA6Cfg.TvalEn)
            misaligned_exception.tval = {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{1'b0}}, lsu_ctrl.vaddr};
          if (CVA6Cfg.RVH) begin
            misaligned_exception.tval2 = '0;
            misaligned_exception.tinst = lsu_ctrl.tinst;
            misaligned_exception.gva   = ld_st_v_i;
          end
        end
        default: ;
      endcase
    end

    if (CVA6Cfg.MmuPresent && CVA6Cfg.RVH && en_ld_st_g_translation_i && !en_ld_st_translation_i && lsu_ctrl.g_overflow) begin

      case (lsu_ctrl.fu)
        LOAD: begin
          misaligned_exception.cause = riscv::LOAD_GUEST_PAGE_FAULT;
          misaligned_exception.valid = 1'b1;
          if (CVA6Cfg.TvalEn)
            misaligned_exception.tval = {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{1'b0}}, lsu_ctrl.vaddr};
          if (CVA6Cfg.RVH) begin
            misaligned_exception.tval2 = '0;
            misaligned_exception.tinst = lsu_ctrl.tinst;
            misaligned_exception.gva   = ld_st_v_i;
          end
        end
        STORE: begin
          misaligned_exception.cause = riscv::STORE_GUEST_PAGE_FAULT;
          misaligned_exception.valid = 1'b1;
          if (CVA6Cfg.TvalEn)
            misaligned_exception.tval = {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{1'b0}}, lsu_ctrl.vaddr};
          if (CVA6Cfg.RVH) begin
            misaligned_exception.tval2 = '0;
            misaligned_exception.tinst = lsu_ctrl.tinst;
            misaligned_exception.gva   = ld_st_v_i;
          end
        end
        default: ;
      endcase
    end
  end



  load_store_queue #(
      .CVA6Cfg(CVA6Cfg),
      .lsu_ctrl_t(lsu_ctrl_t),
      .fu_data_t(fu_data_t),
      .exception_t(exception_t),
      .LSQ_DEPTH(CVA6Cfg.NrLSQEntries)
  ) load_store_queue_i (
    .clk_i,
    .rst_ni,
    .flush_i,
    .full_o (lsq_full_o),
    .commit_i, //commit latest store
    .commit_trans_id_i (commit_tran_id_i),
    .dcache_wbuffer_not_ni_i (dcache_wbuffer_not_ni_i),

    .rollback_i (lsu_rollback_i),
    .rollback_trans_id_i (lsu_rollback_trans_id_i),
    .store_dispatched_id_o,
    // TODO: je pense que store_dispatched_o n'est plus nécessaire dans ce design
    //Je le laisse la pour le moment as a reminder qu'il faut modifier son calcule dans le scoreboard

    //LSQ write data
    .ld_we_i               (ld_we_i),
    .st_we_i               (st_we_i),
    .fu_data_i             (fu_data_i),
    .tinst_i               (tinst_i),
    .decoded_instr_valid_i (decoded_instr_valid_i),
    .decoded_instr_ack_i   (decoded_instr_ack_i),
    .data_trans_id_i       (data_trans_id_i),
    .vaddr_trans_id_i      (vaddr_trans_id_i),
    .st_data_valid_i       (st_data_valid_i),
    .vaddr_valid_i         (vaddr_valid_i),

    //MMU
    .lsu_ctrl_o            (lsu_ctrl),
    .vaddr_o               (lsq_vaddr),
    .tinst_o               (lsq_tinst),
    .hs_ld_st_inst_o       (lsq_hs_ld_st_inst),
    .hlvx_inst_o           (lsq_hlvx_inst),
    .translation_req_o     (lsq_translation_req),
    .paddr_i               (mmu_paddr),
    .ex_i                  (mmu_exception),
    .dtlb_hit_i            (dtlb_hit),
    .dtlb_ppn_i            (dtlb_ppn),

    //Write back info
    .wb_trans_id_i         (wb_trans_id_i),
    .wbdata_i              (wbdata_i),
    .wt_valid_i            (wt_valid_i),

    //Store unit
    .st_buf_lsu_ctrl_o   (st_lsq_ctrl),
    .st_buf_valid_o      (st_valid_i),
    .st_buf_paddr_o      (st_lsq_paddr),
    .no_st_pending_i     (no_st_pending),
    .st_sent_to_cache_i  (st_sent_to_cache),
    .st_return_token_o   (st_return_token_o),
    .ld_return_token_o   (ld_return_token_o),

    //Load unit
    .ldbuf_full_i       (ldbuf_full),
    .ld_pop_i           (pop_ld),
    .ld_unit_lsu_ctrl_o (ld_lsq_ctrl),
    .ld_unit_valid_o    (ld_valid_i),
    .ld_unit_paddr_o    (ld_lsq_paddr),
    .ld_unit_idx_o      (ld_lsq_idx_i),
    .ld_result_valid_i  (ld_lsq_result_valid),
    .ld_result_i        (ld_lsq_result),
    .ld_unit_idx_i      (ld_lsq_idx_o),

    //Load write back
    .ld_valid_o           (ld_valid),
    .ld_trans_id_o        (ld_trans_id),
    .ld_global_id_o       (ld_global_id),
    .ld_result_o          (ld_result),
    .ld_ex_o              (ld_ex),

    //Store write back
    .st_valid_o           (st_valid),
    .st_trans_id_o        (st_trans_id),
    .st_result_o          (st_result),
    .st_ex_o              (st_ex)
  );

  assign rvfi_lsu_ctrl_o = lsu_ctrl;
  assign st_translation_req = (lsu_ctrl.fu == STORE);

  // pragma translate off
  assert property (
  @(posedge clk_i) disable iff (!rst_ni)
  translation_valid |-> !$isunknown(mmu_paddr)
  )
  else $error(
    "TRANSLATION VALID BUT PADDR X: valid=%b paddr=%h lsu_paddr=%h pmp_valid=%b",
    $sampled(translation_valid),
    $sampled(mmu_paddr),
    $sampled(lsu_paddr),
    $sampled(pmp_translation_valid)
  );
  // pragma translate on

endmodule


