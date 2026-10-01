// Simulation only
`ifndef SYNTHESIS

package OoO_perf_pkg;
  bit          window        = 1'b0;
  int unsigned n_cycle_reads = 0;
endpackage

module OoO_perf_window (
  input logic             clk_i,
  input logic             rst_ni,
  input ariane_pkg::fu_op csr_op_i,
  input logic [11:0]      csr_addr_i
);
  int unsigned open_n  = 1;
  int unsigned close_n = 2;

  initial begin
    void'($value$plusargs("perf_open=%d",  open_n));
    void'($value$plusargs("perf_close=%d", close_n));
    $display("ça marche");
  end

  always_ff @(posedge clk_i) if (rst_ni) begin
    if (csr_op_i == ariane_pkg::CSR_READ &&
        csr_addr_i inside {riscv::CSR_CYCLE, riscv::CSR_MCYCLE}) begin
      OoO_perf_pkg::n_cycle_reads++;
      $display("[perf] lecture de cycle n°%0d @%0t", OoO_perf_pkg::n_cycle_reads, $time);
      if (OoO_perf_pkg::n_cycle_reads == open_n)  OoO_perf_pkg::window = 1'b1;
      if (OoO_perf_pkg::n_cycle_reads == close_n) OoO_perf_pkg::window = 1'b0;
    end
  end
endmodule

`endif
