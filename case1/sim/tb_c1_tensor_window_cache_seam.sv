`timescale 1ns/1ps

module tb_c1_tensor_window_cache_seam;
    localparam integer DATA_W = 64;
    localparam integer MAX_ROW_WORDS = 8;
    localparam integer NORMAL_W = 4;
    localparam integer NORMAL_H = 3;
    localparam integer NORMAL_G = 2;
    localparam integer ROW_WORDS = NORMAL_W * NORMAL_G;
    localparam logic [31:0] NORMAL_BASE = 32'h0000_1000;
    localparam logic [31:0] DIRECT_BASE = 32'h0000_1800;
    localparam logic [31:0] LARGE_BASE = 32'h0000_2000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic stage_start_valid;
    logic stage_start_ready;
    logic stage_cache_enable;
    logic [31:0] stage_base_addr;
    logic [15:0] stage_width;
    logic [15:0] stage_height;
    logic [3:0] stage_groups;
    logic stage_start_done;
    logic stage_cache_active;
    logic stage_cache_fallback;
    logic [3:0] stage_cache_reason;

    logic abort_req;
    logic abort_done;
    logic flush_req;
    logic flush_done;

    logic s_req_valid;
    logic s_req_ready;
    logic s_req_write;
    logic [31:0] s_req_addr;
    logic [63:0] s_req_wdata;
    logic [7:0] s_req_wstrb;
    logic s_req_cacheable;
    logic signed [16:0] s_req_cache_x;
    logic signed [16:0] s_req_cache_y;
    logic [2:0] s_req_cache_group;
    logic s_rsp_valid;
    logic s_rsp_ready;
    logic s_rsp_error;
    logic [63:0] s_rsp_rdata;

    logic m_req_valid;
    logic m_req_ready;
    logic m_req_write;
    logic [31:0] m_req_addr;
    logic [63:0] m_req_wdata;
    logic [7:0] m_req_wstrb;
    logic m_rsp_valid;
    logic m_rsp_ready;
    logic m_rsp_error;
    logic [63:0] m_rsp_rdata;

    logic cache_error;
    logic [2:0] cache_error_code;
    logic busy;
    logic quiescent;

    c1_tensor_window_cache_seam #(
        .DATA_W(DATA_W),
        .LINE_ROWS(3),
        .MAX_ROW_WORDS(MAX_ROW_WORDS),
        .MAX_GROUPS(8)
    ) dut (
        .clk(clk),
        .rst(rst),
        .stage_start_valid(stage_start_valid),
        .stage_start_ready(stage_start_ready),
        .stage_cache_enable(stage_cache_enable),
        .stage_base_addr(stage_base_addr),
        .stage_width(stage_width),
        .stage_height(stage_height),
        .stage_groups(stage_groups),
        .stage_start_done(stage_start_done),
        .stage_cache_active(stage_cache_active),
        .stage_cache_fallback(stage_cache_fallback),
        .stage_cache_reason(stage_cache_reason),
        .abort_req(abort_req),
        .abort_done(abort_done),
        .flush_req(flush_req),
        .flush_done(flush_done),
        .s_req_valid(s_req_valid),
        .s_req_ready(s_req_ready),
        .s_req_write(s_req_write),
        .s_req_addr(s_req_addr),
        .s_req_wdata(s_req_wdata),
        .s_req_wstrb(s_req_wstrb),
        .s_req_cacheable(s_req_cacheable),
        .s_req_cache_x(s_req_cache_x),
        .s_req_cache_y(s_req_cache_y),
        .s_req_cache_group(s_req_cache_group),
        .s_rsp_valid(s_rsp_valid),
        .s_rsp_ready(s_rsp_ready),
        .s_rsp_error(s_rsp_error),
        .s_rsp_rdata(s_rsp_rdata),
        .m_req_valid(m_req_valid),
        .m_req_ready(m_req_ready),
        .m_req_write(m_req_write),
        .m_req_addr(m_req_addr),
        .m_req_wdata(m_req_wdata),
        .m_req_wstrb(m_req_wstrb),
        .m_rsp_valid(m_rsp_valid),
        .m_rsp_ready(m_rsp_ready),
        .m_rsp_error(m_rsp_error),
        .m_rsp_rdata(m_rsp_rdata),
        .cache_error(cache_error),
        .cache_error_code(cache_error_code),
        .busy(busy),
        .quiescent(quiescent)
    );

    logic [63:0] memory [0:2047];
    logic [31:0] request_log_addr [0:255];
    logic request_log_write [0:255];
    logic [63:0] request_log_wdata [0:255];
    logic [7:0] request_log_wstrb [0:255];

    integer cycle_count;
    integer down_req_count;
    integer down_read_count;
    integer down_write_count;
    integer logical_req_count;
    integer logical_rsp_count;
    integer stage_done_count;
    integer flush_done_count;
    integer abort_done_count;
    integer s_req_stall_cycles;
    integer s_rsp_stall_cycles;
    integer m_req_stall_cycles;
    integer m_rsp_stall_cycles;

    logic mem_pending_q;
    integer mem_delay_q;
    logic [63:0] mem_rsp_data_q;
    logic mem_rsp_valid_q;
    integer mem_index;
    integer lane;
    integer init_index;

    logic s_rsp_hold_q;
    logic [64:0] s_rsp_hold_payload_q;
    logic m_req_hold_q;
    logic [104:0] m_req_hold_payload_q;
    logic m_rsp_hold_q;
    logic [64:0] m_rsp_hold_payload_q;

    function automatic [63:0] initial_word(input integer word_index);
        integer byte_lane;
        integer byte_value;
        begin
            initial_word = 64'd0;
            for (byte_lane = 0; byte_lane < 8;
                 byte_lane = byte_lane + 1) begin
                byte_value = word_index * 37 + byte_lane * 19 + 8'h5d;
                initial_word[byte_lane*8 +: 8] = byte_value[7:0];
            end
        end
    endfunction

    function automatic [31:0] tensor_addr(
        input logic [31:0] base,
        input integer width_value,
        input integer groups_value,
        input integer x_value,
        input integer y_value,
        input integer group_value
    );
        integer beat;
        begin
            beat = ((y_value * width_value + x_value) * groups_value) +
                   group_value;
            tensor_addr = base + beat * 8;
        end
    endfunction

    function automatic [63:0] merge_write(
        input [63:0] old_value,
        input [63:0] new_value,
        input [7:0] strobe
    );
        integer merge_lane;
        begin
            merge_write = old_value;
            for (merge_lane = 0; merge_lane < 8;
                 merge_lane = merge_lane + 1) begin
                if (strobe[merge_lane])
                    merge_write[merge_lane*8 +: 8] =
                        new_value[merge_lane*8 +: 8];
            end
        end
    endfunction

    assign m_req_ready = !mem_pending_q && !mem_rsp_valid_q &&
                         (cycle_count[2:0] != 3'b011);
    assign m_rsp_valid = mem_rsp_valid_q;
    assign m_rsp_error = 1'b0;
    assign m_rsp_rdata = mem_rsp_data_q;

    // Single-outstanding downstream memory with deterministic request stalls,
    // response latency, partial writes, and response backpressure.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            down_req_count <= 0;
            down_read_count <= 0;
            down_write_count <= 0;
            logical_req_count <= 0;
            logical_rsp_count <= 0;
            stage_done_count <= 0;
            flush_done_count <= 0;
            abort_done_count <= 0;
            s_req_stall_cycles <= 0;
            s_rsp_stall_cycles <= 0;
            m_req_stall_cycles <= 0;
            m_rsp_stall_cycles <= 0;
            mem_pending_q <= 1'b0;
            mem_delay_q <= 0;
            mem_rsp_data_q <= 64'd0;
            mem_rsp_valid_q <= 1'b0;
            s_rsp_hold_q <= 1'b0;
            m_req_hold_q <= 1'b0;
            m_rsp_hold_q <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (s_req_valid && s_req_ready)
                logical_req_count <= logical_req_count + 1;
            if (s_rsp_valid && s_rsp_ready)
                logical_rsp_count <= logical_rsp_count + 1;
            if (stage_start_done)
                stage_done_count <= stage_done_count + 1;
            if (flush_done)
                flush_done_count <= flush_done_count + 1;
            if (abort_done)
                abort_done_count <= abort_done_count + 1;
            if (s_req_valid && !s_req_ready)
                s_req_stall_cycles <= s_req_stall_cycles + 1;
            if (s_rsp_valid && !s_rsp_ready)
                s_rsp_stall_cycles <= s_rsp_stall_cycles + 1;
            if (m_req_valid && !m_req_ready)
                m_req_stall_cycles <= m_req_stall_cycles + 1;
            if (m_rsp_valid && !m_rsp_ready)
                m_rsp_stall_cycles <= m_rsp_stall_cycles + 1;

            if (s_rsp_hold_q &&
                (!s_rsp_valid ||
                 ({s_rsp_error, s_rsp_rdata} != s_rsp_hold_payload_q)))
                $fatal(1, "upstream response changed under backpressure");
            s_rsp_hold_q <= s_rsp_valid && !s_rsp_ready;
            s_rsp_hold_payload_q <= {s_rsp_error, s_rsp_rdata};

            if (m_req_hold_q &&
                (!m_req_valid ||
                 ({m_req_write, m_req_addr, m_req_wdata, m_req_wstrb} !=
                  m_req_hold_payload_q)))
                $fatal(1, "downstream request changed under backpressure");
            m_req_hold_q <= m_req_valid && !m_req_ready;
            m_req_hold_payload_q <= {m_req_write, m_req_addr,
                                     m_req_wdata, m_req_wstrb};

            if (m_rsp_hold_q &&
                (!m_rsp_valid ||
                 ({m_rsp_error, m_rsp_rdata} != m_rsp_hold_payload_q)))
                $fatal(1, "memory response changed under backpressure");
            m_rsp_hold_q <= m_rsp_valid && !m_rsp_ready;
            m_rsp_hold_payload_q <= {m_rsp_error, m_rsp_rdata};

            if (m_req_valid && m_req_ready) begin
                if (down_req_count >= 256)
                    $fatal(1, "downstream request log overflow");
                request_log_addr[down_req_count] <= m_req_addr;
                request_log_write[down_req_count] <= m_req_write;
                request_log_wdata[down_req_count] <= m_req_wdata;
                request_log_wstrb[down_req_count] <= m_req_wstrb;
                down_req_count <= down_req_count + 1;
                mem_pending_q <= 1'b1;
                mem_delay_q <= (down_req_count % 3) + 1;
                mem_index = m_req_addr >> 3;
                if ((m_req_addr[2:0] != 0) ||
                    (mem_index < 0) || (mem_index >= 2048))
                    $fatal(1, "invalid downstream address %h", m_req_addr);
                if (m_req_write) begin
                    down_write_count <= down_write_count + 1;
                    for (lane = 0; lane < 8; lane = lane + 1) begin
                        if (m_req_wstrb[lane])
                            memory[mem_index][lane*8 +: 8] <=
                                m_req_wdata[lane*8 +: 8];
                    end
                    mem_rsp_data_q <= 64'd0;
                end else begin
                    down_read_count <= down_read_count + 1;
                    mem_rsp_data_q <= memory[mem_index];
                end
            end

            if (mem_pending_q && !mem_rsp_valid_q) begin
                if (mem_delay_q == 0)
                    mem_rsp_valid_q <= 1'b1;
                else
                    mem_delay_q <= mem_delay_q - 1;
            end

            if (mem_rsp_valid_q && m_rsp_ready) begin
                mem_rsp_valid_q <= 1'b0;
                mem_pending_q <= 1'b0;
            end
        end
    end

    task automatic start_stage(
        input logic enable_cache,
        input logic [31:0] base,
        input integer width_value,
        input integer height_value,
        input integer groups_value,
        input logic expected_active,
        input logic [3:0] expected_reason
    );
        begin
            @(negedge clk);
            stage_cache_enable = enable_cache;
            stage_base_addr = base;
            stage_width = width_value;
            stage_height = height_value;
            stage_groups = groups_value;
            stage_start_valid = 1'b1;
            do begin
                @(posedge clk);
            end while (!stage_start_ready);
            @(negedge clk);
            stage_start_valid = 1'b0;
            while (!stage_start_done)
                @(negedge clk);
            if (stage_cache_active !== expected_active)
                $fatal(1, "stage active mismatch got=%0b expected=%0b reason=%0d",
                       stage_cache_active, expected_active,
                       stage_cache_reason);
            if (stage_cache_reason !== expected_reason)
                $fatal(1, "stage reason mismatch got=%0d expected=%0d",
                       stage_cache_reason, expected_reason);
            if (stage_cache_fallback !== !expected_active)
                $fatal(1, "stage fallback mismatch");
        end
    endtask

    task automatic transact(
        input logic write_request,
        input logic [31:0] address,
        input logic [63:0] write_data,
        input logic [7:0] write_strobe,
        input logic cacheable,
        input integer cache_x,
        input integer cache_y,
        input integer cache_group,
        input logic [63:0] expected_data,
        input logic expected_error,
        input integer response_stall_cycles
    );
        integer stall_index;
        begin
            @(negedge clk);
            s_rsp_ready = 1'b0;
            s_req_write = write_request;
            s_req_addr = address;
            s_req_wdata = write_data;
            s_req_wstrb = write_strobe;
            s_req_cacheable = cacheable;
            s_req_cache_x = cache_x;
            s_req_cache_y = cache_y;
            s_req_cache_group = cache_group;
            s_req_valid = 1'b1;
            do begin
                @(posedge clk);
            end while (!s_req_ready);
            @(negedge clk);
            s_req_valid = 1'b0;

            while (!s_rsp_valid)
                @(negedge clk);
            if ((s_rsp_rdata !== expected_data) ||
                (s_rsp_error !== expected_error))
                $fatal(1,
                       "logical response mismatch addr=%h got=%h err=%0b expected=%h err=%0b",
                       address, s_rsp_rdata, s_rsp_error,
                       expected_data, expected_error);

            for (stall_index = 0; stall_index < response_stall_cycles;
                 stall_index = stall_index + 1) begin
                @(posedge clk);
                if (!s_rsp_valid || s_rsp_rdata !== expected_data ||
                    s_rsp_error !== expected_error)
                    $fatal(1, "logical response unstable while stalled");
            end
            @(negedge clk);
            s_rsp_ready = 1'b1;
            @(posedge clk);
            if (!s_rsp_valid)
                $fatal(1, "logical response vanished on acceptance edge");
            @(negedge clk);
            s_rsp_ready = 1'b0;
        end
    endtask

    task automatic check_refill_sequence(
        input integer first_log,
        input logic [31:0] row_base
    );
        integer word_index;
        begin
            if (down_req_count != first_log + ROW_WORDS)
                $fatal(1, "row refill count mismatch got=%0d expected=%0d",
                       down_req_count - first_log, ROW_WORDS);
            for (word_index = 0; word_index < ROW_WORDS;
                 word_index = word_index + 1) begin
                if (request_log_write[first_log + word_index] ||
                    request_log_addr[first_log + word_index] !==
                        row_base + word_index * 8)
                    $fatal(1,
                           "row refill address mismatch i=%0d got=%h write=%0b expected=%h",
                           word_index,
                           request_log_addr[first_log + word_index],
                           request_log_write[first_log + word_index],
                           row_base + word_index * 8);
            end
        end
    endtask

    task automatic maintenance_collision(input bit first_abort,input bit second_abort);
        integer base_a,base_f,guard;
        begin
            repeat(2) @(negedge clk);
            base_a=abort_done_count;base_f=flush_done_count;
            if(first_abort) abort_req=1; else flush_req=1;
            @(negedge clk);abort_req=0;flush_req=0;
            guard=0;
            while(!(first_abort ? dut.cache_abort_done : dut.cache_flush_done)) begin
                @(negedge clk);guard++;
                if(guard>100) $fatal(1,"nonburst fixture missed child completion");
            end
            if(first_abort ? abort_done : flush_done)
                $fatal(1,"nonburst collision stimulus late");
            if(second_abort) abort_req=1; else flush_req=1;
            @(negedge clk);abort_req=0;flush_req=0;
            guard=0;
            while(!quiescent || busy ||
                  abort_done_count<base_a+(first_abort||second_abort) ||
                  flush_done_count<base_f+(!first_abort||!second_abort)) begin
                @(negedge clk);guard++;
                if(guard>100) $fatal(1,"nonburst maintenance collision failed drain");
            end
            repeat(12) @(negedge clk);
            if(abort_done_count!=base_a+(first_abort||second_abort) ||
               flush_done_count!=base_f+(!first_abort||!second_abort) || busy || !quiescent)
                $fatal(1,"nonburst maintenance collision duplicate completion");
            $display("C1_NONBURST_MAINTENANCE_COLLISION_PASS first_abort=%0d second_abort=%0d",first_abort,second_abort);
        end
    endtask

    task automatic pulse_flush;
        begin
            @(negedge clk);
            flush_req = 1'b1;
            @(negedge clk);
            flush_req = 1'b0;
            while (!flush_done)
                @(negedge clk);
            if (!stage_cache_active)
                $fatal(1, "flush did not restore active cache state");
        end
    endtask

    initial begin : main_test
        integer down_before;
        logic [31:0] address;
        logic [63:0] expected;
        logic [63:0] old_value;
        logic [63:0] write_value;
        logic [7:0] write_mask;

        for (init_index = 0; init_index < 2048;
             init_index = init_index + 1)
            memory[init_index] = initial_word(init_index);

        stage_start_valid = 1'b0;
        stage_cache_enable = 1'b0;
        stage_base_addr = 32'd0;
        stage_width = 16'd0;
        stage_height = 16'd0;
        stage_groups = 4'd0;
        abort_req = 1'b0;
        flush_req = 1'b0;
        s_req_valid = 1'b0;
        s_req_write = 1'b0;
        s_req_addr = 32'd0;
        s_req_wdata = 64'd0;
        s_req_wstrb = 8'd0;
        s_req_cacheable = 1'b0;
        s_req_cache_x = 17'sd0;
        s_req_cache_y = 17'sd0;
        s_req_cache_group = 3'd0;
        s_rsp_ready = 1'b0;

        repeat (6) @(negedge clk);
        rst = 1'b0;

        // Directed drain_front coverage.  Present a direct read while the
        // valid-stage address guard is still in its 16-cycle CFG_MULTIPLY
        // phase, then request abort.  The already-presented request must be
        // admitted after configuration, returned exactly once, and drained
        // before abort is forwarded to the line cache.
        @(negedge clk);
        stage_cache_enable = 1'b1;
        stage_base_addr = NORMAL_BASE;
        stage_width = NORMAL_W;
        stage_height = NORMAL_H;
        stage_groups = NORMAL_G;
        stage_start_valid = 1'b1;
        do begin
            @(posedge clk);
        end while (!stage_start_ready);
        @(negedge clk);
        stage_start_valid = 1'b0;

        down_before = down_req_count;
        address = DIRECT_BASE + 32'd24;
        expected = memory[address >> 3];
        s_rsp_ready = 1'b0;
        s_req_write = 1'b0;
        s_req_addr = address;
        s_req_wdata = 64'd0;
        s_req_wstrb = 8'd0;
        s_req_cacheable = 1'b0;
        s_req_cache_x = 17'sd0;
        s_req_cache_y = 17'sd0;
        s_req_cache_group = 3'd0;
        s_req_valid = 1'b1;
        @(posedge clk);
        if (s_req_ready)
            $fatal(1, "request was accepted during CFG_MULTIPLY");
        @(negedge clk);
        abort_req = 1'b1;
        @(negedge clk);
        abort_req = 1'b0;

        do begin
            @(posedge clk);
            if (abort_done)
                $fatal(1, "abort completed before drain_front request accepted");
        end while (!s_req_ready);
        @(negedge clk);
        s_req_valid = 1'b0;
        while (!s_rsp_valid) begin
            @(negedge clk);
            if (abort_done)
                $fatal(1, "abort completed before drain_front response");
        end
        if (s_rsp_error || (s_rsp_rdata !== expected))
            $fatal(1, "drain_front response mismatch got=%h err=%0b expected=%h",
                   s_rsp_rdata, s_rsp_error, expected);
        repeat (3) begin
            @(posedge clk);
            if (abort_done || !s_rsp_valid || (s_rsp_rdata !== expected))
                $fatal(1, "abort did not preserve drain_front stalled response");
        end
        @(negedge clk);
        s_rsp_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        s_rsp_ready = 1'b0;
        while (!abort_done)
            @(negedge clk);
        if (down_req_count != down_before + 1)
            $fatal(1, "drain_front direct read did not bypass exactly once");

        start_stage(1'b1, NORMAL_BASE, NORMAL_W, NORMAL_H, NORMAL_G,
                    1'b1, 4'd0);

        // Negative x/y clamp to row 0, word (x=0,group=0).  The miss must
        // fetch one complete, ordered interleaved row.
        down_before = down_req_count;
        address = tensor_addr(NORMAL_BASE, NORMAL_W, NORMAL_G, 0, 0, 0);
        expected = memory[address >> 3];
        transact(1'b0, address, 64'd0, 8'd0, 1'b1,
                 -1, -1, 0, expected, 1'b0, 2);
        check_refill_sequence(down_before, NORMAL_BASE);

        // Same row, a different x and then a different group: both are hits
        // and must issue no downstream request.
        down_before = down_req_count;
        address = tensor_addr(NORMAL_BASE, NORMAL_W, NORMAL_G, 2, 0, 0);
        transact(1'b0, address, 64'd0, 8'd0, 1'b1,
                 2, 0, 0, memory[address >> 3], 1'b0, 1);
        address = tensor_addr(NORMAL_BASE, NORMAL_W, NORMAL_G, 0, 0, 1);
        transact(1'b0, address, 64'd0, 8'd0, 1'b1,
                 -5, -3, 1, memory[address >> 3], 1'b0, 1);
        if (down_req_count != down_before)
            $fatal(1, "same-row cache hits touched downstream memory");

        // Right/bottom clamp selects the last word of row 2 and refills that
        // entire row from its physical row base.
        down_before = down_req_count;
        address = tensor_addr(NORMAL_BASE, NORMAL_W, NORMAL_G, 3, 2, 1);
        transact(1'b0, address, 64'd0, 8'd0, 1'b1,
                 99, 77, 1, memory[address >> 3], 1'b0, 2);
        check_refill_sequence(
            down_before,
            tensor_addr(NORMAL_BASE, NORMAL_W, NORMAL_G, 0, 2, 0));

        // Ordinary read and partial write/readback use the unchanged direct
        // narrow request/response payload.
        down_before = down_req_count;
        address = DIRECT_BASE;
        transact(1'b0, address, 64'd0, 8'd0, 1'b0,
                 0, 0, 0, memory[address >> 3], 1'b0, 3);
        if (down_req_count != down_before + 1 ||
            request_log_addr[down_before] !== address ||
            request_log_write[down_before])
            $fatal(1, "direct read did not bypass exactly once");

        address = DIRECT_BASE + 8;
        old_value = memory[address >> 3];
        write_value = 64'h0123_4567_89ab_cdef;
        write_mask = 8'b1010_1100;
        expected = merge_write(old_value, write_value, write_mask);
        down_before = down_req_count;
        transact(1'b1, address, write_value, write_mask, 1'b0,
                 0, 0, 0, 64'd0, 1'b0, 2);
        if (down_req_count != down_before + 1 ||
            !request_log_write[down_before] ||
            request_log_wdata[down_before] !== write_value ||
            request_log_wstrb[down_before] !== write_mask)
            $fatal(1, "direct write payload mismatch");
        transact(1'b0, address, 64'd0, 8'd0, 1'b0,
                 0, 0, 0, expected, 1'b0, 1);

        // Physical address and cache sideband disagree: safe direct bypass.
        down_before = down_req_count;
        address = tensor_addr(NORMAL_BASE, NORMAL_W, NORMAL_G, 0, 1, 0);
        transact(1'b0, address, 64'd0, 8'd0, 1'b1,
                 1, 1, 0, memory[address >> 3], 1'b0, 2);
        if (down_req_count != down_before + 1 ||
            request_log_addr[down_before] !== address)
            $fatal(1, "sideband/address mismatch was not safely bypassed");

        // Width*groups exceeds MAX_ROW_WORDS: stage stays operational via
        // direct fallback rather than indexing beyond the cache RAM.
        start_stage(1'b1, LARGE_BASE, 5, 2, 2, 1'b0, 4'd4);
        down_before = down_req_count;
        address = tensor_addr(LARGE_BASE, 5, 2, 1, 0, 0);
        transact(1'b0, address, 64'd0, 8'd0, 1'b1,
                 1, 0, 0, memory[address >> 3], 1'b0, 1);
        if (down_req_count != down_before + 1)
            $fatal(1, "capacity-disabled stage did not bypass");

        // Fault-inject a cache-side configuration rejection even though the
        // seam's own geometry guard accepts the stage.  This emulates future
        // parameter/check drift between the wrapper and payload cache.  The
        // stage must complete as a reason-9 fallback and remain usable through
        // the direct memory path rather than deadlocking its first tap.
        force dut.cache_group_start_done = 1'b1;
        force dut.cache_group_start_error = 1'b1;
        force dut.cache_config_valid = 1'b0;
        start_stage(1'b1, NORMAL_BASE, NORMAL_W, NORMAL_H, NORMAL_G,
                    1'b0, 4'd9);
        release dut.cache_group_start_done;
        release dut.cache_group_start_error;
        release dut.cache_config_valid;
        @(negedge clk);
        if (stage_cache_active || !stage_cache_fallback ||
            stage_cache_reason != 4'd9)
            $fatal(1, "cache config rejection did not retain safe fallback");
        down_before = down_req_count;
        address = tensor_addr(NORMAL_BASE, NORMAL_W, NORMAL_G, 2, 0, 1);
        transact(1'b0, address, 64'd0, 8'd0, 1'b1,
                 2, 0, 1, memory[address >> 3], 1'b0, 1);
        if (down_req_count != down_before + 1)
            $fatal(1, "config-rejected cache request did not bypass once");

        // Re-enter the normal stage, populate row zero, then write its first
        // word.  Coherence poison disables cache use until flush.
        start_stage(1'b1, NORMAL_BASE, NORMAL_W, NORMAL_H, NORMAL_G,
                    1'b1, 4'd0);

        // Accept and classify a valid cache tap, then inject a runtime cache
        // fault after FRONT_CHECK has latched the cache route but before the
        // line cache can accept/miss it.  The registered request must switch
        // to the unchanged direct-memory path and retire exactly once.
        down_before = down_req_count;
        address = tensor_addr(NORMAL_BASE, NORMAL_W, NORMAL_G, 1, 0, 0);
        expected = memory[address >> 3];
        @(negedge clk);
        s_rsp_ready = 1'b0;
        s_req_write = 1'b0;
        s_req_addr = address;
        s_req_wdata = 64'd0;
        s_req_wstrb = 8'd0;
        s_req_cacheable = 1'b1;
        s_req_cache_x = 17'sd1;
        s_req_cache_y = 17'sd0;
        s_req_cache_group = 3'd0;
        s_req_valid = 1'b1;
        do begin
            @(posedge clk);
        end while (!s_req_ready);
        @(negedge clk);
        s_req_valid = 1'b0;
        while ((dut.front_state_q != 3'd3) || !dut.front_cache_route_q)
            @(negedge clk);
        force dut.cache_error_i = 1'b1;
        force dut.cache_error_code_i = 3'd2;
        #1;
        if (stage_cache_active || stage_cache_reason != 4'd7)
            $fatal(1, "runtime cache error did not expose fallback status");
        while (!s_rsp_valid)
            @(negedge clk);
        if (s_rsp_error || s_rsp_rdata !== expected)
            $fatal(1, "runtime-error bypass response mismatch");
        if (down_req_count != down_before + 1)
            $fatal(1, "runtime-error cache route did not bypass exactly once");
        @(negedge clk);
        s_rsp_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        s_rsp_ready = 1'b0;
        // XSim does not necessarily re-evaluate a procedurally driven module
        // output merely because a hierarchical force is released.  Restore
        // the payload to the real C8 value first, then remove the force.
        force dut.cache_error_i = 1'b0;
        force dut.cache_error_code_i = 3'd0;
        #1;
        release dut.cache_error_i;
        release dut.cache_error_code_i;
        repeat (2) @(posedge clk);
        if (cache_error || !stage_cache_active || stage_cache_reason != 4'd0)
            $fatal(1, "runtime fault injection did not restore normal stage");

        down_before = down_req_count;
        address = tensor_addr(NORMAL_BASE, NORMAL_W, NORMAL_G, 1, 0, 0);
        transact(1'b0, address, 64'd0, 8'd0, 1'b1,
                 1, 0, 0, memory[address >> 3], 1'b0, 1);
        check_refill_sequence(down_before, NORMAL_BASE);

        address = NORMAL_BASE;
        write_value = 64'hfeed_face_1234_5678;
        transact(1'b1, address, write_value, 8'hff, 1'b0,
                 0, 0, 0, 64'd0, 1'b0, 2);
        if (stage_cache_active || !stage_cache_fallback ||
            stage_cache_reason != 4'd8)
            $fatal(1, "cached-range write did not poison coherence");

        down_before = down_req_count;
        transact(1'b0, address, 64'd0, 8'd0, 1'b1,
                 0, 0, 0, write_value, 1'b0, 2);
        if (down_req_count != down_before + 1)
            $fatal(1, "coherence-poisoned read did not bypass");

        // Flush removes stale tags and coherence poison.  The same logical
        // request must miss, refill all eight words, and see updated memory.
        pulse_flush();
        down_before = down_req_count;
        transact(1'b0, address, 64'd0, 8'd0, 1'b1,
                 0, 0, 0, write_value, 1'b0, 2);
        check_refill_sequence(down_before, NORMAL_BASE);

        // Abort during a row-one miss.  The seam must not abort its line cache
        // early: all eight row reads, the original request handshake, and its
        // stalled response retire before abort_done.
        down_before = down_req_count;
        address = tensor_addr(NORMAL_BASE, NORMAL_W, NORMAL_G, 1, 1, 1);
        expected = memory[address >> 3];
        @(negedge clk);
        s_rsp_ready = 1'b0;
        s_req_write = 1'b0;
        s_req_addr = address;
        s_req_wdata = 64'd0;
        s_req_wstrb = 8'd0;
        s_req_cacheable = 1'b1;
        s_req_cache_x = 17'sd1;
        s_req_cache_y = 17'sd1;
        s_req_cache_group = 3'd1;
        s_req_valid = 1'b1;

        do begin
            @(posedge clk);
        end while (!s_req_ready);
        @(negedge clk);
        s_req_valid = 1'b0;

        while (down_req_count < down_before + 2)
            @(negedge clk);
        abort_req = 1'b1;
        @(negedge clk);
        abort_req = 1'b0;
        @(negedge clk);
        if(!dut.refill_active_q || !dut.abort_pending_q)
            $fatal(1,"repeat abort fixture missed active refill/pending cancellation");
        abort_req=1;
        @(negedge clk);abort_req=0;

        while (down_req_count < down_before + ROW_WORDS) begin
            @(negedge clk);
            if (abort_done || flush_done)
                $fatal(1, "abort completed before row refill drained");
        end
        if (down_req_count != down_before + ROW_WORDS)
            $fatal(1, "abort truncated row refill got=%0d expected=%0d",
                   down_req_count - down_before, ROW_WORDS);
        check_refill_sequence(
            down_before,
            tensor_addr(NORMAL_BASE, NORMAL_W, NORMAL_G, 0, 1, 0));

        while (!s_rsp_valid)
            @(negedge clk);
        if (s_rsp_rdata !== expected || s_rsp_error)
            $fatal(1, "abort-drained cache response mismatch");
        // Two flush pulses join the still-pending repeated abort while the
        // actual logical response is held. Neither fence may complete yet.
        for(integer hold_cycle=0;hold_cycle<12;hold_cycle++) begin
            @(negedge clk);
            flush_req=(hold_cycle==1 || hold_cycle==4);
            if (abort_done || flush_done || !s_rsp_valid || s_rsp_rdata !== expected || s_rsp_error)
                $fatal(1, "abort did not preserve stalled logical response");
        end
        flush_req=0;
        @(negedge clk);
        s_rsp_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        s_rsp_ready = 1'b0;
        while (!abort_done)
            @(negedge clk);

        repeat (4) @(posedge clk);
        if (logical_req_count != 17 || logical_rsp_count != 17)
            $fatal(1, "logical totals mismatch req=%0d rsp=%0d",
                   logical_req_count, logical_rsp_count);
        if (down_req_count != 50 || down_read_count != 48 ||
            down_write_count != 2)
            $fatal(1, "downstream totals mismatch total=%0d read=%0d write=%0d",
                   down_req_count, down_read_count, down_write_count);
        if (stage_done_count != 5 || flush_done_count != 2 ||
            abort_done_count != 2)
            $fatal(1, "control totals mismatch stage=%0d flush=%0d abort=%0d",
                   stage_done_count, flush_done_count, abort_done_count);
        if ((s_req_stall_cycles == 0) || (s_rsp_stall_cycles == 0) ||
            (m_req_stall_cycles == 0) ||
            (m_rsp_stall_cycles == 0))
            $fatal(1, "backpressure coverage missing sreq=%0d srsp=%0d mreq=%0d mrsp=%0d",
                   s_req_stall_cycles, s_rsp_stall_cycles,
                   m_req_stall_cycles, m_rsp_stall_cycles);
        if (stage_cache_active || stage_cache_fallback ||
            cache_error || cache_error_code != 0 || busy || !quiescent)
            $fatal(1, "final abort/quiescent status mismatch");
        $display("C1_NONBURST_INFLIGHT_MAINTENANCE_PASS abort_pulses=2 flush_pulses=2 held_response=12 row_reads=8 logical_retire=1");

        maintenance_collision(0,0);
        maintenance_collision(0,1);
        maintenance_collision(1,0);
        maintenance_collision(1,1);
        $display("C1_TENSOR_WINDOW_CACHE_SEAM_PASS logical_req=%0d logical_rsp=%0d row_refills=5 refill_reads=40 bypass_reads=8 writes=2 downstream=%0d sreq_stalls=%0d srsp_stalls=%0d mreq_stalls=%0d mrsp_stalls=%0d stages=%0d flushes=%0d aborts=%0d cfg_rejects=1 runtime_fallbacks=1",
                 logical_req_count, logical_rsp_count, down_req_count,
                 s_req_stall_cycles, s_rsp_stall_cycles,
                 m_req_stall_cycles, m_rsp_stall_cycles,
                 stage_done_count, flush_done_count, abort_done_count);
        $finish;
    end

    initial begin : timeout_watchdog
        repeat (100000) @(posedge clk);
        $fatal(1, "tensor window cache seam timeout");
    end
endmodule
