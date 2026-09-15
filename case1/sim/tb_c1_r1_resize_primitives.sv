`timescale 1ns/1ps

module tb_c1_r1_resize_primitives;
    localparam integer MAX_CONFIGS = 64;
    localparam integer MAX_REQUESTS = 30000;
    localparam integer MAX_INTERP = 12000;

    reg clk = 1'b0;
    reg rst = 1'b1;

    reg coord_start = 1'b0;
    wire coord_start_ready;
    reg [15:0] coord_win = 16'd0;
    reg [15:0] coord_hin = 16'd0;
    reg [15:0] coord_wout = 16'd0;
    reg [15:0] coord_hout = 16'd0;
    reg signed [31:0] coord_x_step = 32'sd0;
    reg signed [31:0] coord_y_step = 32'sd0;
    reg signed [31:0] coord_x_phase0 = 32'sd0;
    reg signed [31:0] coord_y_phase0 = 32'sd0;
    wire coord_busy;
    wire coord_done;
    wire coord_req_valid;
    reg coord_req_ready = 1'b0;
    wire coord_req_last;
    wire [15:0] coord_out_x;
    wire [15:0] coord_out_y;
    wire [15:0] coord_x0;
    wire [15:0] coord_x1;
    wire [15:0] coord_y0;
    wire [15:0] coord_y1;
    wire [12:0] coord_wx0;
    wire [12:0] coord_wx1;
    wire [12:0] coord_wy0;
    wire [12:0] coord_wy1;

    reg interp_in_valid = 1'b0;
    wire interp_in_ready;
    reg interp_in_sof = 1'b0;
    reg interp_in_eol = 1'b0;
    reg interp_in_eof = 1'b0;
    reg [15:0] interp_in_x = 16'd0;
    reg [15:0] interp_in_y = 16'd0;
    reg [23:0] interp_p00 = 24'd0;
    reg [23:0] interp_p01 = 24'd0;
    reg [23:0] interp_p10 = 24'd0;
    reg [23:0] interp_p11 = 24'd0;
    reg [12:0] interp_wx0 = 13'd0;
    reg [12:0] interp_wx1 = 13'd0;
    reg [12:0] interp_wy0 = 13'd0;
    reg [12:0] interp_wy1 = 13'd0;
    wire interp_out_valid;
    reg interp_out_ready = 1'b0;
    wire interp_out_sof;
    wire interp_out_eol;
    wire interp_out_eof;
    wire [15:0] interp_out_x;
    wire [15:0] interp_out_y;
    wire [23:0] interp_out_rgb;

    reg [15:0] config_win [0:MAX_CONFIGS-1];
    reg [15:0] config_hin [0:MAX_CONFIGS-1];
    reg [15:0] config_wout [0:MAX_CONFIGS-1];
    reg [15:0] config_hout [0:MAX_CONFIGS-1];
    reg [31:0] config_x_step [0:MAX_CONFIGS-1];
    reg [31:0] config_y_step [0:MAX_CONFIGS-1];
    reg [31:0] config_x_phase0 [0:MAX_CONFIGS-1];
    reg [31:0] config_y_phase0 [0:MAX_CONFIGS-1];
    integer config_request_start [0:MAX_CONFIGS-1];
    integer config_request_count [0:MAX_CONFIGS-1];
    reg [148:0] request_vectors [0:MAX_REQUESTS-1];
    reg [171:0] interp_vectors [0:MAX_INTERP-1];

    integer config_count = 0;
    integer request_count = 0;
    integer interp_count = 0;
    integer interp_output_count = 0;
    integer ready_cycle = 0;
    reg coord_test_done = 1'b0;
    reg interp_driver_done = 1'b0;

    reg [23:0] stalled_rgb;
    reg [15:0] stalled_x;
    reg [15:0] stalled_y;
    reg stalled_sof;
    reg stalled_eol;
    reg stalled_eof;

    always #5 clk = ~clk;

    r1_resize_request_q16 u_request (
        .clk(clk), .rst(rst), .start(coord_start),
        .start_ready(coord_start_ready),
        .cfg_win(coord_win), .cfg_hin(coord_hin),
        .cfg_wout(coord_wout), .cfg_hout(coord_hout),
        .cfg_x_step_q16(coord_x_step), .cfg_y_step_q16(coord_y_step),
        .cfg_x_phase0_q16(coord_x_phase0),
        .cfg_y_phase0_q16(coord_y_phase0),
        .busy(coord_busy), .done(coord_done),
        .req_valid(coord_req_valid), .req_ready(coord_req_ready),
        .req_last(coord_req_last), .req_out_x(coord_out_x),
        .req_out_y(coord_out_y), .req_x0(coord_x0), .req_x1(coord_x1),
        .req_y0(coord_y0), .req_y1(coord_y1),
        .req_wx0(coord_wx0), .req_wx1(coord_wx1),
        .req_wy0(coord_wy0), .req_wy1(coord_wy1)
    );

    r1_bilinear_interp_rgb888 u_interp (
        .clk(clk), .rst(rst),
        .in_valid(interp_in_valid), .in_ready(interp_in_ready),
        .in_sof(interp_in_sof), .in_eol(interp_in_eol),
        .in_eof(interp_in_eof), .in_x(interp_in_x), .in_y(interp_in_y),
        .in_rgb_y0x0(interp_p00), .in_rgb_y0x1(interp_p01),
        .in_rgb_y1x0(interp_p10), .in_rgb_y1x1(interp_p11),
        .in_wx0(interp_wx0), .in_wx1(interp_wx1),
        .in_wy0(interp_wy0), .in_wy1(interp_wy1),
        .out_valid(interp_out_valid), .out_ready(interp_out_ready),
        .out_sof(interp_out_sof), .out_eol(interp_out_eol),
        .out_eof(interp_out_eof), .out_x(interp_out_x),
        .out_y(interp_out_y), .out_rgb(interp_out_rgb)
    );

    task automatic load_vectors;
        integer fd;
        integer status;
        integer index;
        begin
            fd = $fopen("c1_r1_resize_configs.txt", "r");
            if (fd == 0) $fatal(1, "cannot open resize configs");
            status = $fscanf(fd, "%d\n", config_count);
            if (status != 1 || config_count <= 0 || config_count > MAX_CONFIGS)
                $fatal(1, "invalid resize config count %0d", config_count);
            for (index = 0; index < config_count; index = index + 1) begin
                status = $fscanf(
                    fd, "%h %h %h %h %h %h %h %h %d %d\n",
                    config_win[index], config_hin[index],
                    config_wout[index], config_hout[index],
                    config_x_step[index], config_y_step[index],
                    config_x_phase0[index], config_y_phase0[index],
                    config_request_start[index], config_request_count[index]);
                if (status != 10)
                    $fatal(1, "malformed resize config %0d", index);
            end
            $fclose(fd);

            fd = $fopen("c1_r1_resize_requests.txt", "r");
            if (fd == 0) $fatal(1, "cannot open resize requests");
            status = $fscanf(fd, "%d\n", request_count);
            if (status != 1 || request_count <= 0 || request_count > MAX_REQUESTS)
                $fatal(1, "invalid resize request count %0d", request_count);
            for (index = 0; index < request_count; index = index + 1) begin
                status = $fscanf(fd, "%h\n", request_vectors[index]);
                if (status != 1) $fatal(1, "malformed resize request %0d", index);
            end
            $fclose(fd);

            fd = $fopen("c1_r1_resize_interp_vectors.txt", "r");
            if (fd == 0) $fatal(1, "cannot open interpolation vectors");
            status = $fscanf(fd, "%d\n", interp_count);
            if (status != 1 || interp_count <= 0 || interp_count > MAX_INTERP)
                $fatal(1, "invalid interpolation vector count %0d", interp_count);
            for (index = 0; index < interp_count; index = index + 1) begin
                status = $fscanf(fd, "%h\n", interp_vectors[index]);
                if (status != 1) $fatal(1, "malformed interpolation vector %0d", index);
            end
            $fclose(fd);
        end
    endtask

    task automatic check_request;
        input integer vector_index;
        reg [148:0] expected;
        begin
            expected = request_vectors[vector_index];
            if (coord_out_x !== expected[148:133] ||
                coord_out_y !== expected[132:117] ||
                coord_x0 !== expected[116:101] ||
                coord_x1 !== expected[100:85] ||
                coord_y0 !== expected[84:69] ||
                coord_y1 !== expected[68:53] ||
                coord_wx0 !== expected[52:40] ||
                coord_wx1 !== expected[39:27] ||
                coord_wy0 !== expected[26:14] ||
                coord_wy1 !== expected[13:1] ||
                coord_req_last !== expected[0])
                $fatal(1, "resize request mismatch vector=%0d", vector_index);
            if (coord_wx0 + coord_wx1 != 13'd4096 ||
                coord_wy0 + coord_wy1 != 13'd4096)
                $fatal(1, "resize weight complement mismatch vector=%0d", vector_index);
        end
    endtask

    task automatic test_coordinate_generator;
        integer config_index;
        integer local_index;
        integer vector_index;
        integer stall_cycle;
        reg accept;
        begin
            coord_req_ready = 1'b0;
            for (config_index = 0; config_index < config_count;
                 config_index = config_index + 1) begin
                @(negedge clk);
                if (!coord_start_ready || coord_busy)
                    $fatal(1, "coordinate generator not idle before config %0d",
                           config_index);
                coord_win = config_win[config_index];
                coord_hin = config_hin[config_index];
                coord_wout = config_wout[config_index];
                coord_hout = config_hout[config_index];
                coord_x_step = config_x_step[config_index];
                coord_y_step = config_y_step[config_index];
                coord_x_phase0 = config_x_phase0[config_index];
                coord_y_phase0 = config_y_phase0[config_index];
                coord_start = 1'b1;
                @(posedge clk);
                #1;
                if (!coord_busy || !coord_req_valid || coord_start_ready)
                    $fatal(1, "coordinate start failed config=%0d", config_index);
                @(negedge clk);
                coord_start = 1'b0;

                // Perturb all external config inputs after start; requests
                // must continue from the atomically captured values.
                coord_win = 16'hffff;
                coord_hin = 16'hfffe;
                coord_wout = 16'h0001;
                coord_hout = 16'h0001;
                coord_x_step = -32'sd1;
                coord_y_step = -32'sd2;
                coord_x_phase0 = 32'sh7fffffff;
                coord_y_phase0 = 32'sh80000000;

                local_index = 0;
                stall_cycle = 0;
                while (local_index < config_request_count[config_index]) begin
                    vector_index = config_request_start[config_index] + local_index;
                    if (!coord_req_valid || !coord_busy)
                        $fatal(1, "coordinate request dropped config=%0d local=%0d",
                               config_index, local_index);
                    check_request(vector_index);

                    // Includes isolated and consecutive backpressure cycles.
                    coord_req_ready = !(((stall_cycle % 7) == 2) ||
                                        ((stall_cycle % 7) == 3) ||
                                        ((stall_cycle % 23) == 9));
                    accept = coord_req_ready;
                    @(posedge clk);
                    #1;
                    if (!accept) begin
                        if (!coord_req_valid || !coord_busy)
                            $fatal(1, "coordinate valid changed during stall");
                        check_request(vector_index);
                        if (coord_done)
                            $fatal(1, "coordinate done asserted during stall");
                    end else begin
                        if (local_index == config_request_count[config_index] - 1) begin
                            if (!coord_done || coord_busy || coord_req_valid)
                                $fatal(1, "coordinate final handshake mismatch config=%0d",
                                       config_index);
                        end else if (coord_done) begin
                            $fatal(1, "coordinate done asserted early config=%0d local=%0d",
                                   config_index, local_index);
                        end
                        local_index = local_index + 1;
                    end
                    stall_cycle = stall_cycle + 1;
                    @(negedge clk);
                end
                coord_req_ready = 1'b0;
            end
            coord_test_done = 1'b1;
        end
    endtask

    task automatic load_interp_input;
        input integer index;
        reg [171:0] vector;
        begin
            vector = interp_vectors[index];
            interp_in_valid = 1'b1;
            interp_in_sof = (index == 0) || ((index % 911) == 0);
            interp_in_eol = ((index % 43) == 42);
            interp_in_eof = (index == interp_count - 1);
            interp_in_x = (index * 7) & 16'hffff;
            interp_in_y = (index * 11) & 16'hffff;
            interp_p00 = vector[171:148];
            interp_p01 = vector[147:124];
            interp_p10 = vector[123:100];
            interp_p11 = vector[99:76];
            interp_wx0 = vector[75:63];
            interp_wx1 = vector[62:50];
            interp_wy0 = vector[49:37];
            interp_wy1 = vector[36:24];
        end
    endtask

    task automatic drive_interpolator;
        integer index;
        begin
            index = 0;
            @(negedge clk);
            load_interp_input(index);
            while (index < interp_count) begin
                @(posedge clk);
                if (interp_in_valid && interp_in_ready) begin
                    index = index + 1;
                    @(negedge clk);
                    if (index == interp_count) begin
                        interp_in_valid = 1'b0;
                        interp_in_sof = 1'b0;
                        interp_in_eol = 1'b0;
                        interp_in_eof = 1'b0;
                    end else begin
                        // Source-side gaps are legal, but once valid is raised
                        // the source holds payload until a handshake.
                        if (((index % 17) == 5) || ((index % 37) == 12)) begin
                            interp_in_valid = 1'b0;
                            interp_in_sof = 1'b0;
                            interp_in_eol = 1'b0;
                            interp_in_eof = 1'b0;
                            @(negedge clk);
                        end
                        load_interp_input(index);
                    end
                end
            end
            interp_driver_done = 1'b1;
        end
    endtask

    // Deterministic output backpressure, including consecutive stalls.
    always @(negedge clk) begin
        if (rst) begin
            ready_cycle = 0;
            interp_out_ready = 1'b0;
        end else begin
            interp_out_ready = !(((ready_cycle % 11) == 3) ||
                                 ((ready_cycle % 11) == 4) ||
                                 ((ready_cycle % 29) == 17));
            ready_cycle = ready_cycle + 1;
        end
    end

    // Compare the payload being consumed before the DUT advances at this edge.
    always @(posedge clk) begin
        if (!rst) begin
            if (!interp_out_valid) begin
                if (interp_out_sof || interp_out_eol || interp_out_eof)
                    $fatal(1, "interpolator metadata asserted while invalid");
            end
            if (interp_out_valid && interp_out_ready) begin
                if (interp_output_count >= interp_count)
                    $fatal(1, "unexpected extra interpolator output");
                if (interp_out_rgb !== interp_vectors[interp_output_count][23:0])
                    $fatal(1, "interpolator mismatch index=%0d got=%h expected=%h",
                           interp_output_count, interp_out_rgb,
                           interp_vectors[interp_output_count][23:0]);
                if (interp_out_x !== ((interp_output_count * 7) & 16'hffff) ||
                    interp_out_y !== ((interp_output_count * 11) & 16'hffff))
                    $fatal(1, "interpolator coordinate mismatch index=%0d",
                           interp_output_count);
                if (interp_out_sof !== ((interp_output_count == 0) ||
                                        ((interp_output_count % 911) == 0)))
                    $fatal(1, "interpolator SOF mismatch index=%0d",
                           interp_output_count);
                if (interp_out_eol !== ((interp_output_count % 43) == 42))
                    $fatal(1, "interpolator EOL mismatch index=%0d",
                           interp_output_count);
                if (interp_out_eof !== (interp_output_count == interp_count - 1))
                    $fatal(1, "interpolator EOF mismatch index=%0d",
                           interp_output_count);
                interp_output_count = interp_output_count + 1;
            end

            if (interp_out_valid && !interp_out_ready) begin
                stalled_rgb = interp_out_rgb;
                stalled_x = interp_out_x;
                stalled_y = interp_out_y;
                stalled_sof = interp_out_sof;
                stalled_eol = interp_out_eol;
                stalled_eof = interp_out_eof;
                #1;
                if (!interp_out_valid || interp_out_rgb !== stalled_rgb ||
                    interp_out_x !== stalled_x || interp_out_y !== stalled_y ||
                    interp_out_sof !== stalled_sof ||
                    interp_out_eol !== stalled_eol ||
                    interp_out_eof !== stalled_eof)
                    $fatal(1, "interpolator output changed while stalled");
            end
        end
    end

    initial begin
        load_vectors();
        repeat (5) @(negedge clk);
        rst = 1'b0;
        fork
            test_coordinate_generator();
            drive_interpolator();
        join

        wait (coord_test_done && interp_driver_done &&
              interp_output_count == interp_count);
        repeat (8) @(negedge clk);
        if (interp_out_valid)
            $fatal(1, "interpolator output did not drain");
        $display("C1_R1_RESIZE_PRIMITIVES_PASS configs=%0d requests=%0d interp=%0d",
                 config_count, request_count, interp_output_count);
        $finish;
    end

    initial begin
        repeat (100000) @(posedge clk);
        $fatal(1, "R1 resize primitive test timeout");
    end

endmodule
