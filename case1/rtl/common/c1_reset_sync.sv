`timescale 1ns/1ps

// Asynchronously asserted, synchronously released active-low reset.
// Instantiate one copy per clock domain.  arst_n may assert without clk;
// srst_n only deasserts after STAGES consecutive rising edges.
module c1_reset_sync #(
    parameter integer STAGES = 2
) (
    input  logic clk,
    input  logic arst_n,
    output logic srst_n
);

    (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_ff;

    initial begin
        if (STAGES < 2)
            $error("c1_reset_sync requires STAGES >= 2");
    end

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            sync_ff <= '0;
        else
            sync_ff <= {sync_ff[STAGES-2:0], 1'b1};
    end

    // Keep reset asserted even before the first destination clock when the
    // external reset starts low. Release still requires the full synchronizer
    // sequence; no asynchronous deassertion path is introduced.
    assign srst_n = arst_n && sync_ff[STAGES-1];

endmodule
