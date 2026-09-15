// Lossless single-event clock-domain crossing using a toggle/ack handshake.
//
// The source may present a one-cycle src_pulse only when src_ready is high.
// Each accepted event produces exactly one dst_pulse in the destination
// domain. A new source event is blocked until the acknowledgement completes.
// Both synchronous resets must be asserted together when flushing the system.
`timescale 1ns/1ps

module c1_event_cdc (
    input  logic src_clk,
    input  logic src_rst,
    input  logic src_pulse,
    output logic src_ready,

    input  logic dst_clk,
    input  logic dst_rst,
    output logic dst_pulse
);
    logic src_toggle;
    (* ASYNC_REG = "TRUE" *) logic dst_request_sync1;
    (* ASYNC_REG = "TRUE" *) logic dst_request_sync2;
    logic dst_seen_toggle;
    (* ASYNC_REG = "TRUE" *) logic src_ack_sync1;
    (* ASYNC_REG = "TRUE" *) logic src_ack_sync2;

    always_comb begin
        src_ready = !src_rst && (src_ack_sync2 == src_toggle);
    end

    always_ff @(posedge src_clk) begin
        if (src_rst) begin
            src_toggle <= 1'b0;
        end else if (src_pulse && src_ready) begin
            src_toggle <= ~src_toggle;
        end
    end

    always_ff @(posedge dst_clk) begin
        if (dst_rst) begin
            dst_request_sync1 <= 1'b0;
            dst_request_sync2 <= 1'b0;
            dst_seen_toggle <= 1'b0;
            dst_pulse <= 1'b0;
        end else begin
            dst_request_sync1 <= src_toggle;
            dst_request_sync2 <= dst_request_sync1;
            dst_pulse <= 1'b0;
            if (dst_request_sync2 != dst_seen_toggle) begin
                dst_seen_toggle <= dst_request_sync2;
                dst_pulse <= 1'b1;
            end
        end
    end

    always_ff @(posedge src_clk) begin
        if (src_rst) begin
            src_ack_sync1 <= 1'b0;
            src_ack_sync2 <= 1'b0;
        end else begin
            src_ack_sync1 <= dst_seen_toggle;
            src_ack_sync2 <= src_ack_sync1;
        end
    end
endmodule
