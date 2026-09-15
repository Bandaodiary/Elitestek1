`timescale 1ns/1ps
// C20 candidate. Four narrow writes form one synchronous wide read.
// Read/write ownership is exclusive in the parameter store; no collision
// semantics are promised. No reset/initialization of SRAM or read output.
module c1_r2_weight_asym_ram #(
    parameter integer BITS=5
) (
    input wire clk,read_en,write_en,
    input wire [8:0] read_addr,
    input wire [10:0] write_addr,
    input wire [BITS-1:0] write_data,
    output logic [4*BITS-1:0] read_data
);
    logic [BITS-1:0] mem [0:2047];
    always_ff @(posedge clk) begin
        if(write_en) mem[write_addr]<=write_data;
        if(read_en)
            for(integer word_id=0;word_id<4;word_id=word_id+1)
                read_data[word_id*BITS+:BITS]<=mem[{read_addr,2'b00}+word_id];
    end
endmodule
