`timescale 1ns/1ps
// REJECTED C20 experiment: Efinity EFX-0680 on RE/WE controls. Even with
// inference repaired, Ti60 TDP is <=10 bits/port, so naive pairing does not
// halve physical RAM. Kept only to explain the failed experiment, not for use.
// Two independent synchronous readers OR one writer, never simultaneous.
// Logical bank parity occupies address bit 6. During load, port A writes
// either bank; during compute, A reads the even bank and B the odd bank.
// This explicitly reuses port A's address rather than describing a 3-port
// memory and relying on synthesis to prove mutually exclusive accesses.
module c1_r2_weight_pair_ram (
    input wire clk,read_en,write_en,
    input wire [5:0] even_addr,odd_addr,
    input wire [6:0] write_addr,
    input wire [31:0] write_data,
    output logic [31:0] even_data,odd_data
);
    logic [31:0] mem[0:127];
    wire [6:0] port_a_addr=write_en ? write_addr : {1'b0,even_addr};
    always_ff @(posedge clk)begin
        if(write_en)mem[port_a_addr]<=write_data;
        else if(read_en)even_data<=mem[port_a_addr];
    end
    always_ff @(posedge clk)begin
        if(read_en)odd_data<=mem[{1'b1,odd_addr}];
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(read_en && write_en)
        $fatal(1,"R2 paired weight RAM cannot load and read concurrently");
`endif
endmodule
