// C16 plan-driven derivative; retained C8 and in-flight C12/C13/C14/C15 are unchanged.
`timescale 1ns/1ps
// R2 row executor with a compile-time generated plan, runtime dimensions and
// parameters. Only input frame/parameters originate outside the RTL graph.
// Three 8MiB tensor slots protect compiler-checked residual lifetimes.
// Plan flags select alias views and RGB conversion only after writer ack.
// Memory ports carry ordered ROW TRANSFER descriptors, not physical AXI.
module c1_r2_planned_pingpong_graph #(
    parameter integer USE_ROW_CACHE=1,
    parameter integer OVERLAP_WRITE=1,
    parameter integer OVERLAP_COMPUTE=1,
    parameter integer PRIORITIZE_REFILL=1
) (
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
               ISSUE=6,WRITE_WAIT=7,COMMIT=8,RESULT=9,ADDRESS_COORD=10,ADDRESS_MUL=11,ADDRESS_ADD=12,
               CACHE_PICK=13,FINAL_WRITE_WAIT=14,ERROR_DRAIN=15,ROW_WRITE_WAIT=16,CONFIG_CAPTURE=17;
    logic [4:0] state;
    logic [4:0] stage_q;
    logic [10:0] width_q;
    logic [9:0] height_q,row_y;
    logic [1:0] physical_row;
    logic residual_b;
    logic read_pending;
    logic [1:0] write_count;
    wire write_pending=write_count!=0;
    logic [1:0] cache_phase,fill_bank;
    logic [2:0] cache_valid;
    logic [9:0] cache_row[0:2],fill_row;
    logic [5:0] row_map;
    logic destination_valid,address_only;
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
    logic [2:0] mode_c_decoded;
    logic [5:0] cin_c_decoded,cout_c_decoded;
    logic [10:0] src_width_decoded,dst_width_decoded;
    logic [9:0] src_height_decoded,dst_height_decoded;
    logic [1:0] src_slot_decoded,dst_slot_decoded,skip_slot_decoded;
    logic [15:0] parameter_beats_decoded;
    logic virtual_c_decoded,view_c_decoded;
    // The generated plan owns topology, tensor slots, view fusion and
    // parameter-block selection. This executor owns row-transfer retirement;
    // physical AXI protocol ownership belongs to the downstream DMA wrapper.
    logic plan_valid_c,plan_last_c,input_rgb_c,output_rgb_c;
    logic plan_valid_decoded,plan_last_decoded,input_rgb_decoded,output_rgb_decoded;
    logic [4:0] parameter_block_c,parameter_block_decoded;
    c1_r2_microstyle_plan u_plan (
        .index(stage_q),.frame_width(width_q),.frame_height(height_q),
        .valid(plan_valid_decoded),.last(plan_last_decoded),
        .input_rgb(input_rgb_decoded),.output_rgb(output_rgb_decoded),
        .virtual_up2(virtual_c_decoded),.view(view_c_decoded),
        .mode(mode_c_decoded),.cin(cin_c_decoded),.cout(cout_c_decoded),
        .src_width(src_width_decoded),.src_height(src_height_decoded),
        .dst_width(dst_width_decoded),.dst_height(dst_height_decoded),
        .src_slot(src_slot_decoded),.dst_slot(dst_slot_decoded),.skip_slot(skip_slot_decoded),
        .parameter_beats(parameter_beats_decoded),.parameter_block(parameter_block_decoded)
    );
    wire spatial_c=mode_c==1 || mode_c==2 || mode_c==4 || mode_c==5;
    wire [2:0] input_groups=(cin_c+7)>>3,output_groups=(cout_c+7)>>3;
    wire [15:0] src_row_beats_c=((src_width+1)>>1)*input_groups;
    wire [15:0] dst_row_beats_c=((dst_width+1)>>1)*output_groups;
    logic [15:0] src_row_beats,dst_row_beats;
    wire [9:0] center_y=mode_c==4 || mode_c==5 ? row_y<<1 : virtual_c ? row_y>>1 : row_y;
    wire [9:0] wanted_row[0:2];
    assign wanted_row[0]=center_y==0 ? 10'd0 : center_y-1'b1;
    assign wanted_row[1]=center_y;
    assign wanted_row[2]=center_y+1>=src_height ? center_y : center_y+1'b1;
    wire [9:0] source_y=!spatial_c ? row_y : USE_ROW_CACHE ? fill_row : wanted_row[physical_row];
    logic cache_hit,free_found;
    logic [1:0] hit_bank,free_bank;
    logic [2:0] needed;
    always_comb begin
        cache_hit=0;hit_bank=0;free_found=0;free_bank=0;needed=0;
        for(integer b=0;b<3;b=b+1) begin
            needed[b]=cache_valid[b] && (cache_row[b]==wanted_row[0] || cache_row[b]==wanted_row[1] || cache_row[b]==wanted_row[2]);
            if(cache_valid[b] && cache_row[b]==wanted_row[cache_phase]) begin cache_hit=1;hit_bank=b;end
            if(!needed[b] && !free_found) begin free_found=1;free_bank=b;end
        end
    end
    wire [31:0] source_base=input_rgb_c ? input_q : workspace_q+({30'd0,(residual_b ? skip_slot : src_slot)}<<23);
    wire [31:0] destination_base=output_rgb_c ? output_q : workspace_q+({30'd0,dst_slot}<<23);
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
    wire bulk_valid,bulk_ready,bulk_residual_b;
    wire [1:0] bulk_row;
    wire [9:0] bulk_pair;
    wire [2:0] bulk_group,bulk_groups;
    wire [127:0] bulk_data;
    wire param_start=state==PARAM_START;
    c1_r2_tensor_stream_loader u_loader (
        .clk(clk),.rst(rst),.start_valid(param_start || state==ROW_START),.start_ready(l_start_ready),
        .start_mode(mode_c),.start_parameters(param_start),.start_residual_b(residual_b),.start_input_rgb(input_rgb_c && !param_start),
        .start_row(USE_ROW_CACHE && spatial_c ? fill_bank : physical_row),.start_groups(input_groups),
        .start_address(param_start ? parameter_q+({27'd0,parameter_block_c}<<13) : source_address),
        .start_beats(param_start ? parameter_beats : src_row_beats),
        .cmd_valid(rd_cmd_valid),.cmd_ready(rd_cmd_ready),.cmd_address(rd_cmd_address),.cmd_beats(rd_cmd_beats),
        .data_valid(rd_valid),.data_ready(rd_ready),.data(rd_data),.data_last(rd_last),.data_error(rd_error),
        .load_valid(l_valid),.load_ready(l_ready),.load_kind(l_kind),.load_addr(l_addr),.load_data(l_data),
        .bulk_valid(bulk_valid),.bulk_ready(bulk_ready),.bulk_row(bulk_row),.bulk_pair(bulk_pair),.bulk_group(bulk_group),.bulk_groups(bulk_groups),
        .bulk_residual_b(bulk_residual_b),.bulk_data(bulk_data),.done(l_done),.error(l_error)
    );
    wire op_start_ready,op_busy,op_valid,op_ready,op_last,w_start_ready,w_done,w_error;
    wire [47:0] op_data;
    wire [5:0] op_mask;
    wire [15:0] op_index;
    wire [2:0] op_mode;
    wire issue=state==ISSUE && op_start_ready && w_start_ready && (OVERLAP_COMPUTE || !write_pending) && !read_pending && !(w_done && w_error);
    wire [13:0] op_size=mode_c==3 ? ({3'd0,dst_width}<<4)+({3'd0,dst_width}<<3) : src_width;
    c1_r2_cnn_bulk_engine u_operator (
        .clk(clk),.rst(rst),.mode(mode_c),.load_valid(l_valid),.load_ready(l_ready),.load_kind(l_kind),.load_addr(l_addr),.load_data(l_data),
        .bulk_valid(bulk_valid),.bulk_ready(bulk_ready),.bulk_row(bulk_row),.bulk_pair(bulk_pair),.bulk_group(bulk_group),.bulk_groups(bulk_groups),.bulk_residual_b(bulk_residual_b),.bulk_data(bulk_data),
        .start_valid(issue),.start_ready(op_start_ready),.start_size(op_size),.start_channels(cin_c),.start_outputs(cout_c),
        .row_top(center_y==0),.row_bottom(center_y+1==src_height),.virtual_up2(virtual_c),.row_phase(row_y[0]),.busy(op_busy),
        .start_row_map(USE_ROW_CACHE ? row_map : 6'b10_01_00),
        .out_valid(op_valid),.out_ready(op_ready),.out_data(op_data),.out_mask(op_mask),.out_index(op_index),.out_mode(op_mode),.out_last(op_last)
    );
    // A shared DDR service must refill promptly to restart compute; draining
    // older rows equally during refill would serialize most write bandwidth
    // again. The writer pauses new RAM reads, never an already offered word.
    wire refill_phase=state==CACHE_PICK || state==ADDRESS_COORD || state==ADDRESS_MUL || state==ADDRESS_ADD || state==ROW_START || state==ROW_WAIT;
    wire writer_stream_enable=!PRIORITIZE_REFILL || !refill_phase;
    c1_r2_tensor_pingpong_writer u_writer (
        .clk(clk),.rst(rst),.start_valid(issue),.start_ready(w_start_ready),.start_mode(mode_c),.start_width(dst_width),
        .stream_enable(writer_stream_enable),
        .start_channels(cout_c),.start_rgb(output_rgb_c),.start_address(destination_address),
        .in_valid(op_valid),.in_ready(op_ready),.in_data(op_data),.in_mask(op_mask),.in_index(op_index),.in_last(op_last),
        .cmd_valid(wr_cmd_valid),.cmd_ready(wr_cmd_ready),.cmd_address(wr_cmd_address),.cmd_beats(wr_cmd_beats),
        .data_valid(wr_valid),.data_ready(wr_ready),.data(wr_data),.data_last(wr_last),
        .response_valid(wr_response_valid),.response_error(wr_response_error),.response_ready(wr_response_ready),.done(w_done),.error(w_error)
    );
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;stage_q<=0;width_q<=0;height_q<=0;row_y<=0;physical_row<=0;residual_b<=0;
            plan_valid_c<=0;plan_last_c<=0;input_rgb_c<=0;output_rgb_c<=0;parameter_block_c<=0;
            input_q<=0;workspace_q<=0;output_q<=0;parameter_q<=0;done_error<=0;frame_cycles<=0;stage_done<=0;stage_done_index<=0;
            src_row_beats<=0;dst_row_beats<=0;source_y_q<=0;source_base_q<=0;destination_base_q<=0;
            source_offset_q<=0;destination_offset_q<=0;source_address<=0;destination_address<=0;
            read_pending<=0;write_count<=0;cache_phase<=0;fill_bank<=0;fill_row<=0;cache_valid<=0;row_map<=6'b10_01_00;
            destination_valid<=0;address_only<=0;
            mode_c<=0;cin_c<=16;cout_c<=8;src_width<=0;dst_width<=0;src_height<=0;dst_height<=0;
            src_slot<=0;dst_slot<=1;skip_slot<=2;parameter_beats<=0;virtual_c<=0;view_c<=0;
            for(integer b=0;b<3;b=b+1) cache_row[b]<=0;
        end else begin
            stage_done<=0;
            if((state==PARAM_START || state==ROW_START) && l_start_ready) read_pending<=1;
            if(l_done) read_pending<=0;
            case({issue,w_done})
                2'b10:write_count<=write_count+1'b1;
                2'b01:write_count<=write_count-1'b1;
                default:begin end
            endcase
            if(busy && state!=RESULT) frame_cycles<=frame_cycles+1'b1;
            case(state)
                IDLE:if(start_valid && start_ready) begin
                    state<=SETUP;stage_q<=0;width_q<=frame_width;height_q<=frame_height;input_q<=input_base;
                    workspace_q<=workspace_base;output_q<=output_base;parameter_q<=parameter_base;frame_cycles<=0;done_error<=0;
                end
                SETUP:begin
                    row_y<=0;physical_row<=0;residual_b<=0;
                    cache_phase<=0;cache_valid<=0;row_map<=6'b10_01_00;
                    destination_valid<=0;address_only<=0;
                    plan_valid_c<=plan_valid_decoded;plan_last_c<=plan_last_decoded;
                    input_rgb_c<=input_rgb_decoded;output_rgb_c<=output_rgb_decoded;parameter_block_c<=parameter_block_decoded;
                    mode_c<=mode_c_decoded;cin_c<=cin_c_decoded;cout_c<=cout_c_decoded;
                    src_width<=src_width_decoded;dst_width<=dst_width_decoded;src_height<=src_height_decoded;dst_height<=dst_height_decoded;
                    src_slot<=src_slot_decoded;dst_slot<=dst_slot_decoded;skip_slot<=skip_slot_decoded;
                    parameter_beats<=parameter_beats_decoded;virtual_c<=virtual_c_decoded;view_c<=view_c_decoded;
                    state<=CONFIG_CAPTURE;
                end
                CONFIG_CAPTURE:begin
                    src_row_beats<=src_row_beats_c;dst_row_beats<=dst_row_beats_c;
                    if(!plan_valid_c)begin done_error<=1;state<=RESULT;end
                    else state<=view_c ? COMMIT : parameter_beats!=0 ? PARAM_START : USE_ROW_CACHE && spatial_c ? CACHE_PICK : ADDRESS_COORD;
                end
                PARAM_START:if(l_start_ready) state<=PARAM_WAIT;
                PARAM_WAIT:if(l_done) state<=USE_ROW_CACHE && spatial_c ? CACHE_PICK : ADDRESS_COORD;
                CACHE_PICK:begin
                    if(cache_hit) begin
                        row_map[cache_phase*2+:2]<=hit_bank;
                        if(cache_phase==2) begin
                            if(destination_valid) state<=ISSUE;
                            else begin address_only<=1;state<=ADDRESS_COORD;end
                        end else cache_phase<=cache_phase+1'b1;
                    end else if(free_found) begin fill_bank<=free_bank;fill_row<=wanted_row[cache_phase];address_only<=0;state<=ADDRESS_COORD;end
                end
                ADDRESS_COORD:begin source_y_q<=source_y;source_base_q<=source_base;destination_base_q<=destination_base;state<=ADDRESS_MUL;end
                ADDRESS_MUL:begin source_offset_q<=source_y_q*src_row_beats;destination_offset_q<=row_y*dst_row_beats;state<=ADDRESS_ADD;end
                ADDRESS_ADD:begin
                    source_address<=source_base_q+(source_offset_q<<4);destination_address<=destination_base_q+(destination_offset_q<<4);
                    destination_valid<=1;state<=address_only ? ISSUE : ROW_START;
                end
                ROW_START:if(l_start_ready) state<=ROW_WAIT;
                ROW_WAIT:if(l_done) begin
                    if(USE_ROW_CACHE && spatial_c) begin
                        cache_row[fill_bank]<=fill_row;cache_valid[fill_bank]<=1;row_map[cache_phase*2+:2]<=fill_bank;
                        if(cache_phase==2) state<=ISSUE;else begin cache_phase<=cache_phase+1'b1;state<=CACHE_PICK;end
                    end
                    else if(spatial_c && physical_row!=2) begin physical_row<=physical_row+1'b1;state<=ADDRESS_COORD;end
                    else if(mode_c==3 && !residual_b) begin residual_b<=1;state<=ADDRESS_COORD;end
                    else state<=ISSUE;
                end
                ISSUE:if(issue) state<=WRITE_WAIT;
                WRITE_WAIT:if(op_valid && op_ready && op_last) begin
                    if(row_y+1==dst_height) state<=FINAL_WRITE_WAIT;
                    else if(OVERLAP_WRITE) begin
                        row_y<=row_y+1'b1;physical_row<=0;residual_b<=0;cache_phase<=0;destination_valid<=0;
                        state<=USE_ROW_CACHE && spatial_c ? CACHE_PICK : ADDRESS_COORD;
                    end else state<=ROW_WRITE_WAIT;
                end
                ROW_WRITE_WAIT:if(!write_pending) begin
                    row_y<=row_y+1'b1;physical_row<=0;residual_b<=0;cache_phase<=0;destination_valid<=0;
                    state<=USE_ROW_CACHE && spatial_c ? CACHE_PICK : ADDRESS_COORD;
                end
                FINAL_WRITE_WAIT:if(!write_pending) state<=COMMIT;
                ERROR_DRAIN:if(!write_pending && !read_pending && !op_busy) state<=RESULT;
                COMMIT:begin
                    stage_done<=1;stage_done_index<=stage_q;
                    if(plan_last_c) state<=RESULT;
                    else begin stage_q<=stage_q+1'b1;state<=SETUP;end
                end
                RESULT:if(done_ready) state<=IDLE;
                default:state<=IDLE;
            endcase
            // There can be two reserved writer pages, including a row still
            // being computed. On error keep accepting that operator's output
            // and drain both pages plus any accepted read. Never publish the
            // failed frame or issue a new operator job after the error.
            if((l_done && l_error) || (w_done && w_error)) begin done_error<=1;state<=ERROR_DRAIN;end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst) begin
        if(state==ISSUE && !op_start_ready) $fatal(1,"graph operator row launch not ready");
        if(state==CACHE_PICK && !cache_hit && !free_found) $fatal(1,"graph cache has no reclaimable row");
        if(issue && (read_pending || (!OVERLAP_COMPUTE && write_pending))) $fatal(1,"graph issued over forbidden transfer");
        if(write_count>2 || (w_done && write_count==0)) $fatal(1,"graph writer credit underflow/overflow");
        if(stage_done && write_pending) $fatal(1,"graph committed outstanding writer pages");
        if(op_valid && op_mode!=mode_c) $fatal(1,"graph operator owner changed");
        if(stage_done && op_busy) $fatal(1,"graph committed live operator");
    end
`endif
endmodule
