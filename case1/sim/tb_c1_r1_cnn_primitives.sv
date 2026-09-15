`timescale 1ns/1ps

module tb_c1_r1_cnn_primitives;
    localparam integer MAX_VECTORS = 12000;

    reg clk = 1'b0;
    reg rst = 1'b1;

    reg req_in_valid = 1'b0;
    reg req_in_sof = 1'b0;
    reg req_in_eol = 1'b0;
    reg req_in_eof = 1'b0;
    reg [9:0] req_in_x = 10'd0;
    reg [8:0] req_in_y = 9'd0;
    reg signed [31:0] req_in_acc = 32'sd0;
    reg signed [17:0] req_in_mult = 18'sd0;
    reg [5:0] req_in_shift = 6'd0;
    reg [1:0] req_in_activation = 2'd0;
    wire req_out_valid;
    wire req_out_sof;
    wire req_out_eol;
    wire req_out_eof;
    wire [9:0] req_out_x;
    wire [8:0] req_out_y;
    wire signed [7:0] req_out_data;

    reg res_in_valid = 1'b0;
    reg res_in_sof = 1'b0;
    reg res_in_eol = 1'b0;
    reg res_in_eof = 1'b0;
    reg [9:0] res_in_x = 10'd0;
    reg [8:0] res_in_y = 9'd0;
    reg signed [7:0] res_in_main = 8'sd0;
    reg signed [7:0] res_in_skip = 8'sd0;
    reg res_in_relu = 1'b0;
    wire res_out_valid;
    wire res_out_sof;
    wire res_out_eol;
    wire res_out_eof;
    wire [9:0] res_out_x;
    wire [8:0] res_out_y;
    wire signed [7:0] res_out_data;

    reg [31:0] requant_acc_vectors [0:MAX_VECTORS-1];
    reg [17:0] requant_mult_vectors [0:MAX_VECTORS-1];
    reg [5:0] requant_shift_vectors [0:MAX_VECTORS-1];
    reg [1:0] requant_activation_vectors [0:MAX_VECTORS-1];
    reg [7:0] requant_expected_vectors [0:MAX_VECTORS-1];

    reg [7:0] residual_main_vectors [0:MAX_VECTORS-1];
    reg [7:0] residual_skip_vectors [0:MAX_VECTORS-1];
    reg residual_relu_vectors [0:MAX_VECTORS-1];
    reg [7:0] residual_expected_vectors [0:MAX_VECTORS-1];

    integer requant_vector_count = 0;
    integer residual_vector_count = 0;
    integer requant_output_count = 0;
    integer residual_output_count = 0;
    reg requant_driver_done = 1'b0;
    reg residual_driver_done = 1'b0;

    reg [2:0] requant_expected_valid = 3'b000;
    reg [1:0] residual_expected_valid = 2'b00;

    always #5 clk = ~clk;

    c1_requant_s8 u_requant (
        .clk(clk),
        .rst(rst),
        .in_valid(req_in_valid),
        .in_sof(req_in_sof),
        .in_eol(req_in_eol),
        .in_eof(req_in_eof),
        .in_x(req_in_x),
        .in_y(req_in_y),
        .in_acc(req_in_acc),
        .in_mult(req_in_mult),
        .in_shift(req_in_shift),
        .in_activation(req_in_activation),
        .out_valid(req_out_valid),
        .out_sof(req_out_sof),
        .out_eol(req_out_eol),
        .out_eof(req_out_eof),
        .out_x(req_out_x),
        .out_y(req_out_y),
        .out_data(req_out_data)
    );

    c1_residual_add_s8 u_residual (
        .clk(clk),
        .rst(rst),
        .in_valid(res_in_valid),
        .in_sof(res_in_sof),
        .in_eol(res_in_eol),
        .in_eof(res_in_eof),
        .in_x(res_in_x),
        .in_y(res_in_y),
        .in_main(res_in_main),
        .in_skip(res_in_skip),
        .in_relu(res_in_relu),
        .out_valid(res_out_valid),
        .out_sof(res_out_sof),
        .out_eol(res_out_eol),
        .out_eof(res_out_eof),
        .out_x(res_out_x),
        .out_y(res_out_y),
        .out_data(res_out_data)
    );

    task automatic load_requant_vectors;
        integer fd;
        integer scan_status;
        integer index;
        begin
            fd = $fopen("c1_requant_s8_vectors.txt", "r");
            if (fd == 0)
                $fatal(1, "cannot open c1_requant_s8_vectors.txt");
            scan_status = $fscanf(fd, "%d\n", requant_vector_count);
            if (scan_status != 1 || requant_vector_count <= 0 ||
                requant_vector_count > MAX_VECTORS)
                $fatal(1, "invalid requant vector count %0d", requant_vector_count);
            for (index = 0; index < requant_vector_count; index = index + 1) begin
                scan_status = $fscanf(
                    fd, "%h %h %h %h %h\n",
                    requant_acc_vectors[index],
                    requant_mult_vectors[index],
                    requant_shift_vectors[index],
                    requant_activation_vectors[index],
                    requant_expected_vectors[index]
                );
                if (scan_status != 5)
                    $fatal(1, "malformed requant vector %0d", index);
            end
            $fclose(fd);
        end
    endtask

    task automatic load_residual_vectors;
        integer fd;
        integer scan_status;
        integer index;
        begin
            fd = $fopen("c1_residual_add_s8_vectors.txt", "r");
            if (fd == 0)
                $fatal(1, "cannot open c1_residual_add_s8_vectors.txt");
            scan_status = $fscanf(fd, "%d\n", residual_vector_count);
            if (scan_status != 1 || residual_vector_count <= 0 ||
                residual_vector_count > MAX_VECTORS)
                $fatal(1, "invalid residual vector count %0d", residual_vector_count);
            for (index = 0; index < residual_vector_count; index = index + 1) begin
                scan_status = $fscanf(
                    fd, "%h %h %h %h\n",
                    residual_main_vectors[index],
                    residual_skip_vectors[index],
                    residual_relu_vectors[index],
                    residual_expected_vectors[index]
                );
                if (scan_status != 4)
                    $fatal(1, "malformed residual vector %0d", index);
            end
            $fclose(fd);
        end
    endtask

    task automatic drive_requant_vectors;
        integer index;
        integer drive_cycle;
        begin
            index = 0;
            drive_cycle = 0;
            while (index < requant_vector_count) begin
                // Deterministic valid gaps exercise metadata/valid alignment.
                if (((drive_cycle % 7) == 3) || ((drive_cycle % 19) == 5)) begin
                    req_in_valid = 1'b0;
                    req_in_sof = 1'b0;
                    req_in_eol = 1'b0;
                    req_in_eof = 1'b0;
                end else begin
                    req_in_valid = 1'b1;
                    req_in_sof = (index == 0) || ((index % 997) == 0);
                    req_in_eol = ((index % 17) == 16);
                    req_in_eof = (index == requant_vector_count - 1);
                    req_in_x = index % 1024;
                    req_in_y = (index * 7) % 512;
                    req_in_acc = requant_acc_vectors[index];
                    req_in_mult = requant_mult_vectors[index];
                    req_in_shift = requant_shift_vectors[index];
                    req_in_activation = requant_activation_vectors[index];
                    index = index + 1;
                end
                drive_cycle = drive_cycle + 1;
                @(negedge clk);
            end
            req_in_valid = 1'b0;
            req_in_sof = 1'b0;
            req_in_eol = 1'b0;
            req_in_eof = 1'b0;
            requant_driver_done = 1'b1;
        end
    endtask

    task automatic drive_residual_vectors;
        integer index;
        integer drive_cycle;
        begin
            index = 0;
            drive_cycle = 0;
            while (index < residual_vector_count) begin
                if (((drive_cycle % 5) == 1) || ((drive_cycle % 23) == 9)) begin
                    res_in_valid = 1'b0;
                    res_in_sof = 1'b0;
                    res_in_eol = 1'b0;
                    res_in_eof = 1'b0;
                end else begin
                    res_in_valid = 1'b1;
                    res_in_sof = (index == 0) || ((index % 701) == 0);
                    res_in_eol = ((index % 31) == 30);
                    res_in_eof = (index == residual_vector_count - 1);
                    res_in_x = (index * 3) % 1024;
                    res_in_y = (index * 11) % 512;
                    res_in_main = residual_main_vectors[index];
                    res_in_skip = residual_skip_vectors[index];
                    res_in_relu = residual_relu_vectors[index];
                    index = index + 1;
                end
                drive_cycle = drive_cycle + 1;
                @(negedge clk);
            end
            res_in_valid = 1'b0;
            res_in_sof = 1'b0;
            res_in_eol = 1'b0;
            res_in_eof = 1'b0;
            residual_driver_done = 1'b1;
        end
    endtask

    // Cycle-exact valid pipeline and ordered result/metadata scoreboards.
    always @(posedge clk) begin
        if (rst) begin
            requant_expected_valid <= 3'b000;
            residual_expected_valid <= 2'b00;
            requant_output_count = 0;
            residual_output_count = 0;
        end else begin
            requant_expected_valid <= {requant_expected_valid[1:0], req_in_valid};
            residual_expected_valid <= {residual_expected_valid[0], res_in_valid};
            #1;

            if (req_out_valid !== requant_expected_valid[2])
                $fatal(1, "requant valid latency mismatch");
            if (res_out_valid !== residual_expected_valid[1])
                $fatal(1, "residual valid latency mismatch");

            if (!req_out_valid) begin
                if (req_out_sof || req_out_eol || req_out_eof)
                    $fatal(1, "requant metadata asserted while invalid");
            end else begin
                if (requant_output_count >= requant_vector_count)
                    $fatal(1, "unexpected extra requant output");
                if (req_out_data !== requant_expected_vectors[requant_output_count])
                    $fatal(1, "requant mismatch index=%0d got=%h expected=%h",
                           requant_output_count, req_out_data,
                           requant_expected_vectors[requant_output_count]);
                if (req_out_x !== (requant_output_count % 1024) ||
                    req_out_y !== ((requant_output_count * 7) % 512))
                    $fatal(1, "requant coordinate mismatch index=%0d",
                           requant_output_count);
                if (req_out_sof !== ((requant_output_count == 0) ||
                                     ((requant_output_count % 997) == 0)))
                    $fatal(1, "requant SOF mismatch index=%0d", requant_output_count);
                if (req_out_eol !== ((requant_output_count % 17) == 16))
                    $fatal(1, "requant EOL mismatch index=%0d", requant_output_count);
                if (req_out_eof !==
                    (requant_output_count == requant_vector_count - 1))
                    $fatal(1, "requant EOF mismatch index=%0d", requant_output_count);
                requant_output_count = requant_output_count + 1;
            end

            if (!res_out_valid) begin
                if (res_out_sof || res_out_eol || res_out_eof)
                    $fatal(1, "residual metadata asserted while invalid");
            end else begin
                if (residual_output_count >= residual_vector_count)
                    $fatal(1, "unexpected extra residual output");
                if (res_out_data !== residual_expected_vectors[residual_output_count])
                    $fatal(1, "residual mismatch index=%0d got=%h expected=%h",
                           residual_output_count, res_out_data,
                           residual_expected_vectors[residual_output_count]);
                if (res_out_x !== ((residual_output_count * 3) % 1024) ||
                    res_out_y !== ((residual_output_count * 11) % 512))
                    $fatal(1, "residual coordinate mismatch index=%0d",
                           residual_output_count);
                if (res_out_sof !== ((residual_output_count == 0) ||
                                     ((residual_output_count % 701) == 0)))
                    $fatal(1, "residual SOF mismatch index=%0d", residual_output_count);
                if (res_out_eol !== ((residual_output_count % 31) == 30))
                    $fatal(1, "residual EOL mismatch index=%0d", residual_output_count);
                if (res_out_eof !==
                    (residual_output_count == residual_vector_count - 1))
                    $fatal(1, "residual EOF mismatch index=%0d", residual_output_count);
                residual_output_count = residual_output_count + 1;
            end
        end
    end

    initial begin
        load_requant_vectors();
        load_residual_vectors();

        repeat (5) @(negedge clk);
        rst = 1'b0;
        fork
            drive_requant_vectors();
            drive_residual_vectors();
        join

        wait (requant_driver_done && residual_driver_done &&
              requant_output_count == requant_vector_count &&
              residual_output_count == residual_vector_count);
        repeat (5) @(negedge clk);
        if (req_out_valid || res_out_valid)
            $fatal(1, "valid did not drain after final vector");

        $display("C1_R1_CNN_PRIMITIVES_PASS requant=%0d residual=%0d",
                 requant_output_count, residual_output_count);
        $finish;
    end

    initial begin
        repeat (50000) @(posedge clk);
        $fatal(1, "R1 CNN primitive test timeout");
    end

endmodule
