`timescale 1ns/1ps

// Native input-DMA/frame-table staged preflight.
//
// This bench deliberately stops at the read-side boundary that is still
// missing from the capture/table preflight: a real frame-table reader and a
// real XRGB frame reader share the real ID-less c1_axi2_serial_arbiter_128.
// Three 640x480 slots are described by 16-byte table entries.  The table
// lookup for slot N+1 is issued while slot N is being raster-read, so the
// arbiter has to preserve ownership across a table transaction and a frame
// burst.  No CNN, tensor traffic, display reader, CSI IP, or board-specific
// block is instantiated here.
module tb_c1_r1_native_input_dma;
    localparam integer FRAME_W = 640;
    localparam integer FRAME_H = 480;
    localparam integer STRIDE = FRAME_W * 4;
    localparam integer FRAME_BYTES = STRIDE * FRAME_H;
    localparam integer FRAME_SLOT_BYTES = 32'h0012_c000;
    localparam integer FRAME_BEATS = (FRAME_W / 4) * FRAME_H;
    localparam integer FRAME_BURSTS = FRAME_H * ((FRAME_W / 4 + 15) / 16);
    localparam logic [31:0] TABLE_BASE = 32'h0008_0000;
    localparam logic [31:0] INPUT_BASE = 32'h0010_0000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // Table-reader client (arbiter master 0)
    // ------------------------------------------------------------------
    logic table_abort = 1'b0;
    logic table_request_valid = 1'b0;
    logic table_request_ready;
    logic [63:0] table_request_base = TABLE_BASE;
    logic [1:0] table_request_index = '0;
    logic table_response_valid;
    logic table_response_ready = 1'b1;
    logic table_response_error;
    logic [127:0] table_response_raw;
    logic [63:0] table_response_base;
    logic [31:0] table_response_stride;
    logic [15:0] table_response_width;
    logic [15:0] table_response_height;
    logic [31:0] table_araddr;
    logic [7:0] table_arlen;
    logic [2:0] table_arsize;
    logic [1:0] table_arburst;
    logic table_arvalid;
    logic table_arready;
    logic [127:0] table_rdata;
    logic [1:0] table_rresp;
    logic table_rlast;
    logic table_rvalid;
    logic table_rready;

    c1_axi_frame_buffer_table_reader #(.INDEX_BITS(2)) u_table_reader (
        .clk, .rst, .abort(table_abort),
        .request_valid(table_request_valid), .request_ready(table_request_ready),
        .request_table_base(table_request_base),
        .request_entry_index(table_request_index),
        .response_valid(table_response_valid), .response_ready(table_response_ready),
        .response_error(table_response_error), .response_raw(table_response_raw),
        .response_base_address(table_response_base),
        .response_stride_bytes(table_response_stride),
        .response_width_pixels(table_response_width),
        .response_height_lines(table_response_height),
        .m_axi_araddr(table_araddr), .m_axi_arlen(table_arlen),
        .m_axi_arsize(table_arsize), .m_axi_arburst(table_arburst),
        .m_axi_arvalid(table_arvalid), .m_axi_arready(table_arready),
        .m_axi_rdata(table_rdata), .m_axi_rresp(table_rresp),
        .m_axi_rlast(table_rlast), .m_axi_rvalid(table_rvalid),
        .m_axi_rready(table_rready)
    );

    // ------------------------------------------------------------------
    // XRGB input-DMA client (arbiter master 1)
    // ------------------------------------------------------------------
    logic reader_start = 1'b0;
    logic reader_cancel = 1'b0;
    logic [31:0] reader_cfg_base = '0;
    logic [15:0] reader_cfg_width = FRAME_W;
    logic [15:0] reader_cfg_height = FRAME_H;
    logic [31:0] reader_cfg_stride = STRIDE;
    logic reader_busy;
    logic reader_done;
    logic reader_error;
    logic reader_m_valid;
    logic reader_m_ready;
    logic [23:0] reader_m_rgb;
    logic reader_m_sof;
    logic reader_m_eol;
    logic reader_m_eof;
    logic [15:0] reader_m_x;
    logic [15:0] reader_m_y;
    logic [31:0] reader_araddr;
    logic [7:0] reader_arlen;
    logic [2:0] reader_arsize;
    logic [1:0] reader_arburst;
    logic reader_arvalid;
    logic reader_arready;
    logic [127:0] reader_rdata;
    logic [1:0] reader_rresp;
    logic reader_rlast;
    logic reader_rvalid;
    logic reader_rready;

    c1_axi_xrgb_frame_reader u_frame_reader (
        .clk, .rst, .start(reader_start), .cancel(reader_cancel),
        .cfg_base_addr(reader_cfg_base),
        .cfg_width_pixels(reader_cfg_width),
        .cfg_height_lines(reader_cfg_height),
        .cfg_stride_bytes(reader_cfg_stride),
        .busy(reader_busy), .done(reader_done), .error(reader_error),
        .m_valid(reader_m_valid), .m_ready(reader_m_ready),
        .m_rgb(reader_m_rgb), .m_sof(reader_m_sof), .m_eol(reader_m_eol),
        .m_eof(reader_m_eof), .m_x(reader_m_x), .m_y(reader_m_y),
        .m_axi_araddr(reader_araddr), .m_axi_arlen(reader_arlen),
        .m_axi_arsize(reader_arsize), .m_axi_arburst(reader_arburst),
         .m_axi_arvalid(reader_arvalid), .m_axi_arready(reader_arready),
         .m_axi_rdata(reader_rdata), .m_axi_rresp(reader_rresp),
         .m_axi_rlast(reader_rlast), .m_axi_rvalid(reader_rvalid),
         .m_axi_rready(reader_rready), .m_axi_ar_allow(1'b1)
     );

    // ------------------------------------------------------------------
    // Real shared AXI read arbiter.  Write channels are intentionally idle;
    // this staged test is specifically the input read-side seam.
    // ------------------------------------------------------------------
    logic [31:0] m_araddr;
    logic [7:0] m_arlen;
    logic [2:0] m_arsize;
    logic [1:0] m_arburst;
    logic m_arvalid;
    logic m_arready;
    logic [127:0] m_rdata;
    logic [1:0] m_rresp;
    logic m_rlast;
    logic m_rvalid;
    logic m_rready;

    c1_axi2_serial_arbiter_128 u_read_arbiter (
        .clk, .rst,
        .s0_awaddr('0), .s0_awlen('0), .s0_awsize('0), .s0_awburst('0),
        .s0_awvalid(1'b0), .s0_awready(), .s0_wdata('0), .s0_wstrb('0),
        .s0_wlast(1'b0), .s0_wvalid(1'b0), .s0_wready(),
        .s0_bresp(), .s0_bvalid(), .s0_bready(1'b0),
        .s0_araddr(table_araddr), .s0_arlen(table_arlen),
        .s0_arsize(table_arsize), .s0_arburst(table_arburst),
        .s0_arvalid(table_arvalid), .s0_arready(table_arready),
        .s0_rdata(table_rdata), .s0_rresp(table_rresp),
        .s0_rlast(table_rlast), .s0_rvalid(table_rvalid),
        .s0_rready(table_rready),
        .s1_awaddr('0), .s1_awlen('0), .s1_awsize('0), .s1_awburst('0),
        .s1_awvalid(1'b0), .s1_awready(), .s1_wdata('0), .s1_wstrb('0),
        .s1_wlast(1'b0), .s1_wvalid(1'b0), .s1_wready(),
        .s1_bresp(), .s1_bvalid(), .s1_bready(1'b0),
        .s1_araddr(reader_araddr), .s1_arlen(reader_arlen),
        .s1_arsize(reader_arsize), .s1_arburst(reader_arburst),
        .s1_arvalid(reader_arvalid), .s1_arready(reader_arready),
        .s1_rdata(reader_rdata), .s1_rresp(reader_rresp),
        .s1_rlast(reader_rlast), .s1_rvalid(reader_rvalid),
        .s1_rready(reader_rready),
        .m_awaddr(), .m_awlen(), .m_awsize(), .m_awburst(), .m_awvalid(),
        .m_awready(1'b0), .m_wdata(), .m_wstrb(), .m_wlast(), .m_wvalid(),
        .m_wready(1'b0), .m_bresp(2'b00), .m_bvalid(1'b0), .m_bready(),
        .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arvalid, .m_arready,
        .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
    );

    // ------------------------------------------------------------------
    // Shared AXI read BFM and deterministic native slot model.
    // ------------------------------------------------------------------
    integer cycle_count = 0;
    integer shared_ar_count = 0;
    integer shared_r_count = 0;
    integer table_ar_count = 0;
    integer table_r_count = 0;
    integer frame_ar_count = 0;
    integer frame_r_count = 0;
    integer ar_stall_count = 0;
    integer r_stall_count = 0;
    integer r_gap_count = 0;
    integer table_active_slot = 0;
    integer active_kind = -1; // 0=table, 1=frame
    integer active_slot = 0;
    integer active_ar_addr = 0;
    integer active_ar_beats = 0;
    integer active_r_index = 0;
    integer r_delay = 0;
    logic burst_active = 1'b0;
    logic [127:0] rdata_reg = '0;
    logic [1:0] rresp_reg = 2'b00;
    logic rlast_reg = 1'b0;
    logic rvalid_reg = 1'b0;

    integer frame_expected_next_addr = INPUT_BASE;
    integer frame_expected_row = 0;
    integer frame_expected_row_bytes = STRIDE;
    integer frame_expected_slot = 0;

    // Keep these declarations before the diagnostic task. Vivado's xvlog
    // requires module identifiers to be visible at the point of use.
    logic failure_seen = 1'b0;
    integer active_model_slot = 0;
    integer pixel_count = 0;

    assign m_rdata = rdata_reg;
    assign m_rresp = rresp_reg;
    assign m_rlast = rlast_reg;
    assign m_rvalid = rvalid_reg;
    always_comb begin
        // A deterministic periodic pause exercises both arbiter grant hold
        // and ARVALID stability without making the native run unbounded.
        m_arready = !burst_active && !rvalid_reg && ((cycle_count % 23) != 0);
    end

    function automatic [31:0] slot_base(input integer slot);
        slot_base = INPUT_BASE + slot * FRAME_SLOT_BYTES;
    endfunction

    function automatic [127:0] table_entry(input integer slot);
        begin
            // Little-endian AXI beat: base[63:0], stride[31:0],
            // width[15:0], height[15:0].
            table_entry = {16'd480, 16'd640, 32'h0000_0a00,
                           32'd0, slot_base(slot)};
        end
    endfunction

    function automatic [23:0] pixel_value(input integer slot,
                                           input integer x,
                                           input integer y);
        reg [7:0] red;
        reg [7:0] green;
        reg [7:0] blue;
        begin
            red = slot*8'h29 + x*3 + y*17;
            green = slot*8'h53 + x*11 + y*5;
            blue = slot*8'h87 + x*7 + y*13;
            pixel_value = {red, green, blue};
        end
    endfunction

    function automatic [127:0] frame_beat(input integer address,
                                           input integer slot,
                                           input integer beat_index);
        integer lane;
        integer pixel_index;
        integer px;
        integer py;
        reg [23:0] rgb;
        begin
            frame_beat = '0;
            for (lane = 0; lane < 4; lane = lane + 1) begin
                pixel_index = ((address - slot_base(slot)) + beat_index*16 +
                               lane*4) / 4;
                px = pixel_index % FRAME_W;
                py = pixel_index / FRAME_W;
                rgb = pixel_value(slot, px, py);
                frame_beat[lane*32 +: 32] = {8'h00, rgb};
            end
        end
    endfunction

    task automatic fail(input string message);
        begin
            if (!failure_seen) begin
                failure_seen = 1'b1;
                $display("C1_R1_NATIVE_INPUT_DMA_FAIL time=%0t slot=%0d table_ar=%0d frame_ar=%0d r=%0d pixels=%0d: %s",
                         $time, active_model_slot, table_ar_count,
                         frame_ar_count, shared_r_count, pixel_count, message);
                $fatal(1);
                $finish;
            end
        end
    endtask

    logic [127:0] next_rdata;
    integer burst_bytes;
    integer planned_beats;
    integer row_offset;
    integer boundary_beats;

    always @(posedge clk) begin : shared_axi_bfm
        integer idx;
        if (rst) begin
            cycle_count <= 0;
            burst_active <= 1'b0;
            rvalid_reg <= 1'b0;
            rdata_reg <= '0;
            rresp_reg <= 2'b00;
            rlast_reg <= 1'b0;
            active_kind <= -1;
            active_r_index <= 0;
            r_delay <= 0;
            shared_ar_count <= 0;
            shared_r_count <= 0;
            table_ar_count <= 0;
            table_r_count <= 0;
            frame_ar_count <= 0;
            frame_r_count <= 0;
            ar_stall_count <= 0;
            r_stall_count <= 0;
            r_gap_count <= 0;
            frame_expected_next_addr <= INPUT_BASE;
            frame_expected_row <= 0;
            frame_expected_row_bytes <= STRIDE;
        end else begin
            cycle_count <= cycle_count + 1;
            if (m_arvalid && !m_arready)
                ar_stall_count <= ar_stall_count + 1;
            if (m_rvalid && !m_rready)
                r_stall_count <= r_stall_count + 1;

            if (m_arvalid && m_arready) begin
                if (burst_active || rvalid_reg)
                    fail("shared BFM accepted AR while a prior burst was active");
                if ((m_arsize != 3'd4) || (m_arburst != 2'b01) ||
                    (m_araddr[3:0] != 0))
                    fail("shared AR attributes/alignment invalid");
                active_ar_addr <= m_araddr;
                active_r_index <= 0;
                active_kind <= -1;
                active_slot <= 0;
                if ((m_araddr >= TABLE_BASE) &&
                    (m_araddr < TABLE_BASE + 3*16)) begin
                    if (m_arlen != 0 || ((m_araddr - TABLE_BASE) & 15) != 0)
                        fail("frame-table AR is not one aligned beat");
                    idx = (m_araddr - TABLE_BASE) >> 4;
                    if (idx < 0 || idx > 2)
                        fail("frame-table index outside three-slot table");
                    active_kind <= 0;
                    active_slot <= idx;
                    active_ar_beats <= 1;
                    table_ar_count <= table_ar_count + 1;
                end else begin
                    if (m_arlen > 8'd15)
                        fail("input DMA burst exceeds 16 beats");
                    if ((m_araddr < slot_base(0)) ||
                        (m_araddr >= slot_base(2) + FRAME_BYTES))
                        fail("input DMA AR outside native slot arena");
                    if ((m_araddr >= slot_base(0) + FRAME_BYTES) &&
                        (m_araddr < slot_base(1)))
                        fail("input DMA AR in slot gap");
                    if ((m_araddr >= slot_base(1) + FRAME_BYTES) &&
                        (m_araddr < slot_base(2)))
                        fail("input DMA AR in slot gap");
                    if (m_araddr < slot_base(1)) active_slot <= 0;
                    else if (m_araddr < slot_base(2)) active_slot <= 1;
                    else active_slot <= 2;
                    if (m_araddr !== frame_expected_next_addr[31:0])
                        fail("input DMA AR address skipped or reordered");
                    boundary_beats = (4096 - (m_araddr & 4095)) / 16;
                    planned_beats = 16;
                    if ((frame_expected_row_bytes / 16) < planned_beats)
                        planned_beats = frame_expected_row_bytes / 16;
                    if (boundary_beats < planned_beats)
                        planned_beats = boundary_beats;
                    if ((m_arlen + 1) != planned_beats)
                        fail("input DMA ARLEN does not match row/4KiB plan");
                    burst_bytes = planned_beats * 16;
                    if (((m_araddr & 4095) + burst_bytes) > 4096)
                        fail("input DMA burst crosses 4KiB boundary");
                    row_offset = m_araddr -
                                 (slot_base(frame_expected_slot) +
                                  frame_expected_row*STRIDE);
                    if (row_offset + burst_bytes > STRIDE)
                        fail("input DMA burst crosses row boundary");
                    active_kind <= 1;
                    active_ar_beats <= planned_beats;
                    frame_ar_count <= frame_ar_count + 1;
                    if (frame_expected_row_bytes == burst_bytes) begin
                        frame_expected_row <= frame_expected_row + 1;
                        if (frame_expected_row + 1 < FRAME_H) begin
                            frame_expected_next_addr <=
                                slot_base(frame_expected_slot) +
                                (frame_expected_row + 1)*STRIDE;
                            frame_expected_row_bytes <= STRIDE;
                        end else begin
                            frame_expected_row_bytes <= 0;
                        end
                    end else begin
                        frame_expected_next_addr <=
                            frame_expected_next_addr + burst_bytes;
                        frame_expected_row_bytes <=
                            frame_expected_row_bytes - burst_bytes;
                    end
                end
                burst_active <= 1'b1;
                r_delay <= 1 + (cycle_count % 3);
                shared_ar_count <= shared_ar_count + 1;
            end

            if (m_rvalid && m_rready) begin
                if (!burst_active)
                    fail("shared R handshake without active burst");
                if (m_rlast !== (active_r_index == active_ar_beats-1))
                    fail("shared RLAST disagrees with ARLEN");
                shared_r_count <= shared_r_count + 1;
                if (active_kind == 0)
                    table_r_count <= table_r_count + 1;
                else if (active_kind == 1)
                    frame_r_count <= frame_r_count + 1;
                if (m_rlast || (active_r_index == active_ar_beats-1)) begin
                    burst_active <= 1'b0;
                    rvalid_reg <= 1'b0;
                    rlast_reg <= 1'b0;
                end else begin
                    active_r_index <= active_r_index + 1;
                    rvalid_reg <= 1'b0;
                    rlast_reg <= 1'b0;
                    r_delay <= 0; // at least one zero-gap beat per burst
                end
            end else if (!rvalid_reg && burst_active) begin
                if (r_delay > 0) begin
                    r_delay <= r_delay - 1;
                    r_gap_count <= r_gap_count + 1;
                end else begin
                    if (active_kind == 0)
                        rdata_reg <= table_entry(active_slot);
                    else
                        rdata_reg <= frame_beat(active_ar_addr,
                                                 active_slot, active_r_index);
                    rresp_reg <= 2'b00;
                    rlast_reg <= (active_r_index == active_ar_beats-1);
                    rvalid_reg <= 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Raster scoreboard.  The sink is deliberately stalled periodically;
    // the reader must hold RGB/coordinates/markers until handshake.
    // ------------------------------------------------------------------
    integer slot_pixel_count [0:2];
    integer slot_sof_count [0:2];
    integer slot_eol_count [0:2];
    integer slot_eof_count [0:2];
    integer expected_x = 0;
    integer expected_y = 0;
    integer output_stall_count = 0;
    logic held_output = 1'b0;
    logic [23:0] held_rgb = '0;
    logic [15:0] held_x = '0;
    logic [15:0] held_y = '0;
    logic held_sof = 1'b0, held_eol = 1'b0, held_eof = 1'b0;

    always_comb begin
        reader_m_ready = ((cycle_count % 19) != 0);
    end

    always @(posedge clk) begin
        integer expected_rgb;
        if (rst) begin
            pixel_count <= 0;
            expected_x <= 0;
            expected_y <= 0;
            output_stall_count <= 0;
            held_output <= 1'b0;
            slot_pixel_count[0] <= 0;
            slot_pixel_count[1] <= 0;
            slot_pixel_count[2] <= 0;
            slot_sof_count[0] <= 0;
            slot_sof_count[1] <= 0;
            slot_sof_count[2] <= 0;
            slot_eol_count[0] <= 0;
            slot_eol_count[1] <= 0;
            slot_eol_count[2] <= 0;
            slot_eof_count[0] <= 0;
            slot_eof_count[1] <= 0;
            slot_eof_count[2] <= 0;
        end else begin
            if (held_output && !reader_m_ready) begin
                if (!reader_m_valid || reader_m_rgb !== held_rgb ||
                    reader_m_x !== held_x || reader_m_y !== held_y ||
                    reader_m_sof !== held_sof || reader_m_eol !== held_eol ||
                    reader_m_eof !== held_eof)
                    fail("RGB payload changed while sink was stalled");
            end
            if (reader_m_valid && !reader_m_ready)
                output_stall_count <= output_stall_count + 1;
            if (reader_m_valid && reader_m_ready) begin
                expected_rgb = pixel_value(active_model_slot, expected_x,
                                           expected_y);
                if (reader_m_rgb !== expected_rgb[23:0])
                    fail("input DMA RGB unpack/pixel order mismatch");
                if (reader_m_x !== expected_x[15:0] ||
                    reader_m_y !== expected_y[15:0])
                    fail("input DMA raster coordinates mismatch");
                if (reader_m_sof !== ((expected_x == 0) && (expected_y == 0)))
                    fail("input DMA SOF mismatch");
                if (reader_m_eol !== (expected_x == FRAME_W-1))
                    fail("input DMA EOL mismatch");
                if (reader_m_eof !== ((expected_x == FRAME_W-1) &&
                                      (expected_y == FRAME_H-1)))
                    fail("input DMA EOF mismatch");
                pixel_count <= pixel_count + 1;
                slot_pixel_count[active_model_slot] <=
                    slot_pixel_count[active_model_slot] + 1;
                if (reader_m_sof)
                    slot_sof_count[active_model_slot] <=
                        slot_sof_count[active_model_slot] + 1;
                if (reader_m_eol)
                    slot_eol_count[active_model_slot] <=
                        slot_eol_count[active_model_slot] + 1;
                if (reader_m_eof)
                    slot_eof_count[active_model_slot] <=
                        slot_eof_count[active_model_slot] + 1;
                if (expected_x == FRAME_W-1) begin
                    expected_x <= 0;
                    expected_y <= expected_y + 1;
                end else begin
                    expected_x <= expected_x + 1;
                end
            end
            held_output <= reader_m_valid && !reader_m_ready;
            held_rgb <= reader_m_rgb;
            held_x <= reader_m_x;
            held_y <= reader_m_y;
            held_sof <= reader_m_sof;
            held_eol <= reader_m_eol;
            held_eof <= reader_m_eof;
        end
    end

    // Table response monitor.  Only one table lookup is outstanding, so the
    // software-owned request slot is the response tag for this staged seam.
    integer table_seen_count = 0;
    logic table_seen [0:2];
    logic [31:0] desc_base [0:2];
    logic [31:0] desc_stride [0:2];
    logic [15:0] desc_width [0:2];
    logic [15:0] desc_height [0:2];
    always @(posedge clk) begin
        if (!rst && table_response_valid && table_response_ready) begin
            if (table_response_error || table_response_base[63:32] != 0)
                fail("frame-table response reported an error/high address");
            if (table_response_base[31:0] !== slot_base(table_active_slot) ||
                table_response_stride !== STRIDE ||
                table_response_width !== FRAME_W ||
                table_response_height !== FRAME_H)
                fail("frame-table descriptor fields mismatch");
            desc_base[table_active_slot] <= table_response_base[31:0];
            desc_stride[table_active_slot] <= table_response_stride;
            desc_width[table_active_slot] <= table_response_width;
            desc_height[table_active_slot] <= table_response_height;
            table_seen[table_active_slot] <= 1'b1;
            table_seen_count <= table_seen_count + 1;
        end
        if (!rst && reader_error)
            fail("input frame reader asserted error");
    end

    task automatic request_table(input integer slot);
        integer guard;
        begin
            table_active_slot = slot;
            @(negedge clk);
            table_request_index <= slot[1:0];
            table_request_base <= TABLE_BASE;
            table_request_valid <= 1'b1;
            guard = 0;
            while (!table_request_ready) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 10000)
                    fail("frame-table request-ready timeout");
            end
            @(negedge clk);
            table_request_valid <= 1'b0;
            while (!table_seen[slot]) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 10000)
                    fail("frame-table response timeout");
            end
        end
    endtask

    task automatic launch_reader(input integer slot);
        integer guard;
        begin
            guard = 0;
            while (reader_busy) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 10000)
                    fail("input reader remained busy before next slot");
            end
            active_model_slot = slot;
            expected_x = 0;
            expected_y = 0;
            frame_expected_slot = slot;
            frame_expected_next_addr = slot_base(slot);
            frame_expected_row = 0;
            frame_expected_row_bytes = STRIDE;
            @(negedge clk);
            reader_cfg_base <= desc_base[slot];
            reader_cfg_stride <= desc_stride[slot];
            reader_cfg_width <= desc_width[slot];
            reader_cfg_height <= desc_height[slot];
            reader_start <= 1'b1;
            @(negedge clk);
            reader_start <= 1'b0;
        end
    endtask

    task automatic wait_reader_done(input integer slot);
        integer guard;
        begin
            guard = 0;
            while (!reader_done) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20000000)
                    fail("native input reader completion timeout");
            end
            #0.1;
            if (reader_busy || reader_error)
                fail("input reader ended busy/error");
            if (slot_pixel_count[slot] != FRAME_W*FRAME_H ||
                slot_sof_count[slot] != 1 ||
                slot_eol_count[slot] != FRAME_H ||
                slot_eof_count[slot] != 1)
                fail("slot raster/marker count mismatch");
            @(posedge clk);
        end
    endtask

    initial begin : main_test
        integer slot;
        for (slot = 0; slot < 3; slot = slot + 1)
            table_seen[slot] = 1'b0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst <= 1'b0;

        // First table ownership is a prerequisite for the first DMA start.
        request_table(0);
        launch_reader(0);
        // These requests intentionally overlap the preceding raster read;
        // the real arbiter must queue them behind a committed R burst.
        request_table(1);
        wait_reader_done(0);
        launch_reader(1);
        request_table(2);
        wait_reader_done(1);
        launch_reader(2);
        wait_reader_done(2);

        if (table_seen_count != 3 || table_ar_count != 3 || table_r_count != 3)
            fail("three frame-table ownership lookups did not complete");
        if (frame_ar_count != 3*FRAME_BURSTS ||
            frame_r_count != 3*FRAME_BEATS)
            fail("native input-DMA AR/R count mismatch");
        if (shared_ar_count != table_ar_count + frame_ar_count ||
            shared_r_count != table_r_count + frame_r_count)
            fail("shared AXI fabric counters do not balance");
        // Both real readers keep RREADY asserted while an accepted burst
        // drains; this boundary therefore measures response latency
        // (`r_gap_count`) rather than inventing downstream RREADY stalls.
        // Raster backpressure is checked independently at the reader sink.
        if (ar_stall_count == 0 || r_gap_count == 0 ||
            output_stall_count == 0)
            fail("shared AXI/output backpressure coverage was incomplete");
        if (slot_base(2) + FRAME_BYTES >= 32'h0200_0000)
            fail("native input slots overlap tensor arena");

        $display("C1_R1_NATIVE_INPUT_DMA_PASS frames=3 frame_pixels=%0d table_ar=%0d table_r=%0d frame_ar=%0d frame_r=%0d shared_ar=%0d shared_r=%0d ar_stalls=%0d r_stalls=%0d r_gaps=%0d output_stalls=%0d slots=%08x/%08x/%08x",
                 pixel_count, table_ar_count, table_r_count, frame_ar_count,
                 frame_r_count, shared_ar_count, shared_r_count,
                 ar_stall_count, r_stall_count, r_gap_count,
                 output_stall_count, slot_base(0), slot_base(1), slot_base(2));
        $finish;
    end

    initial begin
        // Keep the delay below the signed 32-bit unsized-delay overflow limit.
        #100_000_000;
        fail("native input-DMA global timeout");
    end
endmodule
