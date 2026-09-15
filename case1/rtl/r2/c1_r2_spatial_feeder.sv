`timescale 1ns/1ps
// One spatial SRAM pool for RGB Cin8/Cout3 and DW Cin16/24/48.
// DW processes one C8 group across two pixels in three six-lane batches.
// Tag DW={0,x[9:0],group[2:0],batch[1:0]}; it is NOT a flat HWC address.
module c1_r2_spatial_feeder (
    input wire clk,rst,load_valid,
    output wire load_ready,
    input wire [1:0] load_kind,
    input wire [13:0] load_addr,
    input wire [31:0] load_data,
    input wire start_valid,
    output wire start_ready,
    input wire start_dw,
    input wire [10:0] row_width,
    input wire [2:0] start_groups,
    input wire row_top,row_bottom,finish,
    output logic busy,
    output wire req_valid,
    input wire req_ready,
    output wire req_first,req_last,
    output wire [5:0] req_mask,
    output wire [15:0] req_tag,
    output wire [767:0] req_a,req_b,
    output wire [191:0] req_bias,
    output wire [107:0] req_mult,
    output wire [35:0] req_shift,
    output wire [5:0] req_relu
);
    assign load_ready=!rst && !busy && !start_valid;
    wire legal_shape=row_width!=0 && row_width<=1024 &&
        (start_dw ? ((start_groups==2) || (start_groups==3 && row_width<=682) || (start_groups==6 && row_width<=340)) : start_groups==1);
    assign start_ready=!rst && !busy && legal_shape;
    wire load_fire=load_valid && load_ready;
    wire start_fire=start_valid && start_ready;
    wire [4607:0] weights;
    for(genvar w=0;w<144;w=w+1) begin : g_weight
        logic [31:0] value_q;
        always_ff @(posedge clk) if(load_fire && load_kind==1 && load_addr==w) value_q<=load_data;
        assign weights[w*32+:32]=value_q;
    end
    wire [1535:0] biases;
    wire [1199:0] affine;
    for(genvar c=0;c<48;c=c+1) begin : g_parameter
        logic [31:0] bias_q;logic [24:0] affine_q;
        always_ff @(posedge clk) if(load_fire && load_addr==c) begin
            if(load_kind==2) bias_q<=load_data;
            if(load_kind==3) affine_q<=load_data[24:0];
        end
        assign biases[c*32+:32]=bias_q;assign affine[c*25+:25]=affine_q;
    end
    logic dw_q,top_q,bottom_q;
    logic [10:0] width_q,request_x;
    logic [2:0] groups_q,request_group,beat_q;
    wire request_valid=busy && request_x<width_q;
    wire request_ready,window_valid,window_ready;
    wire [9:0] window_x;
    wire [2:0] window_group;
    wire [767:0] window_data;
    c1_r2_group_window_store u_store (
        .clk(clk),.rst(rst),.write_en(load_fire && load_kind==0),.write_addr(load_addr),.write_data(load_data),
        .req_valid(request_valid),.req_ready(request_ready),.req_x(request_x[9:0]),.req_width(width_q),
        .req_group(request_group),.req_groups(groups_q),.req_top(top_q),.req_bottom(bottom_q),
        .out_valid(window_valid),.out_ready(window_ready),.out_x(window_x),.out_group(window_group),.out_window(window_data)
    );
    assign window_ready=req_ready && (dw_q ? beat_q==2 : beat_q==4);
    always_ff @(posedge clk) begin
        if(rst) begin
            busy<=0;dw_q<=0;top_q<=0;bottom_q<=0;width_q<=0;request_x<=0;groups_q<=1;request_group<=0;beat_q<=0;
        end else begin
            if(start_fire) begin
                busy<=1;dw_q<=start_dw;top_q<=row_top;bottom_q<=row_bottom;width_q<=row_width;
                groups_q<=start_groups;request_x<=0;request_group<=0;beat_q<=0;
            end else if(request_valid && request_ready) begin
                if(request_group+1==groups_q) begin request_group<=0;request_x<=request_x+2;end
                else request_group<=request_group+1'b1;
            end
            if(window_valid && req_ready) beat_q<=(dw_q ? beat_q==2 : beat_q==4) ? 0 : beat_q+1'b1;
            if(finish) busy<=0;
        end
    end
    logic [1:0] tap_row0,tap_col0,tap_row1,tap_col1;
    always @* begin
        tap_row0=0;tap_col0=0;tap_row1=0;tap_col1=1;
        case(beat_q)
            1:begin tap_row0=0;tap_col0=2;tap_row1=1;tap_col1=0;end
            2:begin tap_row0=1;tap_col0=1;tap_row1=1;tap_col1=2;end
            3:begin tap_row0=2;tap_col0=0;tap_row1=2;tap_col1=1;end
            4:begin tap_row0=2;tap_col0=2;tap_row1=2;tap_col1=2;end
            default:begin end
        endcase
    end
    wire [255:0] rgb_operands;
    for(genvar p=0;p<2;p=p+1) begin : g_rgb
        wire [3:0] i0={tap_row0,2'b00}+tap_col0+p;
        wire [3:0] i1={tap_row1,2'b00}+tap_col1+p;
        assign rgb_operands[p*128+:64]=window_data[i0*64+:64];
        assign rgb_operands[p*128+64+:64]=beat_q==4 ? 64'd0 : window_data[i1*64+:64];
    end
    wire [767:0] dw_weights=weights[window_group*768+:768];
    wire [255:0] dw_biases=biases[window_group*256+:256];
    wire [199:0] dw_affine=affine[window_group*200+:200];
    wire [4:0] dw_base=beat_q==0 ? 0 : beat_q==1 ? 6 : 12;
    assign req_valid=window_valid;
    assign req_first=dw_q || beat_q==0;
    assign req_last=dw_q || beat_q==4;
    assign req_tag=dw_q ? {1'b0,window_x,window_group,beat_q[1:0]} : {6'd0,window_x};
    for(genvar r=0;r<6;r=r+1) begin : g_lane
        localparam integer RGB_C=r%3;
        wire [4:0] scalar=dw_base+r;
        wire pixel=scalar[3];
        // The schedule has only THREE possible lane-to-pixel/channel maps.
        // Explicit constant wires avoid inferring a general 96-byte dynamic
        // gather/barrel network from index*64+c*8 in every one of 54 taps.
        wire [383:0] a_options,b_options;
        wire [95:0] bias_options;
        wire [74:0] q_options;
        for(genvar batch=0;batch<3;batch=batch+1) begin : g_dw_map
            localparam integer LOCAL_SCALAR=batch*6+r;
            localparam integer CHANNEL=LOCAL_SCALAR%8;
            localparam integer PIXEL=LOCAL_SCALAR/8;
            if(LOCAL_SCALAR<16) begin : g_valid
                for(genvar k=0;k<16;k=k+1) begin : g_tap
                    if(k<9) assign a_options[batch*128+k*8+:8]=window_data[((k/3)*4+(k%3)+PIXEL)*64+CHANNEL*8+:8];
                    else assign a_options[batch*128+k*8+:8]=0;
                end
                assign b_options[batch*128+:128]={56'd0,dw_weights[CHANNEL*96+:72]};
                assign bias_options[batch*32+:32]=dw_biases[CHANNEL*32+:32];
                assign q_options[batch*25+:25]=dw_affine[CHANNEL*25+:25];
            end else begin : g_padding
                assign a_options[batch*128+:128]=0;assign b_options[batch*128+:128]=0;
                assign bias_options[batch*32+:32]=0;assign q_options[batch*25+:25]=0;
            end
        end
        wire [127:0] dw_a=beat_q==0 ? a_options[0+:128] : beat_q==1 ? a_options[128+:128] : a_options[256+:128];
        wire [127:0] dw_b=beat_q==0 ? b_options[0+:128] : beat_q==1 ? b_options[128+:128] : b_options[256+:128];
        wire [31:0] dw_bias=beat_q==0 ? bias_options[0+:32] : beat_q==1 ? bias_options[32+:32] : bias_options[64+:32];
        wire [24:0] dw_qparam=beat_q==0 ? q_options[0+:25] : beat_q==1 ? q_options[25+:25] : q_options[50+:25];
        wire [24:0] q=dw_q ? dw_qparam : affine[RGB_C*25+:25];
        assign req_a[r*128+:128]=dw_q ? dw_a : rgb_operands[(r/3)*128+:128];
        assign req_b[r*128+:128]=dw_q ? dw_b : weights[RGB_C*640+beat_q*128+:128];
        assign req_bias[r*32+:32]=dw_q ? dw_bias : biases[RGB_C*32+:32];
        assign req_mult[r*18+:18]=q[17:0];assign req_shift[r*6+:6]=q[23:18];assign req_relu[r]=q[24];
        assign req_mask[r]=dw_q ? (scalar<16 && (!pixel || {1'b0,window_x}+1<width_q)) : (r<3 || {1'b0,window_x}+1<width_q);
    end
endmodule
