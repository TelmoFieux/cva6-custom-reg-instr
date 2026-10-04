`ifndef SYNTHESIS
module tohost_monitor #(parameter int PLEN = 34, parameter int XLEN = 32) (
  input logic            clk_i, rst_ni,
  input logic            valid_i,
  input logic [PLEN-1:0] paddr_i,
  input logic [XLEN-1:0] data_i
);
  logic [PLEN-1:0] tohost;
  initial if (!$value$plusargs("tohost_addr=%h", tohost)) tohost = '0;

  always_ff @(posedge clk_i)
    if (rst_ni && tohost != '0 && valid_i && paddr_i == tohost) begin
      if (data_i[31:0] == 32'd1) $display("*** ISA PASS *** @%0t", $time);
      else                       $display("*** ISA FAIL *** sous-test %0d @%0t", data_i[31:0] >> 1, $time);
      $finish;
    end
endmodule
`endif
