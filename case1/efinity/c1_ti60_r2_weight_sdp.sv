// C20 runtime-observable weight-store probe; not a CNN/board top.
module c1_ti60_r2_weight_sdp(
    input wire clk,rst,load_valid,read_en,
    input wire [1:0] load_kind,
    input wire [10:0] load_addr,
    input wire [31:0] load_data,
    input wire [47:0] read_addr,
    input wire [4:0] observe,
    output wire [31:0] weight_value,bias_value,
    output wire [24:0] affine_value
);
    wire [1023:0] weights;
    wire [255:0] biases;
    wire [199:0] affine;
    c1_r2_weight_store8 u_weights(
        .clk(clk),.rst(rst),.load_valid(load_valid),.load_kind(load_kind),
        .load_addr(load_addr),.load_data(load_data),.read_en(read_en),.read_addr(read_addr),
        .read_weights(weights),.read_bias(biases),.read_affine(affine)
    );
    assign weight_value=weights[observe*32+:32];
    assign bias_value=biases[observe[2:0]*32+:32];
    assign affine_value=affine[observe[2:0]*25+:25];
endmodule
