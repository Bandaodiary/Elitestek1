`timescale 1ns/1ps

module tb_c1_rgb_s8_center_codec;
    localparam integer COUNT = 512;
    localparam integer LINE_WIDTH = 17;
    localparam integer X_BITS = 5;
    localparam integer Y_BITS = 5;

    logic clk;
    logic rst;
    logic src_valid;
    logic src_ready;
    logic [23:0] src_data;
    logic src_sof, src_eol, src_eof;
    logic [X_BITS-1:0] src_x;
    logic [Y_BITS-1:0] src_y;
    logic mid_valid, mid_ready;
    logic [23:0] mid_data;
    logic mid_sof, mid_eol, mid_eof;
    logic [X_BITS-1:0] mid_x;
    logic [Y_BITS-1:0] mid_y;
    logic dst_valid, dst_ready;
    logic [23:0] dst_data;
    logic dst_sof, dst_eol, dst_eof;
    logic [X_BITS-1:0] dst_x;
    logic [Y_BITS-1:0] dst_y;

    logic [23:0] expected_data [0:COUNT-1];
    logic [31:0] lfsr;
    integer send_index;
    integer mid_index;
    integer recv_index;
    integer cycles;
    integer stalls;
    logic previous_mid_stall;
    logic previous_dst_stall;
    logic [27+X_BITS+Y_BITS-1:0] previous_mid_payload;
    logic [27+X_BITS+Y_BITS-1:0] previous_dst_payload;

    c1_rgb_s8_center_codec #(.X_BITS(X_BITS), .Y_BITS(Y_BITS)) u_encode (
        .clk, .rst,
        .in_valid(src_valid), .in_ready(src_ready), .in_data(src_data),
        .in_sof(src_sof), .in_eol(src_eol), .in_eof(src_eof),
        .in_x(src_x), .in_y(src_y),
        .out_valid(mid_valid), .out_ready(mid_ready), .out_data(mid_data),
        .out_sof(mid_sof), .out_eol(mid_eol), .out_eof(mid_eof),
        .out_x(mid_x), .out_y(mid_y)
    );

    c1_rgb_s8_center_codec #(.X_BITS(X_BITS), .Y_BITS(Y_BITS)) u_decode (
        .clk, .rst,
        .in_valid(mid_valid), .in_ready(mid_ready), .in_data(mid_data),
        .in_sof(mid_sof), .in_eol(mid_eol), .in_eof(mid_eof),
        .in_x(mid_x), .in_y(mid_y),
        .out_valid(dst_valid), .out_ready(dst_ready), .out_data(dst_data),
        .out_sof(dst_sof), .out_eol(dst_eol), .out_eof(dst_eof),
        .out_x(dst_x), .out_y(dst_y)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic logic expected_sof(input integer index);
        expected_sof = (index == 0);
    endfunction

    function automatic logic expected_eol(input integer index);
        expected_eol = ((index % LINE_WIDTH) == LINE_WIDTH-1) ||
                       (index == COUNT-1);
    endfunction

    function automatic logic expected_eof(input integer index);
        expected_eof = (index == COUNT-1);
    endfunction

    initial begin : initialize_vectors
        integer i;
        for (i = 0; i < COUNT; i = i + 1) begin
            expected_data[i][23:16] = i[7:0];
            expected_data[i][15:8] = 8'hff - i[7:0];
            expected_data[i][7:0] = (i * 73 + 19) & 255;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            lfsr <= 32'h1ace_b00c;
            dst_ready <= 1'b0;
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            dst_ready <= lfsr[0] || lfsr[3];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            src_valid <= 1'b0;
            src_data <= '0;
            src_sof <= 1'b0;
            src_eol <= 1'b0;
            src_eof <= 1'b0;
            src_x <= '0;
            src_y <= '0;
            send_index <= 0;
        end else begin
            if (src_valid && src_ready) begin
                src_valid <= 1'b0;
                send_index <= send_index + 1;
            end
            if (!src_valid && send_index < COUNT && (lfsr[2] || lfsr[7])) begin
                src_valid <= 1'b1;
                src_data <= expected_data[send_index];
                src_sof <= expected_sof(send_index);
                src_eol <= expected_eol(send_index);
                src_eof <= expected_eof(send_index);
                src_x <= send_index % LINE_WIDTH;
                src_y <= send_index / LINE_WIDTH;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            mid_index <= 0;
            recv_index <= 0;
            cycles <= 0;
            stalls <= 0;
            previous_mid_stall <= 1'b0;
            previous_dst_stall <= 1'b0;
            previous_mid_payload <= '0;
            previous_dst_payload <= '0;
        end else begin
            cycles <= cycles + 1;
            if (previous_mid_stall &&
                {mid_eof,mid_eol,mid_sof,mid_y,mid_x,mid_data} !==
                previous_mid_payload)
                $fatal(1, "middle payload changed while stalled");
            if (previous_dst_stall &&
                {dst_eof,dst_eol,dst_sof,dst_y,dst_x,dst_data} !==
                previous_dst_payload)
                $fatal(1, "output payload changed while stalled");

            previous_mid_stall <= mid_valid && !mid_ready;
            previous_dst_stall <= dst_valid && !dst_ready;
            previous_mid_payload <= {mid_eof,mid_eol,mid_sof,mid_y,mid_x,mid_data};
            previous_dst_payload <= {dst_eof,dst_eol,dst_sof,dst_y,dst_x,dst_data};
            if ((mid_valid && !mid_ready) || (dst_valid && !dst_ready))
                stalls <= stalls + 1;

            if (mid_valid && mid_ready) begin
                if (mid_index >= COUNT ||
                    mid_data !== (expected_data[mid_index] ^ 24'h80_80_80))
                    $fatal(1, "centered s8 mismatch at %0d", mid_index);
                if ({mid_sof,mid_eol,mid_eof} !==
                    {expected_sof(mid_index),expected_eol(mid_index),
                     expected_eof(mid_index)})
                    $fatal(1, "middle marker mismatch at %0d", mid_index);
                if (mid_x !== mid_index % LINE_WIDTH ||
                    mid_y !== mid_index / LINE_WIDTH)
                    $fatal(1, "middle coordinate mismatch at %0d", mid_index);
                mid_index <= mid_index + 1;
            end

            if (dst_valid && dst_ready) begin
                if (recv_index >= COUNT || dst_data !== expected_data[recv_index])
                    $fatal(1, "RGB loopback mismatch at %0d", recv_index);
                if ({dst_sof,dst_eol,dst_eof} !==
                    {expected_sof(recv_index),expected_eol(recv_index),
                     expected_eof(recv_index)})
                    $fatal(1, "output marker mismatch at %0d", recv_index);
                if (dst_x !== recv_index % LINE_WIDTH ||
                    dst_y !== recv_index / LINE_WIDTH)
                    $fatal(1, "output coordinate mismatch at %0d", recv_index);
                if (recv_index == COUNT-1) begin
                    $display("C1_RGB_S8_CODEC_PASS items=%0d cycles=%0d stalls=%0d",
                             COUNT, cycles, stalls);
                    $finish;
                end
                recv_index <= recv_index + 1;
            end

            if (cycles > 20000)
                $fatal(1, "RGB/s8 codec timeout");
        end
    end

    initial begin
        rst = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
    end
endmodule
