//Simulation only. Dictates if mesuring period has started
`ifndef SYNTHESIS
package perf_pkg;
  bit          window        = 1'b0;
  int unsigned n_cycle_reads = 0;
endpackage
`endif
