`timescale 1ns/1ps

module tb_c1_layer_scheduler;
    localparam integer DESC_BITS = 64;
    localparam integer COUNT_BITS = 4;
    localparam integer LAYERS = 5;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start_pulse = 1'b0;
    logic abort_pulse = 1'b0;
    logic [COUNT_BITS-1:0] descriptor_count = '0;
    logic descriptor_request_valid;
    logic descriptor_request_ready = 1'b0;
    logic [COUNT_BITS-1:0] descriptor_request_index;
    logic descriptor_response_valid = 1'b0;
    logic descriptor_response_error = 1'b0;
    logic [DESC_BITS-1:0] descriptor_response_data = '0;
    logic layer_command_valid;
    logic layer_command_ready = 1'b0;
    logic [COUNT_BITS-1:0] layer_command_index;
    logic [DESC_BITS-1:0] layer_command_descriptor;
    logic layer_done_pulse = 1'b0;
    logic layer_error_pulse = 1'b0;
    logic busy, done_pulse, error_pulse, aborted_pulse;
    logic [COUNT_BITS-1:0] active_layer_index;

    integer cycles = 0;
    integer requests = 0;
    integer launches = 0;
    integer response_delay = -1;
    integer done_delay = -1;
    integer pending_index = 0;
    logic [15:0] lfsr = 16'h1ace;

    always #5 clk = ~clk;

    function automatic [DESC_BITS-1:0] descriptor_for(input integer index);
        descriptor_for = 64'hc100_0000_0000_0000 | index;
    endfunction

    c1_layer_scheduler #(
        .DESCRIPTOR_BITS(DESC_BITS), .COUNT_BITS(COUNT_BITS)
    ) dut (
        .clk, .rst_n, .start_pulse, .abort_pulse, .descriptor_count,
        .descriptor_request_valid, .descriptor_request_ready,
        .descriptor_request_index, .descriptor_response_valid,
        .descriptor_response_error, .descriptor_response_data,
        .layer_command_valid, .layer_command_ready, .layer_command_index,
        .layer_command_descriptor, .layer_done_pulse, .layer_error_pulse,
        .busy, .done_pulse, .error_pulse, .aborted_pulse, .active_layer_index
    );

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        descriptor_count = LAYERS;
        @(negedge clk);
        start_pulse = 1'b1;
        @(negedge clk);
        start_pulse = 1'b0;
        wait (done_pulse);
        if (requests != LAYERS || launches != LAYERS || busy)
            $fatal(1, "scheduler layer count mismatch req=%0d launch=%0d", requests, launches);

        // Zero descriptors is a configuration error and must not enter busy.
        @(negedge clk);
        descriptor_count = 0;
        start_pulse = 1'b1;
        @(negedge clk);
        start_pulse = 1'b0;
        if (!error_pulse || busy)
            $fatal(1, "scheduler failed zero-count rejection");

        // A live job can be aborted from any wait state.
        @(negedge clk);
        descriptor_count = 3;
        start_pulse = 1'b1;
        @(negedge clk);
        start_pulse = 1'b0;
        wait (busy);
        abort_pulse = 1'b1;
        @(negedge clk);
        abort_pulse = 1'b0;
        if (!aborted_pulse || busy)
            $fatal(1, "scheduler abort failed");

        $display("C1_LAYER_SCHEDULER_PASS layers=%0d cycles=%0d", LAYERS, cycles);
        $finish;
    end

    always @(negedge clk) begin
        cycles = cycles + 1;
        if (!rst_n) begin
            descriptor_request_ready = 1'b0;
            layer_command_ready = 1'b0;
            descriptor_response_valid = 1'b0;
            layer_done_pulse = 1'b0;
            response_delay = -1;
            done_delay = -1;
        end else begin
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            descriptor_request_ready = lfsr[0] | lfsr[3];
            layer_command_ready = lfsr[1] | lfsr[5];
            descriptor_response_valid = 1'b0;
            layer_done_pulse = 1'b0;

            if (descriptor_request_valid && descriptor_request_ready) begin
                if (response_delay >= 0)
                    $fatal(1, "multiple descriptor requests outstanding");
                pending_index = descriptor_request_index;
                response_delay = lfsr[7:6];
                requests = requests + 1;
            end
            if (response_delay == 0) begin
                descriptor_response_valid = 1'b1;
                descriptor_response_data = descriptor_for(pending_index);
                response_delay = -1;
            end else if (response_delay > 0) begin
                response_delay = response_delay - 1;
            end

            if (layer_command_valid && layer_command_ready) begin
                if (layer_command_index !== launches[COUNT_BITS-1:0] ||
                    layer_command_descriptor !== descriptor_for(launches))
                    $fatal(1, "layer command mismatch launch=%0d", launches);
                launches = launches + 1;
                done_delay = lfsr[9:8] + 1;
            end
            if (done_delay == 0) begin
                layer_done_pulse = 1'b1;
                done_delay = -1;
            end else if (done_delay > 0) begin
                done_delay = done_delay - 1;
            end
        end
        if (cycles > 2000)
            $fatal(1, "scheduler timeout");
    end
endmodule
