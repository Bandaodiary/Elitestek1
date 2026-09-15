// Atomic two-participant runtime lifecycle join, in one clock domain.
// Children must clear old done/error state at child_start, and keep busy high
// until all their externally committed transactions have retired. Errors are
// reported to the parent, which must cancel BOTH children. This block never
// resets a child or fabricates an AXI terminal response.
module c1_r1_runtime_join (
    input logic clk, rst,
    input logic start_valid, output logic start_ready,
    input logic cancel,
    output logic child_start,
    input logic left_ready, right_ready,
    input logic left_busy, left_done, left_error,
    input logic [7:0] left_error_code,
    input logic [31:0] left_error_address,
    input logic right_busy, right_done, right_error,
    input logic [7:0] right_error_code,
    input logic [31:0] right_error_address,
    output logic busy, done, error,
    output logic [7:0] error_code,
    output logic [31:0] error_address
);
    logic active_q, cancel_q, fault_q;
    logic left_done_q, right_done_q;
    logic [7:0] fault_code_q;
    logic [31:0] fault_address_q;
    logic children_idle;
    always_comb begin
        children_idle = !left_busy && !right_busy;
        busy = active_q || !children_idle;
        start_ready = !rst && !cancel && !busy && left_ready && right_ready;
        child_start = start_valid && start_ready;
        // Ignore idle/launch-edge residue. First observed fault wins; left
        // wins only when both children first report an error on the same edge.
        error = !rst && active_q && (fault_q || left_error || right_error);
        error_code = 0;
        error_address = 0;
        if (error) begin
            error_code = fault_q ? fault_code_q :
                         (left_error ? left_error_code : right_error_code);
            error_address = fault_q ? fault_address_q :
                            (left_error ? left_error_address : right_error_address);
        end
        // Combinational final qualification lets the parent's completion-vs-
        // watchdog priority act on this very edge, without an extra done flop.
        done = !rst && active_q && !cancel && !cancel_q && !error &&
               (left_done_q || left_done) && (right_done_q || right_done) && children_idle;
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            active_q<=0;cancel_q<=0;fault_q<=0;
            left_done_q<=0;right_done_q<=0;
            fault_code_q<=0;fault_address_q<=0;
        end else if (child_start) begin
            active_q<=1;cancel_q<=0;fault_q<=0;
            left_done_q<=0;right_done_q<=0;
            fault_code_q<=0;fault_address_q<=0;
        end else if (active_q) begin
            if (left_done) left_done_q<=1;
            if (right_done) right_done_q<=1;
            if (!fault_q && (left_error || right_error)) begin
                fault_q<=1;
                fault_code_q<=left_error ? left_error_code : right_error_code;
                fault_address_q<=left_error ? left_error_address : right_error_address;
            end
            if (cancel) cancel_q<=1;
            // Canceled stream processors need not produce done. Their busy
            // contract, particularly the DMA's B retirement, is still binding.
            if (done || ((cancel || cancel_q) && children_idle)) active_q<=0;
        end
    end
endmodule
