// Portable one-read/one-write synchronous RAM with defined read-first
// behaviour when both ports address the same location in one cycle.
`timescale 1ns/1ps

module c1_ram_sdp_read_first #(
    parameter integer DATA_WIDTH = 8,
    parameter integer DEPTH = 640,
    parameter integer ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  logic                  clk,
    input  logic                  rd_en,
    input  logic [ADDR_WIDTH-1:0] rd_addr,
    output logic [DATA_WIDTH-1:0] rd_data,
    input  logic                  wr_en,
    input  logic [ADDR_WIDTH-1:0] wr_addr,
    input  logic [DATA_WIDTH-1:0] wr_data
);
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

`ifndef SYNTHESIS
    initial begin
        if(DATA_WIDTH<1)
            $fatal(1,"c1_ram_sdp_read_first DATA_WIDTH must be positive");
        if(DEPTH<1)
            $fatal(1,"c1_ram_sdp_read_first DEPTH must be positive");
        if(ADDR_WIDTH<1 || ADDR_WIDTH<$clog2(DEPTH))
            $fatal(1,"c1_ram_sdp_read_first ADDR_WIDTH cannot address DEPTH");
    end
`endif

    always_ff @(posedge clk) begin
        if (rd_en)
            rd_data <= mem[rd_addr];
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end
endmodule
