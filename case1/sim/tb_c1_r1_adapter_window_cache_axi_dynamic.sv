`timescale 1ns/1ps

// Full dynamic boardless integration:
//   22-stage adapter scoreboard -> window-cache seam -> real 64/128 bridge
//   -> strict, randomly backpressured, single-outstanding AXI128 memory BFM.
//
// base.memory remains the logical-request reference. This BFM has independent
// storage updated ONLY from accepted AXI AW/W and serves reads from it. Both
// memories are compared without sharing their procedural writers.
module tb_c1_r1_adapter_window_cache_axi_dynamic;
    localparam logic [31:0] BASE_ADDR = 32'h0000_1000;
    localparam integer BANK_BYTES = 1024;
    localparam integer MEMORY_WORDS = (3 * BANK_BYTES) / 8;

    tb_c1_r1_microstyle_tensor_adapter base();
    defparam base.dut.ENABLE_WINDOW_CACHE_SIDEBAND = 1;

    logic seam_stage_ready, seam_stage_done;
    logic seam_stage_active, seam_stage_fallback;
    logic [3:0] seam_stage_reason;
    logic seam_abort_done, seam_flush_done;
    logic seam_s_req_ready, seam_s_rsp_valid;
    logic seam_s_rsp_error;
    logic [63:0] seam_s_rsp_rdata;
    logic cache_error;
    logic [2:0] cache_error_code;
    logic seam_busy, seam_quiescent;

    logic down_req_valid, down_req_ready, down_req_write;
    logic [31:0] down_req_addr;
    logic [63:0] down_req_wdata;
    logic [7:0] down_req_wstrb;
    logic down_rsp_valid, down_rsp_ready, down_rsp_error;
    logic [63:0] down_rsp_rdata;

    logic [31:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_awvalid, m_axi_awready;
    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic [1:0] m_axi_bresp;
    logic m_axi_bvalid, m_axi_bready;
    logic [31:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arvalid, m_axi_arready;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast, m_axi_rvalid, m_axi_rready;

    // Interpose only adapter input/config-handshake nets.  Adapter output nets
    // remain directly visible to the seam and the original scoreboard.
    initial begin
        force base.cache_stage_start_ready = seam_stage_ready;
        force base.mem_req_ready = seam_s_req_ready;
        force base.mem_rsp_valid = seam_s_rsp_valid;
        force base.mem_rsp_error = seam_s_rsp_error;
        force base.mem_rsp_rdata = seam_s_rsp_rdata;
    end

    c1_tensor_window_cache_seam #(
        .DATA_W(64), .LINE_ROWS(3), .MAX_ROW_WORDS(1280), .MAX_GROUPS(8)
    ) u_seam (
        .clk(base.clk), .rst(base.rst),
        .stage_start_valid(base.cache_stage_start_valid),
        .stage_start_ready(seam_stage_ready),
        .stage_cache_enable(base.cache_stage_enable),
        .stage_base_addr(base.cache_stage_base_addr),
        .stage_width(base.cache_stage_width),
        .stage_height(base.cache_stage_height),
        .stage_groups(base.cache_stage_groups),
        .stage_start_done(seam_stage_done),
        .stage_cache_active(seam_stage_active),
        .stage_cache_fallback(seam_stage_fallback),
        .stage_cache_reason(seam_stage_reason),
        .abort_req(base.adapter_abort), .abort_done(seam_abort_done),
        .flush_req(1'b0), .flush_done(seam_flush_done),
        .s_req_valid(base.mem_req_valid), .s_req_ready(seam_s_req_ready),
        .s_req_write(base.mem_req_write), .s_req_addr(base.mem_req_addr),
        .s_req_wdata(base.mem_req_wdata), .s_req_wstrb(base.mem_req_wstrb),
        .s_req_cacheable(base.mem_req_cacheable),
        .s_req_cache_x(base.mem_req_cache_x),
        .s_req_cache_y(base.mem_req_cache_y),
        .s_req_cache_group(base.mem_req_cache_group),
        .s_rsp_valid(seam_s_rsp_valid), .s_rsp_ready(base.mem_rsp_ready),
        .s_rsp_error(seam_s_rsp_error), .s_rsp_rdata(seam_s_rsp_rdata),
        .m_req_valid(down_req_valid), .m_req_ready(down_req_ready),
        .m_req_write(down_req_write), .m_req_addr(down_req_addr),
        .m_req_wdata(down_req_wdata), .m_req_wstrb(down_req_wstrb),
        .m_rsp_valid(down_rsp_valid), .m_rsp_ready(down_rsp_ready),
        .m_rsp_error(down_rsp_error), .m_rsp_rdata(down_rsp_rdata),
        .cache_error(cache_error), .cache_error_code(cache_error_code),
        .busy(seam_busy), .quiescent(seam_quiescent)
    );

    c1_tensor_mem_axi128_bridge u_bridge (
        .read_cache_invalidate(1'b0),
        .clk(base.clk), .rst(base.rst),
        .mem_req_valid(down_req_valid), .mem_req_ready(down_req_ready),
        .mem_req_write(down_req_write), .mem_req_addr(down_req_addr),
        .mem_req_wdata(down_req_wdata), .mem_req_wstrb(down_req_wstrb),
        .mem_rsp_valid(down_rsp_valid), .mem_rsp_ready(down_rsp_ready),
        .mem_rsp_error(down_rsp_error), .mem_rsp_rdata(down_rsp_rdata),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    logic [31:0] bfm_lfsr_q;
    logic bridge_req_active_q, bridge_req_write_q, bridge_req_error_q;
    logic [31:0] bridge_req_addr_q;
    logic [63:0] bridge_req_wdata_q;
    logic [7:0] bridge_req_wstrb_q;

    logic read_pending_q, read_valid_q;
    logic [2:0] read_delay_q;
    logic [127:0] read_data_q;
    logic [1:0] read_resp_q;
    logic aw_seen_q, w_seen_q, b_pending_q, b_valid_q;
    logic [2:0] b_delay_q;
    logic [1:0] b_resp_q;

    wire axi_ar_fire = m_axi_arvalid && m_axi_arready;
    wire axi_r_fire = m_axi_rvalid && m_axi_rready;
    wire axi_aw_fire = m_axi_awvalid && m_axi_awready;
    wire axi_w_fire = m_axi_wvalid && m_axi_wready;
    wire axi_b_fire = m_axi_bvalid && m_axi_bready;

    // Random request-channel backpressure is overridden only by the original
    // base test's explicit force-ready windows.  Response holding is shared
    // with the base abort scenario so an accepted write truly drains through
    // seam, bridge and AXI B before adapter_aborted can pulse.
    assign m_axi_arready = !read_pending_q && !read_valid_q &&
        (base.force_request_ready || (bfm_lfsr_q[0] && bfm_lfsr_q[5]));
    assign m_axi_rvalid = read_valid_q && !base.hold_responses;
    assign m_axi_rdata = read_data_q;
    assign m_axi_rresp = read_resp_q;
    assign m_axi_rlast = 1'b1;

    assign m_axi_awready = !aw_seen_q && !b_pending_q && !b_valid_q &&
        (base.force_request_ready || (bfm_lfsr_q[1] && bfm_lfsr_q[6]));
    assign m_axi_wready = !w_seen_q && !b_pending_q && !b_valid_q &&
        (base.force_request_ready || (bfm_lfsr_q[2] && bfm_lfsr_q[7]));
    assign m_axi_bvalid = b_valid_q && !base.hold_responses;
    assign m_axi_bresp = b_resp_q;

    integer logical_req_count, logical_rsp_count;
    integer logical_read_count, logical_write_count;
    integer cacheable_read_count, bypass_read_count;
    integer one_by_one_read_count, upsample_read_count, residual_read_count;
    integer down_req_count, down_rsp_count, down_read_count, down_write_count;
    integer stage_config_count, cache_stage_count, bypass_stage_count;
    integer row_refill_count, row_refill_word_count;
    integer cache_hit_count, cache_miss_count;
    integer down_req_stall_count, upstream_rsp_stall_count;
    integer memory_error_rsp_count;
    integer ar_count, r_count, aw_count, w_count, b_count;
    integer ar_stall_count, aw_stall_count, w_stall_count;
    integer r_gap_count, b_gap_count, r_hold_count, b_hold_count;
    integer lower_half_count, upper_half_count;
    integer aw_first_count, w_first_count, same_aw_w_count;
    integer axi_error_count;
    integer axi_word_index;
    logic [63:0] axi_memory [0:MEMORY_WORDS-1];
    logic [31:0] accepted_awaddr_q;
    logic [127:0] accepted_wdata_q;
    logic [15:0] accepted_wstrb_q;
    logic [31:0] commit_addr;
    logic [127:0] commit_data;
    logic [15:0] commit_strb;
    integer write_commit_count=0;
    logic cache_logical_inflight_q, cache_logical_refilled_q;
    logic inject_for_logical_q, saw_generation_error_q, printed_q;

    always_ff @(posedge base.clk) begin
        if (base.rst) begin
            for(integer word=0;word<MEMORY_WORDS;word++) axi_memory[word]<=0;
            accepted_awaddr_q<=0; accepted_wdata_q<=0; accepted_wstrb_q<=0;
            write_commit_count<=0;
            bfm_lfsr_q <= 32'h91c7_2da5;
            bridge_req_active_q <= 1'b0;
            bridge_req_write_q <= 1'b0;
            bridge_req_error_q <= 1'b0;
            bridge_req_addr_q <= 32'd0;
            bridge_req_wdata_q <= 64'd0;
            bridge_req_wstrb_q <= 8'd0;
            read_pending_q <= 1'b0;
            read_valid_q <= 1'b0;
            read_delay_q <= 3'd0;
            read_data_q <= 128'd0;
            read_resp_q <= 2'd0;
            aw_seen_q <= 1'b0;
            w_seen_q <= 1'b0;
            b_pending_q <= 1'b0;
            b_valid_q <= 1'b0;
            b_delay_q <= 3'd0;
            b_resp_q <= 2'd0;
            logical_req_count <= 0;
            logical_rsp_count <= 0;
            logical_read_count <= 0;
            logical_write_count <= 0;
            cacheable_read_count <= 0;
            bypass_read_count <= 0;
            one_by_one_read_count <= 0;
            upsample_read_count <= 0;
            residual_read_count <= 0;
            down_req_count <= 0;
            down_rsp_count <= 0;
            down_read_count <= 0;
            down_write_count <= 0;
            stage_config_count <= 0;
            cache_stage_count <= 0;
            bypass_stage_count <= 0;
            row_refill_count <= 0;
            row_refill_word_count <= 0;
            cache_hit_count <= 0;
            cache_miss_count <= 0;
            down_req_stall_count <= 0;
            upstream_rsp_stall_count <= 0;
            memory_error_rsp_count <= 0;
            ar_count <= 0;
            r_count <= 0;
            aw_count <= 0;
            w_count <= 0;
            b_count <= 0;
            ar_stall_count <= 0;
            aw_stall_count <= 0;
            w_stall_count <= 0;
            r_gap_count <= 0;
            b_gap_count <= 0;
            r_hold_count <= 0;
            b_hold_count <= 0;
            lower_half_count <= 0;
            upper_half_count <= 0;
            aw_first_count <= 0;
            w_first_count <= 0;
            same_aw_w_count <= 0;
            axi_error_count <= 0;
            cache_logical_inflight_q <= 1'b0;
            cache_logical_refilled_q <= 1'b0;
            inject_for_logical_q <= 1'b0;
            saw_generation_error_q <= 1'b0;
            printed_q <= 1'b0;
        end else begin
            bfm_lfsr_q <= {bfm_lfsr_q[30:0],
                bfm_lfsr_q[31] ^ bfm_lfsr_q[21] ^
                bfm_lfsr_q[1] ^ bfm_lfsr_q[0]};

            if (down_req_valid && !down_req_ready)
                down_req_stall_count <= down_req_stall_count + 1;
            if (seam_s_rsp_valid && !base.mem_rsp_ready)
                upstream_rsp_stall_count <= upstream_rsp_stall_count + 1;
            if (m_axi_arvalid && !m_axi_arready)
                ar_stall_count <= ar_stall_count + 1;
            if (m_axi_awvalid && !m_axi_awready)
                aw_stall_count <= aw_stall_count + 1;
            if (m_axi_wvalid && !m_axi_wready)
                w_stall_count <= w_stall_count + 1;
            if (read_pending_q && !read_valid_q)
                r_gap_count <= r_gap_count + 1;
            if (b_pending_q && !b_valid_q)
                b_gap_count <= b_gap_count + 1;
            if (read_valid_q && base.hold_responses)
                r_hold_count <= r_hold_count + 1;
            if (b_valid_q && base.hold_responses)
                b_hold_count <= b_hold_count + 1;

            if (read_pending_q && !read_valid_q) begin
                if (read_delay_q == 0)
                    read_valid_q <= 1'b1;
                else
                    read_delay_q <= read_delay_q - 1'b1;
            end
            if (b_pending_q && !b_valid_q) begin
                if (b_delay_q == 0)
                    b_valid_q <= 1'b1;
                else
                    b_delay_q <= b_delay_q - 1'b1;
            end

            if (base.cache_stage_start_valid && seam_stage_ready) begin
                stage_config_count <= stage_config_count + 1;
                if (base.cache_stage_enable)
                    cache_stage_count <= cache_stage_count + 1;
                else
                    bypass_stage_count <= bypass_stage_count + 1;
            end

            if (base.mem_req_valid && seam_s_req_ready) begin
                logical_req_count <= logical_req_count + 1;
                inject_for_logical_q <= base.inject_response_error;
                if (base.mem_req_write) begin
                    logical_write_count <= logical_write_count + 1;
                end else begin
                    logical_read_count <= logical_read_count + 1;
                    if (base.mem_req_cacheable) begin
                        cacheable_read_count <= cacheable_read_count + 1;
                        if (cache_logical_inflight_q)
                            $fatal(1, "second cache logical request accepted");
                        cache_logical_inflight_q <= 1'b1;
                        cache_logical_refilled_q <= 1'b0;
                    end else begin
                        bypass_read_count <= bypass_read_count + 1;
                        case (base.active_stage_opcode)
                            8'd2: one_by_one_read_count <= one_by_one_read_count + 1;
                            8'd4: upsample_read_count <= upsample_read_count + 1;
                            8'd5: residual_read_count <= residual_read_count + 1;
                            default: ;
                        endcase
                    end
                end
            end

            if (u_seam.cache_refill_req_valid &&
                u_seam.cache_refill_req_ready) begin
                row_refill_count <= row_refill_count + 1;
                row_refill_word_count <= row_refill_word_count +
                    u_seam.cache_refill_req_word_count;
                if (!cache_logical_inflight_q)
                    $fatal(1, "row refill without cache logical owner");
                cache_logical_refilled_q <= 1'b1;
            end

            if (seam_s_rsp_valid && base.mem_rsp_ready) begin
                logical_rsp_count <= logical_rsp_count + 1;
                if (seam_s_rsp_error)
                    memory_error_rsp_count <= memory_error_rsp_count + 1;
                inject_for_logical_q <= 1'b0;
                if (cache_logical_inflight_q) begin
                    if (cache_logical_refilled_q)
                        cache_miss_count <= cache_miss_count + 1;
                    else
                        cache_hit_count <= cache_hit_count + 1;
                    cache_logical_inflight_q <= 1'b0;
                end
            end

            // Capture the exact 64-bit request accepted by the real bridge.
            if (down_req_valid && down_req_ready) begin
                if (bridge_req_active_q)
                    $fatal(1, "bridge accepted a second outstanding request");
                if (down_req_addr[2:0] != 0 || down_req_addr < BASE_ADDR ||
                    down_req_addr >= BASE_ADDR + 3 * BANK_BYTES)
                    $fatal(1, "bridge request outside tensor arena: %h",
                           down_req_addr);
                bridge_req_active_q <= 1'b1;
                bridge_req_write_q <= down_req_write;
                bridge_req_error_q <= inject_for_logical_q;
                bridge_req_addr_q <= down_req_addr;
                bridge_req_wdata_q <= down_req_wdata;
                bridge_req_wstrb_q <= down_req_wstrb;
                down_req_count <= down_req_count + 1;
                if (down_req_addr[3])
                    upper_half_count <= upper_half_count + 1;
                else
                    lower_half_count <= lower_half_count + 1;
                if (down_req_write) begin
                    down_write_count <= down_write_count + 1;
                    if (down_req_wstrb != 8'hff)
                        $fatal(1, "bridge write strobe mismatch");
                end else begin
                    down_read_count <= down_read_count + 1;
                    if (down_req_wstrb != 0)
                        $fatal(1, "bridge read carried byte strobes");
                end
            end

            if (down_rsp_valid && down_rsp_ready) begin
                if (!bridge_req_active_q)
                    $fatal(1, "bridge produced response without request");
                down_rsp_count <= down_rsp_count + 1;
                bridge_req_active_q <= 1'b0;
                bridge_req_error_q <= 1'b0;
            end

            if (axi_ar_fire) begin
                if (!bridge_req_active_q || bridge_req_write_q)
                    $fatal(1, "AXI AR without active read request");
                if (m_axi_araddr !== {bridge_req_addr_q[31:4], 4'b0000} ||
                    m_axi_arlen != 0 || m_axi_arsize != 3'd4 ||
                    m_axi_arburst != 2'b01)
                    $fatal(1, "AXI AR payload mismatch");
                if (m_axi_araddr < BASE_ADDR ||
                    m_axi_araddr + 16 > BASE_ADDR + 3 * BANK_BYTES)
                    $fatal(1, "AXI AR beat outside tensor arena: %h",
                           m_axi_araddr);
                axi_word_index = (m_axi_araddr - BASE_ADDR) >> 3;
                if ({axi_memory[axi_word_index+1],axi_memory[axi_word_index]} !==
                    {base.memory[axi_word_index+1],base.memory[axi_word_index]})
                    $fatal(1,"AXI committed memory differs from logical reference at read %h",m_axi_araddr);
                read_data_q <= {axi_memory[axi_word_index + 1],
                                axi_memory[axi_word_index]};
                read_resp_q <= bridge_req_error_q ? 2'b10 : 2'b00;
                read_pending_q <= 1'b1;
                read_delay_q <= {1'b0, bfm_lfsr_q[4:3]};
                ar_count <= ar_count + 1;
                if (bridge_req_error_q)
                    axi_error_count <= axi_error_count + 1;
            end

            if (axi_r_fire) begin
                if (!read_pending_q || !read_valid_q)
                    $fatal(1, "AXI R handshake without scheduled response");
                r_count <= r_count + 1;
                read_pending_q <= 1'b0;
                read_valid_q <= 1'b0;
            end

            if (axi_aw_fire) begin
                if (!bridge_req_active_q || !bridge_req_write_q || aw_seen_q)
                    $fatal(1, "AXI AW without active write request");
                if (m_axi_awaddr !== {bridge_req_addr_q[31:4], 4'b0000} ||
                    m_axi_awlen != 0 || m_axi_awsize != 3'd4 ||
                    m_axi_awburst != 2'b01)
                    $fatal(1, "AXI AW payload mismatch");
                aw_seen_q <= 1'b1;
                accepted_awaddr_q <= m_axi_awaddr;
                aw_count <= aw_count + 1;
            end

            if (axi_w_fire) begin
                if (!bridge_req_active_q || !bridge_req_write_q || w_seen_q ||
                    !m_axi_wlast)
                    $fatal(1, "AXI W without active write request");
                if (bridge_req_addr_q[3]) begin
                    if (m_axi_wdata !== {bridge_req_wdata_q, 64'd0} ||
                        m_axi_wstrb !== {bridge_req_wstrb_q, 8'd0})
                        $fatal(1, "AXI upper-half W mapping mismatch");
                end else begin
                    if (m_axi_wdata !== {64'd0, bridge_req_wdata_q} ||
                        m_axi_wstrb !== {8'd0, bridge_req_wstrb_q})
                        $fatal(1, "AXI lower-half W mapping mismatch");
                end
                w_seen_q <= 1'b1;
                accepted_wdata_q <= m_axi_wdata;
                accepted_wstrb_q <= m_axi_wstrb;
                w_count <= w_count + 1;
            end

            if (axi_aw_fire && axi_w_fire)
                same_aw_w_count <= same_aw_w_count + 1;
            else if (axi_aw_fire && !w_seen_q)
                aw_first_count <= aw_first_count + 1;
            else if (axi_w_fire && !aw_seen_q)
                w_first_count <= w_first_count + 1;

            if (!b_pending_q && !b_valid_q &&
                (aw_seen_q || axi_aw_fire) && (w_seen_q || axi_w_fire)) begin
                // AW-first, W-first and same-edge are all legal. Use the
                // independently captured channel payloads, not bridge_req_*.
                commit_addr = axi_aw_fire ? m_axi_awaddr : accepted_awaddr_q;
                commit_data = axi_w_fire ? m_axi_wdata : accepted_wdata_q;
                commit_strb = axi_w_fire ? m_axi_wstrb : accepted_wstrb_q;
                if(commit_addr<BASE_ADDR || commit_addr+16>BASE_ADDR+3*BANK_BYTES)
                    $fatal(1,"AXI write outside independent memory");
                for(integer byte_index=0;byte_index<16;byte_index++)
                    if(commit_strb[byte_index])
                        axi_memory[((commit_addr-BASE_ADDR)>>3)+byte_index/8]
                            [(byte_index%8)*8+:8] <= commit_data[byte_index*8+:8];
                write_commit_count<=write_commit_count+1;
                b_pending_q <= 1'b1;
                // During the directed abort test the base holds memory
                // responses.  Present the internal B response immediately so
                // this full chain deterministically proves that an accepted
                // AXI write remains pending throughout the abort drain.
                if (base.hold_responses) begin
                    b_delay_q <= 3'd0;
                    b_valid_q <= 1'b1;
                end else begin
                    b_delay_q <= {1'b0, bfm_lfsr_q[9:8]};
                end
                b_resp_q <= bridge_req_error_q ? 2'b10 : 2'b00;
                if (bridge_req_error_q)
                    axi_error_count <= axi_error_count + 1;
            end

            if (axi_b_fire) begin
                if (!b_pending_q || !b_valid_q || !aw_seen_q || !w_seen_q)
                    $fatal(1, "AXI B handshake before AW/W completion");
                b_count <= b_count + 1;
                b_pending_q <= 1'b0;
                b_valid_q <= 1'b0;
                aw_seen_q <= 1'b0;
                w_seen_q <= 1'b0;
            end

            if (base.adapter_error && base.adapter_error_code == 8'h03)
                saw_generation_error_q <= 1'b1;
        end
    end

    // The base test finishes one rising edge after its final generation-error
    // abort.  At this falling edge all dynamic memory scenarios are complete.
    always @(negedge base.adapter_abort) begin
        if (saw_generation_error_q && !printed_q) begin
            printed_q = 1'b1;
            for(integer word=0;word<MEMORY_WORDS;word++)
                if(axi_memory[word]!==base.memory[word])
                    $fatal(1,"final AXI memory mismatch word=%0d",word);
            if(write_commit_count!=w_count || write_commit_count!=b_count)
                $fatal(1,"AXI write commit count differs from W/B");
            $display("C1_ADAPTER_AXI_MEMORY_COMMIT_PASS writes=%0d compared_words=%0d",write_commit_count,MEMORY_WORDS);
            if (stage_config_count != 22 || cache_stage_count != 8 ||
                bypass_stage_count != 14)
                $fatal(1, "stage coverage mismatch cfg=%0d cache=%0d bypass=%0d",
                       stage_config_count, cache_stage_count, bypass_stage_count);
            if (cacheable_read_count == 0 || cache_hit_count == 0 ||
                cache_miss_count == 0 || row_refill_count == 0 ||
                row_refill_word_count == 0)
                $fatal(1, "cache hit/miss/refill coverage missing");
            if (one_by_one_read_count == 0 || upsample_read_count == 0 ||
                residual_read_count == 0 || logical_write_count == 0)
                $fatal(1, "mandatory bypass class coverage missing");
            if (logical_req_count != logical_rsp_count ||
                down_req_count != down_rsp_count || bridge_req_active_q)
                $fatal(1, "logical/downstream accounting mismatch logical=%0d/%0d down=%0d/%0d active=%0b",
                       logical_req_count, logical_rsp_count,
                       down_req_count, down_rsp_count, bridge_req_active_q);
            if (ar_count != r_count || ar_count != down_read_count ||
                aw_count != w_count || aw_count != b_count ||
                aw_count != down_write_count ||
                down_req_count != ar_count + aw_count)
                $fatal(1, "AXI accounting mismatch ar/r=%0d/%0d aw/w/b=%0d/%0d/%0d down=%0d r/w=%0d/%0d",
                       ar_count, r_count, aw_count, w_count, b_count,
                       down_req_count, down_read_count, down_write_count);
            if (read_pending_q || read_valid_q || aw_seen_q || w_seen_q ||
                b_pending_q || b_valid_q)
                $fatal(1, "AXI BFM not quiescent at final check");
            if (down_read_count * 4 >= logical_read_count * 3)
                $fatal(1, "cache did not materially reduce AXI reads logical=%0d axi=%0d",
                       logical_read_count, ar_count);
            if (ar_stall_count == 0 || aw_stall_count == 0 ||
                w_stall_count == 0 || r_gap_count == 0 || b_gap_count == 0 ||
                b_hold_count == 0)
                $fatal(1, "AXI/backpressure coverage missing ar=%0d aw=%0d w=%0d rgap=%0d bgap=%0d bhold=%0d down=%0d",
                       ar_stall_count, aw_stall_count, w_stall_count,
                       r_gap_count, b_gap_count, b_hold_count,
                       down_req_stall_count);
            if (lower_half_count == 0 || upper_half_count == 0 ||
                aw_first_count == 0 || w_first_count == 0 ||
                same_aw_w_count == 0)
                $fatal(1, "AXI lane/order coverage missing lower=%0d upper=%0d awfirst=%0d wfirst=%0d same=%0d",
                       lower_half_count, upper_half_count, aw_first_count,
                       w_first_count, same_aw_w_count);
            if (memory_error_rsp_count != 1 || axi_error_count != 1)
                $fatal(1, "memory/AXI error coverage mismatch logical=%0d axi=%0d",
                       memory_error_rsp_count, axi_error_count);
            if (base.abort_drain_count == 0 || cache_error)
                $fatal(1, "abort/cache final state mismatch drains=%0d cache_error=%0b code=%0d",
                       base.abort_drain_count, cache_error, cache_error_code);

            $display("C1_R1_ADAPTER_WINDOW_CACHE_AXI_DYNAMIC_PASS stage_cfg=%0d cache_stages=%0d bypass_stages=%0d logical_req=%0d logical_rsp=%0d logical_reads=%0d logical_writes=%0d cacheable=%0d bypass_reads=%0d onebyone=%0d upsample=%0d residual=%0d hits=%0d misses=%0d row_refills=%0d refill_words=%0d bridge_req=%0d bridge_rsp=%0d axi_ar=%0d axi_r=%0d axi_aw=%0d axi_w=%0d axi_b=%0d ar_stalls=%0d aw_stalls=%0d w_stalls=%0d r_gaps=%0d b_gaps=%0d b_holds=%0d lower=%0d upper=%0d aw_first=%0d w_first=%0d same_aw_w=%0d memory_errors=%0d abort_drains=%0d",
                     stage_config_count, cache_stage_count, bypass_stage_count,
                     logical_req_count, logical_rsp_count, logical_read_count,
                     logical_write_count, cacheable_read_count,
                     bypass_read_count, one_by_one_read_count,
                     upsample_read_count, residual_read_count,
                     cache_hit_count, cache_miss_count, row_refill_count,
                     row_refill_word_count, down_req_count, down_rsp_count,
                     ar_count, r_count, aw_count, w_count, b_count,
                     ar_stall_count, aw_stall_count, w_stall_count,
                     r_gap_count, b_gap_count, b_hold_count,
                     lower_half_count, upper_half_count, aw_first_count,
                     w_first_count, same_aw_w_count,
                     memory_error_rsp_count, base.abort_drain_count);
        end
    end
endmodule
