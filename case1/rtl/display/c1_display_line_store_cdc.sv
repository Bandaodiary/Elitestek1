`timescale 1ns/1ps

// Two-bank RGB888 line store crossing from a prefetch/core clock to the
// unstalled pixel clock.  Completed-line ownership crosses the domains with
// toggle/ack handshakes; line pixels themselves remain stable in the selected
// bank until the pixel side acknowledges the final request of that line.
//
// Core-side contract:
//   * s_x/s_y are raster coordinates and s_eol marks the final accepted pixel;
//   * even and odd lines map to independent banks;
//   * s_ready backpressures a producer before it overwrites an unconsumed line.
//
// Pixel-side contract:
//   * every request produces a registered response one pixel clock later;
//   * a missing/mismatched line returns black and pulses underflow;
//   * request_last acknowledges the selected bank after its final pixel has
//     been captured into the response register.
//
// The RGB arrays intentionally have one write clock and one read clock and are
// not reset.  This is the portable simple-dual-port, dual-clock RAM boundary;
// final Efinity mapping may replace only this storage wrapper if required.
module c1_display_line_store_cdc #(
    parameter integer MAX_WIDTH = 640,
    parameter integer X_BITS = (MAX_WIDTH <= 1) ? 1 : $clog2(MAX_WIDTH),
    parameter integer Y_BITS = 16
) (
    input  logic                  core_clk,
    input  logic                  core_rst,
    input  logic                  s_valid,
    output logic                  s_ready,
    input  logic [23:0]           s_rgb,
    input  logic [X_BITS-1:0]     s_x,
    input  logic [Y_BITS-1:0]     s_y,
    input  logic                  s_eol,
    output logic                  primed,
    output logic                  empty,

    input  logic                  pixel_clk,
    input  logic                  pixel_rst,
    input  logic                  request,
    input  logic [X_BITS-1:0]     request_x,
    input  logic [Y_BITS-1:0]     request_y,
    input  logic                  request_last,
    output logic                  response_valid,
    output logic [23:0]           response_rgb,
    output logic                  underflow_pulse
);

    logic [23:0] bank0 [0:MAX_WIDTH-1];
    logic [23:0] bank1 [0:MAX_WIDTH-1];

    logic [1:0] ready_toggle_core;
    logic [Y_BITS-1:0] line_y_core [0:1];
    logic [1:0] ack_toggle_pixel;

    logic [1:0] ack_sync1_core;
    logic [1:0] ack_sync2_core;
    logic [1:0] ready_sync1_pixel;
    logic [1:0] ready_sync2_pixel;
    logic [1:0] ready_sync3_pixel;
    logic [Y_BITS-1:0] line_y_sync1_pixel [0:1];
    logic [Y_BITS-1:0] line_y_sync2_pixel [0:1];

    logic selected_bank_free;
    logic selected_bank_pending;
    logic selected_line_matches;
    logic push_fire;

    always_comb begin
        selected_bank_free =
            (ready_toggle_core[s_y[0]] == ack_sync2_core[s_y[0]]);
        s_ready = !core_rst && (s_x < MAX_WIDTH) && selected_bank_free;
        push_fire = s_valid && s_ready;
        primed = (ready_toggle_core[0] != ack_sync2_core[0]) &&
                 (ready_toggle_core[1] != ack_sync2_core[1]);
        empty = (ready_toggle_core[0] == ack_sync2_core[0]) &&
                (ready_toggle_core[1] == ack_sync2_core[1]);

        selected_bank_pending =
            (ready_sync3_pixel[request_y[0]] !=
             ack_toggle_pixel[request_y[0]]);
        selected_line_matches =
            (line_y_sync2_pixel[request_y[0]] == request_y);
    end

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            ready_toggle_core <= 2'b00;
            line_y_core[0] <= '0;
            line_y_core[1] <= '0;
        end else if (push_fire) begin
            if (s_y[0])
                bank1[s_x] <= s_rgb;
            else
                bank0[s_x] <= s_rgb;

            if (s_eol) begin
                line_y_core[s_y[0]] <= s_y;
                ready_toggle_core[s_y[0]] <=
                    ~ready_toggle_core[s_y[0]];
            end
        end
    end

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            ack_sync1_core <= 2'b00;
            ack_sync2_core <= 2'b00;
        end else begin
            ack_sync1_core <= ack_toggle_pixel;
            ack_sync2_core <= ack_sync1_core;
        end
    end

    // The ownership toggle uses three destination flops while the bundled
    // line number uses two.  Thus the multi-bit line number has a complete
    // extra pixel cycle to settle before a new ownership event is observed.
    always_ff @(posedge pixel_clk) begin
        if (pixel_rst) begin
            ready_sync1_pixel <= 2'b00;
            ready_sync2_pixel <= 2'b00;
            ready_sync3_pixel <= 2'b00;
            line_y_sync1_pixel[0] <= '0;
            line_y_sync1_pixel[1] <= '0;
            line_y_sync2_pixel[0] <= '0;
            line_y_sync2_pixel[1] <= '0;
        end else begin
            ready_sync1_pixel <= ready_toggle_core;
            ready_sync2_pixel <= ready_sync1_pixel;
            ready_sync3_pixel <= ready_sync2_pixel;
            line_y_sync1_pixel[0] <= line_y_core[0];
            line_y_sync1_pixel[1] <= line_y_core[1];
            line_y_sync2_pixel[0] <= line_y_sync1_pixel[0];
            line_y_sync2_pixel[1] <= line_y_sync1_pixel[1];
        end
    end

    always_ff @(posedge pixel_clk) begin
        if (pixel_rst) begin
            ack_toggle_pixel <= 2'b00;
            response_valid <= 1'b0;
            response_rgb <= 24'h000000;
            underflow_pulse <= 1'b0;
        end else begin
            response_valid <= 1'b0;
            underflow_pulse <= 1'b0;

            if (request) begin
                response_valid <= 1'b1;
                if ((request_x < MAX_WIDTH) && selected_bank_pending &&
                    selected_line_matches) begin
                    if (request_y[0])
                        response_rgb <= bank1[request_x];
                    else
                        response_rgb <= bank0[request_x];
                end else begin
                    response_rgb <= 24'h000000;
                    underflow_pulse <= 1'b1;
                end

                // A stale line with the same parity is also released at the
                // end of the requested line.  This guarantees recovery after
                // a dropped display frame instead of permanently deadlocking
                // that ping-pong bank.
                if (request_last && selected_bank_pending)
                    ack_toggle_pixel[request_y[0]] <=
                        ready_sync3_pixel[request_y[0]];
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (MAX_WIDTH < 2)
            $fatal(1, "c1_display_line_store_cdc MAX_WIDTH must be >= 2");
        if (Y_BITS < 2)
            $fatal(1, "c1_display_line_store_cdc Y_BITS must be >= 2");
    end

    always_ff @(posedge core_clk) begin
        if (!core_rst && s_valid && (s_x >= MAX_WIDTH))
            $fatal(1, "display prefetch x exceeds MAX_WIDTH");
        if (!core_rst && push_fire && s_eol &&
            (ready_toggle_core[s_y[0]] != ack_sync2_core[s_y[0]]))
            $fatal(1, "display line ownership toggled while bank was busy");
    end
`endif

endmodule
