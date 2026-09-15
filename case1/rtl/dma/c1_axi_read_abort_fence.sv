`timescale 1ns/1ps

// Converts an arbitrary abort request into a one-cycle cancel pulse that
// cannot retract an ARVALID already observed by an outer transaction-locking
// arbiter. If ARVALID is stalled, cancellation waits for the address
// handshake; after a committed AR, cancellation is delivered immediately so
// the leaf drains R while suppressing its response.
module c1_axi_read_abort_fence (
    input  logic clk,
    input  logic rst,
    input  logic abort_request,
    input  logic leaf_arvalid,
    input  logic leaf_arready,
    output logic abort_pending,
    output logic abort_to_leaf
);

    logic request_seen_q;
    logic pending_q;
    logic request_edge;
    logic cancellation_safe;

    always_comb begin
        request_edge = abort_request && !request_seen_q;
        cancellation_safe = !leaf_arvalid || leaf_arready;
        abort_to_leaf = (pending_q || request_edge) &&
                        cancellation_safe;
        abort_pending = pending_q || request_edge;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            request_seen_q <= 1'b0;
            pending_q <= 1'b0;
        end else begin
            if (!abort_request)
                request_seen_q <= 1'b0;
            else
                request_seen_q <= 1'b1;

            if (request_edge)
                pending_q <= 1'b1;
            if (abort_to_leaf)
                pending_q <= 1'b0;
        end
    end

endmodule
