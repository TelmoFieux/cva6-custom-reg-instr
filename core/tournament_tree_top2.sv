// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright 2024 - PlanV Technologies for additionnal contribution.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied.
//
// Engineer: Fieux Telmo - fieuxtelmo@gmail.com
//
// Description:
//   Tournament tree returning the two oldest valid entries.
//   winner_o[0] = oldest valid player
//   winner_o[1] = second oldest valid player
//

module tournament_tree_top2 #(
    parameter int unsigned ID_SIZE   = 8,
    parameter int unsigned NR_PLAYER = 16
) (
    input  logic [NR_PLAYER-1:0]                         valid_i,
    input  logic [NR_PLAYER-1:0][ID_SIZE-1:0]            seq_num_i,
    input  logic [NR_PLAYER-1:0][$clog2(NR_PLAYER)-1:0]  id_i,

    output logic [1:0][$clog2(NR_PLAYER)-1:0]            winner_o,
    output logic [1:0]                                   winner_valid_o
);

  localparam int unsigned ID_WIDTH  = $clog2(NR_PLAYER);
  localparam int unsigned TREE_SIZE = 2 * NR_PLAYER;

  // Best candidate of each subtree.
  logic [TREE_SIZE-1:0][ID_SIZE-1:0]  first_seq;
  logic [TREE_SIZE-1:0][ID_WIDTH-1:0] first_id;
  logic [TREE_SIZE-1:0]               first_valid;

  // Second best candidate of each subtree.
  logic [TREE_SIZE-1:0][ID_SIZE-1:0]  second_seq;
  logic [TREE_SIZE-1:0][ID_WIDTH-1:0] second_id;
  logic [TREE_SIZE-1:0]               second_valid;


  // --------------------------------------------------------------------------
  // Circular age comparison.
  //
  // Returns 1 when seq_a is older than seq_b.
  // Same behavior as the comparison used by the original tournament tree.
  // --------------------------------------------------------------------------
  function automatic logic is_older(
      input logic [ID_SIZE-1:0] seq_a,
      input logic [ID_SIZE-1:0] seq_b
  );
    logic signed [ID_SIZE-1:0] diff;
    begin
      diff = seq_b - seq_a;

      is_older =
          (diff[ID_SIZE-1] == 1'b0) &&
          (diff != '0);
    end
  endfunction


  always_comb begin : top2_tournament

    first_seq    = '0;
    first_id     = '0;
    first_valid  = '0;

    second_seq   = '0;
    second_id    = '0;
    second_valid = '0;


    // ------------------------------------------------------------------------
    // Leaves
    // ------------------------------------------------------------------------
    for (int i = NR_PLAYER; i < TREE_SIZE; i++) begin
      first_seq[i]   = seq_num_i[i-NR_PLAYER];
      first_id[i]    = id_i[i-NR_PLAYER];
      first_valid[i] = valid_i[i-NR_PLAYER];

      // A leaf contains only one candidate.
      second_seq[i]   = '0;
      second_id[i]    = '0;
      second_valid[i] = 1'b0;
    end


    // ------------------------------------------------------------------------
    // Tree reduction
    //
    // Each node receives:
    //
    //   left  : L0 = oldest left
    //           L1 = second-oldest left
    //
    //   right : R0 = oldest right
    //           R1 = second-oldest right
    //
    // If L0 wins:
    //
    //   first  = L0
    //   second = oldest(L1, R0)
    //
    // If R0 wins:
    //
    //   first  = R0
    //   second = oldest(L0, R1)
    //
    // ------------------------------------------------------------------------
    for (int i = NR_PLAYER-1; i > 0; i--) begin

      // No valid element on left
      if (!first_valid[2*i]) begin

        first_seq[i]    = first_seq[2*i+1];
        first_id[i]     = first_id[2*i+1];
        first_valid[i]  = first_valid[2*i+1];

        second_seq[i]   = second_seq[2*i+1];
        second_id[i]    = second_id[2*i+1];
        second_valid[i] = second_valid[2*i+1];


      // No valid element on right
      end else if (!first_valid[2*i+1]) begin

        first_seq[i]    = first_seq[2*i];
        first_id[i]     = first_id[2*i];
        first_valid[i]  = first_valid[2*i];

        second_seq[i]   = second_seq[2*i];
        second_id[i]    = second_id[2*i];
        second_valid[i] = second_valid[2*i];


      // L0 is older than R0
      end else if (is_older(first_seq[2*i],
                            first_seq[2*i+1])) begin

        first_seq[i]   = first_seq[2*i];
        first_id[i]    = first_id[2*i];
        first_valid[i] = 1'b1;

        // Second = oldest(L1, R0)
        if (!second_valid[2*i]) begin

          second_seq[i]   = first_seq[2*i+1];
          second_id[i]    = first_id[2*i+1];
          second_valid[i] = first_valid[2*i+1];

        end else if (is_older(second_seq[2*i],
                              first_seq[2*i+1])) begin

          second_seq[i]   = second_seq[2*i];
          second_id[i]    = second_id[2*i];
          second_valid[i] = 1'b1;

        end else begin

          second_seq[i]   = first_seq[2*i+1];
          second_id[i]    = first_id[2*i+1];
          second_valid[i] = 1'b1;

        end


      // R0 is older than L0
      end else begin

        first_seq[i]   = first_seq[2*i+1];
        first_id[i]    = first_id[2*i+1];
        first_valid[i] = 1'b1;

        // Second = oldest(L0, R1)
        if (!second_valid[2*i+1]) begin

          second_seq[i]   = first_seq[2*i];
          second_id[i]    = first_id[2*i];
          second_valid[i] = first_valid[2*i];

        end else if (is_older(first_seq[2*i],
                              second_seq[2*i+1])) begin

          second_seq[i]   = first_seq[2*i];
          second_id[i]    = first_id[2*i];
          second_valid[i] = 1'b1;

        end else begin

          second_seq[i]   = second_seq[2*i+1];
          second_id[i]    = second_id[2*i+1];
          second_valid[i] = 1'b1;

        end
      end
    end


    // Root results
    winner_o[0]       = first_id[1];
    winner_valid_o[0] = first_valid[1];

    winner_o[1]       = second_id[1];
    winner_valid_o[1] = second_valid[1];

  end

endmodule
