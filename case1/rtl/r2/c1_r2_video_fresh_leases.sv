`timescale 1ns/1ps
// C14 four raw inputs + three styled outputs, preserve the latest READY. A raw/styled pair remains leased
// through repeated displays. Only DMA/NN completion fences release ownership.
// Requests precede the first camera/ROI pixel; command descriptors are held
// until accepted. Newest completed capture/output is chosen, stale READY
// buffers may be reclaimed, but active or displayed buffers never are.
// Fixed 8MiB slots preserve C10 tensor layout; default arena avoids CPU code
// at low DDR addresses. Physical platform address decoding still needs audit.
module c1_r2_video_fresh_leases #(
    parameter logic [31:0] ARENA_BASE=32'h08000000
) (
    input wire clk,rst,enable,
    input wire cap_request,
    input wire [31:0] capture_tag,
    output wire cap_request_ready,
    output wire cap_cmd_valid,
    input wire cap_cmd_ready,
    output wire [31:0] cap_base,cap_tag,
    input wire cap_done_valid,cap_done_bad,
    output wire cap_done_ready,
    input wire nn_request,
    output wire nn_request_ready,nn_cmd_valid,
    input wire nn_cmd_ready,
    output wire [31:0] nn_input,nn_output,nn_workspace,nn_parameters,nn_tag,
    input wire nn_done_valid,nn_done_bad,
    output wire nn_done_ready,
    input wire display_request,
    output wire display_request_ready,display_cmd_valid,
    input wire display_cmd_ready,
    output wire [31:0] display_raw,display_style,display_tag,
    input wire display_done_valid,display_done_bad,
    output wire display_done_ready,
    output wire [3:0] input_owned,
    output wire [2:0] output_owned,
    output wire capture_active,nn_active,display_active,front_valid,
    output logic [31:0] dropped_captures,retired_pairs,display_errors,
    output logic protocol_error
);
    localparam FREE=0,CAPTURING=1,READY=2,PROCESSING=3,PAIR_READY=4,FRONT=5;
    logic [2:0] ins[0:3],ins_n[0:3],outs[0:2],outs_n[0:2];
    logic [31:0] tags[0:3],tags_n[0:3];
    logic [1:0] out_input[0:2],out_input_n[0:2];
    logic cap_owned,nn_owned,disp_owned,cap_pending,nn_pending,disp_pending,front;
    logic cap_owned_n,nn_owned_n,disp_owned_n,front_n;
    logic [1:0] cap_i,nn_i,front_i,latest_i;
    logic [1:0] cap_i_n,nn_i_n,front_i_n,latest_i_n;
    logic [1:0] nn_o,front_o,latest_o,nn_o_n,front_o_n,latest_o_n;
    logic [31:0] dropped_n,retired_n,display_errors_n;
    integer cap_choice,nn_choice,out_choice,display_choice;
    logic cap_admit,nn_admit,disp_admit;
    function automatic [31:0] input_address(input [1:0] i);
        case(i) 0:input_address=ARENA_BASE;1:input_address=ARENA_BASE+32'h03000000;2:input_address=ARENA_BASE+32'h04000000;default:input_address=ARENA_BASE+32'h05000000;endcase
    endfunction
    function automatic [31:0] output_address(input [1:0] i);
        case(i)0:output_address=ARENA_BASE+32'h02000000;1:output_address=ARENA_BASE+32'h03800000;default:output_address=ARENA_BASE+32'h05800000;endcase
    endfunction
    assign cap_base=input_address(cap_i);assign cap_tag=tags[cap_i];
    assign nn_input=input_address(nn_i);assign nn_output=output_address(nn_o);assign nn_tag=tags[nn_i];
    assign nn_workspace=ARENA_BASE+32'h00800000;assign nn_parameters=ARENA_BASE+32'h02800000;
    assign display_raw=input_address(front_i);assign display_style=output_address(front_o);assign display_tag=tags[front_i];
    assign cap_request_ready=!rst && enable && !protocol_error && cap_admit;
    assign nn_request_ready=!rst && enable && !protocol_error && nn_admit;
    assign display_request_ready=!rst && enable && !protocol_error && disp_admit;
    assign cap_cmd_valid=!rst && cap_pending;assign nn_cmd_valid=!rst && nn_pending;assign display_cmd_valid=!rst && disp_pending;
    assign cap_done_ready=!rst && cap_owned && !cap_pending;
    assign nn_done_ready=!rst && nn_owned && !nn_pending;
    assign display_done_ready=!rst && disp_owned && !disp_pending;
    assign capture_active=cap_owned;assign nn_active=nn_owned;assign display_active=disp_owned;assign front_valid=front;
    for(genvar i=0;i<4;i=i+1)assign input_owned[i]=ins[i]!=FREE;
    for(genvar i=0;i<3;i=i+1)assign output_owned[i]=outs[i]!=FREE;
    // One priority-ordered next-state transaction prevents two same-edge
    // requesters from allocating the same just-freed buffer.
    always_comb begin
        for(integer i=0;i<4;i=i+1)begin ins_n[i]=ins[i];tags_n[i]=tags[i];end
        for(integer i=0;i<3;i=i+1)begin outs_n[i]=outs[i];out_input_n[i]=out_input[i];end
        cap_owned_n=cap_owned;nn_owned_n=nn_owned;disp_owned_n=disp_owned;
        front_n=front;cap_i_n=cap_i;nn_i_n=nn_i;front_i_n=front_i;latest_i_n=latest_i;
        nn_o_n=nn_o;front_o_n=front_o;latest_o_n=latest_o;
        dropped_n=dropped_captures;retired_n=retired_pairs;display_errors_n=display_errors;
        cap_choice=-1;nn_choice=-1;out_choice=-1;display_choice=-1;
        if(cap_done_valid&&cap_done_ready)begin
            cap_owned_n=0;ins_n[cap_i]=cap_done_bad ? FREE : READY;
            if(cap_done_bad)dropped_n=dropped_n+1'b1;else latest_i_n=cap_i;
        end
        if(nn_done_valid&&nn_done_ready)begin
            nn_owned_n=0;
            if(nn_done_bad)begin ins_n[nn_i]=FREE;outs_n[nn_o]=FREE;end
            else begin ins_n[nn_i]=PAIR_READY;outs_n[nn_o]=PAIR_READY;out_input_n[nn_o]=nn_i;latest_o_n=nn_o;end
        end
        if(display_done_valid&&display_done_ready)begin
            disp_owned_n=0;if(display_done_bad)display_errors_n=display_errors_n+1'b1;
            // A read underrun does not corrupt the stored pair. Retain it for
            // the next refresh; no release until a replacement is selected.
        end
        for(integer i=0;i<3;i=i+1)if(outs_n[i]==PAIR_READY)display_choice=i;
        if(outs_n[latest_o_n]==PAIR_READY)display_choice=latest_o_n;
        disp_admit=!disp_owned_n && (display_choice>=0 || front_n);
        if(display_request && !rst && enable && !protocol_error && disp_admit)begin
            if(display_choice>=0)begin
                if(front_n)begin ins_n[front_i_n]=FREE;outs_n[front_o_n]=FREE;retired_n=retired_n+1'b1;end
                for(integer i=0;i<3;i=i+1)if(outs_n[i]==PAIR_READY && i!=display_choice)begin
                    ins_n[out_input_n[i]]=FREE;outs_n[i]=FREE;retired_n=retired_n+1'b1;
                end
                front_i_n=out_input_n[display_choice];front_o_n=display_choice;
                ins_n[front_i_n]=FRONT;outs_n[front_o_n]=FRONT;front_n=1;
            end
            disp_owned_n=1;
        end
        for(integer i=0;i<4;i=i+1)if(ins_n[i]==READY)nn_choice=i;
        if(ins_n[latest_i_n]==READY)nn_choice=latest_i_n;
        for(integer i=2;i>=0;i=i-1)if(outs_n[i]==FREE)out_choice=i;
        nn_admit=!nn_owned_n && nn_choice>=0 && out_choice>=0;
        if(nn_request && !rst && enable && !protocol_error && nn_admit)begin
            for(integer i=0;i<4;i=i+1)if(ins_n[i]==READY && i!=nn_choice)begin ins_n[i]=FREE;dropped_n=dropped_n+1'b1;end
            nn_i_n=nn_choice;nn_o_n=out_choice;ins_n[nn_choice]=PROCESSING;outs_n[out_choice]=PROCESSING;
            nn_owned_n=1;
        end
        // Prefer truly free storage. Only a READY capture may be reclaimed.
        for(integer i=3;i>=0;i=i-1)if(ins_n[i]==READY)cap_choice=i;
        // Prefer an older READY over latest_i_n, regardless of slot number
        // or numerical tag order. The first scan is the fallback when the
        // latest READY is the ONLY reclaimable slot. FREE still wins below.
        for(integer i=3;i>=0;i=i-1)if(ins_n[i]==READY && i!=latest_i_n)cap_choice=i;
        for(integer i=3;i>=0;i=i-1)if(ins_n[i]==FREE)cap_choice=i;
        cap_admit=!cap_owned_n && cap_choice>=0;
        if(cap_request && !rst && enable && !protocol_error && cap_admit)begin
            if(ins_n[cap_choice]==READY)dropped_n=dropped_n+1'b1;
            cap_i_n=cap_choice;tags_n[cap_choice]=capture_tag;ins_n[cap_choice]=CAPTURING;cap_owned_n=1;
        end
    end
    always_ff @(posedge clk)begin
        if(rst)begin
            for(integer i=0;i<4;i=i+1)begin ins[i]<=FREE;tags[i]<=0;end
            for(integer i=0;i<3;i=i+1)begin outs[i]<=FREE;out_input[i]<=0;end
            cap_owned<=0;nn_owned<=0;disp_owned<=0;cap_pending<=0;nn_pending<=0;disp_pending<=0;front<=0;
            cap_i<=0;nn_i<=0;front_i<=0;latest_i<=0;nn_o<=0;front_o<=0;latest_o<=0;
            dropped_captures<=0;retired_pairs<=0;display_errors<=0;protocol_error<=0;
        end else begin
            for(integer i=0;i<4;i=i+1)begin ins[i]<=ins_n[i];tags[i]<=tags_n[i];end
            for(integer i=0;i<3;i=i+1)begin outs[i]<=outs_n[i];out_input[i]<=out_input_n[i];end
            cap_owned<=cap_owned_n;nn_owned<=nn_owned_n;disp_owned<=disp_owned_n;
            // Explicit command-valid enables avoid self-fed combinational
            // pending next-state muxes; request handshakes set, DMA accepts
            // clear. Admission has priority if both occur on the same edge.
            if(cap_cmd_valid&&cap_cmd_ready)cap_pending<=0;
            if(nn_cmd_valid&&nn_cmd_ready)nn_pending<=0;
            if(display_cmd_valid&&display_cmd_ready)disp_pending<=0;
            if(cap_request&&cap_request_ready)cap_pending<=1;
            if(nn_request&&nn_request_ready)nn_pending<=1;
            if(display_request&&display_request_ready)disp_pending<=1;
            front<=front_n;
            cap_i<=cap_i_n;nn_i<=nn_i_n;front_i<=front_i_n;latest_i<=latest_i_n;nn_o<=nn_o_n;front_o<=front_o_n;latest_o<=latest_o_n;
            dropped_captures<=dropped_n;retired_pairs<=retired_n;display_errors<=display_errors_n;
            if((cap_done_valid&&!cap_done_ready)||(nn_done_valid&&!nn_done_ready)||(display_done_valid&&!display_done_ready))protocol_error<=1;
        end
    end
`ifndef SYNTHESIS
    initial if(ARENA_BASE[22:0]!=0 || {1'b0,ARENA_BASE}+33'h6000000>33'h10000000)$fatal(1,"video arena outside 256MiB DDR");
    always @(posedge clk)if(!rst)begin
        if(cap_owned && ins[cap_i]!=CAPTURING)$fatal(1,"capture lease missing");
        if(nn_owned && (ins[nn_i]!=PROCESSING || outs[nn_o]!=PROCESSING))$fatal(1,"NN lease missing");
        if(front && (ins[front_i]!=FRONT || outs[front_o]!=FRONT || out_input[front_o]!=front_i))$fatal(1,"display pair broken");
    end
`endif
endmodule
