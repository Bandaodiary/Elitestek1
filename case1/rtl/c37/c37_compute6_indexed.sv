// C37 independent resource candidate; baseline files are unchanged.
// C29 capacity candidate; retained C28 baseline unchanged.
`timescale 1ns/1ps
// Shared six-output INT8 compute pipeline: 96 products and six requant lanes.
// FIRST captures channel IDs. The layer's affine table is leased until all
// accepted transactions retire; a dedicated elastic stage resolves parameters.
// Transactions may be adjacent, but their reduction beats cannot interleave.
// Local reset discards all partial work; no external AXI cancellation implied.
module c37_compute6_indexed #(
    parameter integer TAG_BITS=16,
    parameter integer PARAM_DEPTH=8,
    parameter integer MAX_CHANNELS=24
) (
    input wire clk,rst,
    input wire in_valid,
    output wire in_ready,
    input wire in_first,in_last,
    input wire [5:0] in_mask,
    input wire [TAG_BITS-1:0] in_tag,
    input wire [767:0] in_a,in_b,
    input wire [191:0] in_bias,
    input wire [35:0] in_channels,
    input wire in_residual,
    input wire [MAX_CHANNELS*25-1:0] affine_table,
    output wire out_valid,
    input wire out_ready,
    output wire [47:0] out_data,
    output wire [5:0] out_mask,
    output wire [TAG_BITS-1:0] out_tag,
    output wire busy
);
    localparam integer PTR_BITS=$clog2(PARAM_DEPTH);
    localparam integer CFG_BITS=TAG_BITS+43;
    localparam integer DEBT_BITS=$clog2(PARAM_DEPTH+16);
    logic [PTR_BITS-1:0] write_ptr,read_ptr;
    logic [PTR_BITS:0] param_count;
    logic [DEBT_BITS-1:0] transaction_count;
    wire [PARAM_DEPTH*CFG_BITS-1:0] configs;
    // C37b: static bit planes plus a shared decoder, not an unaligned packed
    // vector shift by read_ptr*59. The latter mapped to expensive selection.
    wire [CFG_BITS-1:0] current_config;
    wire [PARAM_DEPTH-1:0] head_select;
    for(genvar entry=0;entry<PARAM_DEPTH;entry=entry+1)begin : g_head_decode
        assign head_select[entry]=read_ptr==entry;
    end
    for(genvar bit_id=0;bit_id<CFG_BITS;bit_id=bit_id+1)begin : g_head_bit
        wire [PARAM_DEPTH-1:0] plane;
        for(genvar entry=0;entry<PARAM_DEPTH;entry=entry+1)begin : g_entry
            assign plane[entry]=head_select[entry] && configs[entry*CFG_BITS+bit_id];
        end
        assign current_config[bit_id]=|plane;
    end
    wire [CFG_BITS-1:0] input_config={in_tag,in_mask,in_channels,in_residual};
    wire [TAG_BITS-1:0] param_tag;
    wire [5:0] param_mask;
    wire [35:0] param_channels;
    wire param_residual;
    wire mac_ready,mac_valid,mac_busy,quant_ready;
    wire [191:0] mac_acc;
    wire [5:0] mac_mask;
    wire [TAG_BITS-1:0] mac_tag;
    assign {param_tag,param_mask,param_channels,param_residual}=current_config;
    logic resolved_valid;
    wire resolved_ready=!resolved_valid || quant_ready;
    logic [191:0] resolved_acc;
    logic [TAG_BITS-1:0] resolved_tag;
    logic [5:0] resolved_mask,param_relu;
    logic [107:0] param_mult;
    logic [35:0] param_shift;
    wire [149:0] selected_affine;
    for(genvar lane=0;lane<6;lane=lane+1)begin : g_affine_lookup
        wire [5:0] channel=param_channels[lane*6+:6];
        wire [MAX_CHANNELS-1:0] channel_select;
        wire [24:0] affine_value;
        for(genvar c=0;c<MAX_CHANNELS;c=c+1)begin : g_channel
            assign channel_select[c]=param_mask[lane] && channel==c;
        end
        for(genvar bit_id=0;bit_id<25;bit_id=bit_id+1)begin : g_value
            wire [MAX_CHANNELS-1:0] plane;
            for(genvar c=0;c<MAX_CHANNELS;c=c+1)begin : g_term
                assign plane[c]=channel_select[c] && affine_table[c*25+bit_id];
            end
            assign affine_value[bit_id]=|plane;
        end
        // Inactive lanes and residual bypass do not read an uninitialized entry.
        assign selected_affine[lane*25+:25]=param_residual ? {1'b1,6'd0,18'd1} :
            affine_value;
        always_ff @(posedge clk) if(!rst && resolved_ready && mac_valid && param_count!=0) begin
            param_mult[lane*18+:18]<=selected_affine[lane*25+:18];
            param_shift[lane*6+:6]<=selected_affine[lane*25+18+:6];
            param_relu[lane]<=selected_affine[lane*25+24];
        end
    end
    // Separates FIFO/channel lookup from quantization multiplication. II=1.
    always_ff @(posedge clk)begin
        if(rst)resolved_valid<=0;
        else if(resolved_ready)begin
            resolved_valid<=mac_valid && param_count!=0;
            if(mac_valid && param_count!=0)begin
                resolved_acc<=mac_acc;resolved_tag<=mac_tag;resolved_mask<=mac_mask;
            end
        end
    end
    wire pop=mac_valid && resolved_ready && param_count!=0;
    wire space=param_count<PARAM_DEPTH || pop;
    wire input_gate=!in_first || space;
    assign in_ready=!rst && mac_ready && input_gate;
    wire accept=in_valid && in_ready;
    wire push=accept && in_first;
    wire retire=out_valid && out_ready;
    assign busy=transaction_count!=0 || mac_busy;

    // Explicit shallow registers avoid turning a small metadata FIFO into
    // replicated Efinity block RAM. Simultaneous full pop/push reads old head.
    for(genvar entry=0;entry<PARAM_DEPTH;entry=entry+1) begin : g_config
        logic [CFG_BITS-1:0] value_q;
        always_ff @(posedge clk) if(!rst && push && write_ptr==entry) value_q<=input_config;
        assign configs[entry*CFG_BITS+:CFG_BITS]=value_q;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            write_ptr<=0;read_ptr<=0;param_count<=0;transaction_count<=0;
        end else begin
            if(push) write_ptr<=write_ptr+1'b1;
            if(pop) read_ptr<=read_ptr+1'b1;
            case({push,pop})
                2'b10: param_count<=param_count+1'b1;
                2'b01: param_count<=param_count-1'b1;
                default: begin end
            endcase
            case({push,retire})
                2'b10: transaction_count<=transaction_count+1'b1;
                2'b01: transaction_count<=transaction_count-1'b1;
                default: begin end
            endcase
        end
    end
    c1_r2_dot16_array #(.ROWS(6),.TAG_BITS(TAG_BITS)) u_mac (
        .clk(clk),.rst(rst),.in_valid(in_valid && input_gate),.in_ready(mac_ready),
        .in_first(in_first),.in_last(in_last),.in_mask(in_mask),.in_tag(in_tag),
        .in_a(in_a),.in_b(in_b),.in_bias(in_bias),.out_valid(mac_valid),
        .out_ready(resolved_ready && param_count!=0),.out_mask(mac_mask),.out_tag(mac_tag),.out_acc(mac_acc),.busy(mac_busy)
    );
    wire [15:0] activation;
    for(genvar r=0;r<6;r=r+1) begin : g_relu
        assign activation[r*2+:2]={1'b0,param_relu[r]};
    end
    assign activation[15:12]=0;
    wire [63:0] quant_data;
    c1_requant_bank8_compact #(.X_BITS(TAG_BITS),.Y_BITS(6)) u_quant (
        .clk(clk),.rst(rst),.in_valid(resolved_valid),.in_ready(quant_ready),
        .in_acc_s32({64'd0,resolved_acc}),.in_mult_s18({36'd0,param_mult}),.in_shift_u6({12'd0,param_shift}),
        .in_activation(activation),.in_sof(1'b0),.in_eol(1'b0),.in_eof(1'b0),
        .in_x(resolved_tag),.in_y(resolved_mask),.out_valid(out_valid),.out_ready(out_ready),
        .out_data_s8(quant_data),.out_sof(),.out_eol(),.out_eof(),.out_x(out_tag),.out_y(out_mask)
    );
    for(genvar r=0;r<6;r=r+1) begin : g_mask
        assign out_data[r*8+:8]=out_mask[r] ? quant_data[r*8+:8] : 8'd0;
    end
`ifndef SYNTHESIS
    logic [TAG_BITS-1:0] open_tag;
    logic [5:0] open_mask;
    logic [36:0] open_parameters;
    logic [MAX_CHANNELS*25-1:0] epoch_parameters;
    initial if(MAX_CHANNELS!=24 && MAX_CHANNELS!=48) $fatal(1,"C37 compute invalid capacity");
    initial if(PARAM_DEPTH<2 || (PARAM_DEPTH & (PARAM_DEPTH-1))!=0 || TAG_BITS<1)
        $fatal(1,"R2 compute parameter FIFO must be a power of two >=2");
    always @(posedge clk) if(!rst) begin
        if(param_count>PARAM_DEPTH || (retire && transaction_count==0)) $fatal(1,"R2 compute ownership count violation");
        if(mac_valid && param_count==0) $fatal(1,"R2 compute accumulator without affine owner");
        if(pop && ({param_tag,param_mask}!=={mac_tag,mac_mask})) $fatal(1,"R2 compute affine/result mismatch");
        if(pop) for(integer r=0;r<6;r=r+1)
            if(selected_affine[r*25+18+:6]>47) $fatal(1,"C37 resolved shift out of range");
        if(push && transaction_count==0) epoch_parameters<=affine_table;
        if(transaction_count!=0 && affine_table!==epoch_parameters)
            $fatal(1,"C37 live parameter table changed during transaction lease");
        if(accept) begin
            if(in_first) begin
                open_tag<=in_tag;open_mask<=in_mask;open_parameters<={in_channels,in_residual};
                for(integer r=0;r<6;r=r+1) if(in_mask[r] && !in_residual && in_channels[r*6+:6]>=MAX_CHANNELS)
                    $fatal(1,"C37 compute channel out of capacity");
            end else if({in_tag,in_mask,in_channels,in_residual}!=={open_tag,open_mask,open_parameters}) $fatal(1,"R2 compute interleaved reduction metadata");
        end
    end
`endif
endmodule
