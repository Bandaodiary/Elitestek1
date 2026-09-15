// C29 capacity candidate; retained C28 baseline unchanged.
`timescale 1ns/1ps
// Shared six-output INT8 compute pipeline: 96 products and six requant lanes.
// Affine parameters are captured on FIRST, not read from live operator state.
// Transactions may be adjacent, but their reduction beats cannot interleave.
// Local reset discards all partial work; no external AXI cancellation implied.
module c1_r2_compute6_compact #(
    parameter integer TAG_BITS=16,
    parameter integer PARAM_DEPTH=8
) (
    input wire clk,rst,
    input wire in_valid,
    output wire in_ready,
    input wire in_first,in_last,
    input wire [5:0] in_mask,
    input wire [TAG_BITS-1:0] in_tag,
    input wire [767:0] in_a,in_b,
    input wire [191:0] in_bias,
    input wire [107:0] in_mult,
    input wire [35:0] in_shift,
    input wire [5:0] in_relu,
    output wire out_valid,
    input wire out_ready,
    output wire [47:0] out_data,
    output wire [5:0] out_mask,
    output wire [TAG_BITS-1:0] out_tag,
    output wire busy
);
    localparam integer PTR_BITS=$clog2(PARAM_DEPTH);
    localparam integer CFG_BITS=TAG_BITS+156;
    localparam integer DEBT_BITS=$clog2(PARAM_DEPTH+16);
    logic [PTR_BITS-1:0] write_ptr,read_ptr;
    logic [PTR_BITS:0] param_count;
    logic [DEBT_BITS-1:0] transaction_count;
    wire [PARAM_DEPTH*CFG_BITS-1:0] configs;
    wire [CFG_BITS-1:0] current_config=configs[read_ptr*CFG_BITS+:CFG_BITS];
    wire [CFG_BITS-1:0] input_config={in_tag,in_mask,in_mult,in_shift,in_relu};
    wire [TAG_BITS-1:0] param_tag;
    wire [5:0] param_mask,param_relu;
    wire [107:0] param_mult;
    wire [35:0] param_shift;
    assign {param_tag,param_mask,param_mult,param_shift,param_relu}=current_config;
    wire mac_ready,mac_valid,mac_busy,quant_ready;
    wire [191:0] mac_acc;
    wire [5:0] mac_mask;
    wire [TAG_BITS-1:0] mac_tag;
    wire pop=mac_valid && quant_ready && param_count!=0;
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
        .out_ready(quant_ready && param_count!=0),.out_mask(mac_mask),.out_tag(mac_tag),.out_acc(mac_acc),.busy(mac_busy)
    );
    wire [15:0] activation;
    for(genvar r=0;r<6;r=r+1) begin : g_relu
        assign activation[r*2+:2]={1'b0,param_relu[r]};
    end
    assign activation[15:12]=0;
    wire [63:0] quant_data;
    c1_requant_bank8_compact #(.X_BITS(TAG_BITS),.Y_BITS(6)) u_quant (
        .clk(clk),.rst(rst),.in_valid(mac_valid && param_count!=0),.in_ready(quant_ready),
        .in_acc_s32({64'd0,mac_acc}),.in_mult_s18({36'd0,param_mult}),.in_shift_u6({12'd0,param_shift}),
        .in_activation(activation),.in_sof(1'b0),.in_eol(1'b0),.in_eof(1'b0),
        .in_x(mac_tag),.in_y(mac_mask),.out_valid(out_valid),.out_ready(out_ready),
        .out_data_s8(quant_data),.out_sof(),.out_eol(),.out_eof(),.out_x(out_tag),.out_y(out_mask)
    );
    for(genvar r=0;r<6;r=r+1) begin : g_mask
        assign out_data[r*8+:8]=out_mask[r] ? quant_data[r*8+:8] : 8'd0;
    end
`ifndef SYNTHESIS
    logic [TAG_BITS-1:0] open_tag;
    logic [5:0] open_mask;
    initial if(PARAM_DEPTH<2 || (PARAM_DEPTH & (PARAM_DEPTH-1))!=0 || TAG_BITS<1)
        $fatal(1,"R2 compute parameter FIFO must be a power of two >=2");
    always @(posedge clk) if(!rst) begin
        if(param_count>PARAM_DEPTH || (retire && transaction_count==0)) $fatal(1,"R2 compute ownership count violation");
        if(mac_valid && param_count==0) $fatal(1,"R2 compute accumulator without affine owner");
        if(pop && ({param_tag,param_mask}!=={mac_tag,mac_mask})) $fatal(1,"R2 compute affine/result mismatch");
        if(accept) begin
            if(in_first) begin
                open_tag<=in_tag;open_mask<=in_mask;
                for(integer r=0;r<6;r=r+1) if(in_shift[r*6+:6]>47) $fatal(1,"R2 compute shift out of range");
            end else if({in_tag,in_mask}!=={open_tag,open_mask}) $fatal(1,"R2 compute interleaved reduction metadata");
        end
    end
`endif
endmodule
