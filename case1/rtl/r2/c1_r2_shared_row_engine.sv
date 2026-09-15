`timescale 1ns/1ps
// Production R2 sharing boundary. Mode 0=PW16x8; 1=RGB Cin8/Cout3 3x3.
// One compute6 instance, two operand feeders. SRAM pools are still separate;
// a later tile allocator/DMA stage must share/refill them. No CPU ABI change.
module c1_r2_shared_row_engine (
    input wire clk,rst,
    input wire [1:0] mode,
    input wire load_valid,
    output wire load_ready,
    input wire [1:0] load_kind,
    input wire [12:0] load_addr,
    input wire [31:0] load_data,
    input wire start_valid,
    output wire start_ready,
    input wire [10:0] start_size,
    input wire row_top,row_bottom,
    output logic busy,
    output wire out_valid,
    input wire out_ready,
    output wire [47:0] out_data,
    output wire [5:0] out_mask,
    output wire [15:0] out_index,
    output wire [1:0] out_mode,
    output wire out_last
);
    logic [1:0] owner_q;
    logic [13:0] total_q;
    wire [1:0] f_load_ready,f_start_ready,f_busy,f_valid,f_ready,f_first,f_last;
    wire [11:0] f_mask,f_relu;
    wire [31:0] f_tag;
    wire [1535:0] f_a,f_b;
    wire [383:0] f_bias;
    wire [215:0] f_mult;
    wire [71:0] f_shift;
    wire compute_ready,compute_valid,compute_busy;
    wire legal_mode=mode<2;
    wire legal_affine=load_kind!=3 || (load_data[31:25]==0 && load_data[23:18]<=47);
    wire legal_address=mode==0 ? (load_kind==0 ? load_addr<4096 : load_kind==1 ? load_addr<32 : load_addr<8) :
                       mode==1 ? (load_kind==0 ? load_addr<6144 : load_kind==1 ? load_addr<60 : load_addr<3) : 1'b0;
    wire load_gate=!rst && !busy && !start_valid && legal_mode && legal_address && legal_affine;
    assign load_ready=load_gate && (mode==0 ? f_load_ready[0] : f_load_ready[1]);
    wire start_gate=!rst && !busy && !compute_busy && legal_mode;
    assign start_ready=start_gate && (mode==0 ? f_start_ready[0] : f_start_ready[1]);
    wire start_fire=start_valid && start_ready;
    assign out_valid=busy && compute_valid;
    assign out_mode=owner_q;
    assign out_last=owner_q==0 ? ({1'b0,out_index}+6>=total_q) : ({1'b0,out_index}+2>=total_q);
    wire finish=out_valid && out_ready && out_last;
    always_ff @(posedge clk) begin
        if(rst) begin busy<=0;owner_q<=0;total_q<=0;end
        else begin
            if(start_fire) begin
                busy<=1;owner_q<=mode;total_q<=mode==0 ? {start_size,3'b000} : {3'b000,start_size};
            end
            if(finish) busy<=0;
        end
    end
    c1_r2_pw16x8_feeder u_pw (
        .clk(clk),.rst(rst),.load_valid(load_valid && load_gate && mode==0),.load_ready(f_load_ready[0]),
        .load_kind(load_kind),.load_addr(load_addr[11:0]),.load_data(load_data),
        .start_valid(start_valid && start_gate && mode==0),.start_ready(f_start_ready[0]),.pixel_count(start_size),
        .busy(f_busy[0]),.finish(finish && owner_q==0),.req_valid(f_valid[0]),.req_ready(f_ready[0]),
        .req_first(f_first[0]),.req_last(f_last[0]),.req_mask(f_mask[0+:6]),.req_tag(f_tag[0+:16]),
        .req_a(f_a[0+:768]),.req_b(f_b[0+:768]),.req_bias(f_bias[0+:192]),
        .req_mult(f_mult[0+:108]),.req_shift(f_shift[0+:36]),.req_relu(f_relu[0+:6])
    );
    c1_r2_rgb3x3_feeder u_rgb (
        .clk(clk),.rst(rst),.load_valid(load_valid && load_gate && mode==1),.load_ready(f_load_ready[1]),
        .load_kind(load_kind),.load_addr(load_addr),.load_data(load_data),
        .start_valid(start_valid && start_gate && mode==1),.start_ready(f_start_ready[1]),.row_width(start_size),
        .row_top(row_top),.row_bottom(row_bottom),.busy(f_busy[1]),.finish(finish && owner_q==1),
        .req_valid(f_valid[1]),.req_ready(f_ready[1]),.req_first(f_first[1]),.req_last(f_last[1]),
        .req_mask(f_mask[6+:6]),.req_tag(f_tag[16+:16]),.req_a(f_a[768+:768]),.req_b(f_b[768+:768]),
        .req_bias(f_bias[192+:192]),.req_mult(f_mult[108+:108]),.req_shift(f_shift[36+:36]),.req_relu(f_relu[6+:6])
    );
    assign f_ready[0]=busy && owner_q==0 && compute_ready;
    assign f_ready[1]=busy && owner_q==1 && compute_ready;
    c1_r2_compute6 u_compute (
        .clk(clk),.rst(rst),.in_valid(busy && (owner_q==0 ? f_valid[0] : f_valid[1])),.in_ready(compute_ready),
        .in_first(owner_q==0 ? f_first[0] : f_first[1]),.in_last(owner_q==0 ? f_last[0] : f_last[1]),
        .in_mask(owner_q==0 ? f_mask[0+:6] : f_mask[6+:6]),.in_tag(owner_q==0 ? f_tag[0+:16] : f_tag[16+:16]),
        .in_a(owner_q==0 ? f_a[0+:768] : f_a[768+:768]),.in_b(owner_q==0 ? f_b[0+:768] : f_b[768+:768]),
        .in_bias(owner_q==0 ? f_bias[0+:192] : f_bias[192+:192]),.in_mult(owner_q==0 ? f_mult[0+:108] : f_mult[108+:108]),
        .in_shift(owner_q==0 ? f_shift[0+:36] : f_shift[36+:36]),.in_relu(owner_q==0 ? f_relu[0+:6] : f_relu[6+:6]),
        .out_valid(compute_valid),.out_ready(out_ready && busy),.out_data(out_data),.out_mask(out_mask),.out_tag(out_index),.busy(compute_busy)
    );
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst) begin
        if(!busy && compute_busy) $fatal(1,"R2 shared compute lost its job owner");
        if(busy && f_busy!==(owner_q==0 ? 2'b01 : 2'b10)) $fatal(1,"R2 shared feeder ownership mismatch");
    end
`endif
endmodule
