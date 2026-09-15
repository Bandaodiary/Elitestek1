`timescale 1ns/1ps

// Ordered logical C8 -> AXI128 packer with real descriptor-level MLP.
// A slot owns its payload and logical echoes until its final response retires.
// Commands, W payloads and responses follow independent IN-ORDER cursors.
// Thus even conflicting writes in different bursts preserve physical order.
// No cancellation/posting: stop admitting upstream and drain every accepted
// request. An unfinished batch self-closes on timeout, end, or req_flush.
module c1_tensor_mem_axi128_ordered_write_client #(
    parameter integer MAX_OUTSTANDING=2,
    parameter integer BURST_BEATS=4,
    parameter integer BUILD_TIMEOUT_CYCLES=8,
    parameter bit USE_REQUEST_END=1'b0
) (
    input logic clk,rst,
    input logic req_valid,
    output logic req_ready,
    input logic req_flush,req_end,
    input logic [31:0] req_addr,
    input logic [63:0] req_wdata,
    input logic [7:0] req_wstrb,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic rsp_error,
    output logic [63:0] rsp_rdata,
    output logic [31:0] m_axi_awaddr,
    output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,
    output logic [1:0] m_axi_awburst,
    output logic m_axi_awvalid,
    input logic m_axi_awready,
    output logic [127:0] m_axi_wdata,
    output logic [15:0] m_axi_wstrb,
    output logic m_axi_wlast,m_axi_wvalid,
    input logic m_axi_wready,
    input logic [1:0] m_axi_bresp,
    input logic m_axi_bvalid,
    output logic m_axi_bready,
    output logic perf_busy,
    output logic [7:0] perf_outstanding,perf_max_outstanding
);
    localparam integer WORDS=2*BURST_BEATS;
    localparam integer PTR_W=$clog2(MAX_OUTSTANDING);
    localparam integer CNT_W=$clog2(MAX_OUTSTANDING+1);
    localparam integer WORD_W=$clog2(WORDS+1);
    localparam integer BEAT_W=(BURST_BEATS<=1)?1:$clog2(BURST_BEATS);
    localparam integer AGE_W=(BUILD_TIMEOUT_CYCLES<=1)?1:$clog2(BUILD_TIMEOUT_CYCLES+1);
    initial begin
        if(MAX_OUTSTANDING<2 || MAX_OUTSTANDING>8) $fatal(1,"ordered packer slots must be 2..8");
        if(BURST_BEATS<1 || BURST_BEATS>256) $fatal(1,"ordered packer burst must be 1..256");
        if(BUILD_TIMEOUT_CYCLES<1) $fatal(1,"ordered packer timeout must be positive");
    end

    logic [MAX_OUTSTANDING-1:0] valid_q,sealed_q,command_sent_q,payload_sent_q,local_error_q;
    logic [31:0] base_mem[0:MAX_OUTSTANDING-1];
    logic [8:0] beats_mem[0:MAX_OUTSTANDING-1];
    logic [WORD_W-1:0] words_mem[0:MAX_OUTSTANDING-1];
    // Payload is written before seal, never reset or reused before retirement.
    logic [127:0] data_mem[0:MAX_OUTSTANDING-1][0:BURST_BEATS-1];
    logic [15:0] strb_mem[0:MAX_OUTSTANDING-1][0:BURST_BEATS-1];
    logic [63:0] echo_mem[0:MAX_OUTSTANDING-1][0:WORDS-1];
    logic [PTR_W-1:0] tail_q,issue_q,feed_q,retire_q;
    logic [CNT_W-1:0] count_q;
    logic building_q;
    logic [AGE_W-1:0] age_q;
    logic [1:0] last_lanes_q;
    logic [BEAT_W-1:0] feed_beat_q;
    logic [WORD_W-1:0] response_word_q;

    function automatic [PTR_W-1:0] advance(input [PTR_W-1:0] ptr);
        advance=(ptr==MAX_OUTSTANDING-1)?'0:ptr+1'b1;
    endfunction
    wire [31:0] aligned_addr={req_addr[31:4],4'b0};
    wire [32:0] next_addr={1'b0,base_mem[tail_q]}+({24'd0,beats_mem[tail_q]}<<4);
    wire same_beat=building_q && {1'b0,aligned_addr}==next_addr-33'd16;
    wire next_beat=building_q && beats_mem[tail_q]<BURST_BEATS && !next_addr[32] &&
        {1'b0,aligned_addr}==next_addr && aligned_addr[31:12]==base_mem[tail_q][31:12];
    wire append_ok=req_addr[2:0]==0 && words_mem[tail_q]<WORDS &&
        ((same_beat && !last_lanes_q[req_addr[3]]) || next_beat);
    wire [BEAT_W-1:0] append_beat=next_beat ? beats_mem[tail_q] : beats_mem[tail_q]-1'b1;
    assign req_ready=!rst && (building_q ? (!req_flush && append_ok) : count_q<MAX_OUTSTANDING);
    wire request_fire=req_valid && req_ready;
    wire allocate=request_fire && !building_q;
    wire close_idle=building_q && !request_fire &&
        (req_flush || req_valid || age_q>=BUILD_TIMEOUT_CYCLES-1);

    wire command_valid=!rst && valid_q[issue_q] && sealed_q[issue_q] && !command_sent_q[issue_q];
    wire command_ready;
    wire command_fire=command_valid && command_ready;
    wire payload_valid=!rst && valid_q[feed_q] && command_sent_q[feed_q] && !payload_sent_q[feed_q];
    wire payload_ready;
    wire payload_last=feed_beat_q==beats_mem[feed_q]-1'b1;
    wire payload_fire=payload_valid && payload_ready;
    wire backend_rsp_valid,backend_rsp_ready,backend_rsp_error,backend_busy;
    wire [31:0] backend_rsp_addr;
    wire [8:0] backend_rsp_beats;
    wire backend_early_b,backend_orphan_b;
    wire response_last=response_word_q==words_mem[retire_q]-1'b1;
    assign rsp_valid=!rst && valid_q[retire_q] && payload_sent_q[retire_q] && backend_rsp_valid;
    assign rsp_error=rsp_valid && backend_rsp_error;
    assign rsp_rdata=rsp_valid ? echo_mem[retire_q][response_word_q] : 64'd0;
    wire response_fire=rsp_valid && rsp_ready;
    wire retire=response_fire && response_last;
    assign backend_rsp_ready=retire;
    assign perf_busy=count_q!=0 || backend_busy;

    c1_axi128_write_mlp #(
        .MAX_OUTSTANDING(MAX_OUTSTANDING),.MAX_BEATS(BURST_BEATS),
        .RSP_FIFO_DEPTH(MAX_OUTSTANDING),.TAG_WIDTH(8),.ISSUE_AW_BEFORE_PAYLOAD(1'b1),
        .PIPELINE_WRITE_DATA(1'b1)
    ) u_backend (
        .clk,.rst,.cmd_valid(command_valid),.cmd_ready(command_ready),
        // Poisoned local alignment rejection keeps its place in the ordered
        // stream, consumes a zero-strobe payload and never produces an AW.
        .cmd_addr(base_mem[issue_q] | (local_error_q[issue_q]?32'd1:32'd0)),
        .cmd_beats(beats_mem[issue_q]),
        .payload_valid,.payload_ready,.payload_data(data_mem[feed_q][feed_beat_q]),
        .payload_strb(strb_mem[feed_q][feed_beat_q]),.payload_last,.payload_flush(1'b0),
        .rsp_valid(backend_rsp_valid),.rsp_ready(backend_rsp_ready),.rsp_error(backend_rsp_error),
        .rsp_addr(backend_rsp_addr),.rsp_beats(backend_rsp_beats),.rsp_tag(),
        .m_axi_awaddr,.m_axi_awlen,.m_axi_awsize,.m_axi_awburst,.m_axi_awvalid,.m_axi_awready,
        .m_axi_wdata,.m_axi_wstrb,.m_axi_wlast,.m_axi_wvalid,.m_axi_wready,
        .m_axi_bresp,.m_axi_bvalid,.m_axi_bready,
        .early_b_error(backend_early_b),.orphan_b_error(backend_orphan_b),
        .perf_busy(backend_busy)
    );

    always_ff @(posedge clk) begin
        if(rst) begin
            valid_q<='0;sealed_q<='0;command_sent_q<='0;payload_sent_q<='0;local_error_q<='0;
            tail_q<=0;issue_q<=0;feed_q<=0;retire_q<=0;count_q<=0;
            building_q<=0;age_q<=0;last_lanes_q<=0;feed_beat_q<=0;response_word_q<=0;
            perf_outstanding<=0;perf_max_outstanding<=0;
        end else begin
            // Count physical AW/B only. Backend issue slots also include
            // local poisoned descriptors and must not be reported as AXI.
            case({m_axi_awvalid && m_axi_awready,m_axi_bvalid && m_axi_bready})
                2'b10:begin
                    perf_outstanding<=perf_outstanding+1'b1;
                    if(perf_outstanding+1'b1>perf_max_outstanding)perf_max_outstanding<=perf_outstanding+1'b1;
                end
                2'b01:perf_outstanding<=perf_outstanding-1'b1;
                default:;
            endcase
            case({allocate,retire})
                2'b10:count_q<=count_q+1'b1;
                2'b01:count_q<=count_q-1'b1;
                default:;
            endcase
            if(allocate) begin
                valid_q[tail_q]<=1;sealed_q[tail_q]<=0;
                command_sent_q[tail_q]<=0;payload_sent_q[tail_q]<=0;
                local_error_q[tail_q]<=req_addr[2:0]!=0;
                base_mem[tail_q]<=aligned_addr;beats_mem[tail_q]<=1;words_mem[tail_q]<=1;
                data_mem[tail_q][0]<=req_addr[3] ? {req_wdata,64'd0} : {64'd0,req_wdata};
                strb_mem[tail_q][0]<=req_addr[2:0]!=0 ? 16'd0 :
                    (req_addr[3] ? {req_wstrb,8'd0} : {8'd0,req_wstrb});
                echo_mem[tail_q][0]<=req_addr[2:0]!=0 ? 64'd0 : req_wdata;
                last_lanes_q<=req_addr[3] ? 2'b10 : 2'b01;
                age_q<=0;building_q<=1;
                if(req_addr[2:0]!=0 || (USE_REQUEST_END && req_end)) begin
                    sealed_q[tail_q]<=1;tail_q<=advance(tail_q);building_q<=0;
                end
            end else if(request_fire) begin
                echo_mem[tail_q][words_mem[tail_q]]<=req_wdata;
                words_mem[tail_q]<=words_mem[tail_q]+1'b1;age_q<=0;
                if(next_beat) begin
                    beats_mem[tail_q]<=beats_mem[tail_q]+1'b1;
                    data_mem[tail_q][append_beat]<=req_addr[3] ? {req_wdata,64'd0} : {64'd0,req_wdata};
                    strb_mem[tail_q][append_beat]<=req_addr[3] ? {req_wstrb,8'd0} : {8'd0,req_wstrb};
                    last_lanes_q<=req_addr[3] ? 2'b10 : 2'b01;
                end else begin
                    data_mem[tail_q][append_beat][req_addr[3]*64+:64]<=req_wdata;
                    strb_mem[tail_q][append_beat][req_addr[3]*8+:8]<=req_wstrb;
                    last_lanes_q<=2'b11;
                end
                if((USE_REQUEST_END && req_end) || words_mem[tail_q]+1'b1==WORDS) begin
                    sealed_q[tail_q]<=1;tail_q<=advance(tail_q);building_q<=0;
                end
            end else if(close_idle) begin
                sealed_q[tail_q]<=1;tail_q<=advance(tail_q);building_q<=0;
            end else if(building_q) age_q<=age_q+1'b1;
            if(command_fire) begin command_sent_q[issue_q]<=1;issue_q<=advance(issue_q);end
            if(payload_fire) begin
                if(payload_last) begin
                    payload_sent_q[feed_q]<=1;feed_q<=advance(feed_q);feed_beat_q<=0;
                end else feed_beat_q<=feed_beat_q+1'b1;
            end
            if(response_fire) begin
                if(response_last) begin
                    valid_q[retire_q]<=0;retire_q<=advance(retire_q);response_word_q<=0;
                end else response_word_q<=response_word_q+1'b1;
            end
        end
    end
`ifndef SYNTHESIS
    logic response_held_q;
    logic [64:0] response_saved_q;
    always_ff @(posedge clk) begin
        if(rst) response_held_q<=0;
        else begin
            if(count_q>MAX_OUTSTANDING || (allocate && valid_q[tail_q]))
                $fatal(1,"ordered packer reused an owned slot");
            if(backend_early_b || backend_orphan_b) $fatal(1,"ordered packer backend AXI ownership error");
            if(rsp_valid && (backend_rsp_addr!==(base_mem[retire_q] | (local_error_q[retire_q]?32'd1:32'd0)) ||
                backend_rsp_beats!==beats_mem[retire_q])) $fatal(1,"ordered packer response descriptor mismatch");
            if(response_held_q && (!rsp_valid || {rsp_error,rsp_rdata}!==response_saved_q))
                $fatal(1,"ordered packer changed held logical response");
            response_held_q<=rsp_valid && !rsp_ready;response_saved_q<={rsp_error,rsp_rdata};
        end
    end
`endif
endmodule
