`timescale 1ns/1ps
// Simulation workload source, NOT a camera/HDMI/CPU RTL implementation.
// Issues actual AXI transactions; each burst drains at bus speed, and the
// period paces burst admission (models a buffered/prefetching consumer).
module c1_r2_axi_traffic_agent (
    input wire clk,rst,start,stop,
    input wire [31:0] cfg_base,cfg_words,cfg_period,
    input wire [1:0] cfg_mode, // 0 write, 1 read, 2 alternating write/read
    input wire cfg_repeat,
    output logic active,finished,error,
    output wire [31:0] write_address,
    input wire [127:0] write_value,
    output wire read_check,
    output wire [31:0] read_address,
    output wire [127:0] read_value,
    output integer bursts,read_beats,write_beats,max_late,
    output wire [31:0] araddr,awaddr,
    output wire [7:0] arlen,awlen,
    output wire [2:0] arsize,awsize,
    output wire [1:0] arburst,awburst,
    output wire arvalid,awvalid,
    input wire arready,awready,
    input wire [127:0] rdata,
    input wire [1:0] rresp,bresp,
    input wire rlast,rvalid,bvalid,
    output wire rready,bready,
    output wire [127:0] wdata,
    output wire [15:0] wstrb,
    output wire wlast,wvalid,
    input wire wready
);
    localparam WAIT=0,READ=1,WRITE=2;
    logic [1:0] state,mode_q;
    logic address_done,read_direction,repeat_q;
    logic [31:0] base_q,total_q,offset_q,period_q,address_q;
    integer cycle=0,due=0,length_q=1,position=0;
    assign araddr=address_q;assign awaddr=address_q;
    assign arlen=length_q-1;assign awlen=length_q-1;
    assign arsize=4;assign awsize=4;assign arburst=1;assign awburst=1;
    assign arvalid=!rst && active && state==READ && !address_done;
    assign awvalid=!rst && active && state==WRITE && !address_done;
    assign rready=!rst && active && state==READ;
    assign wvalid=!rst && active && state==WRITE && position<length_q;
    assign wdata=write_value;assign wstrb=16'hffff;assign wlast=position==length_q-1;
    assign bready=!rst && active && state==WRITE && address_done && position==length_q;
    assign write_address=address_q+position*32'd16;
    assign read_check=rvalid && rready;
    assign read_address=address_q+position*32'd16;assign read_value=rdata;
    wire read_end=read_check && (rlast || position==length_q-1);
    wire write_end=bvalid && bready;
    wire read_bad=read_check && (rresp!=0 || rlast!=(position==length_q-1));
    wire write_bad=write_end && bresp!=0;
    always @(posedge clk) begin : agent
        integer n,page;
        if(rst) begin
            active<=0;finished<=0;error<=0;state<=WAIT;address_done<=0;cycle<=0;
            base_q<=0;total_q<=0;offset_q<=0;period_q<=0;address_q<=0;mode_q<=0;read_direction<=0;repeat_q<=0;
            bursts<=0;read_beats<=0;write_beats<=0;max_late<=0;position<=0;length_q<=1;due<=0;
        end else begin
            cycle<=cycle+1;finished<=0;
            if(start && !active) begin
                if(cfg_words==0 || cfg_base[3:0]!=0 || cfg_mode>2) $fatal(1,"traffic source configuration");
                active<=1;error<=0;base_q<=cfg_base;total_q<=cfg_words;offset_q<=0;period_q<=cfg_period;
                mode_q<=cfg_mode;read_direction<=cfg_mode==1;repeat_q<=cfg_repeat;
                state<=WAIT;due<=cycle;bursts<=0;read_beats<=0;write_beats<=0;max_late<=0;
            end
            if(active && state==WAIT) begin
                if(stop || error) begin active<=0;finished<=1;end
                else if(cycle>=due) begin
                    n=total_q-offset_q;if(n>16)n=16;
                    page=256-((base_q+offset_q*32'd16)&4095)/16;if(n>page)n=page;
                    address_q<=base_q+offset_q*32'd16;length_q<=n;position<=0;address_done<=0;
                    state<=read_direction ? READ : WRITE;
                    if(cycle-due>max_late) max_late<=cycle-due;
                end
            end
            if(arvalid && arready || awvalid && awready) address_done<=1;
            if(wvalid && wready) begin position<=position+1;write_beats<=write_beats+1;end
            if(read_check) begin position<=position+1;read_beats<=read_beats+1;end
            if(read_bad || write_bad) error<=1;
            if(read_end || write_end) begin
                bursts<=bursts+1;state<=WAIT;due<=due+period_q;
                if(mode_q==2 && write_end) begin
                    // Read back the same physical words before advancing.
                end else if(offset_q+length_q==total_q) begin
                    offset_q<=0;
                    if(!repeat_q) begin active<=0;finished<=1;end
                end else offset_q<=offset_q+length_q;
                if(mode_q==2) read_direction<=!read_direction;
            end
        end
    end
endmodule
