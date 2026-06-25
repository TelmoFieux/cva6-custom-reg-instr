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


module tournament_tree #(
    parameter int unsigned           ID_SIZE       = 8,
    parameter int unsigned           NR_PLAYER     = 16
) (
    input  logic  [NR_PLAYER-1:0]                           valid_i, // is player ready
    input  logic  [NR_PLAYER-1:0][ID_SIZE-1:0]              seq_num_i, // player tag
    input  logic  [NR_PLAYER-1:0][$clog2(NR_PLAYER)-1:0]    id_i, // player id
    output logic  [$clog2(NR_PLAYER)-1:0]                   winner_o,
    output logic                                            winner_valid_o
);
  localparam int unsigned TREE_SIZE = NR_PLAYER*2;

  logic [TREE_SIZE-1:0][ID_SIZE-1:0] seq_num_tree;
  logic [TREE_SIZE-1:0][$clog2(NR_PLAYER)-1:0] id_tree;
  logic [TREE_SIZE-1:0] valid_tree;

  always_comb begin : tournament
    seq_num_tree = '0;
    id_tree = '0;
    valid_tree = '0;

    for (int i = NR_PLAYER; i<TREE_SIZE; i++) begin
      seq_num_tree[i] = seq_num_i[i-NR_PLAYER];
      id_tree[i] = id_i[i-NR_PLAYER];
      valid_tree[i] = valid_i[i-NR_PLAYER];
    end

    for (int i = NR_PLAYER-1 ; i > 0 ; i--) begin
      if (valid_tree[2*i] && (!valid_tree[2*i+1] || (seq_num_tree[2*i] < seq_num_tree[2*i+1]))) begin
        seq_num_tree[i] = seq_num_tree[2*i];
        valid_tree[i]   = valid_tree[2*i];
        id_tree[i]      = id_tree[2*i];
      end else begin
        seq_num_tree[i] = seq_num_tree[2*i+1];
        valid_tree[i]   = valid_tree[2*i+1];
        id_tree[i]      = id_tree[2*i+1];
      end
    end
  end

  assign winner_o = id_tree[1];
  assign winner_valid_o = valid_tree[1];


endmodule
