`timescale 1ns/1ps
// C11 autonomous-video control ABI R2V1, not C10's R2C1 job ABI.
// Disable stops admissions only. Existing frames/AXI debts still drain.
module c1_r2_video_csr #(
    parameter integer WIDTH=640,HEIGHT=480,
    parameter logic [31:0] ARENA_BASE=32'h08000000
) (
    input wire clk,rst,psel,penable,pwrite,
    input wire [7:0] paddr,
    input wire [31:0] pwdata,
    input wire [3:0] pstrb,
    output logic [31:0] prdata,
    output wire pready,
    output logic pslverr,
    output logic enabled,
    output logic [2:0] request_enable,
    output wire irq,
    input wire platform_ready,fabric_error,lease_error,cap_active,nn_active,display_active,front_valid,
    input wire cap_event,cap_bad,nn_event,nn_bad,display_event,display_bad,overflow_event,underflow_event,
    input wire [31:0] nn_cycles,nn_tag,dropped_captures,retired_pairs,
    input wire [7:0] read_outstanding,write_outstanding,
    output logic [31:0] capture_count,nn_count,display_count,underflow_count,
    output logic [31:0] last_nn_cycles,last_nn_tag
);
    logic [3:0] irq_status,irq_enable;
    wire access=!rst && psel && penable;
    wire wr=access && pwrite;
    wire [31:0] byte_mask={{8{pstrb[3]}},{8{pstrb[2]}},{8{pstrb[1]}},{8{pstrb[0]}}};
    wire [3:0] events={fabric_error||lease_error,overflow_event||underflow_event,
        (cap_event&&cap_bad)||(nn_event&&nn_bad)||(display_event&&display_bad),nn_event};
    wire [3:0] clear_irq=wr && paddr==8'h30 && !pslverr && pstrb[0] ? pwdata[3:0] : 0;
    assign pready=!rst;assign irq=|(irq_status&irq_enable);
    always_comb begin
        prdata=0;pslverr=0;
        case(paddr)
            8'h00:prdata=32'h52325631;
            8'h04:prdata=32'h00010000;
            8'h08:prdata={28'd0,request_enable,enabled}; // global,capture,NN,display
            8'h0c:prdata={25'd0,lease_error,fabric_error,platform_ready,front_valid,display_active,nn_active,cap_active};
            8'h10:prdata=nn_count;8'h14:prdata=last_nn_cycles;8'h18:prdata=last_nn_tag;
            8'h1c:prdata=dropped_captures;8'h20:prdata=capture_count;8'h24:prdata=display_count;8'h28:prdata=underflow_count;
            8'h2c:prdata={16'd0,read_outstanding,write_outstanding};
            8'h30:prdata={28'd0,irq_status};8'h34:prdata={28'd0,irq_enable};
            8'h38:prdata={16'(HEIGHT),16'(WIDTH)};8'h3c:prdata=ARENA_BASE;8'h40:prdata=retired_pairs;
            default:pslverr=1;
        endcase
        if(pwrite)case(paddr)
            8'h08:if((pwdata&byte_mask&32'hfffffff0)!=0)pslverr=1;
            8'h30,8'h34:if((pwdata&byte_mask&32'hfffffff0)!=0)pslverr=1;
            default:pslverr=1;
        endcase
        pslverr=access && pslverr;
    end
    always_ff @(posedge clk)begin
        if(rst)begin enabled<=0;request_enable<=0;irq_status<=0;irq_enable<=0;capture_count<=0;nn_count<=0;display_count<=0;underflow_count<=0;last_nn_cycles<=0;last_nn_tag<=0;end
        else begin
            irq_status<=(irq_status&~clear_irq)|events;
            if(wr&&!pslverr&&pstrb[0])case(paddr)
                8'h08:begin enabled<=pwdata[0];request_enable<=pwdata[3:1];end
                8'h34:irq_enable<=pwdata[3:0];default:begin end
            endcase
            if(cap_event&&!cap_bad)capture_count<=capture_count+1'b1;
            if(nn_event&&!nn_bad)begin nn_count<=nn_count+1'b1;last_nn_cycles<=nn_cycles;last_nn_tag<=nn_tag;end
            if(display_event&&!display_bad)display_count<=display_count+1'b1;
            if(underflow_event)underflow_count<=underflow_count+1'b1;
        end
    end
endmodule
