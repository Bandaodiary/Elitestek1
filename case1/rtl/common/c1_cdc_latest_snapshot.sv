`timescale 1ns/1ps
// Latest-value telemetry, NOT a lossless event/command queue. Intermediate
// source values may coalesce. Both domains require coordinated global reset.
// Resets are synchronous: both clocks must run long enough to sample reset
// before either domain resumes normal traffic. Reset drops any in-flight
// snapshot; after coordinated reset the current source value is resent.
// The bundled bus stays fixed from request through returned ACK. Implementers
// must constrain its source-hold -> destination capture delay against the
// two-stage request synchronizer; ASYNC_REG alone is not a bus timing proof.
module c1_cdc_latest_snapshot #(parameter integer WIDTH=41) (
    input logic src_clk, src_rst,
    input logic [WIDTH-1:0] src_data,
    input logic dst_clk, dst_rst,
    output logic [WIDTH-1:0] dst_data,
    output logic dst_valid, dst_update
);
    logic [WIDTH-1:0] payload_q;
    logic request_q, sent_q, acknowledge_q;
    (* ASYNC_REG = "TRUE" *) logic req_sync1_q, req_sync2_q;
    (* ASYNC_REG = "TRUE" *) logic ack_sync1_q, ack_sync2_q;
    wire src_ready = request_q == ack_sync2_q;
    wire src_accept = !src_rst && src_ready && (!sent_q || src_data != payload_q);

    always_ff @(posedge src_clk) begin
        if(src_rst) begin
            payload_q <= '0;
            request_q <= 0;
            sent_q <= 0;
            ack_sync1_q <= 0;
            ack_sync2_q <= 0;
        end else begin
            ack_sync1_q <= acknowledge_q;
            ack_sync2_q <= ack_sync1_q;
            if(src_accept) begin
                payload_q <= src_data;
                request_q <= ~request_q;
                sent_q <= 1;
            end
        end
    end
    always_ff @(posedge dst_clk) begin
        if(dst_rst) begin
            req_sync1_q <= 0;
            req_sync2_q <= 0;
            acknowledge_q <= 0;
            dst_data <= '0;
            dst_valid <= 0;
            dst_update <= 0;
        end else begin
            req_sync1_q <= request_q;
            req_sync2_q <= req_sync1_q;
            dst_update <= 0;
            if(req_sync2_q != acknowledge_q) begin
                dst_data <= payload_q;
                dst_valid <= 1;
                dst_update <= 1;
                acknowledge_q <= req_sync2_q;
            end
        end
    end
endmodule
