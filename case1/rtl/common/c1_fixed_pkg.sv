`timescale 1ns/1ps

package c1_fixed_pkg;

    // Signed round-to-nearest with ties away from zero.  This definition is
    // mirrored exactly by golden/style_pipeline.py.
    function automatic logic signed [31:0] c1_round_shift_s32(
        input logic signed [31:0] value,
        input logic        [4:0]  shift
    );
        logic signed [32:0] extended;
        logic signed [32:0] magnitude;
        logic signed [32:0] rounded;
        begin
            extended = {value[31], value};
            if (shift == 0) begin
                rounded = extended;
            end else if (extended < 0) begin
                magnitude = -extended;
                rounded = -((magnitude + (33'sd1 <<< (shift - 1'b1))) >>> shift);
            end else begin
                rounded = (extended + (33'sd1 <<< (shift - 1'b1))) >>> shift;
            end
            c1_round_shift_s32 = rounded[31:0];
        end
    endfunction

    function automatic logic [7:0] c1_clamp_u8(
        input logic signed [31:0] value
    );
        begin
            if (value < 0)
                c1_clamp_u8 = 8'd0;
            else if (value > 32'sd255)
                c1_clamp_u8 = 8'd255;
            else
                c1_clamp_u8 = value[7:0];
        end
    endfunction

endpackage

