// C37 independent resource candidate; baseline files are unchanged.
// C35 independent shared-MAC row-shadow integration candidate, not yet simulated.
// External row controller owns parameter switching, cache-row validity and DDR debt.
// Normal starts require partition_en=0. Capture is up2 DW16; consume is PW16->8.
// C29 capacity candidate; retained C28 baseline unchanged.
// C22 independent feature-overlay branch; retained C21 sources unchanged.
// C21 independent six-lane weight branch; retained C18 sources unchanged.
// C7 derivative; retained C5/C6 source remains unchanged.
`timescale 1ns/1ps
// R2 operator executor: shared feature/parameter SRAM and one compute6.
// 0 PW; 1 RGB; 2 DW (+ optional virtual nearest2x); 3 add+ReLU;
// 4 encoder Cin3->Cout12 stride2; 5 encoder Cin12->Cout24 stride2.
// Fallback PW/residual overlays spatial row0 and requires view-change refill.
// Explicit partition leases preserve DW row0 while publishing a PW shadow.
// Internal prototype ABI;
// no DDR/CPU integration. All job writes and starts are mutually exclusive.
`ifndef C37_MAX_CHANNELS
`define C37_MAX_CHANNELS 24
`endif
`ifndef C37_ROW_WORDS
`define C37_ROW_WORDS 512
`endif
module c1_r2_cnn_row_shadow_engine #(
    parameter integer MAX_CHANNELS=`C37_MAX_CHANNELS,
    parameter integer ROW_WORDS=`C37_ROW_WORDS
) (
    input wire partition_en,
    input wire [8:0] partition_base,
    input wire [9:0] partition_end,
    input wire start_shadow_capture,start_shadow_read,
    output wire shadow_available,shadow_error,
    output logic op_done,
    input wire clk,rst,
    input wire [2:0] mode,
    input wire load_valid,
    output wire load_ready,
    input wire [1:0] load_kind,
    input wire [13:0] load_addr,
    input wire [31:0] load_data,
    input wire bulk_valid,
    output wire bulk_ready,
    input wire [1:0] bulk_row,
    input wire [9:0] bulk_pair,
    input wire [2:0] bulk_group,bulk_groups,
    input wire bulk_residual_b,
    input wire [127:0] bulk_data,
    input wire start_valid,
    output wire start_ready,
    input wire [13:0] start_size,
    input wire [5:0] start_channels,start_outputs,
    input wire row_top,row_bottom,virtual_up2,row_phase,
    input wire [5:0] start_row_map,
    output logic busy,
    output wire out_valid,
    input wire out_ready,
    output wire [47:0] out_data,
    output wire [5:0] out_mask,
    output wire [15:0] out_index,
    output wire [2:0] out_mode,
    output wire out_last
);
    localparam integer REQUEST_BITS=1264;
    logic [2:0] owner_q;
    logic capture_q,shadow_read_q,shadow_consumed_q;
    logic [10:0] shadow_width_q;
    logic [8:0] shadow_base_q;
    wire sink_start_ready,sink_ready,sink_busy,sink_done,sink_error,sink_row_valid;
    wire [7:0] shadow_wr_en;
    wire [71:0] shadow_wr_addr;
    wire [255:0] shadow_wr_data;
    assign shadow_available=!rst && partition_en && sink_row_valid && !sink_error && !shadow_consumed_q;
    assign shadow_error=sink_error;
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
    wire [13:0] shape_pairs=(start_size+14'd1)>>1;
    wire [12:0] shape_words=times_group(shape_pairs[9:0],selected_groups);
    wire capacity_ok=start_channels<=MAX_CHANNELS && start_outputs<=MAX_CHANNELS &&
        (load_linear_pool || shape_words<=ROW_WORDS);
    wire legal_shape=capacity_ok && start_size!=0 && (!virtual_up2 || mode==2) &&
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
        (mode==0 ? (weight_channel<MAX_CHANNELS && load_addr[4:2]<3) :
         mode==1 ? (weight_channel<3 && load_addr[4:2]<5) :
         mode==2 ? (weight_channel<MAX_CHANNELS && load_addr[4:2]==0) :
         mode==4 ? (weight_channel<12 && load_addr[4:2]<2) :
         mode==5 ? (weight_channel<24 && load_addr[4:2]<7) : 1'b0);
    wire legal_parameter=mode==0 || mode==2 ? load_addr<MAX_CHANNELS : mode==1 ? load_addr<3 :
                         mode==4 ? load_addr<12 : mode==5 ? load_addr<24 : 1'b0;
    // In C7 the 32-bit path is PARAMETERS ONLY. Feature writes use the
    // explicit 128-bit bank port; C5 retains the old narrow feature ABI.
    wire legal_address=mode<=5 && (load_kind==0 ? 1'b0 :
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
    wire [1:0] f_weight_en;
    wire [95:0] f_weight_addr;
    wire [767:0] weight_data;
    wire [107:0] f_lane_addr;
    wire [MAX_CHANNELS*32-1:0] bias_table;
    wire [MAX_CHANNELS*25-1:0] affine_table;
    wire weight_read_en=busy && (own_linear_pool ? f_weight_en[0] : f_weight_en[1]);
    wire [47:0] weight_read_addr=own_linear_pool ? f_weight_addr[0+:48] : f_weight_addr[48+:48];
    wire [53:0] weight_lane_addr=own_linear_pool ? f_lane_addr[0+:54] : f_lane_addr[54+:54];
    // Weight data is common to both feeders and already aligned by their
    // synchronous read handshake. Do not select it through each feeder.
    // The pending request still owns a private copy across backpressure.
    logic [35:0] weight_channels_q;
    wire residual_request=owner_q==3;
    wire [767:0] selected_b;
    wire [5:0] selected_mask=own_linear_pool ? f_mask[0+:6] : f_mask[6+:6];
    for(genvar lane=0;lane<6;lane=lane+1)begin : g_request
        always_ff @(posedge clk) if(!rst && weight_read_en)
            weight_channels_q[lane*6+:6]<={weight_lane_addr[lane*9+3+:3],weight_lane_addr[lane*9+6+:3]};
        assign selected_b[lane*128+:128]=residual_request ? 128'h0101 :
            owner_q==2 ? (selected_mask[lane] ? {56'd0,weight_data[lane*128+:72]} : 128'd0) :
            weight_data[lane*128+:128];
    end
    wire [767:0] selected_a=own_linear_pool ? f_a[0+:768] : f_a[768+:768];
    // Producer-native format: never unpack the spatial operand only to repack it.
    wire [431:0] spatial_packed_a;
    wire [95:0] linear_residual_a;
    for(genvar c39_lane=0;c39_lane<6;c39_lane=c39_lane+1)begin : g_direct_residual
        assign linear_residual_a[c39_lane*16+:16]=f_a[c39_lane*128+:16];
    end
    wire [431:0] linear_packed_a=residual_request ? {336'd0,linear_residual_a} :
        {176'd0,f_a[640+:128],f_a[0+:128]};
    wire [431:0] packed_a=own_linear_pool ? linear_packed_a : spatial_packed_a;
    wire [REQUEST_BITS-1:0] selected_request={
        own_linear_pool ? f_first[0] : f_first[1],
        own_linear_pool ? f_last[0] : f_last[1],
        selected_mask,own_linear_pool ? f_tag[0+:16] : f_tag[16+:16],
        packed_a,owner_q,
        selected_b,residual_request ? 36'd0 : weight_channels_q,residual_request};
    wire selected_valid=busy && (own_linear_pool ? f_valid[0] : f_valid[1]);
    wire load_gate=!rst && !busy && !compute_busy && !request_valid_q && !start_valid && !bulk_valid && legal_address && legal_affine;
    function automatic [12:0] times_group(input [9:0] pair_id,input [2:0] groups);
        reg [12:0] p;
        begin
            p={3'd0,pair_id};
            case(groups) 1:times_group=p;2:times_group=p<<1;3:times_group=(p<<1)+p;6:times_group=(p<<2)+(p<<1);default:times_group=0;endcase
        end
    endfunction
    wire [12:0] bulk_spatial_address=times_group(bulk_pair,bulk_groups)+bulk_group;
    // A final residual pair may contain only its even logical pixel. Admit
    // the in-range half; the feeder independently masks each physical bank.
    // Requiring the larger odd-half address rejected valid scalars 8161..8192.
    wire [12:0] bulk_linear_address=times_group(bulk_pair,bulk_groups==2 ? 3'd1 : bulk_groups==3 && mode==0 ? 3'd2 : 3'd3)+(bulk_group>>1);
    wire legal_bulk_group=bulk_group<bulk_groups &&
        ((mode!=0 && mode!=2) || bulk_groups<=MAX_CHANNELS/8) && (mode==1 || mode==4 ? bulk_groups==1 : mode==5 ? bulk_groups==2 : mode==3 ? bulk_groups==3 : (mode==0 || mode==2) && (bulk_groups==2 || bulk_groups==3 || bulk_groups==6));
    wire legal_partition_bulk=!partition_en || (!load_linear_pool &&
        (bulk_row!=0 || (bulk_spatial_address>>1)<{4'd0,partition_base}));
    wire legal_bulk=legal_partition_bulk && legal_bulk_group && (load_linear_pool ? bulk_linear_address<512 : bulk_row<3 && bulk_spatial_address<(bulk_row==0 ? 1024 : ROW_WORDS));
    assign bulk_ready=!rst && !busy && !start_valid && !load_valid && legal_bulk && (load_linear_pool ? f_load_ready[0] : f_load_ready[1]);
    wire bulk_fire=bulk_valid && bulk_ready;
    assign load_ready=load_gate && (load_kind!=0 || (load_linear_pool ? f_load_ready[0] : f_load_ready[1]));
    wire [11:0] shadow_end={3'd0,partition_base}+{2'd0,effective_width[10:1]};
    wire legal_capture=start_shadow_capture && !start_shadow_read && mode==2 && virtual_up2 &&
        start_channels==16 && start_outputs==16 && start_size>=2 && start_size<=320 && !start_size[0] &&
        {2'd0,partition_base}==(effective_width>>2) && shadow_end<={2'd0,partition_end} && partition_end<=512 && sink_start_ready;
    wire legal_shadow_read=start_shadow_read && !start_shadow_capture && mode==0 && !virtual_up2 &&
        start_channels==16 && start_outputs==8 && shadow_available && start_size=={3'd0,shadow_width_q} &&
        partition_base==shadow_base_q;
    wire legal_shadow_operation=partition_en ? (legal_capture || legal_shadow_read) : (!start_shadow_capture && !start_shadow_read);
    wire start_gate=!rst && !busy && !compute_busy && !request_valid_q && legal_shape && legal_shadow_operation;
    assign start_ready=start_gate && (load_linear_pool ? f_start_ready[0] : f_start_ready[1]);
    wire start_fire=start_valid && start_ready;
    wire compute_sink_ready=capture_q ? sink_ready : out_ready;
    assign out_valid=busy && compute_valid && !capture_q;assign out_mode=owner_q;
    assign out_last=owner_q==0 || owner_q==3 || owner_q==4 || owner_q==5 ? ({1'b0,out_index}+6>=total_q) : owner_q==1 ? ({1'b0,out_index}+2>=total_q) :
        (({1'b0,out_index[14:5]}+2>=total_q) && ({1'b0,out_index[4:2]}+1==groups_q) && out_index[1:0]==2);
    wire finish=busy && compute_valid && compute_sink_ready && out_last;
    // Capture and PW consumption are separate row leases. No other operator
    // may observe or re-consume a previously published shadow row.
    always_ff @(posedge clk)begin
        if(rst)begin capture_q<=0;shadow_read_q<=0;shadow_consumed_q<=1;shadow_width_q<=0;shadow_base_q<=0;op_done<=0;end
        else begin
            op_done<=finish;
            if(!partition_en)shadow_consumed_q<=1;
            if(start_fire)begin
                capture_q<=start_shadow_capture;
                shadow_read_q<=start_shadow_read;
                shadow_consumed_q<=!start_shadow_capture;
                if(start_shadow_capture)begin shadow_width_q<=effective_width;shadow_base_q<=partition_base;end
            end
        end
    end
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
    c1_r2_weight_store6 #(.PACKED(1),.MAX_CHANNELS(MAX_CHANNELS)) u_weights (
        .clk(clk),.rst(rst),.load_valid(load_valid && load_gate && load_kind!=0),
        .load_kind(load_kind),.load_addr(load_addr[10:0]),.load_data(load_data),
        .read_en(weight_read_en),.lane_addr(weight_lane_addr),
        .read_weights(weight_data),.bias_table(bias_table),.affine_table(affine_table)
    );
    wire linear_rd_en;
    wire [17:0] linear_rd_addr;
    wire [255:0] linear_rd_data,linear_wr_data;
    wire [7:0] linear_wr_en;
    wire [71:0] linear_wr_addr;
    c1_r2_pw_shadow_feeder u_linear (
        .start_shadow(start_shadow_read),.start_shadow_base(partition_base),
        .feature_rd_en(linear_rd_en),.feature_rd_addr(linear_rd_addr),.feature_data(linear_rd_data),
        .feature_wr_en(linear_wr_en),.feature_wr_addr(linear_wr_addr),.feature_wr_data(linear_wr_data),
        .clk(clk),.rst(rst),.load_valid(1'b0),.load_ready(f_load_ready[0]),
        .load_addr(12'd0),.load_data(32'd0),
        .bulk_en(bulk_fire && load_linear_pool),.bulk_residual(mode==3),.bulk_residual_b(bulk_residual_b),
        .bulk_pair(bulk_pair),.bulk_group(bulk_group),.bulk_groups(bulk_groups),.bulk_data(bulk_data),
        .start_valid(start_valid && start_gate && load_linear_pool),.start_ready(f_start_ready[0]),
        .start_count(start_size),.start_channels(start_channels),.start_outputs(start_outputs),.start_linear(mode==3),.busy(f_busy[0]),.finish(finish && own_linear_pool),
        .weight_read_en(f_weight_en[0]),.weight_read_addr(f_weight_addr[0+:48]),.weight_lane_addr(f_lane_addr[0+:54]),
        .weight_data(weight_data),.bias_data(256'd0),.affine_data(200'd0),
        .req_valid(f_valid[0]),.req_ready(f_ready[0]),.req_first(f_first[0]),.req_last(f_last[0]),
        .req_mask(f_mask[0+:6]),.req_tag(f_tag[0+:16]),.req_a(f_a[0+:768]),.req_b(f_b[0+:768]),
        .req_bias(f_bias[0+:192]),.req_mult(f_mult[0+:108]),.req_shift(f_shift[0+:36]),.req_relu(f_relu[0+:6])
    );
    c1_r2_spatial_partitioned_feeder #(.ROW_WORDS(ROW_WORDS)) u_spatial (
        .partition_en(partition_en),.partition_base(partition_base),.partition_end(partition_end),
        .linear_rd_en(linear_rd_en),.linear_rd_addr(linear_rd_addr),.linear_rd_data(linear_rd_data),
        .linear_wr_en(linear_wr_en|shadow_wr_en),
        .linear_wr_addr(|shadow_wr_en ? shadow_wr_addr : linear_wr_addr),
        .linear_wr_data(|shadow_wr_en ? shadow_wr_data : linear_wr_data),
        .clk(clk),.rst(rst),.load_valid(1'b0),.load_ready(f_load_ready[1]),
        .load_addr(14'd0),.load_data(32'd0),
        .bulk_en(bulk_fire && !load_linear_pool),.bulk_row(bulk_row),.bulk_pair(bulk_pair),.bulk_group(bulk_group),.bulk_groups(bulk_groups),.bulk_data(bulk_data),
        .start_valid(start_valid && start_gate && !load_linear_pool),.start_ready(f_start_ready[1]),
        .start_kind(mode==1 ? 2'd0 : mode==2 ? 2'd1 : mode==4 ? 2'd2 : 2'd3),
        .start_up2(virtual_up2),.start_row_phase(row_phase),.row_width(effective_width),.start_groups(selected_groups),.row_top(row_top),.row_bottom(row_bottom),
        .start_row_map(start_row_map),
        .finish(finish && !own_linear_pool),.busy(f_busy[1]),
        .weight_read_en(f_weight_en[1]),.weight_read_addr(f_weight_addr[48+:48]),.weight_lane_addr(f_lane_addr[54+:54]),
        .weight_data(weight_data),.bias_data(256'd0),.affine_data(200'd0),.req_valid(f_valid[1]),.req_ready(f_ready[1]),
        .req_first(f_first[1]),.req_last(f_last[1]),.req_mask(f_mask[6+:6]),.req_tag(f_tag[16+:16]),
        .req_a(f_a[768+:768]),.req_packed_a(spatial_packed_a),.req_b(f_b[768+:768]),.req_bias(f_bias[192+:192]),
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
    wire [35:0] q_channels;
    wire q_residual;
    wire [431:0] q_packed_a;
    wire [2:0] q_mode;
    assign {q_first,q_last,q_mask,q_tag,q_packed_a,q_mode,q_b,q_channels,q_residual}=request_q;
    c39_operand_unpack u_unpack(.mode(q_mode),.channels(q_channels),.packed_a(q_packed_a),.expanded(q_a));
`ifndef SYNTHESIS
    wire [767:0] checked_a;
    c39_operand_unpack u_pack_check(.mode(owner_q),.channels(residual_request ? 36'd0 : weight_channels_q),.packed_a(packed_a),.expanded(checked_a));
    always @(posedge clk)if(!rst && selected_valid && request_slot_ready && checked_a!==selected_a)
        $fatal(1,"C39 feeder violates lossless operand packing contract");
`endif
    for(genvar lane=0;lane<6;lane=lane+1)begin : g_bias_lookup
        wire [5:0] channel=q_channels[lane*6+:6];
        assign q_bias[lane*32+:32]=q_residual || !q_mask[lane] ? 32'd0 : bias_table[channel*32+:32];
    end
    c37_compute6_indexed #(.MAX_CHANNELS(MAX_CHANNELS)) u_compute (
        .clk(clk),.rst(rst),.in_valid(request_valid_q),.in_ready(compute_ready),.in_first(q_first),.in_last(q_last),
        .in_mask(q_mask),.in_tag(q_tag),.in_bias(q_bias),.in_a(q_a),.in_b(q_b),.in_channels(q_channels),.in_residual(q_residual),.affine_table(affine_table),
        .out_valid(compute_valid),.out_ready(compute_sink_ready && busy),.out_data(out_data),.out_mask(out_mask),.out_tag(out_index),.busy(compute_busy)
    );
    c1_r2_dw16_row_shadow_writer u_shadow (
        .clk(clk),.rst(rst),.abort(1'b0),.start_valid(start_fire && start_shadow_capture),.start_ready(sink_start_ready),
        .start_width(effective_width),.start_base(partition_base),.write_enable(1'b1),
        .in_valid(busy && compute_valid && capture_q),.in_ready(sink_ready),
        .in_data(out_data),.in_mask(out_mask),.in_index(out_index),.in_last(out_last),
        .linear_wr_en(shadow_wr_en),.linear_wr_addr(shadow_wr_addr),.linear_wr_data(shadow_wr_data),
        .busy(sink_busy),.done(sink_done),.error(sink_error),.row_valid(sink_row_valid)
    );
`ifndef SYNTHESIS
    initial if((MAX_CHANNELS!=24 && MAX_CHANNELS!=48) || (ROW_WORDS!=512 && ROW_WORDS!=1024))
        $fatal(1,"C37 invalid capacity profile");
    always @(posedge clk) if(!rst) begin
        if(|linear_wr_en && |shadow_wr_en)$fatal(1,"shadow engine two linear write owners");
        if(busy && (capture_q || shadow_read_q) && !partition_en)$fatal(1,"shadow engine lost active partition");
        if(start_fire && start_shadow_read && (sink_busy || !shadow_available))$fatal(1,"shadow engine read before publication");
        if(!busy && (compute_busy || request_valid_q)) $fatal(1,"CNN row lost job owner");
        if(busy && f_busy!==(own_linear_pool ? 2'b01 : 2'b10)) $fatal(1,"CNN row feeder owner mismatch");
    end
`endif
endmodule
