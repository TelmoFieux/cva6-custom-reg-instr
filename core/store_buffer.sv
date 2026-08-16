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
// Date: 25.04.2017
// Description: Store queue persists store requests and pushes them to memory
//              if they are no longer speculative


module store_buffer
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic
) (
    input  logic                          clk_i,  // Clock
    input  logic                          rst_ni,  // Asynchronous reset active low
    input  logic                          flush_i,  // if we flush we need to pause the transactions on the memory
                                                    // otherwise we will run in a deadlock with the memory arbiter
    input  logic                          stall_st_pending_i,  // Stall issuing non-speculative request
    output logic                          no_st_pending_o, // non-speculative queue is empty (e.g.: everything is committed to the memory hierarchy)

    input  logic                          commit_i,  // commit the instruction which was placed there most recently
    input  logic                          store_buffer_valid_i,
    output logic                          commit_ready_o,  // commit queue is ready to accept another commit request
                                                     // it is only ready if it can unconditionally commit the instruction, e.g.:
                                                     // the commit buffer needs to be empty
                                                     //

    input  logic [CVA6Cfg.PLEN-1:0]       paddr_i,         // physical address of store which needs to be placed in the queue
    output logic [CVA6Cfg.PLEN-1:0]       rvfi_mem_paddr_o,
    input  logic [CVA6Cfg.XLEN-1:0]       data_i,  // data which is placed in the queue
    input  logic [(CVA6Cfg.XLEN/8)-1:0]   be_i,  // byte enable in
    input  logic [1:0]                    data_size_i,  // type of request we are making (e.g.: bytes to write)

    // a store request has been sent to the cache - LOAD_STORE_QUEUE
    output logic                          sent_to_cache_o,

    // D$ interface
    input  dcache_req_o_t req_port_i,
    output dcache_req_i_t req_port_o
);

  struct packed {
    logic [CVA6Cfg.PLEN-1:0] address;
    logic [CVA6Cfg.XLEN-1:0] data;
    logic [(CVA6Cfg.XLEN/8)-1:0] be;
    logic [1:0] data_size;
    logic valid;  // this entry is valid, we need this for checking if the address offset matches
  }
      commit_queue_n[DEPTH_COMMIT-1:0],
      commit_queue_q[DEPTH_COMMIT-1:0];

  // keep a status count for both buffers
  logic [$clog2(DEPTH_COMMIT):0] commit_status_cnt_n, commit_status_cnt_q;
  // Commit Queue
  logic [$clog2(DEPTH_COMMIT)-1:0] commit_read_pointer_n, commit_read_pointer_q;
  logic [$clog2(DEPTH_COMMIT)-1:0] commit_write_pointer_n, commit_write_pointer_q;


  // ----------------------------------------
  // Commit Queue - Memory Interface
  // ----------------------------------------

  // we will never kill a request in the store buffer since we already know that the translation is valid
  // e.g.: a kill request will only be necessary if we are not sure if the requested memory address will result in a TLB fault
  assign req_port_o.kill_req = 1'b0;
  assign req_port_o.data_we = 1'b1;  // we will always write in the store queue
  assign req_port_o.tag_valid = 1'b0;

  // we do not require an acknowledgement for writes, thus we do not need to identify uniquely the responses
  assign req_port_o.data_id = '0;
  // those signals can directly be output to the memory
  assign req_port_o.address_index = commit_queue_q[commit_read_pointer_q].address[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
  // if we got a new request we already saved the tag from the previous cycle
  assign req_port_o.address_tag   = commit_queue_q[commit_read_pointer_q].address[CVA6Cfg.DCACHE_TAG_WIDTH     +
                                                                                    CVA6Cfg.DCACHE_INDEX_WIDTH-1 :
                                                                                    CVA6Cfg.DCACHE_INDEX_WIDTH];
  assign req_port_o.data_wdata = commit_queue_q[commit_read_pointer_q].data;
  assign req_port_o.data_wuser = '0;
  assign req_port_o.data_be = commit_queue_q[commit_read_pointer_q].be;
  assign req_port_o.data_size = commit_queue_q[commit_read_pointer_q].data_size;


  always_comb begin : store_if
    automatic logic [$clog2(DEPTH_COMMIT):0] commit_status_cnt;
    commit_status_cnt      = commit_status_cnt_q;

    commit_ready_o         = (commit_status_cnt_q < DEPTH_COMMIT);
    // no store is pending if we don't have any element in the commit queue e.g.: it is empty
    no_st_pending_o        = (commit_status_cnt_q == 0);
    // default assignments
    commit_read_pointer_n  = commit_read_pointer_q;
    commit_write_pointer_n = commit_write_pointer_q;

    commit_queue_n         = commit_queue_q;

    req_port_o.data_req    = 1'b0;

    sent_to_cache_o = 1'b0;

    // there should be no commit when we are flushing
    if (commit_queue_q[commit_read_pointer_q].valid && !stall_st_pending_i) begin
      req_port_o.data_req = 1'b1;
      sent_to_cache_o = 1'b1;
      if (req_port_i.data_gnt) begin
        // we can evict it from the commit buffer
        commit_queue_n[commit_read_pointer_q].valid = 1'b0;
        // advance the read_pointer
        commit_read_pointer_n = commit_read_pointer_q + 1'b1;
        commit_status_cnt--;
      end
    end
    // we ignore the rvalid signal for now as we assume that the store
    // happened if we got a grant

    // shift the store request from the speculative buffer to the non-speculative
    if (commit_i & store_buffer_valid_i) begin
      commit_queue_n[commit_write_pointer_q].address = paddr_i;
      commit_queue_n[commit_write_pointer_q].data = data_i;
      commit_queue_n[commit_write_pointer_q].be = be_i;
      commit_queue_n[commit_write_pointer_q].data_size = data_size_i;
      commit_queue_n[commit_write_pointer_q].valid = 1'b1;
      commit_write_pointer_n = commit_write_pointer_n + 1'b1;
      commit_status_cnt++;
    end

    commit_status_cnt_n = commit_status_cnt;
  end

  // registers
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_commit
    if (~rst_ni) begin
      commit_queue_q         <= '{default: 0};
      commit_read_pointer_q  <= '0;
      commit_write_pointer_q <= '0;
      commit_status_cnt_q    <= '0;
    end else begin
      commit_queue_q         <= commit_queue_n;
      commit_read_pointer_q  <= commit_read_pointer_n;
      commit_write_pointer_q <= commit_write_pointer_n;
      commit_status_cnt_q    <= commit_status_cnt_n;
    end
  end

  ///////////////////////////////////////////////////////
  // assertions
  ///////////////////////////////////////////////////////

  //pragma translate_off
  // assert that commit is never set when we are flushing this would be counter intuitive
  // as flush and commit is decided in the same stage
  commit_and_flush :
  assert property (@(posedge clk_i) rst_ni && flush_i |-> !commit_i)
  else $error("[Commit Queue] You are trying to commit and flush in the same cycle");

  commit_buffer_overflow :
  assert property (@(posedge clk_i) rst_ni && (commit_status_cnt_q == DEPTH_COMMIT) |-> !commit_i)
  else $error("[Commit Queue] You are trying to commit a store although the buffer is full");
  //pragma translate_on
endmodule



