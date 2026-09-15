`timescale 1ns/1ps
// Synchronous-RAM FIFO. Two output slots + one read reservation; occupancy
// includes all three locations. Read reservations share the two output credits,
// so a stalled output is never overwritten. Steady-state II=1 word.
// Reset is a LOCAL flush, never an AXI cancellation mechanism.
module c1_r2_video_bram_fifo #(
    parameter integer WIDTH=48,DEPTH=512,
    parameter integer LW=$clog2(DEPTH+1)
) (
    input wire clk,rst,in_valid,
    output wire in_ready,
    input wire [WIDTH-1:0] in_data,
    output wire out_valid,
    input wire out_ready,
    output wire [WIDTH-1:0] out_data,
    output logic [LW-1:0] level
);
    localparam AW=$clog2(DEPTH);
    logic [AW-1:0] wr,rd;
    logic [LW-1:0] stored;
    logic pending;
    logic [WIDTH-1:0] stage[0:1];
    logic head,tail;
    logic [1:0] staged;
    assign out_valid=!rst && staged!=0;
    assign out_data=stage[head];
    wire pop=!rst && out_valid && out_ready;
    assign in_ready=!rst && (level<DEPTH || pop);
    wire push=in_valid && in_ready;
    wire fetch=!rst && (staged+int'(pending)<2 || pop) && stored!=0;
    wire [WIDTH-1:0] ram_data;
    c1_ram_sdp_read_first #(.DATA_WIDTH(WIDTH),.DEPTH(DEPTH)) u_ram (
        .clk(clk),.rd_en(fetch),.rd_addr(rd),.rd_data(ram_data),
        .wr_en(push),.wr_addr(wr),.wr_data(in_data)
    );
    function automatic [AW-1:0] next_ptr(input [AW-1:0] p);
        next_ptr=p==DEPTH-1 ? 0 : p+1'b1;
    endfunction
    always_ff @(posedge clk) begin
        if(rst) begin wr<=0;rd<=0;stored<=0;level<=0;pending<=0;head<=0;tail<=0;staged<=0;end
        else begin
            if(pop) head<=!head;
            if(pending) begin stage[tail]<=ram_data;tail<=!tail;end
            case({pending,pop}) 2'b10:staged<=staged+1'b1;2'b01:staged<=staged-1'b1;default:begin end endcase
            pending<=fetch;
            if(push) wr<=next_ptr(wr);
            if(fetch) rd<=next_ptr(rd);
            case({push,fetch}) 2'b10:stored<=stored+1'b1;2'b01:stored<=stored-1'b1;default:begin end endcase
            case({push,pop}) 2'b10:level<=level+1'b1;2'b01:level<=level-1'b1;default:begin end endcase
        end
    end
`ifndef SYNTHESIS
    initial if(DEPTH<4 || WIDTH<1 || LW<$clog2(DEPTH+1)) $fatal(1,"video FIFO parameters");
    always @(posedge clk) if(!rst) begin
        if(level>DEPTH || stored+int'(pending)+int'(staged)!=level) $fatal(1,"video FIFO occupancy");
        if(staged+int'(pending)>2) $fatal(1,"video FIFO reservation overflow");
    end
`endif
endmodule
