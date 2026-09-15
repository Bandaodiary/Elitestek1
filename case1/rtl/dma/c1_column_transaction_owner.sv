`timescale 1ns/1ps

// One-flight column transaction/fence owner. Normal requests and responses
// bypass without an added pipeline cycle; a stalled downstream request or
// upstream response is retained in a private register (no READY loop).
//
// An unaccepted cache request may NOT be withdrawn. If a fence arrives while
// that request is held, defer the downstream fence until its acceptance.
// Once the cache owns the request, it may cancel/refill-drain it normally.
// The owner holds its upstream response as needed and joins cache
// maintenance ACKs with upstream response retirement before reporting DONE.
// An already presented upstream response is never changed by a later fence.
//
// During a fence, or with no valid cache configuration, new upstream requests
// are accepted as local zero/error responses, not forwarded into a closed
// cache. This also retires a producer's late-held request after an abort.
// Repeated edges of the same pending kind coalesce; different kinds join.
// Held-high controls block normal work but cause only one downstream pulse.
// Configuration has priority over normal requests; gate BOTH backend config
// VALID and upstream config READY with config_permit. Reset must reset the
// whole transaction domain, or occur only after it is fully drained.
module c1_column_transaction_owner (
    input logic clk,rst,
    input logic s_req_valid,
    output logic s_req_ready,
    input logic signed [16:0] s_req_x,s_req_center_y,
    input logic [2:0] s_req_group,
    output logic s_rsp_valid,
    input logic s_rsp_ready,
    output logic [191:0] s_rsp_data,
    output logic s_rsp_error,
    output logic m_req_valid,
    input logic m_req_ready,
    output logic signed [16:0] m_req_x,m_req_center_y,
    output logic [2:0] m_req_group,
    input logic m_rsp_valid,
    output logic m_rsp_ready,
    input logic [191:0] m_rsp_data,
    input logic m_rsp_error,
    input logic abort_req,flush_req,
    output logic abort_done,flush_done,
    output logic m_abort_req,m_flush_req,
    input logic m_abort_done,m_flush_done,
    input logic backend_config_valid,backend_quiescent,
    input logic config_pending,
    output logic config_permit,
    output logic busy,quiescent
);
    typedef enum logic [1:0] { IDLE, REQUEST, RESPONSE, RETURN } state_t;
    state_t state_q;
    logic [36:0] request_q;
    logic [191:0] response_q;
    logic response_error_q;
    logic [1:0] seen_q,pending_q,sent_q,ack_q;
    wire [1:0] raw_control={flush_req,abort_req};
    wire [1:0] new_control=raw_control & ~seen_q;
    wire [1:0] pending_now=pending_q | new_control;
    wire maintenance=(|pending_now) || (|raw_control);
    wire normal_admission=!maintenance && !config_pending && backend_config_valid;
    // Never feed M_REQ_READY into the fence pulse: caches may gate READY by
    // abort/flush, so doing that would recreate a combinational deadlock.
    wire [1:0] send_mask=(!rst && state_q!=REQUEST) ? (pending_q & ~sent_q) : 2'b00;
    wire [1:0] done_mask={m_flush_done,m_abort_done};
    wire [1:0] ack_now=ack_q | (done_mask & (sent_q | send_mask));
    wire complete_fence=(|pending_now) && ((ack_now & pending_now)==pending_now) &&
                        state_q==IDLE && !s_req_valid && backend_quiescent;

    always_comb begin
        s_req_ready=!rst && state_q==IDLE && (maintenance || !config_pending);
        m_req_valid=!rst && (state_q==REQUEST ||
                    (state_q==IDLE && s_req_valid && normal_admission));
        {m_req_x,m_req_center_y,m_req_group}=(state_q==REQUEST) ? request_q :
                                         {s_req_x,s_req_center_y,s_req_group};
        m_rsp_ready=!rst && state_q==RESPONSE;
        s_rsp_valid=!rst && (state_q==RETURN || (state_q==RESPONSE && m_rsp_valid));
        // Cancellation belongs to the backend once it accepts the request.
        // Do not combinationally poison a successful backend response with
        // a later fence: it may already be visible through this bypass.
        s_rsp_error=(state_q==RETURN) ? response_error_q : m_rsp_error;
        s_rsp_data=(state_q==RETURN) ? response_q :
                   (m_rsp_error ? 192'b0 : m_rsp_data);
        m_abort_req=send_mask[0];m_flush_req=send_mask[1];
        quiescent=state_q==IDLE && pending_q==0 && backend_quiescent;
        busy=!quiescent;
        config_permit=!rst && state_q==IDLE && !maintenance && backend_quiescent;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            state_q<=IDLE;request_q<='0;response_q<='0;response_error_q<=0;
            seen_q<=0;pending_q<=0;sent_q<=0;ack_q<=0;
            abort_done<=0;flush_done<=0;
        end else begin
            seen_q<=raw_control;
            pending_q<=pending_now;
            sent_q<=sent_q | send_mask;
            ack_q<=ack_now;
            abort_done<=0;flush_done<=0;
            case(state_q)
                IDLE: if(s_req_valid && s_req_ready) begin
                    request_q<={s_req_x,s_req_center_y,s_req_group};
                    if(!normal_admission) begin
                        response_q<='0;response_error_q<=1;state_q<=RETURN;
                    end else if(m_req_ready) state_q<=RESPONSE;
                    else state_q<=REQUEST;
                end
                REQUEST: if(m_req_ready) state_q<=RESPONSE;
                RESPONSE: if(m_rsp_valid) begin
                    if(s_rsp_ready) state_q<=IDLE;
                    else begin
                        response_q<=s_rsp_data;response_error_q<=s_rsp_error;
                        state_q<=RETURN;
                    end
                end
                RETURN: if(s_rsp_ready) state_q<=IDLE;
            endcase
            if(complete_fence) begin
                abort_done<=pending_now[0];flush_done<=pending_now[1];
                pending_q<=0;sent_q<=0;ack_q<=0;
            end
        end
    end
`ifndef SYNTHESIS
    logic held_request_q,held_response_q;
    logic [36:0] held_request_payload_q;
    logic [192:0] held_response_payload_q;
    always_ff @(posedge clk) begin
        if(rst) begin held_request_q<=0;held_response_q<=0;end
        else begin
            if(held_request_q && (!m_req_valid ||
                {m_req_x,m_req_center_y,m_req_group}!==held_request_payload_q))
                $fatal(1,"column owner withdrew/changed a stalled cache request");
            if(held_response_q && (!s_rsp_valid ||
                {s_rsp_error,s_rsp_data}!==held_response_payload_q))
                $fatal(1,"column owner withdrew/changed a stalled upstream response");
            held_request_q<=m_req_valid && !m_req_ready;
            held_request_payload_q<={m_req_x,m_req_center_y,m_req_group};
            held_response_q<=s_rsp_valid && !s_rsp_ready;
            held_response_payload_q<={s_rsp_error,s_rsp_data};
            if((m_abort_req || m_flush_req) && m_req_valid)
                $fatal(1,"column owner fenced an unaccepted cache request");
            if((abort_done || flush_done) && !quiescent)
                $fatal(1,"column owner completed before protocol drain");
        end
    end
`endif
endmodule
