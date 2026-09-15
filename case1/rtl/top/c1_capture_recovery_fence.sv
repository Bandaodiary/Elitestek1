`timescale 1ns/1ps
// Optional capture-recovery primitive, used by the capture frontend and SoC.
// Caller closes admission on request acceptance and keeps the source stopped
// through done. source_quiescent means an explicit source-stop acknowledgement,
// NOT merely !camera_valid. fabric_drained must include all offered/inflight AXI.
// Clocks must run to acknowledge synchronous FIFO reset; no timeout fabricates ACK.
// A held request is accepted once. Requests while !request_ready are not queued.
// Global core_rst/camera_rst must be coordinated, independently released.
module c1_capture_recovery_fence (
    input logic core_clk,core_rst,camera_clk,camera_rst,
    input logic request,source_quiescent,fabric_drained,
    output logic request_ready,busy,done,
    output logic core_fifo_reset,camera_fifo_reset
);
    logic armed_q,flush_busy;
    wire accept=request && request_ready;
    assign request_ready=!core_rst && armed_q && !flush_busy;
    assign busy=flush_busy || accept;
    always_ff @(posedge core_clk) begin
        if(core_rst) armed_q<=1;
        else if(accept) armed_q<=0;
        else if(!request) armed_q<=1;
    end
    // ACK is returned only after the camera edge actually sampled the reset
    // level; core reset remains asserted through the camera release ACK.
    c1_display_flush_reset u_flush (
        .core_clk(core_clk),.core_rst(core_rst),.request(accept),
        .safe_to_flush(source_quiescent && fabric_drained),
        .busy(flush_busy),.done(done),.core_soft_reset(core_fifo_reset),
        .pixel_clk(camera_clk),.pixel_rst(camera_rst),
        .pixel_soft_reset(camera_fifo_reset)
    );
endmodule
