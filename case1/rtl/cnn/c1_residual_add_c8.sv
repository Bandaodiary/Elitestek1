`timescale 1ns/1ps

// Board-independent C8 same-scale residual-add engine.
//
// main and skip are independent ready/valid streams.  Each has a one-beat
// elastic/skid register, so either side may arrive first without loss.  A
// third one-beat register holds the output.  With both sources and the sink
// continuously ready, the engine retires one C8 pair per clock after filling.
//
// Each lane is bit-equivalent to c1_residual_add_s8: signed8 inputs are
// sign-extended and added in signed9, saturated to [-128,127], then optional
// ReLU is applied after saturation.  cfg_relu is snapshotted by start and is
// immutable through the matched EOF output handshake.
//
// Pairing requires identical x/y/SOF/EOL/EOF sidebands.  A mismatched pair is
// consumed and discarded, error_pulse/error_code identify the mismatch, and
// the entire active frame is terminated without done.  Software/upstream must
// restart the frame.  This policy prevents a dropped/misaligned token from
// silently shifting every subsequent residual pair.
module c1_residual_add_c8 #(
    parameter integer X_BITS = 16,
    parameter integer Y_BITS = 16
) (
    input  logic                   clk,
    input  logic                   rst,
    input  logic                   abort,

    input  logic                   start_valid,
    output logic                   start_ready,
    input  logic                   cfg_relu,
    output logic                   busy,
    output logic                   done,
    output logic                   error_pulse,
    output logic [1:0]             error_code,

    input  logic                   main_valid,
    output logic                   main_ready,
    input  logic [63:0]            main_data_s8,
    input  logic [X_BITS-1:0]      main_x,
    input  logic [Y_BITS-1:0]      main_y,
    input  logic                   main_sof,
    input  logic                   main_eol,
    input  logic                   main_eof,

    input  logic                   skip_valid,
    output logic                   skip_ready,
    input  logic [63:0]            skip_data_s8,
    input  logic [X_BITS-1:0]      skip_x,
    input  logic [Y_BITS-1:0]      skip_y,
    input  logic                   skip_sof,
    input  logic                   skip_eol,
    input  logic                   skip_eof,

    output logic                   out_valid,
    input  logic                   out_ready,
    output logic [63:0]            out_data_s8,
    output logic [X_BITS-1:0]      out_x,
    output logic [Y_BITS-1:0]      out_y,
    output logic                   out_sof,
    output logic                   out_eol,
    output logic                   out_eof
);

    localparam logic [1:0] ERROR_NONE = 2'd0;
    localparam logic [1:0] ERROR_COORDINATE = 2'd1;
    localparam logic [1:0] ERROR_MARKER = 2'd2;
    localparam logic [1:0] ERROR_COORDINATE_AND_MARKER = 2'd3;

    logic relu_q;
    logic input_complete;

    logic main_buffer_valid;
    logic [63:0] main_buffer_data;
    logic [X_BITS-1:0] main_buffer_x;
    logic [Y_BITS-1:0] main_buffer_y;
    logic main_buffer_sof, main_buffer_eol, main_buffer_eof;

    logic skip_buffer_valid;
    logic [63:0] skip_buffer_data;
    logic [X_BITS-1:0] skip_buffer_x;
    logic [Y_BITS-1:0] skip_buffer_y;
    logic skip_buffer_sof, skip_buffer_eol, skip_buffer_eof;

    logic output_slot_ready;
    logic pair_available;
    logic coordinate_match;
    logic marker_match;
    logic pair_match;
    logic pair_terminal;
    logic pair_process;
    logic allow_replacement;
    logic main_take;
    logic skip_take;
    logic [1:0] mismatch_code;
    logic [63:0] pair_result;
    logic signed [8:0] lane_sum [0:7];
    integer lane;

    function automatic logic signed [7:0] saturate_relu_s9(
        input logic signed [8:0] value,
        input logic              relu_enable
    );
        logic signed [7:0] saturated;
        begin
            if (value > 9'sd127)
                saturated = 8'sh7f;
            else if (value < -9'sd128)
                saturated = 8'sh80;
            else
                saturated = value[7:0];

            if (relu_enable && saturated[7])
                saturate_relu_s9 = 8'sd0;
            else
                saturate_relu_s9 = saturated;
        end
    endfunction

    always_comb begin
        start_ready = !rst && !abort && !busy && !main_buffer_valid &&
                      !skip_buffer_valid && !out_valid;
        output_slot_ready = !out_valid || out_ready;
        pair_available = main_buffer_valid && skip_buffer_valid;
        coordinate_match = (main_buffer_x == skip_buffer_x) &&
                           (main_buffer_y == skip_buffer_y);
        marker_match = (main_buffer_sof == skip_buffer_sof) &&
                       (main_buffer_eol == skip_buffer_eol) &&
                       (main_buffer_eof == skip_buffer_eof);
        pair_match = coordinate_match && marker_match;
        pair_terminal = pair_match && main_buffer_eof;
        pair_process = busy && !input_complete && pair_available &&
                       output_slot_ready;
        // Do not accept tokens behind a pair that will terminate or abort the
        // frame; otherwise those handshakes would be silently discarded.
        allow_replacement = pair_process && pair_match && !pair_terminal;

        main_ready = !abort && busy && !input_complete &&
                     (!main_buffer_valid || allow_replacement);
        skip_ready = !abort && busy && !input_complete &&
                     (!skip_buffer_valid || allow_replacement);
        main_take = main_valid && main_ready;
        skip_take = skip_valid && skip_ready;

        case ({!marker_match, !coordinate_match})
            2'b01: mismatch_code = ERROR_COORDINATE;
            2'b10: mismatch_code = ERROR_MARKER;
            2'b11: mismatch_code = ERROR_COORDINATE_AND_MARKER;
            default: mismatch_code = ERROR_NONE;
        endcase

        pair_result = '0;
        for (lane = 0; lane < 8; lane = lane + 1) begin
            lane_sum[lane] =
                $signed({main_buffer_data[lane*8+7],
                         main_buffer_data[lane*8 +: 8]}) +
                $signed({skip_buffer_data[lane*8+7],
                         skip_buffer_data[lane*8 +: 8]});
            pair_result[lane*8 +: 8] =
                saturate_relu_s9(lane_sum[lane], relu_q);
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            relu_q <= 1'b0;
            input_complete <= 1'b0;
            main_buffer_valid <= 1'b0;
            main_buffer_data <= 64'd0;
            main_buffer_x <= '0;
            main_buffer_y <= '0;
            main_buffer_sof <= 1'b0;
            main_buffer_eol <= 1'b0;
            main_buffer_eof <= 1'b0;
            skip_buffer_valid <= 1'b0;
            skip_buffer_data <= 64'd0;
            skip_buffer_x <= '0;
            skip_buffer_y <= '0;
            skip_buffer_sof <= 1'b0;
            skip_buffer_eol <= 1'b0;
            skip_buffer_eof <= 1'b0;
            out_valid <= 1'b0;
            out_data_s8 <= 64'd0;
            out_x <= '0;
            out_y <= '0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            error_pulse <= 1'b0;
            error_code <= ERROR_NONE;
        end else if (abort) begin
            relu_q <= 1'b0;
            input_complete <= 1'b0;
            main_buffer_valid <= 1'b0;
            skip_buffer_valid <= 1'b0;
            out_valid <= 1'b0;
            out_sof <= 1'b0;
            out_eol <= 1'b0;
            out_eof <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            error_pulse <= 1'b0;
            error_code <= ERROR_NONE;
        end else begin
            done <= 1'b0;
            error_pulse <= 1'b0;
            error_code <= ERROR_NONE;

            if (start_valid && start_ready) begin
                relu_q <= cfg_relu;
                input_complete <= 1'b0;
                busy <= 1'b1;
            end

            if (out_valid && out_ready)
                out_valid <= 1'b0;

            if (pair_process) begin
                main_buffer_valid <= 1'b0;
                skip_buffer_valid <= 1'b0;
                if (pair_match) begin
                    out_valid <= 1'b1;
                    out_data_s8 <= pair_result;
                    out_x <= main_buffer_x;
                    out_y <= main_buffer_y;
                    out_sof <= main_buffer_sof;
                    out_eol <= main_buffer_eol;
                    out_eof <= main_buffer_eof;
                    if (pair_terminal)
                        input_complete <= 1'b1;

                    if (main_take) begin
                        main_buffer_valid <= 1'b1;
                        main_buffer_data <= main_data_s8;
                        main_buffer_x <= main_x;
                        main_buffer_y <= main_y;
                        main_buffer_sof <= main_sof;
                        main_buffer_eol <= main_eol;
                        main_buffer_eof <= main_eof;
                    end
                    if (skip_take) begin
                        skip_buffer_valid <= 1'b1;
                        skip_buffer_data <= skip_data_s8;
                        skip_buffer_x <= skip_x;
                        skip_buffer_y <= skip_y;
                        skip_buffer_sof <= skip_sof;
                        skip_buffer_eol <= skip_eol;
                        skip_buffer_eof <= skip_eof;
                    end
                end else begin
                    // Explicit policy: consume/drop the bad pair and abort the
                    // frame.  No result is produced for this pair.
                    out_valid <= 1'b0;
                    out_sof <= 1'b0;
                    out_eol <= 1'b0;
                    out_eof <= 1'b0;
                    input_complete <= 1'b0;
                    busy <= 1'b0;
                    error_pulse <= 1'b1;
                    error_code <= mismatch_code;
                end
            end else begin
                if (main_take) begin
                    main_buffer_valid <= 1'b1;
                    main_buffer_data <= main_data_s8;
                    main_buffer_x <= main_x;
                    main_buffer_y <= main_y;
                    main_buffer_sof <= main_sof;
                    main_buffer_eol <= main_eol;
                    main_buffer_eof <= main_eof;
                end
                if (skip_take) begin
                    skip_buffer_valid <= 1'b1;
                    skip_buffer_data <= skip_data_s8;
                    skip_buffer_x <= skip_x;
                    skip_buffer_y <= skip_y;
                    skip_buffer_sof <= skip_sof;
                    skip_buffer_eol <= skip_eol;
                    skip_buffer_eof <= skip_eof;
                end
            end

            if (out_valid && out_ready && out_eof) begin
                out_valid <= 1'b0;
                input_complete <= 1'b0;
                main_buffer_valid <= 1'b0;
                skip_buffer_valid <= 1'b0;
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst && !abort) begin
            if (done && busy)
                $fatal(1, "c1_residual_add_c8 done asserted while busy");
            if (error_pulse && (error_code == ERROR_NONE))
                $fatal(1, "c1_residual_add_c8 error pulse without code");
            if (error_pulse && out_valid)
                $fatal(1, "c1_residual_add_c8 mismatched pair produced output");
        end
    end
`endif

endmodule

