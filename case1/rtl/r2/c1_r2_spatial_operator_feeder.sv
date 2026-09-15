`timescale 1ns/1ps
// RGB/DW feature window feeder using the central synchronous weight banks.
// No private weights, affine pool, MAC, or quantizer. An elastic operand stage
// aligns the window/tap metadata with the shared parameter SRAM's one-cycle read.
module c1_r2_spatial_operator_feeder (
    input wire clk,rst,load_valid,
    output wire load_ready,
    input wire [13:0] load_addr,
    input wire [31:0] load_data,
    input wire start_valid,
    output wire start_ready,
    input wire [1:0] start_kind, // 0 RGB, 1 DW, 2 encoder Cin3, 3 encoder Cin12
    input wire start_up2,start_row_phase,
    input wire [10:0] row_width,
    input wire [2:0] start_groups,
    input wire row_top,row_bottom,finish,
    output logic busy,
    output wire weight_read_en,
    output wire [47:0] weight_read_addr,
    input wire [1023:0] weight_data,
    input wire [255:0] bias_data,
    input wire [199:0] affine_data,
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
    wire [10:0] source_width=start_up2 ? row_width>>1 : row_width;
    wire legal_groups=start_kind==0 || start_kind==2 ? start_groups==1 :
                      start_kind==3 ? start_groups==2 : (start_groups==2 || start_groups==3 || start_groups==6);
    wire legal_capacity=start_groups<=2 ? source_width<=1024 : start_groups==3 ? source_width<=682 : source_width<=340;
    wire legal_shape=row_width!=0 && row_width<=1024 && legal_groups && legal_capacity &&
                     (!start_up2 || (start_kind==1 && !row_width[0]));
    assign start_ready=!rst && !busy && legal_shape;
    wire start_fire=start_valid && start_ready;
    logic dw_q,top_q,bottom_q,encoder_q,up2_q,phase_q;
    logic [10:0] width_q,request_x;
    logic [2:0] groups_q,request_group,beat_q;
    wire request_valid=busy && request_x<width_q;
    wire request_ready,window_valid,window_ready;
    wire [9:0] window_x;wire [2:0] window_group;
    wire [767:0] window_data;
    c1_r2_mapped_window_store u_store (
        .clk(clk),.rst(rst),.write_en(load_valid && load_ready),.write_addr(load_addr),.write_data(load_data),
        .req_valid(request_valid),.req_ready(request_ready),.req_x(request_x[9:0]),.req_width(width_q),
        .req_group(request_group),.req_groups(groups_q),.req_top(top_q),.req_bottom(bottom_q),.req_up2(up2_q),.req_row_phase(phase_q),
        .out_valid(window_valid),.out_ready(window_ready),.out_x(window_x),.out_group(window_group),.out_window(window_data)
    );
    wire e_window_ready,e_weight_en,e_valid,e_first,e_last;
    wire [47:0] e_weight_addr;
    wire [5:0] e_mask,e_relu;
    wire [15:0] e_tag;
    wire [767:0] e_a,e_b;
    wire [191:0] e_bias;
    wire [107:0] e_mult;
    wire [35:0] e_shift;
    c1_r2_encoder_feeder u_encoder (
        .clk(clk),.rst(rst),.start_valid(start_fire && start_kind[1]),.wide(start_kind==3),
        .window_valid(window_valid && encoder_q),.window_ready(e_window_ready),
        .window_x(window_x),.window_group(window_group),.window_data(window_data),
        .weight_read_en(e_weight_en),.weight_read_addr(e_weight_addr),
        .weight_data(weight_data),.bias_data(bias_data),.affine_data(affine_data),
        .req_valid(e_valid),.req_ready(req_ready && encoder_q),.req_first(e_first),.req_last(e_last),
        .req_mask(e_mask),.req_tag(e_tag),.req_a(e_a),.req_b(e_b),.req_bias(e_bias),
        .req_mult(e_mult),.req_shift(e_shift),.req_relu(e_relu)
    );
    logic rd_valid_q,rd_first_q,rd_last_q,rd_dw_q;
    logic [1:0] rd_batch_q;
    logic [15:0] rd_tag_q;
    logic [5:0] rd_mask_q;
    logic [767:0] rd_a_q;
    wire read_slot_ready=!rd_valid_q || req_ready;
    wire read_fire=!rst && !encoder_q && window_valid && read_slot_ready;
    wire last_beat=dw_q ? beat_q==2 : beat_q==4;
    assign window_ready=encoder_q ? e_window_ready : read_slot_ready && last_beat;
    assign weight_read_en=encoder_q ? e_weight_en : read_fire;
    for(genvar bank=0;bank<8;bank=bank+1) begin : g_address
        assign weight_read_addr[bank*6+:6]=encoder_q ? e_weight_addr[bank*6+:6] : dw_q ? {window_group,3'd0} : {3'd0,beat_q};
    end
    wire [767:0] issue_a;
    wire [5:0] issue_mask;
    always_ff @(posedge clk) begin
        if(rst) begin
            busy<=0;encoder_q<=0;up2_q<=0;phase_q<=0;dw_q<=0;top_q<=0;bottom_q<=0;width_q<=0;request_x<=0;groups_q<=1;request_group<=0;beat_q<=0;
            rd_valid_q<=0;rd_first_q<=0;rd_last_q<=0;rd_dw_q<=0;rd_batch_q<=0;rd_tag_q<=0;rd_mask_q<=0;
        end else begin
            if(start_fire) begin
                busy<=1;encoder_q<=start_kind[1];up2_q<=start_up2;phase_q<=start_row_phase;dw_q<=start_kind==1;top_q<=row_top;bottom_q<=row_bottom;width_q<=row_width;
                groups_q<=start_groups;request_x<=0;request_group<=0;beat_q<=0;
            end else if(request_valid && request_ready) begin
                if(request_group+1==groups_q) begin request_group<=0;request_x<=request_x+2;end
                else request_group<=request_group+1'b1;
            end
            if(read_fire) beat_q<=last_beat ? 0 : beat_q+1'b1;
            if(finish) busy<=0;
            if(read_slot_ready) begin
                rd_valid_q<=read_fire;
                if(read_fire) begin
                    rd_first_q<=dw_q || beat_q==0;rd_last_q<=dw_q || beat_q==4;
                    rd_dw_q<=dw_q;rd_batch_q<=beat_q[1:0];rd_a_q<=issue_a;rd_mask_q<=issue_mask;
                    rd_tag_q<=dw_q ? {1'b0,window_x,window_group,beat_q[1:0]} : {6'd0,window_x};
                end
            end
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
    wire [4:0] dw_base=beat_q==0 ? 0 : beat_q==1 ? 6 : 12;
    assign req_valid=encoder_q ? e_valid : rd_valid_q;assign req_first=encoder_q ? e_first : rd_first_q;assign req_last=encoder_q ? e_last : rd_last_q;
    assign req_mask=encoder_q ? e_mask : rd_mask_q;assign req_tag=encoder_q ? e_tag : rd_tag_q;assign req_a=encoder_q ? e_a : rd_a_q;
    for(genvar r=0;r<6;r=r+1) begin : g_lane
        localparam integer RGB_C=r%3;
        wire [4:0] scalar=dw_base+r;
        wire pixel=scalar[3];
        wire [383:0] a_options,b_options;
        wire [95:0] bias_options;wire [74:0] q_options;
        for(genvar batch=0;batch<3;batch=batch+1) begin : g_dw_map
            localparam integer LOCAL_SCALAR=batch*6+r,CHANNEL=LOCAL_SCALAR%8,PIXEL=LOCAL_SCALAR/8;
            if(LOCAL_SCALAR<16) begin : g_valid
                for(genvar k=0;k<16;k=k+1) begin : g_tap
                    if(k<9) assign a_options[batch*128+k*8+:8]=window_data[((k/3)*4+(k%3)+PIXEL)*64+CHANNEL*8+:8];
                    else assign a_options[batch*128+k*8+:8]=0;
                end
                assign b_options[batch*128+:128]={56'd0,weight_data[CHANNEL*128+:72]};
                assign bias_options[batch*32+:32]=bias_data[CHANNEL*32+:32];
                assign q_options[batch*25+:25]=affine_data[CHANNEL*25+:25];
            end else begin : g_padding
                assign a_options[batch*128+:128]=0;assign b_options[batch*128+:128]=0;
                assign bias_options[batch*32+:32]=0;assign q_options[batch*25+:25]=0;
            end
        end
        wire [127:0] dw_a=beat_q==0 ? a_options[0+:128] : beat_q==1 ? a_options[128+:128] : a_options[256+:128];
        wire [127:0] dw_b=rd_batch_q==0 ? b_options[0+:128] : rd_batch_q==1 ? b_options[128+:128] : b_options[256+:128];
        wire [31:0] dw_bias=rd_batch_q==0 ? bias_options[0+:32] : rd_batch_q==1 ? bias_options[32+:32] : bias_options[64+:32];
        wire [24:0] dw_qparam=rd_batch_q==0 ? q_options[0+:25] : rd_batch_q==1 ? q_options[25+:25] : q_options[50+:25];
        wire [24:0] q=rd_dw_q ? dw_qparam : affine_data[RGB_C*25+:25];
        assign issue_a[r*128+:128]=dw_q ? dw_a : rgb_operands[(r/3)*128+:128];
        assign issue_mask[r]=dw_q ? (scalar<16 && (!pixel || {1'b0,window_x}+1<width_q)) : (r<3 || {1'b0,window_x}+1<width_q);
        assign req_b[r*128+:128]=encoder_q ? e_b[r*128+:128] : rd_dw_q ? dw_b : weight_data[RGB_C*128+:128];
        assign req_bias[r*32+:32]=encoder_q ? e_bias[r*32+:32] : rd_dw_q ? dw_bias : bias_data[RGB_C*32+:32];
        assign req_mult[r*18+:18]=encoder_q ? e_mult[r*18+:18] : q[17:0];assign req_shift[r*6+:6]=encoder_q ? e_shift[r*6+:6] : q[23:18];assign req_relu[r]=encoder_q ? e_relu[r] : q[24];
    end
endmodule
