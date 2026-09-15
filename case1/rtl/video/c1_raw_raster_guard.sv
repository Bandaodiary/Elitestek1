`timescale 1ns/1ps
// One explicitly started frame of backpressured RAW10 tokens. A malformed
// token is consumed locally but NEVER forwarded; the first error latches and
// blocks both interfaces until cancel/reset. Previously forwarded pixels are
// not recalled: integration must discard/retire the downstream partial frame.
// This block neither resets an ISP nor releases external buffer ownership.
module c1_raw_raster_guard #(
    parameter integer FRAME_WIDTH=642, FRAME_HEIGHT=482,
    parameter integer X_BITS=(FRAME_WIDTH<=1)?1:$clog2(FRAME_WIDTH),
    parameter integer Y_BITS=(FRAME_HEIGHT<=1)?1:$clog2(FRAME_HEIGHT)
) (
    input logic clk,rst,cancel,start_valid,
    output logic start_ready,busy,done,error,
    output logic [3:0] error_code,
    input logic s_valid,
    output logic s_ready,
    input logic [9:0] s_raw10,
    input logic [X_BITS-1:0] s_x,
    input logic [Y_BITS-1:0] s_y,
    input logic s_sof,s_eol,s_eof,
    output logic m_valid,
    input logic m_ready,
    output logic [9:0] m_raw10,
    output logic [X_BITS-1:0] m_x,
    output logic [Y_BITS-1:0] m_y,
    output logic m_sof,m_eol,m_eof
);
    logic active_q;
    logic [X_BITS-1:0] x_q;
    logic [Y_BITS-1:0] y_q;
    logic [3:0] violation;
    wire last_x=x_q==FRAME_WIDTH-1;
    wire last_y=y_q==FRAME_HEIGHT-1;
    always_comb begin
        violation=0;
        if(s_x!=x_q || s_y!=y_q) violation=1;
        else if(s_sof!=((x_q==0)&&(y_q==0))) violation=2;
        else if(s_eol!=last_x) violation=3;
        else if(s_eof!=(last_x&&last_y)) violation=4;
        start_ready=!rst && !cancel && !active_q && !error;
        busy=active_q || error;
        m_valid=!rst && !cancel && active_q && !error && s_valid && (violation==0);
        s_ready=!rst && !cancel && active_q && !error && ((violation!=0)||m_ready);
        {m_raw10,m_x,m_y,m_sof,m_eol,m_eof}={s_raw10,s_x,s_y,s_sof,s_eol,s_eof};
    end
    always_ff @(posedge clk) begin
        if(rst || cancel) begin
            active_q<=0; x_q<='0; y_q<='0;
            done<=0; error<=0; error_code<=0;
        end else begin
            done<=0;
            if(start_valid && start_ready) begin
                active_q<=1; x_q<='0; y_q<='0;
            end
            if(s_valid && s_ready) begin
                if(violation!=0) begin
                    error<=1; error_code<=violation;
                end else if(last_x && last_y) begin
                    active_q<=0; done<=1;
                end else if(last_x) begin
                    x_q<='0; y_q<=y_q+1'b1;
                end else x_q<=x_q+1'b1;
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 || X_BITS<1 || Y_BITS<1 ||
           FRAME_WIDTH>(64'd1<<X_BITS) || FRAME_HEIGHT>(64'd1<<Y_BITS))
            $fatal(1,"raw raster guard geometry/coordinate width invalid");
    end
`endif
endmodule
