`timescale 1ns/1ps

// Independent row memories: one synchronous read per bank per clock, and a
// shared refill address/data bus with per-bank write enables. No reset or row
// validity is implied here; the cache controller owns tags and maintenance.
// Packed lane b is [b*WIDTH +: WIDTH]. Disabled reads hold their last value.
module c1_row_banked_ram #(
    parameter integer DATA_WIDTH = 64,
    parameter integer ROWS = 3,
    parameter integer ROW_WORDS = 1280,
    parameter integer ADDR_WIDTH = (ROW_WORDS <= 1) ? 1 : $clog2(ROW_WORDS)
) (
    input logic clk,
    input logic [ROWS-1:0] rd_en,
    input logic [ROWS*ADDR_WIDTH-1:0] rd_addr,
    output wire [ROWS*DATA_WIDTH-1:0] rd_data,
    input logic [ROWS-1:0] wr_en,
    input logic [ADDR_WIDTH-1:0] wr_addr,
    input logic [DATA_WIDTH-1:0] wr_data
);
    for (genvar bank=0; bank<ROWS; bank++) begin : g_row
        c1_ram_sdp_read_first #(
            .DATA_WIDTH(DATA_WIDTH), .DEPTH(ROW_WORDS), .ADDR_WIDTH(ADDR_WIDTH)
        ) u_ram (
            .clk(clk), .rd_en(rd_en[bank]),
            .rd_addr(rd_addr[bank*ADDR_WIDTH +: ADDR_WIDTH]),
            .rd_data(rd_data[bank*DATA_WIDTH +: DATA_WIDTH]),
            .wr_en(wr_en[bank]), .wr_addr(wr_addr), .wr_data(wr_data)
        );
`ifndef SYNTHESIS
        always @(posedge clk) begin
            // An X enable is silently treated as false by a procedural if.
            // Reject it instead of masking an uninitialized controller/CDC.
            // Unknown addresses remain legal while that port is disabled.
            if ($isunknown(rd_en[bank]))
                $fatal(1,"row-banked RAM read enable unknown");
            if ($isunknown(wr_en[bank]))
                $fatal(1,"row-banked RAM write enable unknown");
            if(rd_en[bank] && ($isunknown(rd_addr[bank*ADDR_WIDTH +: ADDR_WIDTH]) ||
                rd_addr[bank*ADDR_WIDTH +: ADDR_WIDTH] >= ROW_WORDS))
                $fatal(1,"row-banked RAM read address out of range");
            if(wr_en[bank] && ($isunknown(wr_addr) || wr_addr >= ROW_WORDS))
                $fatal(1,"row-banked RAM write address out of range");
        end
`endif
    end
`ifndef SYNTHESIS
    initial if(ROWS<1) $fatal(1,"row-banked RAM ROWS must be positive");
`endif
endmodule
