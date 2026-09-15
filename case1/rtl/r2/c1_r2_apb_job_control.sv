`timescale 1ns/1ps
// C10, new R2 ABI (not the R1 CSR map). APB4, 32-bit, little endian.
// START snapshots all shadow registers. DISCARD suppresses publication but
// does not reset/abort the live C9 engine: it completes/drains the owned frame.
// CPU must ACK the result and the consumer must take the publication before
// the next job. Display/capture leases protect whole 8MiB slots at submission;
// external DMA owners must keep leases valid while accessing their buffers.
module c1_r2_apb_job_control (
    input wire clk,rst,psel,penable,pwrite,
    input wire [7:0] paddr,
    input wire [31:0] pwdata,
    input wire [3:0] pstrb,
    output logic [31:0] prdata,
    output wire pready,
    output logic pslverr,
    output wire irq,busy,
    input wire fabric_error,capture_busy,display_busy,
    input wire [31:0] capture_base,display_base,
    output wire graph_start_valid,
    input wire graph_start_ready,graph_done_valid,graph_done_error,
    output wire graph_done_ready,
    input wire [31:0] graph_cycles,
    input wire [4:0] active_stage,
    input wire [7:0] read_outstanding,write_outstanding,
    output wire [10:0] frame_width,
    output wire [9:0] frame_height,
    output wire [31:0] input_base,workspace_base,output_base,parameter_base,
    output logic publish_valid,
    input wire publish_ready,
    output wire [31:0] publish_base,publish_tag,
    output wire [10:0] publish_width,
    output wire [9:0] publish_height
);
    logic [31:0] shadow[0:5],job[0:5];
    logic owned,pending,discard_q,result_valid,result_error,result_discard;
    logic [31:0] result_cycles,result_tag;
    logic [2:0] irq_enable,irq_status;
    wire access=psel && penable && !rst;
    wire write_access=access && pwrite;
    wire [31:0] byte_mask={{8{pstrb[3]}},{8{pstrb[2]}},{8{pstrb[1]}},{8{pstrb[0]}}};
    wire [2:0] command=pstrb[0] ? pwdata[2:0] : 3'd0;
    wire [8:0] ib=shadow[0][31:23],wb=shadow[1][31:23],ob=shadow[2][31:23],pb=shadow[3][31:23];
    wire [8:0] cb=capture_base[31:23],db=display_base[31:23];
    wire capture_collision=capture_busy && (cb==ib || cb==ob || cb==pb || (cb>=wb && {1'b0,cb}<={1'b0,wb}+2));
    wire display_collision=display_busy && (db==ob || (db>=wb && {1'b0,db}<={1'b0,wb}+2));
    // Reserved shape bits are rejected, not silently truncated.
    wire shape_bits_legal=(shadow[4] & 32'hfc00f800)==0;
    wire can_start=!owned && !result_valid && !publish_valid && !fabric_error &&
                   !capture_collision && !display_collision && shape_bits_legal && graph_start_ready;
    assign pready=!rst;assign irq=|(irq_enable & irq_status);assign busy=owned;
    assign graph_start_valid=!rst && pending;
    assign graph_done_ready=!rst && owned && !pending;
    assign input_base=owned ? job[0] : shadow[0];assign workspace_base=owned ? job[1] : shadow[1];
    assign output_base=owned ? job[2] : shadow[2];assign parameter_base=owned ? job[3] : shadow[3];
    assign frame_width=owned ? job[4][10:0] : shadow[4][10:0];
    assign frame_height=owned ? job[4][25:16] : shadow[4][25:16];
    assign publish_base=job[2];assign publish_tag=job[5];
    assign publish_width=job[4][10:0];assign publish_height=job[4][25:16];
    wire complete=graph_done_valid && graph_done_ready;
    wire discard_now=write_access && paddr==8'h10 && command==2 && !pslverr;
    wire [2:0] events={complete && (discard_q || discard_now),(complete && graph_done_error) || fabric_error,complete};
    wire [2:0] irq_clear=write_access && paddr==8'h1c && !pslverr && pstrb[0] ? pwdata[2:0] : 3'd0;
    always_comb begin
        prdata=0;pslverr=0;
        case(paddr)
            8'h00:prdata=32'h52324331;
            8'h04:prdata=32'h00010000;
            8'h08:prdata=32'h00000407; // P2C8, frozen graph, deferred discard, 4 slots
            8'h10:prdata=0;
            8'h14:prdata={22'd0,display_collision,capture_collision,fabric_error,can_start,publish_valid,result_discard,result_error,result_valid,pending,owned};
            8'h18:prdata={29'd0,irq_enable};
            8'h1c:prdata={29'd0,irq_status};
            8'h20,8'h24,8'h28,8'h2c,8'h30,8'h34:prdata=shadow[(paddr-8'h20)>>2];
            8'h38:prdata=result_cycles;
            8'h3c:prdata=result_tag;
            8'h40:prdata={11'd0,active_stage,read_outstanding,write_outstanding};
            default:pslverr=1;
        endcase
        if(pwrite) begin
            case(paddr)
                8'h10:begin
                    if((pwdata & byte_mask & 32'hfffffff8)!=0 || (command!=0 && command!=1 && command!=2 && command!=4)) pslverr=1;
                    else if(command==1 && !can_start) pslverr=1;
                    // DISCARD is an idle no-op: software cannot prevent a
                    // natural completion between its STATUS read and write.
                    else if(command==4 && !result_valid) pslverr=1;
                end
                8'h18,8'h1c:if((pwdata & byte_mask & 32'hfffffff8)!=0) pslverr=1;
                8'h20,8'h24,8'h28,8'h2c,8'h30,8'h34:begin end
                default:pslverr=1;
            endcase
        end
        pslverr=access && pslverr;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            owned<=0;pending<=0;discard_q<=0;result_valid<=0;result_error<=0;result_discard<=0;
            result_cycles<=0;result_tag<=0;publish_valid<=0;irq_enable<=0;irq_status<=0;
            for(integer i=0;i<6;i=i+1) begin shadow[i]<=0;job[i]<=0;end
        end else begin
            irq_status<=(irq_status & ~irq_clear) | events; // event wins over W1C
            if(publish_valid && publish_ready) publish_valid<=0;
            if(graph_start_valid && graph_start_ready) pending<=0;
            if(write_access && !pslverr) begin
                case(paddr)
                    8'h10:begin
                        if(command==1) begin
                            for(integer i=0;i<6;i=i+1) job[i]<=shadow[i];
                            owned<=1;pending<=1;discard_q<=0;
                        end
                        if(command==2 && owned) discard_q<=1;
                        if(command==4) result_valid<=0;
                    end
                    8'h18:if(pstrb[0]) irq_enable<=pwdata[2:0];
                    8'h20,8'h24,8'h28,8'h2c,8'h30,8'h34:
                        shadow[(paddr-8'h20)>>2]<=(shadow[(paddr-8'h20)>>2] & ~byte_mask) | (pwdata & byte_mask);
                endcase
            end
            if(complete) begin
                owned<=0;result_valid<=1;result_error<=graph_done_error || fabric_error;
                result_discard<=discard_q || discard_now;result_cycles<=graph_cycles;result_tag<=job[5];
                publish_valid<=!(graph_done_error || fabric_error || discard_q || discard_now);
            end
        end
    end
endmodule
