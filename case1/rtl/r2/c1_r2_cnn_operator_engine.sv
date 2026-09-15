`timescale 1ns/1ps
// R2 operator executor: shared feature/parameter SRAM and one compute6.
// 0 PW; 1 RGB; 2 DW (+ optional virtual nearest2x); 3 add+ReLU;
// 4 encoder Cin3->Cout12 stride2; 5 encoder Cin12->Cout24 stride2.
// Two feature pools (PW/residual and RGB/DW) plus one shared parameter pool.
// Internal prototype ABI;
// no DDR/CPU integration. All job writes and starts are mutually exclusive.
module c1_r2_cnn_operator_engine (
    input wire clk,rst,
    input wire [2:0] mode,
    input wire load_valid,
    output wire load_ready,
    input wire [1:0] load_kind,
    input wire [13:0] load_addr,
    input wire [31:0] load_data,
    input wire start_valid,
    output wire start_ready,
    input wire [13:0] start_size,
    input wire [5:0] start_channels,start_outputs,
    input wire row_top,row_bottom,virtual_up2,row_phase,
    output logic busy,
    output wire out_valid,
    input wire out_ready,
    output wire [47:0] out_data,
    output wire [5:0] out_mask,
    output wire [15:0] out_index,
    output wire [2:0] out_mode,
    output wire out_last
);
    localparam integer REQUEST_BITS=1902;
    logic [2:0] owner_q;
    logic [15:0] total_q;
    logic [2:0] groups_q;
    wire load_linear_pool=mode==0 || mode==3;
    wire own_linear_pool=owner_q==0 || owner_q==3;
    wire [2:0] selected_groups=mode==1 || mode==4 ? 3'd1 : mode==5 ? 3'd2 : start_channels==16 ? 3'd2 : start_channels==24 ? 3'd3 : start_channels==48 ? 3'd6 : 3'd0;
    wire [10:0] effective_width=virtual_up2 ? {start_size[9:0],1'b0} : start_size[10:0];
    wire [15:0] encoder_pixels=({2'd0,start_size}+16'd1)>>1;
    wire [15:0] encoder_total=mode==5 ? (encoder_pixels<<4)+(encoder_pixels<<3) : (encoder_pixels<<3)+(encoder_pixels<<2);
    // Capacity is PER parity bank: ceil(width/2)*groups <= 1024.
    // In particular C48/W341 overflows even though width*groups <= 2048.
    wire legal_shape=start_size!=0 && (!virtual_up2 || mode==2) &&
        (mode==0 ? ((start_outputs==8 || start_outputs==16 || start_outputs==24 || start_outputs==48) &&
          ((start_channels==16 && start_size<=1024) || (start_channels==24 && start_size<=512) || (start_channels==48 && start_size<=340))) :
         mode==1 ? (start_size<=1024 && start_channels==8) :
         mode==2 ? ((start_channels==16 && start_size<=(virtual_up2 ? 512 : 1024)) || (start_channels==24 && start_size<=(virtual_up2 ? 512 : 682)) || (start_channels==48 && start_size<=340)) :
         mode==3 ? start_size<=8192 :
         mode==4 ? (start_size<=1024 && start_channels==3 && start_outputs==12) :
         mode==5 ? (start_size<=1024 && start_channels==12 && start_outputs==24) : 1'b0);
    wire legal_affine=load_kind!=3 || (load_data[31:25]==0 && load_data[23:18]<=47);
    wire [5:0] weight_channel={load_addr[7:5],load_addr[10:8]};
    wire legal_weight=load_addr<2048 &&
        (mode==0 ? (weight_channel<48 && load_addr[4:2]<3) :
         mode==1 ? (weight_channel<3 && load_addr[4:2]<5) :
         mode==2 ? (weight_channel<48 && load_addr[4:2]==0) :
         mode==4 ? (weight_channel<12 && load_addr[4:2]<2) :
         mode==5 ? (weight_channel<24 && load_addr[4:2]<7) : 1'b0);
    wire legal_parameter=mode==0 || mode==2 ? load_addr<48 : mode==1 ? load_addr<3 :
                         mode==4 ? load_addr<12 : mode==5 ? load_addr<24 : 1'b0;
    wire legal_address=mode<=5 && (load_kind==0 ? (load_linear_pool ? load_addr<4096 : load_addr<12288) :
                       load_kind==1 ? legal_weight : legal_parameter);
    wire [1:0] f_load_ready,f_start_ready,f_busy,f_valid,f_ready,f_first,f_last;
    wire [11:0] f_mask,f_relu;
    wire [31:0] f_tag;
    wire [1535:0] f_a,f_b;
    wire [383:0] f_bias;
    wire [215:0] f_mult;
    wire [71:0] f_shift;
    wire compute_ready,compute_valid,compute_busy;
    logic request_valid_q;
    logic [REQUEST_BITS-1:0] request_q;
    wire request_slot_ready=!request_valid_q || compute_ready;
    wire [REQUEST_BITS-1:0] selected_request=own_linear_pool ?
        {f_first[0],f_last[0],f_mask[0+:6],f_tag[0+:16],f_bias[0+:192],f_a[0+:768],f_b[0+:768],f_mult[0+:108],f_shift[0+:36],f_relu[0+:6]} :
        {f_first[1],f_last[1],f_mask[6+:6],f_tag[16+:16],f_bias[192+:192],f_a[768+:768],f_b[768+:768],f_mult[108+:108],f_shift[36+:36],f_relu[6+:6]};
    wire selected_valid=busy && (own_linear_pool ? f_valid[0] : f_valid[1]);
    wire load_gate=!rst && !busy && !start_valid && legal_address && legal_affine;
    assign load_ready=load_gate && (load_kind!=0 || (load_linear_pool ? f_load_ready[0] : f_load_ready[1]));
    wire start_gate=!rst && !busy && !compute_busy && !request_valid_q && legal_shape;
    assign start_ready=start_gate && (load_linear_pool ? f_start_ready[0] : f_start_ready[1]);
    wire start_fire=start_valid && start_ready;
    assign out_valid=busy && compute_valid;assign out_mode=owner_q;
    assign out_last=owner_q==0 || owner_q==3 || owner_q==4 || owner_q==5 ? ({1'b0,out_index}+6>=total_q) : owner_q==1 ? ({1'b0,out_index}+2>=total_q) :
        (({1'b0,out_index[14:5]}+2>=total_q) && ({1'b0,out_index[4:2]}+1==groups_q) && out_index[1:0]==2);
    wire finish=out_valid && out_ready && out_last;
    always_ff @(posedge clk) begin
        if(rst) begin busy<=0;owner_q<=0;total_q<=0;groups_q<=1;request_valid_q<=0;end
        else begin
            if(start_fire) begin busy<=1;owner_q<=mode;total_q<=mode==0 ? (start_outputs==8 ? start_size<<3 : start_outputs==16 ? start_size<<4 : start_outputs==24 ? (start_size<<4)+(start_size<<3) : (start_size<<5)+(start_size<<4)) : mode==4 || mode==5 ? encoder_total : mode==2 ? {5'd0,effective_width} : {2'd0,start_size};groups_q<=selected_groups;end
            if(finish) busy<=0;
            if(request_slot_ready) begin
                request_valid_q<=selected_valid;
                if(selected_valid) request_q<=selected_request;
            end
        end
    end
    wire [1:0] f_weight_en;
    wire [95:0] f_weight_addr;
    wire [1023:0] weight_data;
    wire [255:0] bias_data;
    wire [199:0] affine_data;
    wire weight_read_en=busy && (own_linear_pool ? f_weight_en[0] : f_weight_en[1]);
    wire [47:0] weight_read_addr=own_linear_pool ? f_weight_addr[0+:48] : f_weight_addr[48+:48];
    c1_r2_weight_store8 u_weights (
        .clk(clk),.rst(rst),.load_valid(load_valid && load_gate && load_kind!=0),
        .load_kind(load_kind),.load_addr(load_addr[10:0]),.load_data(load_data),
        .read_en(weight_read_en),.read_addr(weight_read_addr),
        .read_weights(weight_data),.read_bias(bias_data),.read_affine(affine_data)
    );
    c1_r2_pw_banked_feeder u_linear (
        .clk(clk),.rst(rst),.load_valid(load_valid && load_gate && load_kind==0 && load_linear_pool),.load_ready(f_load_ready[0]),
        .load_addr(load_addr[11:0]),.load_data(load_data),
        .start_valid(start_valid && start_gate && load_linear_pool),.start_ready(f_start_ready[0]),
        .start_count(start_size),.start_channels(start_channels),.start_outputs(start_outputs),.start_linear(mode==3),.busy(f_busy[0]),.finish(finish && own_linear_pool),
        .weight_read_en(f_weight_en[0]),.weight_read_addr(f_weight_addr[0+:48]),
        .weight_data(weight_data),.bias_data(bias_data),.affine_data(affine_data),
        .req_valid(f_valid[0]),.req_ready(f_ready[0]),.req_first(f_first[0]),.req_last(f_last[0]),
        .req_mask(f_mask[0+:6]),.req_tag(f_tag[0+:16]),.req_a(f_a[0+:768]),.req_b(f_b[0+:768]),
        .req_bias(f_bias[0+:192]),.req_mult(f_mult[0+:108]),.req_shift(f_shift[0+:36]),.req_relu(f_relu[0+:6])
    );
    c1_r2_spatial_operator_feeder u_spatial (
        .clk(clk),.rst(rst),.load_valid(load_valid && load_gate && load_kind==0 && !load_linear_pool),.load_ready(f_load_ready[1]),
        .load_addr(load_addr),.load_data(load_data),
        .start_valid(start_valid && start_gate && !load_linear_pool),.start_ready(f_start_ready[1]),
        .start_kind(mode==1 ? 2'd0 : mode==2 ? 2'd1 : mode==4 ? 2'd2 : 2'd3),
        .start_up2(virtual_up2),.start_row_phase(row_phase),.row_width(effective_width),.start_groups(selected_groups),.row_top(row_top),.row_bottom(row_bottom),
        .finish(finish && !own_linear_pool),.busy(f_busy[1]),
        .weight_read_en(f_weight_en[1]),.weight_read_addr(f_weight_addr[48+:48]),
        .weight_data(weight_data),.bias_data(bias_data),.affine_data(affine_data),.req_valid(f_valid[1]),.req_ready(f_ready[1]),
        .req_first(f_first[1]),.req_last(f_last[1]),.req_mask(f_mask[6+:6]),.req_tag(f_tag[16+:16]),
        .req_a(f_a[768+:768]),.req_b(f_b[768+:768]),.req_bias(f_bias[192+:192]),
        .req_mult(f_mult[108+:108]),.req_shift(f_shift[36+:36]),.req_relu(f_relu[6+:6])
    );
    assign f_ready[0]=busy && own_linear_pool && request_slot_ready;
    assign f_ready[1]=busy && !own_linear_pool && request_slot_ready;
    wire q_first,q_last;
    wire [5:0] q_mask,q_relu;
    wire [15:0] q_tag;
    wire [191:0] q_bias;
    wire [767:0] q_a,q_b;
    wire [107:0] q_mult;
    wire [35:0] q_shift;
    assign {q_first,q_last,q_mask,q_tag,q_bias,q_a,q_b,q_mult,q_shift,q_relu}=request_q;
    c1_r2_compute6 u_compute (
        .clk(clk),.rst(rst),.in_valid(request_valid_q),.in_ready(compute_ready),.in_first(q_first),.in_last(q_last),
        .in_mask(q_mask),.in_tag(q_tag),.in_bias(q_bias),.in_a(q_a),.in_b(q_b),.in_mult(q_mult),.in_shift(q_shift),.in_relu(q_relu),
        .out_valid(compute_valid),.out_ready(out_ready && busy),.out_data(out_data),.out_mask(out_mask),.out_tag(out_index),.busy(compute_busy)
    );
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst) begin
        if(!busy && (compute_busy || request_valid_q)) $fatal(1,"CNN row lost job owner");
        if(busy && f_busy!==(own_linear_pool ? 2'b01 : 2'b10)) $fatal(1,"CNN row feeder owner mismatch");
    end
`endif
endmodule
