`timescale 1ns/1ps
// Ordered NHWC-C8 raster result sink (one group per pixel by default).
// Admission, the held memory request,
// and real write completion are separate events. MAX_PENDING bounds their
// total reservation count, including the one held request. No posted ACKs.
// The caller reserves a contiguous, nonwrapping width*height*groups*8 region.
module c1_pixel_result_writer #(
    parameter integer MAX_PENDING = 15,
    // Ordered packing hint only, never a completion or posted-write ACK.
    // The downstream packer must have a finite idle-build timeout so a
    // partial batch can drain after cancellation or malformed metadata.
    parameter integer BATCH_WORDS = 1,
    parameter bit MULTI_GROUP = 1'b0
) (
    input logic clk, rst, abort,
    input logic start_valid,
    output logic start_ready,
    input logic [31:0] start_base,
    input logic [15:0] start_width, start_height,
    input logic in_valid,
    output logic in_ready,
    input logic [63:0] in_data,
    input logic [2:0] in_group,
    input logic in_group_last,
    input logic [15:0] in_x, in_y,
    input logic in_sof, in_eol, in_eof,
    output logic mem_req_valid,
    input logic mem_req_ready,
    output logic [31:0] mem_req_addr,
    output logic [63:0] mem_req_data,
    output logic mem_req_end,
    input logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input logic mem_rsp_error,
    output logic busy, done, aborted, error,
    output logic [7:0] error_code,
    // Ignored in the default single-group mode for legacy callers.
    input logic [3:0] start_groups
);
    localparam integer COUNT_BITS = $clog2(MAX_PENDING+1);
    logic active_q, stopping_q, eof_q;
    logic [15:0] width_q, height_q, x_q, y_q;
    logic [3:0] groups_q;
    logic [2:0] group_q,batch_word_q;
    logic [31:0] address_q;
    logic [COUNT_BITS-1:0] pending_q;
    wire request_fire = mem_req_valid && mem_req_ready;
    wire response_fire = mem_rsp_valid && mem_rsp_ready;
    wire expected_group_last = group_q==groups_q-1'b1;
    wire expected_eol = expected_group_last && x_q==width_q-1'b1;
    wire expected_eof = expected_eol && y_q==height_q-1'b1;
    wire protocol_valid = in_group==group_q && in_group_last==expected_group_last && in_x==x_q && in_y==y_q &&
        in_sof==(group_q==0 && x_q==0 && y_q==0) && in_eol==expected_eol && in_eof==expected_eof;
    wire [COUNT_BITS:0] reservations = {1'b0,pending_q} + mem_req_valid;
    wire input_fire = in_valid && in_ready;

    assign busy = active_q;
    assign start_ready = !active_q && !rst && !abort;
    assign mem_rsp_ready = pending_q!=0 && !rst;
    assign in_ready = active_q && !stopping_q && !error && !abort && !rst && !eof_q &&
        (!mem_req_valid || mem_req_ready) &&
        (reservations<MAX_PENDING || response_fire) && !(response_fire && mem_rsp_error);

    always_ff @(posedge clk) begin
        if(rst) begin
            active_q<=0;stopping_q<=0;eof_q<=0;pending_q<=0;
            width_q<=0;height_q<=0;x_q<=0;y_q<=0;address_q<=0;
            groups_q<=1;group_q<=0;batch_word_q<=0;
            mem_req_valid<=0;mem_req_addr<=0;mem_req_data<=0;mem_req_end<=0;
            done<=0;aborted<=0;error<=0;error_code<=0;
        end else begin
            done<=0;aborted<=0;
            if(start_valid && start_ready) begin
                active_q<=1;stopping_q<=0;eof_q<=0;
                width_q<=start_width;height_q<=start_height;
                groups_q<=MULTI_GROUP ? start_groups : 4'd1;group_q<=0;batch_word_q<=0;
                x_q<=0;y_q<=0;address_q<=start_base;
                error<=0;error_code<=0;
                if(start_width==0 || start_height==0 || start_base[2:0]!=0 ||
                   (MULTI_GROUP && (start_groups<1 || start_groups>8))) begin
                    stopping_q<=1;error<=1;error_code<=8'h06;
                end
            end
            if(abort && active_q) stopping_q<=1;
            if(request_fire) mem_req_valid<=0;
            if(input_fire) begin
                if(!protocol_valid) begin
                    stopping_q<=1;error<=1;error_code<=8'h06;
                end else begin
                    mem_req_valid<=1;mem_req_addr<=address_q;mem_req_data<=in_data;
                    // Registered with the payload. EOL closes an odd tail;
                    // abort/error must NOT change an already-held end hint.
                    mem_req_end<=expected_eol || batch_word_q==BATCH_WORDS-1;
                    if(expected_eol || batch_word_q==BATCH_WORDS-1)batch_word_q<=0;
                    else batch_word_q<=batch_word_q+1'b1;
                    address_q<=address_q+32'd8;
                    if(expected_group_last) begin
                        group_q<=0;
                        if(expected_eol) begin x_q<=0;y_q<=y_q+1'b1;end
                        else x_q<=x_q+1'b1;
                    end else group_q<=group_q+1'b1;
                    if(expected_eof) eof_q<=1;
                end
            end
            case({request_fire,response_fire})
                2'b10:pending_q<=pending_q+1'b1;
                2'b01:pending_q<=pending_q-1'b1;
                default:;
            endcase
            if(response_fire && mem_rsp_error) begin
                stopping_q<=1;error<=1;error_code<=8'h07;
            end
            // A held request survives cancellation/failure. Completion waits
            // until it has been accepted AND every accepted write has replied.
            if(active_q && (stopping_q || abort || error || eof_q) &&
               !mem_req_valid && pending_q==0) begin
                active_q<=0;
                done<=eof_q && !stopping_q && !abort && !error;
                aborted<=stopping_q || abort || error;
            end
        end
    end

`ifndef SYNTHESIS
    initial if(MAX_PENDING<1 || MAX_PENDING>15)
        $fatal(1,"pixel writer MAX_PENDING must be 1..15");
    initial if((BATCH_WORDS!=1 && BATCH_WORDS!=2 && BATCH_WORDS!=4 && BATCH_WORDS!=8) ||
               BATCH_WORDS>MAX_PENDING)
        $fatal(1,"pixel writer batch must be 1, 2, 4 or 8 and fit reservations");
    logic held_q;
    logic [96:0] held_payload_q;
    always_ff @(posedge clk) begin
        if(rst) held_q<=0;
        else begin
            if(held_q && (!mem_req_valid || {mem_req_addr,mem_req_data,mem_req_end}!==held_payload_q))
                $fatal(1,"pixel writer withdrew a held memory request");
            if(reservations>MAX_PENDING || (!active_q && (mem_req_valid || pending_q!=0)))
                $fatal(1,"pixel writer crossed its reservation/lifecycle fence");
            if(response_fire && pending_q==0)
                $fatal(1,"pixel writer consumed an unowned response");
            if(input_fire && protocol_valid && !expected_eof && address_q>32'hfffffff7)
                $fatal(1,"pixel writer caller supplied a wrapping output region");
            held_q<=mem_req_valid && !mem_req_ready;
            held_payload_q<={mem_req_addr,mem_req_data,mem_req_end};
        end
    end
`endif
endmodule
