// Boardless Ti60F225 resource proxy for Case-1.
//
// This is intentionally a small, synthesizable Verilog-2001 proxy rather than
// a board wrapper.  It keeps the resource questions separate from DDR3,
// MIPI/HDMI, PLL and pin/IP generation.  The datapath mirrors one production
// Case-1 compute beat: eight output channels, eight signed INT8 MACs per
// channel, a registered result, four local 128-bit tile-memory banks, and a
// tiny four-entry outstanding read bookkeeping path.  It is a lower-bound /
// sensitivity probe, not a claim that the complete board design fits.
module c1_ti60_ebr_bank (
    input  wire         clk,
    input  wire         rst,
    input  wire         we,
    input  wire         re,
    input  wire [7:0]   waddr,
    input  wire [7:0]   raddr,
    input  wire [127:0] wdata,
    output reg  [127:0] rdata
);
    // Exact synchronous template used by the Efinix generated FIFO wrapper.
    (* syn_ramstyle = "block_ram", keep = "true" *) reg [127:0] ram [255:0];
    reg [127:0] rdata_1p;
    always @(posedge clk) begin
        if (we)
            ram[waddr] <= wdata;
    end
    always @(posedge clk) begin
        if (rst) begin
            rdata_1p <= 128'd0;
            rdata <= 128'd0;
        end else begin
            if (re)
                rdata_1p <= ram[raddr];
            rdata <= rdata_1p;
        end
    end
endmodule

module c1_ti60_resource_proxy (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire         in_valid,
    input  wire         in_last,
    input  wire [63:0]  activations_s8,
    input  wire [511:0] weights_s8,
    input  wire [255:0] bias_s32,
    input  wire         tile_we,
    input  wire [7:0]   tile_waddr,
    input  wire [127:0] tile_wdata,
    output reg          busy,
    output reg          done,
    output reg [31:0]   checksum,
    output reg [3:0]    outstanding_count,
    output wire [31:0]  tile_observe
);

    // Four independently addressed banks model the local line/tile cache
    // around an AXI128 interface.  4 x 256 x 128 bits is deliberately modest
    // so this probe completes quickly while still exercising Ti60 EBR inference.
    wire [127:0] tile_q0, tile_q1, tile_q2, tile_q3;
    reg [7:0] tile_raddr0, tile_raddr1, tile_raddr2, tile_raddr3;

    // A four-slot tag/age ring represents the control state needed to keep
    // multiple DDR bursts in flight.  It is intentionally independent of the
    // vendor DDR controller and therefore portable to Icarus/Vivado.
    reg [7:0] outstanding_age;
    reg [1:0] outstanding_head;
    reg [1:0] outstanding_tail;

    reg signed [31:0] dot_comb [0:7];
    reg signed [255:0] dot_q_bus;
    reg signed [15:0] prod_tmp;
    reg [7:0] iteration_q;
    reg active_q;
    integer oc;
    integer lane;

    // The explicit loops are constant-bound after elaboration.  Efinity can
    // map the signed 8x8 products to Ti60 DSP blocks; Vivado/Icarus can use
    // the same source for a boardless sanity check.
    always @* begin
        for (oc = 0; oc < 8; oc = oc + 1) begin
            dot_comb[oc] = $signed(bias_s32[oc*32 +: 32]);
            for (lane = 0; lane < 8; lane = lane + 1) begin
                prod_tmp = $signed(activations_s8[lane*8 +: 8]) *
                           $signed(weights_s8[(oc*8+lane)*8 +: 8]);
                dot_comb[oc] = dot_comb[oc] + prod_tmp;
            end
        end
    end

    assign tile_observe = tile_q0[31:0] ^ tile_q1[31:0] ^
                          tile_q2[31:0] ^ tile_q3[31:0];

    c1_ti60_ebr_bank u_tile_bank0 (.clk(clk), .rst(rst), .we(tile_we),
        .re(1'b1), .waddr(tile_waddr), .raddr(tile_raddr0),
        .wdata(tile_wdata), .rdata(tile_q0));
    c1_ti60_ebr_bank u_tile_bank1 (.clk(clk), .rst(rst), .we(tile_we),
        .re(1'b1), .waddr(tile_waddr), .raddr(tile_raddr1),
        .wdata(tile_wdata ^ 128'h0001), .rdata(tile_q1));
    c1_ti60_ebr_bank u_tile_bank2 (.clk(clk), .rst(rst), .we(tile_we),
        .re(1'b1), .waddr(tile_waddr), .raddr(tile_raddr2),
        .wdata(tile_wdata ^ 128'h0002), .rdata(tile_q2));
    c1_ti60_ebr_bank u_tile_bank3 (.clk(clk), .rst(rst), .we(tile_we),
        .re(1'b1), .waddr(tile_waddr), .raddr(tile_raddr3),
        .wdata(tile_wdata ^ 128'h0004), .rdata(tile_q3));

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            checksum <= 32'd0;
            iteration_q <= 8'd0;
            active_q <= 1'b0;
            outstanding_count <= 4'd0;
            outstanding_head <= 2'd0;
            outstanding_tail <= 2'd0;
            tile_raddr0 <= 8'd0;
            tile_raddr1 <= 8'd17;
            tile_raddr2 <= 8'd43;
            tile_raddr3 <= 8'd91;
            dot_q_bus <= 256'd0;
            outstanding_age <= 8'd0;
        end else begin
            done <= 1'b0;
            tile_raddr0 <= tile_raddr0 + 8'd1;
            tile_raddr1 <= tile_raddr1 + 8'd1;
            tile_raddr2 <= tile_raddr2 + 8'd1;
            tile_raddr3 <= tile_raddr3 + 8'd1;

            // Allocate one outstanding slot on each accepted input beat and
            // retire the oldest slot on the following beat.  This exercises
            // the bookkeeping muxes without instantiating a DDR PHY.
            if (in_valid && outstanding_count != 4'd4) begin
                outstanding_age[outstanding_tail*2 +: 2] <= 2'd3;
                outstanding_tail <= outstanding_tail + 2'd1;
                outstanding_count <= outstanding_count + 4'd1;
            end else if (outstanding_count != 4'd0) begin
                outstanding_age[outstanding_head*2 +: 2] <=
                    outstanding_age[outstanding_head*2 +: 2] - 2'd1;
                if (outstanding_age[outstanding_head*2 +: 2] == 2'd0) begin
                    outstanding_head <= outstanding_head + 2'd1;
                    outstanding_count <= outstanding_count - 4'd1;
                end
            end

            if (start) begin
                busy <= 1'b1;
                active_q <= 1'b1;
                iteration_q <= 8'd0;
            end
            if (active_q && in_valid) begin
                for (oc = 0; oc < 8; oc = oc + 1)
                    dot_q_bus[oc*32 +: 32] <= dot_comb[oc];
                iteration_q <= iteration_q + 8'd1;
                checksum <= checksum ^ dot_comb[0] ^ dot_comb[1] ^
                            dot_comb[2] ^ dot_comb[3] ^ dot_comb[4] ^
                            dot_comb[5] ^ dot_comb[6] ^ dot_comb[7] ^
                            tile_observe ^ {24'd0, iteration_q};
                if (in_last) begin
                    active_q <= 1'b0;
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

endmodule
