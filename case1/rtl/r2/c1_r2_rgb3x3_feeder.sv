`timescale 1ns/1ps
// Production R2 operand feeder extracted from the retained standalone probe.
// No MAC or quantizer is instantiated here. finish is issued ONLY after the
// final shared-compute result is consumed, keeping parameters/RAM job-owned.
module c1_r2_rgb3x3_feeder #(
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
    input wire finish,
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
    wire mac_ready=req_ready;
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
            if(finish) busy<=0;
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

    assign req_valid=window_valid;
    assign req_first=beat_q==0;assign req_last=beat_q==4;
    assign req_mask=({1'b0,window_x}+1<width_q) ? 6'b111111 : 6'b000111;
    assign req_tag=window_x;
    for(genvar r=0;r<6;r=r+1) begin : g_request
        localparam integer C=r%3;
        assign req_a[r*128+:128]=pixel_operands[(r/3)*128+:128];
        assign req_b[r*128+:128]=weights[C*640+beat_q*128+:128];
        assign req_bias[r*32+:32]=biases[C*32+:32];
        assign req_mult[r*18+:18]=affine[C*25+:18];
        assign req_shift[r*6+:6]=affine[C*25+18+:6];
        assign req_relu[r]=affine[C*25+24];
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst && load_fire) begin
        if(load_kind==1 && load_addr>=60) $fatal(1,"R2 RGB invalid weight address");
        if(load_kind>=2 && load_addr>=3) $fatal(1,"R2 RGB invalid parameter address");
        if(load_kind==3 && (load_data[23:18]>47 || load_data[31:25]!=0)) $fatal(1,"R2 RGB invalid affine config");
    end
`endif
endmodule
