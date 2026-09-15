`timescale 1ns/1ps

// Coordinated local reset for the dual-clock display prefetch/line stores.
// A request is latched until AXI readers have drained (safe_to_flush). The
// core side is then held in reset while a level handshake asserts and later
// deasserts reset in the pixel domain. done pulses only after both domains
// have observed the complete flush.
module c1_display_flush_reset (
    input  logic core_clk,
    input  logic core_rst,
    input  logic request,
    input  logic safe_to_flush,
    output logic busy,
    output logic done,
    output logic core_soft_reset,

    input  logic pixel_clk,
    input  logic pixel_rst,
    output logic pixel_soft_reset
);

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_WAIT_SAFE,
        ST_ASSERT,
        ST_RELEASE
    } state_t;

    state_t state_q;
    logic flush_level_q;
    (* ASYNC_REG = "TRUE" *) logic pixel_level_sync1_q;
    (* ASYNC_REG = "TRUE" *) logic pixel_level_sync2_q;
    logic pixel_ack_q;
    (* ASYNC_REG = "TRUE" *) logic core_ack_sync1_q;
    (* ASYNC_REG = "TRUE" *) logic core_ack_sync2_q;

    always_comb begin
        busy = (state_q != ST_IDLE);
        core_soft_reset = (state_q == ST_ASSERT) ||
                          (state_q == ST_RELEASE);
        pixel_soft_reset = pixel_rst || pixel_level_sync2_q;
    end

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            state_q <= ST_IDLE;
            flush_level_q <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state_q)
                ST_IDLE: begin
                    if (request)
                        state_q <= ST_WAIT_SAFE;
                end
                ST_WAIT_SAFE: begin
                    if (safe_to_flush) begin
                        flush_level_q <= 1'b1;
                        state_q <= ST_ASSERT;
                    end
                end
                ST_ASSERT: begin
                    if (core_ack_sync2_q) begin
                        flush_level_q <= 1'b0;
                        state_q <= ST_RELEASE;
                    end
                end
                ST_RELEASE: begin
                    if (!core_ack_sync2_q) begin
                        state_q <= ST_IDLE;
                        done <= 1'b1;
                    end
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end

    always_ff @(posedge pixel_clk) begin
        if (pixel_rst) begin
            pixel_level_sync1_q <= 1'b0;
            pixel_level_sync2_q <= 1'b0;
            pixel_ack_q <= 1'b0;
        end else begin
            pixel_level_sync1_q <= flush_level_q;
            pixel_level_sync2_q <= pixel_level_sync1_q;
            pixel_ack_q <= pixel_level_sync2_q;
        end
    end

    always_ff @(posedge core_clk) begin
        if (core_rst) begin
            core_ack_sync1_q <= 1'b0;
            core_ack_sync2_q <= 1'b0;
        end else begin
            core_ack_sync1_q <= pixel_ack_q;
            core_ack_sync2_q <= core_ack_sync1_q;
        end
    end

endmodule
