`timescale 1ns/1ps
// R2-C Cin8/Cout3 3x3 row executor. Six MAC rows = two pixels x RGB.
// Kernel-major/channel-inner 72 terms, five 16-term beats; unused final eight
// terms are zeroed in hardware. Coefficient loader transposes OIHW into this
// order; arithmetic is identical modulo signed32 accumulation.
// Isolated prototype; a future unified executor must SHARE its MAC/quantizer
// with PW/DW feeders, not instantiate several full arrays on Ti60.
module c1_r2_rgb3x3_row #(
    parameter integer X_BITS=10
) (
    input wire clk,rst,load_valid,
    output wire load_ready,
    input wire [1:0] load_kind,
    input wire [X_BITS+2:0] load_addr,
    input wire [31:0] load_data,
    input wire start_valid,
    output wire start_ready,
    input wire [X_BITS:0] row_width,
    input wire row_top,row_bottom,
    output logic busy,
    output wire out_valid,
    input wire out_ready,
    output wire [47:0] out_data,
    output wire [5:0] out_mask,
    output wire [X_BITS-1:0] out_x,
    output wire out_last
);
    // kind0 features: {row[1:0], x, word}; kind1 weights: c*20+beat*4+word.
    // kind2: bias[c], kind3: {reserved[6:0],relu,shift[5:0],signed mult[17:0]}.
    assign load_ready=!rst && !busy && !start_valid;
    assign start_ready=!rst && !busy && row_width!=0 && row_width<=(1<<X_BITS);
    wire load_fire=load_valid && load_ready;
    wire start_fire=start_valid && start_ready;
    wire [1919:0] weights;
    for(genvar word_id=0;word_id<60;word_id=word_id+1) begin : g_weight
        logic [31:0] value_q;
        always_ff @(posedge clk) if(load_fire && load_kind==1 && load_addr==word_id) value_q<=load_data;
        assign weights[word_id*32+:32]=value_q;
    end
    wire [95:0] biases;
    wire [74:0] affine;
    for(genvar c=0;c<3;c=c+1) begin : g_parameter
        logic [31:0] bias_q;
        logic [24:0] affine_q;
        always_ff @(posedge clk) if(load_fire && load_addr==c) begin
            if(load_kind==2) bias_q<=load_data;
            if(load_kind==3) affine_q<=load_data[24:0];
        end
        assign biases[c*32+:32]=bias_q;
        assign affine[c*25+:25]=affine_q;
    end
    logic [X_BITS:0] width_q,request_x;
    logic top_q,bottom_q;
    wire request_ready;
    wire request_valid=busy && request_x<width_q;
    wire window_valid,window_ready;
    wire [X_BITS-1:0] window_x;
    wire [767:0] window_data;
    c1_r2_window3x4_c8 #(.X_BITS(X_BITS)) u_window (
        .clk(clk),.rst(rst),.write_en(load_fire && load_kind==0),.write_addr(load_addr),.write_data(load_data),
        .req_valid(request_valid),.req_ready(request_ready),.req_x(request_x[X_BITS-1:0]),.req_width(width_q),
        .req_top(top_q),.req_bottom(bottom_q),.out_valid(window_valid),.out_ready(window_ready),
        .out_x(window_x),.out_window(window_data)
    );
    wire mac_ready,mac_valid,quant_ready;
    logic [2:0] beat_q;
    assign window_ready=mac_ready && beat_q==4;
    always_ff @(posedge clk) begin
        if(rst) begin
            busy<=0;width_q<=0;request_x<=0;top_q<=0;bottom_q<=0;beat_q<=0;
        end else begin
            if(start_fire) begin
                busy<=1;width_q<=row_width;request_x<=0;top_q<=row_top;bottom_q<=row_bottom;
            end else if(request_valid && request_ready) request_x<=request_x+2;
            if(window_valid && mac_ready) beat_q<=beat_q==4 ? 0 : beat_q+1'b1;
            if(out_valid && out_ready && out_last) busy<=0;
        end
    end
    // Spatial tap pair for each 16-term beat. Eight channels per tap.
    logic [1:0] tap_row0,tap_col0,tap_row1,tap_col1;
    always @* begin
        tap_row0=0;tap_col0=0;tap_row1=0;tap_col1=1;
        case(beat_q)
            1: begin tap_row0=0;tap_col0=2;tap_row1=1;tap_col1=0;end
            2: begin tap_row0=1;tap_col0=1;tap_row1=1;tap_col1=2;end
            3: begin tap_row0=2;tap_col0=0;tap_row1=2;tap_col1=1;end
            4: begin tap_row0=2;tap_col0=2;tap_row1=2;tap_col1=2;end
            default: begin end
        endcase
    end
    wire [255:0] pixel_operands;
    for(genvar p=0;p<2;p=p+1) begin : g_operand
        wire [3:0] index0={tap_row0,2'b00}+tap_col0+p;
        wire [3:0] index1={tap_row1,2'b00}+tap_col1+p;
        assign pixel_operands[p*128+:64]=window_data[index0*64+:64];
        assign pixel_operands[p*128+64+:64]=beat_q==4 ? 64'd0 : window_data[index1*64+:64];
    end
    wire [767:0] mac_a,mac_b;
    wire [191:0] mac_bias,mac_acc;
    wire [5:0] mac_mask;
    wire [X_BITS-1:0] mac_x;
    wire [5:0] input_mask=({1'b0,window_x}+1<width_q) ? 6'b111111 : 6'b000111;
    wire [143:0] quant_mult;
    wire [47:0] quant_shift;
    wire [15:0] quant_act;
    for(genvar r=0;r<6;r=r+1) begin : g_lane
        localparam integer C=r%3;
        assign mac_a[r*128+:128]=pixel_operands[(r/3)*128+:128];
        assign mac_b[r*128+:128]=weights[C*640+beat_q*128+:128];
        assign mac_bias[r*32+:32]=biases[C*32+:32];
        assign quant_mult[r*18+:18]=affine[C*25+:18];
        assign quant_shift[r*6+:6]=affine[C*25+18+:6];
        assign quant_act[r*2+:2]={1'b0,affine[C*25+24]};
    end
    assign quant_mult[143:108]=0;assign quant_shift[47:36]=0;assign quant_act[15:12]=0;
    c1_r2_dot16_array #(.ROWS(6),.TAG_BITS(X_BITS)) u_mac (
        .clk(clk),.rst(rst),.in_valid(window_valid),.in_ready(mac_ready),.in_first(beat_q==0),.in_last(beat_q==4),
        .in_mask(input_mask),.in_tag(window_x),.in_a(mac_a),.in_b(mac_b),.in_bias(mac_bias),
        .out_valid(mac_valid),.out_ready(quant_ready),.out_mask(mac_mask),.out_tag(mac_x),.out_acc(mac_acc),.busy()
    );
    wire [63:0] quant_data;
    c1_requant_bank8 #(.X_BITS(X_BITS),.Y_BITS(6)) u_quant (
        .clk(clk),.rst(rst),.in_valid(mac_valid),.in_ready(quant_ready),.in_acc_s32({64'd0,mac_acc}),
        .in_mult_s18(quant_mult),.in_shift_u6(quant_shift),.in_activation(quant_act),
        .in_sof(1'b0),.in_eol(1'b0),.in_eof(1'b0),.in_x(mac_x),.in_y(mac_mask),
        .out_valid(out_valid),.out_ready(out_ready),.out_data_s8(quant_data),.out_sof(),.out_eol(),.out_eof(),
        .out_x(out_x),.out_y(out_mask)
    );
    for(genvar r=0;r<6;r=r+1) begin : g_mask
        assign out_data[r*8+:8]=out_mask[r] ? quant_data[r*8+:8] : 8'd0;
    end
    assign out_last=({1'b0,out_x}+2>=width_q);
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst && load_fire) begin
        if(load_kind==1 && load_addr>=60) $fatal(1,"R2 RGB invalid weight address");
        if(load_kind>=2 && load_addr>=3) $fatal(1,"R2 RGB invalid parameter address");
        if(load_kind==3 && (load_data[23:18]>47 || load_data[31:25]!=0)) $fatal(1,"R2 RGB invalid affine config");
    end
`endif
endmodule
