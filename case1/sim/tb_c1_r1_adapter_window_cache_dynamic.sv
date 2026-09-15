`timescale 1ns/1ps

// Dynamic integration wrapper around the original, self-checking 22-stage
// adapter test.  The base test remains the owner of descriptors, source and
// result BFMs, the bit-exact engine scoreboard, abort/error scenarios, and the
// tensor-array contents.  This wrapper only interposes the real window-cache
// seam and supplies its downstream single-outstanding 64-bit memory BFM.
module tb_c1_r1_adapter_window_cache_dynamic;
    localparam logic [31:0] BASE_ADDR = 32'h0000_1000;
    localparam integer BANK_BYTES = 1024;
    localparam integer MEMORY_WORDS = (3 * BANK_BYTES) / 8;

    tb_c1_r1_microstyle_tensor_adapter base();
    defparam base.dut.ENABLE_WINDOW_CACHE_SIDEBAND = 1;

    logic seam_stage_ready;
    logic seam_stage_done;
    logic seam_stage_active;
    logic seam_stage_fallback;
    logic [3:0] seam_stage_reason;
    logic seam_abort_done;
    logic seam_flush_done;

    logic seam_s_req_ready;
    logic seam_s_rsp_valid;
    logic seam_s_rsp_error;
    logic [63:0] seam_s_rsp_rdata;

    logic down_req_valid;
    logic down_req_ready;
    logic down_req_write;
    logic [31:0] down_req_addr;
    logic [63:0] down_req_wdata;
    logic [7:0] down_req_wstrb;
    logic down_rsp_valid;
    logic down_rsp_ready;
    logic down_rsp_error;
    logic [63:0] down_rsp_rdata;

    logic cache_error;
    logic [2:0] cache_error_code;
    logic seam_busy;
    logic seam_quiescent;

    // The base test's continuous assignments normally connect its adapter to
    // its local memory BFM.  Force only the adapter input/config handshake
    // nets; adapter output nets remain untouched and feed the seam below.
    initial begin
        force base.cache_stage_start_ready = seam_stage_ready;
        force base.mem_req_ready = seam_s_req_ready;
        force base.mem_rsp_valid = seam_s_rsp_valid;
        force base.mem_rsp_error = seam_s_rsp_error;
        force base.mem_rsp_rdata = seam_s_rsp_rdata;
    end

    c1_tensor_window_cache_seam #(
        .DATA_W(64),
        .LINE_ROWS(3),
        .MAX_ROW_WORDS(1280),
        .MAX_GROUPS(8)
    ) u_seam (
        .clk(base.clk),
        .rst(base.rst),
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
        .abort_req(base.adapter_abort),
        .abort_done(seam_abort_done),
        .flush_req(1'b0),
        .flush_done(seam_flush_done),
        .s_req_valid(base.mem_req_valid),
        .s_req_ready(seam_s_req_ready),
        .s_req_write(base.mem_req_write),
        .s_req_addr(base.mem_req_addr),
        .s_req_wdata(base.mem_req_wdata),
        .s_req_wstrb(base.mem_req_wstrb),
        .s_req_cacheable(base.mem_req_cacheable),
        .s_req_cache_x(base.mem_req_cache_x),
        .s_req_cache_y(base.mem_req_cache_y),
        .s_req_cache_group(base.mem_req_cache_group),
        .s_rsp_valid(seam_s_rsp_valid),
        .s_rsp_ready(base.mem_rsp_ready),
        .s_rsp_error(seam_s_rsp_error),
        .s_rsp_rdata(seam_s_rsp_rdata),
        .m_req_valid(down_req_valid),
        .m_req_ready(down_req_ready),
        .m_req_write(down_req_write),
        .m_req_addr(down_req_addr),
        .m_req_wdata(down_req_wdata),
        .m_req_wstrb(down_req_wstrb),
        .m_rsp_valid(down_rsp_valid),
        .m_rsp_ready(down_rsp_ready),
        .m_rsp_error(down_rsp_error),
        .m_rsp_rdata(down_rsp_rdata),
        .cache_error(cache_error),
        .cache_error_code(cache_error_code),
        .busy(seam_busy),
        .quiescent(seam_quiescent)
    );

    logic [31:0] bfm_lfsr_q;
    logic down_pending_q;
    logic [2:0] down_delay_q;
    logic down_error_q;
    logic [63:0] down_data_q;
    integer down_memory_index;

    integer logical_req_count;
    integer logical_rsp_count;
    integer logical_read_count;
    integer logical_write_count;
    integer cacheable_read_count;
    integer bypass_read_count;
    integer one_by_one_read_count;
    integer upsample_read_count;
    integer residual_read_count;
    integer down_req_count;
    integer down_rsp_count;
    integer down_read_count;
    integer down_write_count;
    integer row_refill_count;
    integer row_refill_word_count;
    integer cache_hit_count;
    integer cache_miss_count;
    integer stage_config_count;
    integer cache_stage_count;
    integer bypass_stage_count;
    integer down_req_stall_count;
    integer down_rsp_gap_count;
    integer upstream_rsp_stall_count;
    integer memory_error_rsp_count;
    logic cache_logical_inflight_q;
    logic cache_logical_refilled_q;
    logic inject_for_logical_q;
    logic saw_generation_error_q;
    logic printed_q;

    assign down_req_ready = !down_pending_q &&
                            (base.force_request_ready || bfm_lfsr_q[0]);
    assign down_rsp_valid = down_pending_q && (down_delay_q == 0) &&
                            !base.hold_responses;
    assign down_rsp_error = down_error_q;
    assign down_rsp_rdata = down_data_q;

    always_ff @(posedge base.clk) begin
        if (base.rst) begin
            bfm_lfsr_q <= 32'hc481_5a39;
            down_pending_q <= 1'b0;
            down_delay_q <= 3'd0;
            down_error_q <= 1'b0;
            down_data_q <= 64'd0;
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
            row_refill_count <= 0;
            row_refill_word_count <= 0;
            cache_hit_count <= 0;
            cache_miss_count <= 0;
            stage_config_count <= 0;
            cache_stage_count <= 0;
            bypass_stage_count <= 0;
            down_req_stall_count <= 0;
            down_rsp_gap_count <= 0;
            upstream_rsp_stall_count <= 0;
            memory_error_rsp_count <= 0;
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
            if (down_pending_q && !down_rsp_valid)
                down_rsp_gap_count <= down_rsp_gap_count + 1;
            if (seam_s_rsp_valid && !base.mem_rsp_ready)
                upstream_rsp_stall_count <= upstream_rsp_stall_count + 1;

            if (down_pending_q && down_delay_q != 0 &&
                !base.hold_responses)
                down_delay_q <= down_delay_q - 1'b1;

            if (base.cache_stage_start_valid && seam_stage_ready) begin
                stage_config_count <= stage_config_count + 1;
                if (base.cache_stage_enable)
                    cache_stage_count <= cache_stage_count + 1;
                else
                    bypass_stage_count <= bypass_stage_count + 1;
            end

            if (base.mem_req_valid && seam_s_req_ready) begin
                logical_req_count <= logical_req_count + 1;
                // The base error scenario removes its injection control as
                // soon as the logical request is accepted.  Preserve that
                // transaction attribute across the seam's registered front
                // end until the corresponding downstream request appears.
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
                            8'd2: one_by_one_read_count <=
                                one_by_one_read_count + 1;
                            8'd4: upsample_read_count <=
                                upsample_read_count + 1;
                            8'd5: residual_read_count <=
                                residual_read_count + 1;
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

            if (down_req_valid && down_req_ready) begin
                if (down_pending_q)
                    $fatal(1, "downstream BFM accepted second outstanding");
                if (down_req_addr[2:0] != 0 || down_req_addr < BASE_ADDR ||
                    down_req_addr >= BASE_ADDR + 3 * BANK_BYTES)
                    $fatal(1, "downstream address outside tensor arena: %h",
                           down_req_addr);
                down_memory_index = (down_req_addr - BASE_ADDR) >> 3;
                down_req_count <= down_req_count + 1;
                down_pending_q <= 1'b1;
                down_delay_q <= {1'b0, bfm_lfsr_q[3:2]};
                down_error_q <= inject_for_logical_q;
                if (down_req_write) begin
                    down_write_count <= down_write_count + 1;
                    if (down_req_wstrb != 8'hff)
                        $fatal(1, "downstream write strobe mismatch");
                    // The base logical-request scoreboard is the sole writer
                    // of its shared tensor array.  This downstream BFM only
                    // acknowledges the same write, avoiding a second
                    // procedural writer and an avoidable simulation race.
                    down_data_q <= 64'd0;
                end else begin
                    down_read_count <= down_read_count + 1;
                    if (down_req_wstrb != 0)
                        $fatal(1, "downstream read carried byte strobes");
                    down_data_q <= base.memory[down_memory_index];
                end
            end

            if (down_rsp_valid && down_rsp_ready) begin
                down_rsp_count <= down_rsp_count + 1;
                down_pending_q <= 1'b0;
                down_delay_q <= 3'd0;
                down_error_q <= 1'b0;
            end

            if (base.adapter_error && base.adapter_error_code == 8'h03)
                saw_generation_error_q <= 1'b1;
        end
    end

    // The base test calls $finish one rising edge after the final abort.  Emit
    // and validate this wrapper's distinct marker on that abort's falling
    // edge, after every dynamic memory scenario has already completed.
    always @(negedge base.adapter_abort) begin
        if (saw_generation_error_q && !printed_q) begin
            printed_q = 1'b1;
            if (stage_config_count != 22 || cache_stage_count != 8 ||
                bypass_stage_count != 14)
                $fatal(1, "cache stage coverage mismatch cfg=%0d cache=%0d bypass=%0d",
                       stage_config_count, cache_stage_count,
                       bypass_stage_count);
            if (cacheable_read_count == 0 || cache_hit_count == 0 ||
                cache_miss_count == 0 || row_refill_count == 0 ||
                row_refill_word_count == 0)
                $fatal(1, "cache hit/miss/refill coverage missing");
            if (one_by_one_read_count == 0 || upsample_read_count == 0 ||
                residual_read_count == 0 || logical_write_count == 0)
                $fatal(1, "mandatory bypass class coverage missing");
            if (logical_req_count != logical_rsp_count ||
                down_req_count != down_rsp_count || down_pending_q)
                $fatal(1, "request/response imbalance logical=%0d/%0d down=%0d/%0d pending=%0b",
                       logical_req_count, logical_rsp_count,
                       down_req_count, down_rsp_count, down_pending_q);
            if (down_read_count * 4 >= logical_read_count * 3)
                $fatal(1, "cache did not materially reduce reads logical=%0d downstream=%0d",
                       logical_read_count, down_read_count);
            if (down_req_stall_count == 0 || down_rsp_gap_count == 0)
                $fatal(1, "random downstream backpressure coverage missing");
            if (memory_error_rsp_count != 1)
                $fatal(1, "memory-error coverage mismatch count=%0d",
                       memory_error_rsp_count);
            if (base.abort_drain_count == 0)
                $fatal(1, "base abort-drain coverage missing");
            if (cache_error)
                $fatal(1, "cache retained error code %0d", cache_error_code);
            $display("C1_R1_ADAPTER_WINDOW_CACHE_DYNAMIC_PASS stage_cfg=%0d cache_stages=%0d bypass_stages=%0d logical_req=%0d logical_rsp=%0d logical_reads=%0d logical_writes=%0d cacheable=%0d bypass_reads=%0d onebyone=%0d upsample=%0d residual=%0d hits=%0d misses=%0d row_refills=%0d refill_words=%0d downstream_req=%0d downstream_rsp=%0d downstream_reads=%0d downstream_writes=%0d req_stalls=%0d rsp_gaps=%0d upstream_rsp_stalls=%0d memory_errors=%0d abort_drains=%0d",
                     stage_config_count, cache_stage_count,
                     bypass_stage_count, logical_req_count,
                     logical_rsp_count, logical_read_count,
                     logical_write_count, cacheable_read_count,
                     bypass_read_count, one_by_one_read_count,
                     upsample_read_count, residual_read_count,
                     cache_hit_count, cache_miss_count,
                     row_refill_count, row_refill_word_count,
                     down_req_count, down_rsp_count, down_read_count,
                     down_write_count, down_req_stall_count,
                     down_rsp_gap_count, upstream_rsp_stall_count,
                     memory_error_rsp_count,
                     base.abort_drain_count);
        end
    end
endmodule
