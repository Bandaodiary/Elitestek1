// Lossless two-consumer fork after Resize/centered-C8 encoding.
// One token is retained until BOTH CNN and preview have accepted it. Each
// branch sees valid exactly until its own handshake; a faster branch cannot
// consume the same pixel twice. A fully retiring token may be replaced on
// the same edge (one pixel/clock steady state, one register of latency).
// rst is a synchronous destructive flush and must be shared with the job's
// stream cancellation boundary. It does NOT retire external AXI requests.
module c1_r1_preview_fork (
    input logic clk, rst,
    input logic in_valid, output logic in_ready,
    input logic [63:0] in_data_s8,
    input logic [15:0] in_x, in_y,
    input logic in_sof, in_eol, in_eof,
    output logic cnn_valid, input logic cnn_ready,
    output logic [63:0] cnn_data_s8,
    output logic [15:0] cnn_x, cnn_y,
    output logic cnn_sof, cnn_eol, cnn_eof,
    output logic preview_valid, input logic preview_ready,
    output logic [23:0] preview_rgb,
    output logic [15:0] preview_x, preview_y,
    output logic preview_sof, preview_eol, preview_eof,
    output logic busy
);
    logic [98:0] token_q;
    logic [1:0] pending_q;
    logic [1:0] remaining;
    always_comb begin
        remaining = pending_q & ~{preview_ready,cnn_ready};
        in_ready = !rst && (remaining == 0);
        cnn_valid = !rst && pending_q[0];
        preview_valid = !rst && pending_q[1];
        busy = !rst && (pending_q != 0);
        {cnn_sof,cnn_eol,cnn_eof,cnn_y,cnn_x,cnn_data_s8} = token_q;
        {preview_sof,preview_eol,preview_eof} = token_q[98:96];
        preview_y = token_q[95:80];
        preview_x = token_q[79:64];
        // Centered signed C8 has R/G/B in byte lanes 0/1/2. Restore RGB888,
        // not BGR, without saturation or re-quantization (u8 = s8 xor 128).
        preview_rgb = {token_q[7:0]^8'h80,token_q[15:8]^8'h80,token_q[23:16]^8'h80};
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            pending_q <= 0;
        end else begin
            pending_q <= remaining;
            if(in_valid && in_ready) begin
                token_q <= {in_sof,in_eol,in_eof,in_y,in_x,in_data_s8};
                pending_q <= 2'b11;
            end
        end
    end
endmodule
