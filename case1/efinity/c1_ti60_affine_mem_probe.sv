`timescale 1ns/1ps

// Tiny, boardless probes for the Efinity channel-depth crash.  They are not
// part of the production datapath; each alias exercises the same metadata
// width with a different storage idiom.
module c1_ti60_affine_unpacked16 (
    input  logic        clk,
    input  logic        rst,
    input  logic [3:0]  index,
    input  logic [31:0] write_data,
    input  logic        write_enable,
    output logic [31:0] read_data
);
    logic [31:0] bias [0:15];
    logic [31:0] multiplier [0:15];
    logic [7:0] shift [0:15];
    always_ff @(posedge clk) begin
        if (rst) begin
            bias[index] <= 32'd0;
            multiplier[index] <= 32'd0;
            shift[index] <= 8'd0;
        end else if (write_enable) begin
            bias[index] <= write_data;
            multiplier[index] <= write_data;
            shift[index] <= write_data[7:0];
        end
    end
    always_comb read_data = bias[index] ^ multiplier[index] ^
                            {24'd0, shift[index]};
endmodule

module c1_ti60_affine_packed16 (
    input  logic        clk,
    input  logic        rst,
    input  logic [3:0]  index,
    input  logic [31:0] write_data,
    input  logic        write_enable,
    output logic [31:0] read_data
);
    logic [511:0] bias;
    logic [511:0] multiplier;
    logic [127:0] shift;
    always_ff @(posedge clk) begin
        if (rst) begin
            bias <= '0;
            multiplier <= '0;
            shift <= '0;
        end else if (write_enable) begin
            bias[index*32 +: 32] <= write_data;
            multiplier[index*32 +: 32] <= write_data;
            shift[index*8 +: 8] <= write_data[7:0];
        end
    end
    always_comb read_data = bias[index*32 +: 32] ^
                            multiplier[index*32 +: 32] ^
                            {24'd0, shift[index*8 +: 8]};
endmodule

module c1_ti60_affine_case16 (
    input  logic        clk,
    input  logic        rst,
    input  logic [3:0]  index,
    input  logic [31:0] write_data,
    input  logic        write_enable,
    output logic [31:0] read_data
);
    logic [31:0] bias [0:15];
    logic [31:0] multiplier [0:15];
    logic [7:0] shift [0:15];
    integer reset_index;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (reset_index = 0; reset_index < 16; reset_index = reset_index + 1) begin
                bias[reset_index] <= 32'd0;
                multiplier[reset_index] <= 32'd0;
                shift[reset_index] <= 8'd0;
            end
        end else if (write_enable) begin
            bias[index] <= write_data;
            multiplier[index] <= write_data;
            shift[index] <= write_data[7:0];
        end
    end
    always_comb begin
        read_data = 32'd0;
        case (index)
            4'd0: read_data = bias[0] ^ multiplier[0] ^ {24'd0, shift[0]};
            4'd1: read_data = bias[1] ^ multiplier[1] ^ {24'd0, shift[1]};
            4'd2: read_data = bias[2] ^ multiplier[2] ^ {24'd0, shift[2]};
            4'd3: read_data = bias[3] ^ multiplier[3] ^ {24'd0, shift[3]};
            4'd4: read_data = bias[4] ^ multiplier[4] ^ {24'd0, shift[4]};
            4'd5: read_data = bias[5] ^ multiplier[5] ^ {24'd0, shift[5]};
            4'd6: read_data = bias[6] ^ multiplier[6] ^ {24'd0, shift[6]};
            4'd7: read_data = bias[7] ^ multiplier[7] ^ {24'd0, shift[7]};
            4'd8: read_data = bias[8] ^ multiplier[8] ^ {24'd0, shift[8]};
            4'd9: read_data = bias[9] ^ multiplier[9] ^ {24'd0, shift[9]};
            4'd10: read_data = bias[10] ^ multiplier[10] ^ {24'd0, shift[10]};
            4'd11: read_data = bias[11] ^ multiplier[11] ^ {24'd0, shift[11]};
            4'd12: read_data = bias[12] ^ multiplier[12] ^ {24'd0, shift[12]};
            4'd13: read_data = bias[13] ^ multiplier[13] ^ {24'd0, shift[13]};
            4'd14: read_data = bias[14] ^ multiplier[14] ^ {24'd0, shift[14]};
            4'd15: read_data = bias[15] ^ multiplier[15] ^ {24'd0, shift[15]};
        endcase
    end
endmodule
