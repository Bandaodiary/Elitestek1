`timescale 1ns/1ps
// Boundary-level test: inject raster coordinates and synchronous line-store
// responses. The real AXI/line-store path is covered by the SoC DDR BFM test.
module tb_c1_display_geometry #(parameter integer STORE_WIDTH = 640,
    parameter integer SEPARATE = 0);
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg [10:0] x = 0;
    reg [9:0] y = 0;
    reg [7:0] mode = 0;
    reg [15:0] w = 8, h = 8;
    reg [15:0] original_w = 8, original_h = 8;
    reg [15:0] cfg_ow = 12, cfg_oh = 4;
    reg start = 0;
    reg [15:0] cfg_w = 8, cfg_h = 8;
    reg ov = 0, sv = 0;
    reg [23:0] expected_previous = 0;
    reg [23:0] expected_now;
    integer oc, sc, checks = 0;
    integer m, xx, yy, size_case;
    c1_r1_display_subsystem #(.FRAME_WIDTH(STORE_WIDTH),
        .SEPARATE_ORIGINAL_GEOMETRY(SEPARATE)) dut (
        .original_width_pixels(cfg_ow), .original_height_lines(cfg_oh),
        .core_clk(clk), .pixel_clk(clk), .core_rst(rst), .pixel_rst(rst),
        .start_valid(start), .abort(1'b0), .flush_request(1'b0),
        .width_pixels(cfg_w), .height_lines(cfg_h),
        .original_base(32'd0), .styled_base(32'd0),
        .original_stride(32'd2560), .styled_stride(32'd2560),
        .feed_active(1'b0), .hold_requests(1'b0),
        .display_mode(8'd0), .osd_status_word(32'd0), .osd_alarm(1'b0),
        .original_axi_arready(1'b0), .original_axi_rdata(128'd0),
        .original_axi_rresp(2'd0), .original_axi_rlast(1'b0),
        .original_axi_rvalid(1'b0),
        .styled_axi_arready(1'b0), .styled_axi_rdata(128'd0),
        .styled_axi_rresp(2'd0), .styled_axi_rlast(1'b0),
        .styled_axi_rvalid(1'b0)
    );
    always @(posedge clk) begin
        ov <= dut.u_prefetch.original_request;
        sv <= dut.u_prefetch.styled_request;
    end
    task sample(input integer px, input integer py);
        reg want_o, want_s;
        integer sx;
        begin
            @(negedge clk); x = px; y = py;
            #1;
            sx = (m == 2) ? px : px - 320;
            want_o = (py >= 120 && py < 120+original_h && py < 600) &&
                ((m == 1 && sx >= 0 && sx < original_w && sx < 640) ||
                 (m != 1 && px < original_w && px < 640));
            sx = (m == 2) ? px - 640 : px - 320;
            want_s = (py >= 120 && py < 120+h && py < 600) &&
                (((m == 0 || m == 2) && sx >= 0 && sx < w && sx < 640) ||
                 ((m == 1 || m == 3) && px < w && px < 640));
            if (dut.u_prefetch.original_request !== want_o ||
                dut.u_prefetch.styled_request !== want_s)
                $fatal(1,"request mismatch mode=%0d x=%0d y=%0d",m,px,py);
            if (want_o && (dut.u_prefetch.original_request_x !== (m == 1 ? px-320 : px) ||
                           dut.u_prefetch.original_request_y !== py-120))
                $fatal(1,"original request coordinates mismatch mode=%0d x=%0d y=%0d",m,px,py);
            if (want_s && (dut.u_prefetch.styled_request_x !== (m == 0 ? px-320 : (m == 2 ? px-640 : px)) ||
                           dut.u_prefetch.styled_request_y !== py-120))
                $fatal(1,"styled request coordinates mismatch mode=%0d x=%0d y=%0d",m,px,py);
            oc = oc + want_o; sc = sc + want_s;
            expected_now = 0;
            if (dut.compositor_original_request && want_o)
                expected_now = 24'h123456;
            if (dut.compositor_styled_request && want_s)
                expected_now = 24'habcdef;
            @(posedge clk); #1;
            if (dut.compositor_rgb !== expected_previous)
                $fatal(1,"response alignment/padding mode=%0d x=%0d y=%0d got=%h expected=%h",
                    m,px,py,dut.compositor_rgb,expected_previous);
            expected_previous = expected_now;
            checks = checks + 1;
        end
    endtask
    initial begin
        repeat (4) @(negedge clk);
        rst = 0;
        force dut.timing_x = x;
        force dut.timing_y = y;
        force dut.timing_de = 1'b1;
        force dut.mode_frame_q = mode;
        force dut.width_sync2_pixel = w;
        force dut.height_sync2_pixel = h;
        force dut.original_width_sync2_pixel = original_w;
        force dut.original_height_sync2_pixel = original_h;
        force dut.request_enable_frame_q = 1'b1;
        force dut.hold_sync2_pixel = 1'b0;
        force dut.original_response_valid = ov;
        force dut.styled_response_valid = sv;
        // Stale nonzero memory outputs MUST NOT leak into black padding.
        force dut.original_rgb = 24'h123456;
        force dut.styled_rgb = 24'habcdef;
        for (size_case=0; size_case<(SEPARATE ? 3 : (STORE_WIDTH >= 640 ? 2 : 1)); size_case=size_case+1) begin
            w = (SEPARATE || size_case == 0) ? 8 : 640;
            h = (SEPARATE || size_case == 0) ? 8 : 480;
            original_w = SEPARATE ? (size_case == 1 ? 4 : 12) : w;
            original_h = SEPARATE ? (size_case == 0 ? 4 : (size_case == 1 ? 12 : 1)) : h;
            for (m=0; m<4; m=m+1) begin
                mode = m; oc = 0; sc = 0;
                // All pixels over the small image and its lower boundary;
                // native geometry checks first/last active and padding rows.
                for (yy=119; yy<=133; yy=yy+1)
                    for (xx=0; xx<1280; xx=xx+1) sample(xx,yy);
                if ((SEPARATE || size_case == 0) && (oc != original_w*original_h || sc != w*h))
                    $fatal(1,"small image request count mismatch original=%0d styled=%0d",oc,sc);
                for (yy=599; yy<=600; yy=yy+1)
                    for (xx=0; xx<1280; xx=xx+1) sample(xx,yy);
            end
        end
        // Only accepted START may replace the bundled geometry.
        release dut.width_sync2_pixel;
        release dut.height_sync2_pixel;
        release dut.original_width_sync2_pixel;
        release dut.original_height_sync2_pixel;
        @(negedge clk); start = 1;
        #1;
        if (!dut.start_ready) $fatal(1,"prefetch not ready for geometry snapshot");
        @(negedge clk); start = 0; cfg_w = 3; cfg_h = 5; cfg_ow = 1; cfg_oh = 2;
        repeat (5) @(negedge clk);
        if (dut.width_sync2_pixel != 8 || dut.height_sync2_pixel != 8)
            $fatal(1,"unaccepted config changed active geometry");
        if (dut.original_width_sync2_pixel != (SEPARATE ? 12 : 8) ||
            dut.original_height_sync2_pixel != (SEPARATE ? 4 : 8))
            $fatal(1,"unaccepted original config changed active geometry");
        $display("C1_DISPLAY_LAYOUT_GEOMETRY_PASS separate=%0d fixtures=%0d modes=4",SEPARATE,SEPARATE ? 3 : (STORE_WIDTH >= 640 ? 2 : 1));
        $display("C1_DISPLAY_GEOMETRY_PASS checks=%0d modes=4 store_width=%0d snapshot=PASS",checks,STORE_WIDTH);
        $finish;
    end
    initial begin #10000000; $fatal(1,"timeout"); end
endmodule
