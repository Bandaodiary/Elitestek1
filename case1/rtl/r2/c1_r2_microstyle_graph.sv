`timescale 1ns/1ps
// R2 complete MicroStyle-24 graph. Frozen topology, runtime dimensions and
// parameters. Only input frame/parameters originate outside the RTL graph.
// Three 8MiB tensor slots protect residual lifetimes. Views 14/17 are aliases;
// stage21 RGB conversion is fused into stage20 writer, committed after ack.
// Memory ports carry ordered ROW TRANSFER descriptors, not physical AXI.
module c1_r2_microstyle_graph (
    input wire clk,rst,start_valid,
    output wire start_ready,
    input wire [10:0] frame_width,
    input wire [9:0] frame_height,
    input wire [31:0] input_base,workspace_base,output_base,parameter_base,
    output wire busy,done_valid,
    input wire done_ready,
    output logic done_error,
    output logic [31:0] frame_cycles,
    output logic stage_done,
    output logic [4:0] stage_done_index,
    output wire [4:0] active_stage,
    output wire rd_cmd_valid,
    input wire rd_cmd_ready,
    output wire [31:0] rd_cmd_address,
    output wire [15:0] rd_cmd_beats,
    input wire rd_valid,
    output wire rd_ready,
    input wire [127:0] rd_data,
    input wire rd_last,rd_error,
    output wire wr_cmd_valid,
    input wire wr_cmd_ready,
    output wire [31:0] wr_cmd_address,
    output wire [15:0] wr_cmd_beats,
    output wire wr_valid,
    input wire wr_ready,
    output wire [127:0] wr_data,
    output wire wr_last,
    input wire wr_response_valid,wr_response_error,
    output wire wr_response_ready
);
    localparam IDLE=0,SETUP=1,PARAM_START=2,PARAM_WAIT=3,ROW_START=4,ROW_WAIT=5,
               ISSUE=6,WRITE_WAIT=7,COMMIT=8,RESULT=9,ADDRESS_COORD=10,ADDRESS_MUL=11,ADDRESS_ADD=12;
    logic [3:0] state;
    logic [4:0] stage_q;
    logic [10:0] width_q;
    logic [9:0] height_q,row_y;
    logic [1:0] physical_row;
    logic residual_b;
    logic [31:0] input_q,workspace_q,output_q,parameter_q;
    // Each host region uses 8MiB alignment. Workspace occupies three slots;
    // all regions must be distinct, without wrap at the 32-bit address limit.
    wire [8:0] ib=input_base[31:23],wb=workspace_base[31:23],ob=output_base[31:23],pb=parameter_base[31:23];
    wire legal_regions=(input_base[22:0]|workspace_base[22:0]|output_base[22:0]|parameter_base[22:0])==0 && wb<=509 &&
        ib!=ob && ib!=pb && ob!=pb && (ib<wb || {1'b0,ib}>{1'b0,wb}+2) &&
        (ob<wb || {1'b0,ob}>{1'b0,wb}+2) && (pb<wb || {1'b0,pb}>{1'b0,wb}+2);
    wire legal_shape=frame_width>=4 && frame_width<=640 && frame_width[1:0]==0 &&
                     frame_height>=4 && frame_height<=480 && frame_height[1:0]==0;
    assign start_ready=!rst && state==IDLE && legal_regions && legal_shape;
    assign busy=state!=IDLE;assign done_valid=!rst && state==RESULT;assign active_stage=stage_q;
    logic [2:0] mode_c;
    logic [5:0] cin_c,cout_c;
    logic [10:0] src_width,dst_width;
    logic [9:0] src_height,dst_height;
    logic [1:0] src_slot,dst_slot,skip_slot;
    logic [15:0] parameter_beats;
    logic virtual_c,view_c;
    always_comb begin
        mode_c=0;cin_c=24;cout_c=48;src_width=width_q>>2;dst_width=width_q>>2;
        src_height=height_q>>2;dst_height=height_q>>2;src_slot=1;dst_slot=0;skip_slot=1;
        parameter_beats=240;virtual_c=0;view_c=0;
        case(stage_q)
            0:begin mode_c=4;cin_c=3;cout_c=12;src_width=width_q;src_height=height_q;dst_width=width_q>>1;dst_height=height_q>>1;dst_slot=0;parameter_beats=60;end
            1:begin mode_c=5;cin_c=12;cout_c=24;src_width=width_q>>1;src_height=height_q>>1;src_slot=0;dst_slot=1;parameter_beats=360;end
            2,6,10:begin src_slot=stage_q==6 ? 2 : 1;end
            3,7,11:begin mode_c=2;cin_c=48;cout_c=48;src_slot=0;dst_slot=stage_q==7 ? 1 : 2;parameter_beats=144;end
            4,8,12:begin cin_c=48;cout_c=24;src_slot=stage_q==8 ? 1 : 2;dst_slot=0;parameter_beats=168;end
            5,9,13:begin mode_c=3;cout_c=24;src_slot=0;dst_slot=stage_q==9 ? 1 : 2;skip_slot=stage_q==9 ? 2 : 1;parameter_beats=0;end
            14,17,21:begin view_c=1;parameter_beats=0;end
            15:begin mode_c=2;cin_c=24;cout_c=24;virtual_c=1;src_slot=2;dst_slot=0;dst_width=width_q>>1;dst_height=height_q>>1;parameter_beats=72;end
            16:begin cin_c=24;cout_c=16;src_slot=0;dst_slot=1;src_width=width_q>>1;dst_width=width_q>>1;src_height=height_q>>1;dst_height=height_q>>1;parameter_beats=80;end
            18:begin mode_c=2;cin_c=16;cout_c=16;virtual_c=1;src_slot=1;dst_slot=0;src_width=width_q>>1;dst_width=width_q;src_height=height_q>>1;dst_height=height_q;parameter_beats=48;end
            19:begin cin_c=16;cout_c=8;src_slot=0;dst_slot=1;src_width=width_q;dst_width=width_q;src_height=height_q;dst_height=height_q;parameter_beats=24;end
            20:begin mode_c=1;cin_c=8;cout_c=3;src_slot=1;dst_slot=0;src_width=width_q;dst_width=width_q;src_height=height_q;dst_height=height_q;parameter_beats=33;end
            default:begin view_c=1;parameter_beats=0;end
        endcase
    end
    wire spatial_c=mode_c==1 || mode_c==2 || mode_c==4 || mode_c==5;
    wire [2:0] input_groups=(cin_c+7)>>3,output_groups=(cout_c+7)>>3;
    wire [15:0] src_row_beats_c=((src_width+1)>>1)*input_groups;
    wire [15:0] dst_row_beats_c=((dst_width+1)>>1)*output_groups;
    logic [15:0] src_row_beats,dst_row_beats;
    wire [9:0] center_y=mode_c==4 || mode_c==5 ? row_y<<1 : virtual_c ? row_y>>1 : row_y;
    wire [9:0] source_y=!spatial_c ? row_y : physical_row==0 ? (center_y==0 ? 10'd0 : center_y-1'b1) :
                          physical_row==2 ? (center_y+1>=src_height ? center_y : center_y+1'b1) : center_y;
    wire [31:0] source_base=stage_q==0 ? input_q : workspace_q+({30'd0,(residual_b ? skip_slot : src_slot)}<<23);
    wire [31:0] destination_base=stage_q==20 ? output_q : workspace_q+({30'd0,dst_slot}<<23);
    // Stage decode -> stride multiply -> coordinate multiply -> base add
    // previously formed the 150MHz failing path. Configuration and transfer
    // addresses have explicit register boundaries, never a false/multicycle
    // timing exception. Cost: three setup clocks per feature row descriptor.
    logic [9:0] source_y_q;
    logic [31:0] source_base_q,destination_base_q,source_offset_q,destination_offset_q;
    logic [31:0] source_address,destination_address;
    wire l_start_ready,l_done,l_error,l_valid,l_ready;
    wire [1:0] l_kind;
    wire [13:0] l_addr;
    wire [31:0] l_data;
    wire param_start=state==PARAM_START;
    c1_r2_tensor_row_loader u_loader (
        .clk(clk),.rst(rst),.start_valid(param_start || state==ROW_START),.start_ready(l_start_ready),
        .start_mode(mode_c),.start_parameters(param_start),.start_residual_b(residual_b),.start_input_rgb(stage_q==0 && !param_start),
        .start_row(physical_row),.start_groups(input_groups),
        .start_address(param_start ? parameter_q+({27'd0,stage_q}<<13) : source_address),
        .start_beats(param_start ? parameter_beats : src_row_beats),
        .cmd_valid(rd_cmd_valid),.cmd_ready(rd_cmd_ready),.cmd_address(rd_cmd_address),.cmd_beats(rd_cmd_beats),
        .data_valid(rd_valid),.data_ready(rd_ready),.data(rd_data),.data_last(rd_last),.data_error(rd_error),
        .load_valid(l_valid),.load_ready(l_ready),.load_kind(l_kind),.load_addr(l_addr),.load_data(l_data),.done(l_done),.error(l_error)
    );
    wire op_start_ready,op_busy,op_valid,op_ready,op_last,w_start_ready,w_done,w_error;
    wire [47:0] op_data;
    wire [5:0] op_mask;
    wire [15:0] op_index;
    wire [2:0] op_mode;
    wire issue=state==ISSUE && op_start_ready && w_start_ready;
    wire [13:0] op_size=mode_c==3 ? dst_width*cout_c : src_width;
    c1_r2_cnn_operator_engine u_operator (
        .clk(clk),.rst(rst),.mode(mode_c),.load_valid(l_valid),.load_ready(l_ready),.load_kind(l_kind),.load_addr(l_addr),.load_data(l_data),
        .start_valid(issue),.start_ready(op_start_ready),.start_size(op_size),.start_channels(cin_c),.start_outputs(cout_c),
        .row_top(center_y==0),.row_bottom(center_y+1==src_height),.virtual_up2(virtual_c),.row_phase(row_y[0]),.busy(op_busy),
        .out_valid(op_valid),.out_ready(op_ready),.out_data(op_data),.out_mask(op_mask),.out_index(op_index),.out_mode(op_mode),.out_last(op_last)
    );
    c1_r2_tensor_row_writer u_writer (
        .clk(clk),.rst(rst),.start_valid(issue),.start_ready(w_start_ready),.start_mode(mode_c),.start_width(dst_width),
        .start_channels(cout_c),.start_rgb(stage_q==20),.start_address(destination_address),
        .in_valid(op_valid),.in_ready(op_ready),.in_data(op_data),.in_mask(op_mask),.in_index(op_index),.in_last(op_last),
        .cmd_valid(wr_cmd_valid),.cmd_ready(wr_cmd_ready),.cmd_address(wr_cmd_address),.cmd_beats(wr_cmd_beats),
        .data_valid(wr_valid),.data_ready(wr_ready),.data(wr_data),.data_last(wr_last),
        .response_valid(wr_response_valid),.response_error(wr_response_error),.response_ready(wr_response_ready),.done(w_done),.error(w_error)
    );
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;stage_q<=0;width_q<=0;height_q<=0;row_y<=0;physical_row<=0;residual_b<=0;
            input_q<=0;workspace_q<=0;output_q<=0;parameter_q<=0;done_error<=0;frame_cycles<=0;stage_done<=0;stage_done_index<=0;
            src_row_beats<=0;dst_row_beats<=0;source_y_q<=0;source_base_q<=0;destination_base_q<=0;
            source_offset_q<=0;destination_offset_q<=0;source_address<=0;destination_address<=0;
        end else begin
            stage_done<=0;
            if(busy && state!=RESULT) frame_cycles<=frame_cycles+1'b1;
            case(state)
                IDLE:if(start_valid && start_ready) begin
                    state<=SETUP;stage_q<=0;width_q<=frame_width;height_q<=frame_height;input_q<=input_base;
                    workspace_q<=workspace_base;output_q<=output_base;parameter_q<=parameter_base;frame_cycles<=0;done_error<=0;
                end
                SETUP:begin
                    row_y<=0;physical_row<=0;residual_b<=0;
                    src_row_beats<=src_row_beats_c;dst_row_beats<=dst_row_beats_c;
                    state<=view_c ? COMMIT : parameter_beats!=0 ? PARAM_START : ADDRESS_COORD;
                end
                PARAM_START:if(l_start_ready) state<=PARAM_WAIT;
                PARAM_WAIT:if(l_done) begin if(l_error) begin state<=RESULT;done_error<=1;end else state<=ADDRESS_COORD;end
                ADDRESS_COORD:begin source_y_q<=source_y;source_base_q<=source_base;destination_base_q<=destination_base;state<=ADDRESS_MUL;end
                ADDRESS_MUL:begin source_offset_q<=source_y_q*src_row_beats;destination_offset_q<=row_y*dst_row_beats;state<=ADDRESS_ADD;end
                ADDRESS_ADD:begin source_address<=source_base_q+(source_offset_q<<4);destination_address<=destination_base_q+(destination_offset_q<<4);state<=ROW_START;end
                ROW_START:if(l_start_ready) state<=ROW_WAIT;
                ROW_WAIT:if(l_done) begin
                    if(l_error) begin state<=RESULT;done_error<=1;end
                    else if(spatial_c && physical_row!=2) begin physical_row<=physical_row+1'b1;state<=ADDRESS_COORD;end
                    else if(mode_c==3 && !residual_b) begin residual_b<=1;state<=ADDRESS_COORD;end
                    else state<=ISSUE;
                end
                ISSUE:if(issue) state<=WRITE_WAIT;
                WRITE_WAIT:if(w_done) begin
                    if(w_error) begin state<=RESULT;done_error<=1;end
                    else if(row_y+1==dst_height) state<=COMMIT;
                    else begin row_y<=row_y+1'b1;physical_row<=0;residual_b<=0;state<=ADDRESS_COORD;end
                end
                COMMIT:begin
                    stage_done<=1;stage_done_index<=stage_q;
                    if(stage_q==21) state<=RESULT;
                    else begin stage_q<=stage_q+1'b1;state<=SETUP;end
                end
                RESULT:if(done_ready) state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst) begin
        if(state==ISSUE && (!op_start_ready || !w_start_ready)) $fatal(1,"graph row launch not ready");
        if(op_valid && op_mode!=mode_c) $fatal(1,"graph operator owner changed");
        if(stage_done && op_busy) $fatal(1,"graph committed live operator");
    end
`endif
endmodule
