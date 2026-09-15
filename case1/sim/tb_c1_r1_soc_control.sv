module tb_c1_r1_soc_control #(
    parameter integer DIFFERENT_RESOLVED_GEOMETRY = 0,
    parameter bit PREVIEW_DISPLAY=0,
    parameter integer SWAP_ABORT_COLLISION=0,
    parameter bit SWAP_ERROR_COLLISION=0,
    // Capture startup safety regression: 1=display original, 2=styled,
    // 3=styled+16. All must reject before either begin/start pulse.
    parameter integer CAPTURE_DISPLAY_ALIAS=0,
    parameter bit CAPTURE_GUARD_CANCEL=0,
    // Real second NN completion versus third capture: during comparison,
    // exactly at commit, pending pair already present, or legal commit retry.
    parameter integer CAPTURE_GUARD_PUBLISH=0,
    // 1 READY alias, 2 READY disjoint, 3 cancel/drain/reuse, 4 processing alias;
    // 5 recycled slot remap, 6 recycled slot aliases another, 7 same-slot reuse.
    parameter integer INPUT_REGION_CASE=0,
    parameter integer WRITE_REGION_CASE=0,
    parameter integer DRAIN_CASE=0,
    parameter integer CAPTURE_FAULT_DRAIN=0
);
    localparam integer ORIGINAL_WIDTH = DIFFERENT_RESOLVED_GEOMETRY ? 960 : 640;
    localparam integer ORIGINAL_HEIGHT = DIFFERENT_RESOLVED_GEOMETRY ? 720 : 480;
    localparam integer ORIGINAL_STRIDE = DIFFERENT_RESOLVED_GEOMETRY ? 4096 : 2560;
    localparam logic [31:0] DISPLAY_BASE=PREVIEW_DISPLAY ? 32'h00300000 : 32'h00100000;
    localparam integer DISPLAY_STRIDE=PREVIEW_DISPLAY ? 4096 : ORIGINAL_STRIDE;
    localparam integer DISPLAY_W=PREVIEW_DISPLAY ? 640 : ORIGINAL_WIDTH;
    localparam integer DISPLAY_H=PREVIEW_DISPLAY ? 480 : ORIGINAL_HEIGHT;
    logic [31:0] boardless_resolved_preview_base=32'h00300000;
    logic [31:0] boardless_resolved_preview_stride=32'd4096;
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic system_enable, continuous_mode, drop_oldest_mode;
    logic start_pulse, abort_pulse;
    logic fabric_write_protocol_error=0,fabric_write_busy=0;
    logic [15:0] frame_width, frame_height;
    logic [15:0] input_frame_width, input_frame_height;
    logic [15:0] boardless_input_width, boardless_input_height;
    logic signed [31:0] resize_x_step_q16=0, boardless_x_step_q16;
    logic signed [31:0] resize_y_step_q16=0, boardless_y_step_q16;
    logic signed [31:0] resize_x_phase0_q16=0, boardless_x_phase0_q16;
    logic signed [31:0] resize_y_phase0_q16=0, boardless_y_phase0_q16;
    logic [3:0] input_pixel_format, output_pixel_format;
    logic [63:0] input_table_base, output_table_base;
    logic [63:0] descriptor_base, weight_base;
    logic [31:0] tensor_base_addr;
    logic [15:0] descriptor_count;
    logic status_busy, done_event, error_event;
    logic [7:0] error_code;
    logic [31:0] error_address;
    logic capture_drop_event, display_swap_event;
    logic display_prefetch_new_done_event;
    logic [2:0] input_ready_count;
    logic [1:0] output_ready_count;
    logic [31:0] display_frame_id;
    logic display_feed_active, display_hold_requests;
    logic parameter_start_valid, parameter_start_ready;
    logic [31:0] parameter_base_addr;
    logic parameter_abort_request, parameter_abort_pending;
    logic parameter_busy, parameter_done;
    logic parameter_error, parameter_aborted;
    logic [3:0] parameter_error_code;
    logic [31:0] parameter_error_address;
    logic parameter_active_valid;
    logic [31:0] parameter_generation;
    logic [31:0] active_parameter_generation;
    logic capture_frame_waiting, capture_begin_ready;
    logic capture_begin_frame, capture_drop_frame, capture_abort_frame;
    logic capture_clear_error, capture_discard_idle, capture_cleanup_busy;
    logic capture_ingress_done;
    logic capture_frame_dropped, capture_frame_aborted, capture_error;
    logic [7:0] capture_error_code;
    logic capture_table_request_valid, capture_table_request_ready;
    logic [63:0] capture_table_request_base;
    logic [1:0] capture_table_request_index;
    logic capture_table_response_valid, capture_table_response_ready;
    logic capture_table_response_error;
    logic [63:0] capture_table_response_base;
    logic [31:0] capture_table_response_stride;
    logic [15:0] capture_table_response_width;
    logic [15:0] capture_table_response_height;
    logic capture_table_abort_request, capture_table_abort_pending;
    logic capture_writer_start, capture_writer_cancel;
    logic [31:0] capture_writer_base, capture_writer_stride;
    logic [15:0] capture_writer_width, capture_writer_height;
    logic capture_writer_busy, capture_writer_done, capture_writer_error;
    logic boardless_start_valid, boardless_start_ready, boardless_abort;
    logic [1:0] boardless_input_index, boardless_output_index;
    logic [63:0] boardless_input_table_base;
    logic [63:0] boardless_output_table_base;
    logic [15:0] boardless_frame_width, boardless_frame_height;
    logic [31:0] boardless_descriptor_base;
    logic [15:0] boardless_descriptor_count;
    logic [31:0] boardless_cycle_budget;
    logic [31:0] boardless_tensor_base_addr;
    logic boardless_busy, boardless_done, boardless_error;
    logic boardless_aborted;
    logic [7:0] boardless_error_code;
    logic [31:0] boardless_error_address;
    logic [31:0] boardless_resolved_input_base;
    logic [31:0] boardless_resolved_input_stride;
    logic [15:0] boardless_resolved_input_width;
    logic [15:0] boardless_resolved_input_height;
    logic [31:0] boardless_resolved_output_base;
    logic [31:0] boardless_resolved_output_stride;
    logic [15:0] boardless_resolved_output_width;
    logic [15:0] boardless_resolved_output_height;
    logic display_frame_start_event;
    logic display_prefetch_start_valid, display_prefetch_start_ready;
    logic display_prefetch_abort, display_flush_request, display_flush_busy;
    logic [31:0] display_original_base, display_original_stride;
    logic [31:0] display_styled_base, display_styled_stride;
    logic [15:0] display_width, display_height;
    logic [15:0] display_original_width, display_original_height;
    logic display_prefetch_busy, display_prefetch_done;
    logic display_prefetch_aborted, display_prefetch_error;
    logic display_prefetch_primed;

    integer capture_requests = 0;
    integer captures=0;
    integer static_test_index=0;
    logic [31:0] static_test_base=0;
    logic [31:0] parameter_expected_base=0;
    always @(posedge clk) begin
        if(rst) captures<=0;
        else if(capture_writer_start) captures<=captures+1;
    end
    wire [96:0] boardless_expected_input;
    logic fabric_read_quiescent=1,fabric_write_quiescent=1;
    logic boardless_region_request=0,boardless_region_cancel=0;
    wire boardless_region_response;
    wire [7:0] boardless_region_error_code;
    wire [31:0] boardless_region_error_address;
    integer guard_requests=0;
    always @(posedge clk) if(!rst && dut.capture_guard_req && dut.capture_guard_ready)
        guard_requests<=guard_requests+1;
    integer nn_launches = 0;
    integer prefetch_launches = 0;
    integer swaps = 0;
    integer repeats = 0;
    integer errors = 0;

`ifdef C1_REPLICATE_ABORT_CONTROL
    localparam integer REPLICATE_ABORT_CONTROL_CFG = 1;
`else
    localparam integer REPLICATE_ABORT_CONTROL_CFG = 0;
`endif
`ifdef C1_REGISTER_FATAL_TICKET
    localparam integer REGISTER_FATAL_TICKET_CFG = 1;
`else
    localparam integer REGISTER_FATAL_TICKET_CFG = 0;
`endif

    c1_r1_soc_control #(
        .FENCE_FABRIC_DRAIN(DRAIN_CASE!=0 || CAPTURE_FAULT_DRAIN!=0),
        .CHECK_WRITE_REGIONS(WRITE_REGION_CASE!=0),.RESERVE_PREVIEW(WRITE_REGION_CASE!=0||PREVIEW_DISPLAY),
        .DISPLAY_RESIZED_PREVIEW(PREVIEW_DISPLAY),
        .ENABLE_FABRIC_FAULT(1),
        .CONFIGURABLE_RESIZE(DIFFERENT_RESOLVED_GEOMETRY),
        .SEPARATE_INPUT_GEOMETRY(DIFFERENT_RESOLVED_GEOMETRY),
        .REQUIRED_INPUT_WIDTH(ORIGINAL_WIDTH), .REQUIRED_INPUT_HEIGHT(ORIGINAL_HEIGHT),
        .REPLICATE_ABORT_CONTROL(REPLICATE_ABORT_CONTROL_CFG),
        .REGISTER_FATAL_TICKET(REGISTER_FATAL_TICKET_CFG)
    ) dut (.*);

    // Real telemetry consumer, wired to the same lifecycle signals as the
    // portable SoC. Bus traffic is idle here; data-plane QoS has separate TBs.
    wire [15:0] qos_completed_frames,qos_protocol_errors;
    wire qos_frame_active;
    c1_axi_shared_qos_monitor #(.CLIENTS(1),.COUNTER_W(16)) u_lifecycle_qos (
        .clk(clk),.rst(rst),.clear_stats(1'b0),
        .awvalid(1'b0),.awready(1'b0),.wvalid(1'b0),.wready(1'b0),
        .bvalid(1'b0),.bready(1'b0),.arvalid(1'b0),.arready(1'b0),
        .rvalid(1'b0),.rready(1'b0),.read_busy(1'b0),.read_quiescent(1'b1),
        .write_busy(1'b0),.write_quiescent(1'b1),.read_owner(1'b0),.write_owner(1'b0),
        .frame_start(boardless_start_valid&&boardless_start_ready),
        .frame_done(display_prefetch_new_done_event),.frame_abort(boardless_abort),
        .frame_deadline_cycles(16'd0),.display_underflow_event(1'b0),
        .frame_count(qos_completed_frames),.frame_active(qos_frame_active),
        .protocol_error_count(qos_protocol_errors)
    );

    task automatic tick(input integer count);
        repeat (count) @(posedge clk);
    endtask

    task automatic reserve_ready_input(input logic [31:0] base, input logic [1:0] slot);
        @(negedge clk);capture_table_response_base={32'd0,base};capture_frame_waiting=1;
        wait(capture_table_request_valid);
        @(negedge clk);capture_table_response_valid=1;
        @(posedge clk);while(!capture_table_response_ready) @(posedge clk);
        @(negedge clk);capture_table_response_valid=0;
        wait(capture_begin_frame);
        if(!capture_writer_start || capture_writer_base!==base || dut.manager_cap_index!==slot)
            $fatal(1,"input reservation fixture allocation mismatch");
        @(negedge clk);capture_frame_waiting=0;capture_writer_busy=1;
        repeat(2) @(negedge clk);
        if(!dut.input_region_valid_q[slot] || dut.input_region_base_q[slot]!==base)
            $fatal(1,"accepted capture did not snapshot physical region");
        capture_ingress_done=1;
        @(negedge clk);capture_ingress_done=0;capture_writer_busy=0;capture_writer_done=1;
        @(negedge clk);capture_writer_done=0;
        repeat(3) @(negedge clk);
    endtask

    task automatic pulse_start;
        begin
            @(negedge clk);
            input_frame_width = ORIGINAL_WIDTH;
            input_frame_height = ORIGINAL_HEIGHT;
            resize_x_step_q16 = -32'sh18000;
            resize_y_step_q16 = 32'sh20000;
            resize_x_phase0_q16 = 32'sh7fffffff;
            resize_y_phase0_q16 = -32'sh8000;
            start_pulse = 1'b1;
            @(negedge clk);
            start_pulse = 1'b0;
            input_frame_width = 0;
            input_frame_height = 0;
            resize_x_step_q16 = 0; resize_y_step_q16 = -1;
            resize_x_phase0_q16 = 0; resize_y_phase0_q16 = 0;
        end
    endtask

    task automatic check_display_pair;
        if (display_original_base !== DISPLAY_BASE ||
            display_original_stride !== DISPLAY_STRIDE ||
            display_original_width !== DISPLAY_W ||
            display_original_height !== DISPLAY_H ||
            display_styled_base !== 32'h0020_0000 ||
            display_styled_stride !== 32'd2560 ||
            display_width !== 16'd640 || display_height !== 16'd480)
            $fatal(1,"display pair geometry/address snapshot mismatch");
    endtask

    task automatic check_second_pair_ticket;
        if(!display_prefetch_start_valid ||
           display_original_base!==(PREVIEW_DISPLAY ? 32'h00500000 : 32'h01000000) ||
           display_original_stride!==(PREVIEW_DISPLAY ? 8192 : ORIGINAL_STRIDE) ||
           display_original_width!==DISPLAY_W || display_original_height!==DISPLAY_H ||
           display_styled_base!==32'h00600000 || display_styled_stride!==4096 ||
           display_width!==640 || display_height!==480)
            $fatal(1,"second display ticket mixed frame metadata");
    endtask

    task automatic check_second_pair_current;
        if(!dut.current_pair_valid_q || !dut.u_frame_manager.display_active ||
           dut.u_frame_manager.display_output_index!==1 || display_frame_id!==1 ||
           dut.current_original_base_q!==(PREVIEW_DISPLAY ? 32'h00500000 : 32'h01000000) ||
           dut.current_original_stride_q!==(PREVIEW_DISPLAY ? 8192 : ORIGINAL_STRIDE) ||
           dut.current_original_width_q!==DISPLAY_W || dut.current_original_height_q!==DISPLAY_H ||
           dut.current_styled_base_q!==32'h00600000 || dut.current_styled_stride_q!==4096 ||
           dut.current_width_q!==640 || dut.current_height_q!==480)
            $fatal(1,"second committed slot retained old/mixed metadata after cancel");
    endtask

    always @(posedge clk) begin
        if (capture_table_request_valid && capture_table_request_ready)
            capture_requests <= capture_requests + 1;
        if (boardless_start_valid && boardless_start_ready)
            nn_launches <= nn_launches + 1;
        if(boardless_start_valid && boardless_start_ready && !boardless_expected_input[96])
            $fatal(1,"NN launch lacks a captured input identity");
        if (display_prefetch_start_valid &&
            display_prefetch_start_ready) begin
            prefetch_launches <= prefetch_launches + 1;
            if (display_feed_active)
                repeats <= repeats + 1;
        end
        if (display_swap_event)
            swaps <= swaps + 1;
        if (error_event)
            errors <= errors + 1;
    end

    initial begin
        system_enable = 1'b0;
        continuous_mode = 1'b1;
        drop_oldest_mode = 1'b1;
        start_pulse = 1'b0;
        abort_pulse = 1'b0;
        frame_width = 16'd640;
        frame_height = 16'd480;
        input_frame_width = 0; input_frame_height = 0;
        input_pixel_format = 4'd2;
        output_pixel_format = 4'd2;
        input_table_base = 64'h0000_0000_0001_0000;
        output_table_base = 64'h0000_0000_0002_0000;
        descriptor_base = 64'h0000_0000_0003_0000;
        descriptor_count = 16'd22;
        weight_base = 64'h0000_0000_0004_0000;
        tensor_base_addr = 32'h0200_0000;
        parameter_start_ready = 1'b1;
        parameter_busy = 1'b0;
        parameter_abort_pending = 1'b0;
        parameter_done = 1'b0;
        parameter_error = 1'b0;
        parameter_aborted = 1'b0;
        parameter_error_code = 4'd0;
        parameter_error_address = 32'd0;
        parameter_active_valid = 1'b0;
        parameter_generation = 32'd0;
        capture_frame_waiting = 1'b0;
        capture_begin_ready = 1'b1;
        capture_ingress_done = 1'b0;
        capture_frame_dropped = 1'b0;
        capture_frame_aborted = 1'b0;
        capture_error = 1'b0;
        capture_error_code = 8'd0;
        capture_cleanup_busy = 1'b0;
        capture_table_request_ready = 1'b1;
        capture_table_abort_pending = 1'b0;
        capture_table_response_valid = 1'b0;
        capture_table_response_error = 1'b0;
        capture_table_response_base = 64'h0000_0000_0010_0000;
        capture_table_response_stride = ORIGINAL_STRIDE;
        capture_table_response_width = ORIGINAL_WIDTH;
        capture_table_response_height = ORIGINAL_HEIGHT;
        capture_writer_busy = 1'b0;
        capture_writer_done = 1'b0;
        capture_writer_error = 1'b0;
        boardless_start_ready = (INPUT_REGION_CASE==0 || INPUT_REGION_CASE==4);
        boardless_busy = 1'b0;
        boardless_done = 1'b0;
        boardless_error = 1'b0;
        boardless_aborted = 1'b0;
        boardless_error_code = 8'd0;
        boardless_error_address = 32'd0;
        boardless_resolved_input_base = 32'h0010_0000;
        boardless_resolved_input_stride = ORIGINAL_STRIDE;
        boardless_resolved_input_width = ORIGINAL_WIDTH;
        boardless_resolved_input_height = ORIGINAL_HEIGHT;
        boardless_resolved_output_base = 32'h0020_0000;
        boardless_resolved_output_stride = 32'd2560;
        boardless_resolved_output_width = 16'd640;
        boardless_resolved_output_height = 16'd480;
        display_frame_start_event = 1'b0;
        display_prefetch_start_ready = 1'b0;
        display_prefetch_busy = 1'b0;
        display_prefetch_done = 1'b0;
        display_prefetch_aborted = 1'b0;
        display_prefetch_error = 1'b0;
        display_prefetch_primed = 1'b0;
        display_flush_busy = 1'b0;

        if(WRITE_REGION_CASE>=15) begin
            static_test_index=(WRITE_REGION_CASE-15)%4;
            if(WRITE_REGION_CASE<=26) static_test_base=32'h0c000000;
            else if(WRITE_REGION_CASE<=30) static_test_base=32'h02000000;
            else if(WRITE_REGION_CASE<=34)
                static_test_base=static_test_index==1 ? 32'hffffffc0 : 32'hfffffff0;
            else case(static_test_index)
                0: static_test_base=32'hffffbe00;
                1: static_test_base=32'hfffffa80;
                2: static_test_base=32'hffffffd0;
                3: static_test_base=32'hffffffe0;
            endcase
            if(WRITE_REGION_CASE==40) static_test_base=32'h02000000;
            case(static_test_index)
                0: weight_base={32'd0,static_test_base};
                1: descriptor_base={32'd0,static_test_base};
                2: input_table_base={32'd0,static_test_base};
                3: output_table_base={32'd0,static_test_base};
            endcase
        end
        parameter_expected_base=weight_base[31:0];
        if(WRITE_REGION_CASE==39) parameter_start_ready=0;
        tick(5);
        rst = 1'b0;
        tick(3);
        capture_cleanup_busy = 1'b1;
        tick(1);
        if (status_busy)
            $fatal(1, "background camera discard incorrectly asserted BUSY");
        capture_cleanup_busy = 1'b0;
        system_enable = 1'b1;
        pulse_start();

        if(WRITE_REGION_CASE==39) begin
            // 2 mode bits + 32 geometry + 8 format + four 64-bit bases
            // + 16 descriptor count + 32 tensor base = 346 bits.
            logic [345:0] accepted_config;
            accepted_config={continuous_mode,drop_oldest_mode,frame_width,frame_height,
                input_pixel_format,output_pixel_format,input_table_base,output_table_base,
                descriptor_base,weight_base,descriptor_count,tensor_base_addr};
            @(negedge clk);
            {continuous_mode,drop_oldest_mode,frame_width,frame_height,
                input_pixel_format,output_pixel_format,input_table_base,output_table_base,
                descriptor_base,weight_base,descriptor_count,tensor_base_addr}=~accepted_config;
            repeat(5) begin
                @(negedge clk);
                if(!dut.static_memory_legal||!parameter_start_valid||parameter_base_addr!==parameter_expected_base||errors!=0)
                    $fatal(1,"live CSR changed accepted static validation");
                if({dut.cfg_continuous_mode_q,dut.cfg_drop_oldest_mode_q,
                    dut.cfg_frame_width_q,dut.cfg_frame_height_q,
                    dut.cfg_input_pixel_format_q,dut.cfg_output_pixel_format_q,
                    dut.cfg_input_table_base_q,dut.cfg_output_table_base_q,
                    dut.cfg_descriptor_base_q,dut.cfg_weight_base_q,
                    dut.cfg_descriptor_count_q,dut.cfg_tensor_base_q} !== accepted_config)
                    $fatal(1,"live configuration replaced accepted START snapshot");
            end
            {continuous_mode,drop_oldest_mode,frame_width,frame_height,
                input_pixel_format,output_pixel_format,input_table_base,output_table_base,
                descriptor_base,weight_base,descriptor_count,tensor_base_addr}=accepted_config;
            parameter_start_ready=1;
            $display("C1_STATIC_CONFIG_SNAPSHOT_PASS live_bad_ignored=1 fields=12 held_cycles=5");
        end
        if(WRITE_REGION_CASE==40) descriptor_base=64'h00030000;
        if((WRITE_REGION_CASE>=27&&WRITE_REGION_CASE<=34)||WRITE_REGION_CASE==40) begin
            repeat(100) begin
                if(parameter_start_valid||capture_table_request_valid||boardless_start_valid)
                    $fatal(1,"invalid static memory config issued work");
                @(negedge clk);
            end
            if(errors!=1||error_code!==8'h15||error_address!==static_test_base||capture_requests!=0||nn_launches!=0)
                $fatal(1,"static config fault mismatch code=%h address=%h",error_code,error_address);
            $display("C1_SOC_WRITE_REGION_PASS mode=%0d static_config_rejected=1 artifact=%0d",WRITE_REGION_CASE,static_test_index);
            $finish;
        end
        wait (parameter_start_valid);
        $display("SOC_STEP parameter_start t=%0t", $time);
        if (parameter_base_addr != parameter_expected_base)
            $fatal(1, "parameter snapshot mismatch");
        @(negedge clk);
        parameter_busy = 1'b1;
        tick(3);
        @(negedge clk);
        parameter_busy = 1'b0;
        parameter_active_valid = 1'b1;
        parameter_generation = 32'd1;
        parameter_done = 1'b1;
        @(negedge clk);
        parameter_done = 1'b0;

        capture_frame_waiting = 1'b1;
        wait (capture_table_request_valid);
        $display("SOC_STEP capture_table_request t=%0t", $time);
        @(negedge clk);
        capture_table_response_valid = 1'b1;
        @(posedge clk);
        while (!capture_table_response_ready)
            @(posedge clk);
        $display("SOC_STEP capture_table_response t=%0t", $time);
        @(negedge clk);
        capture_table_response_valid = 1'b0;
        wait (capture_begin_frame);
        $display("SOC_STEP capture_begin t=%0t", $time);
        if (!capture_writer_start ||
            capture_writer_base != 32'h0010_0000 ||
            capture_writer_width != ORIGINAL_WIDTH || capture_writer_height != ORIGINAL_HEIGHT ||
            capture_writer_stride != ORIGINAL_STRIDE)
            $fatal(1, "capture writer did not start atomically");
        capture_frame_waiting = 1'b0;
        capture_writer_busy = 1'b1;
        if(CAPTURE_FAULT_DRAIN!=0) begin
            repeat(3) @(negedge clk);
            capture_cleanup_busy=1;
            fabric_write_quiescent=0;
            capture_error_code=8'h05;capture_error=1;
            wait(capture_writer_cancel);
            if(!capture_abort_frame || !capture_clear_error)
                $fatal(1,"RAW fault did not fan out to capture cancellation");
            @(posedge clk);
            @(negedge clk);capture_error=0;capture_error_code=0;
            repeat(5) @(negedge clk);
            if(errors!=1 || error_code!==8'h45 || error_address!=0)
                $fatal(1,"RAW fault diagnostic not reported exactly once");
            // The manager may release logical ownership on fatal abort, but
            // physical snapshots must survive every independently delayed tail.
            for(integer phase=0;phase<3;phase++) begin
                repeat(20) begin
                    @(negedge clk);
                    if(!status_busy || !dut.input_region_valid_q[0] ||
                       dut.input_region_base_q[0]!==32'h00100000 ||
                       dut.input_owned_mask!=0 || capture_writer_start || capture_begin_frame ||
                       errors!=1)
                        $fatal(1,"RAW fault released physical region phase=%0d order=%0d",phase,CAPTURE_FAULT_DRAIN);
                end
                if(phase==0) begin
                    if(CAPTURE_FAULT_DRAIN==1) capture_writer_busy=0;
                    else capture_cleanup_busy=0;
                end
                if(phase==1) begin
                    capture_writer_busy=0;capture_cleanup_busy=0;
                end
            end
            fabric_write_quiescent=1;
            wait(!status_busy);repeat(3) @(negedge clk);
            if(dut.input_region_valid_q!=0)
                $fatal(1,"RAW fault reservation leaked after all tails drained");
            pulse_start();capture_frame_waiting=1;
            wait(capture_table_request_valid);
            @(negedge clk);capture_table_response_valid=1;
            @(posedge clk);while(!capture_table_response_ready) @(posedge clk);
            @(negedge clk);capture_table_response_valid=0;
            wait(capture_begin_frame);
            if(!capture_writer_start || capture_writer_base!==32'h00100000 || errors!=1)
                $fatal(1,"RAW fault drained buffer could not be reused without reset");
            $display("C1_SOC_CAPTURE_FAULT_DRAIN_PASS order=%0d ticket=%0d hold_cycles=60 code=45 no_reset_reuse=1",CAPTURE_FAULT_DRAIN,REGISTER_FATAL_TICKET_CFG);
            $finish;
        end
        if(INPUT_REGION_CASE==3) begin
            repeat(3) @(negedge clk);
            abort_pulse=1;
            @(negedge clk);abort_pulse=0;
            repeat(20) begin
                @(negedge clk);
                if(!dut.input_region_valid_q[0] || dut.input_region_base_q[0]!==32'h00100000 ||
                   dut.input_owned_mask!=0 || !status_busy || capture_writer_start)
                    $fatal(1,"canceled input region released before writer drain");
            end
            capture_writer_busy=0;capture_writer_done=1;
            @(negedge clk);capture_writer_done=0;
            wait(!status_busy);repeat(3) @(negedge clk);
            if(dut.input_region_valid_q!=0) $fatal(1,"retired canceled region leaked reservation");
            pulse_start();capture_frame_waiting=1;
            wait(capture_table_request_valid);
            @(negedge clk);capture_table_response_valid=1;
            @(posedge clk);while(!capture_table_response_ready) @(posedge clk);
            @(negedge clk);capture_table_response_valid=0;
            wait(capture_begin_frame);
            if(!capture_writer_start || capture_writer_base!==32'h00100000 || errors!=0)
                $fatal(1,"released input region could not be reused without reset");
            $display("C1_INPUT_REGION_PASS mode=3 retained_during_cancel=20 release_after_drain=1 no_reset_reuse=1");
            $finish;
        end
        tick(3);
        @(negedge clk);
        capture_ingress_done = 1'b1;
        @(negedge clk);
        capture_ingress_done = 1'b0;
        tick(2);
        @(negedge clk);
        capture_writer_busy = 1'b0;
        capture_writer_done = 1'b1;
        @(negedge clk);
        capture_writer_done = 1'b0;

        if(INPUT_REGION_CASE>=5) begin : recycled_input_region
            logic [31:0] replacement;
            wait(input_ready_count==1);
            reserve_ready_input(32'h01000000,1);
            reserve_ready_input(32'h02000000,2);
            if(input_ready_count!=3 || dut.input_region_valid_q!=3'b111)
                $fatal(1,"drop-oldest fixture did not reserve three READY frames");
            replacement=(INPUT_REGION_CASE==5 ? 32'h03000000 :
                         INPUT_REGION_CASE==6 ? 32'h01000010 : 32'h00100000);
            if(INPUT_REGION_CASE!=6) begin
                reserve_ready_input(replacement,0);
                if(input_ready_count!=3 || dut.input_region_valid_q!=3'b111 ||
                   dut.input_region_base_q[0]!==replacement ||
                   dut.input_region_base_q[1]!==32'h01000000 ||
                   dut.input_region_base_q[2]!==32'h02000000 || errors!=0)
                    $fatal(1,"recycle corrupted retained input reservations");
            end else begin
                capture_table_response_base={32'd0,replacement};capture_frame_waiting=1;
                wait(capture_table_request_valid);
                @(negedge clk);capture_table_response_valid=1;
                @(posedge clk);while(!capture_table_response_ready) @(posedge clk);
                @(negedge clk);capture_table_response_valid=0;
                if(dut.manager_cap_index!==0) $fatal(1,"wrong recycled input slot");
                repeat(2000) begin
                    if(capture_writer_start || capture_begin_frame)
                        $fatal(1,"recycle bypassed OTHER input slot protection");
                    @(negedge clk);
                end
                if(errors!=1 || error_code!=8'h31 || error_address!==replacement)
                    $fatal(1,"recycle alias error mismatch");
            end
            if(dut.manager_dropped_count!=1 || nn_launches!=0 || capture_requests!=4)
                $fatal(1,"drop-oldest coverage mismatch");
            $display("C1_INPUT_REGION_PASS mode=%0d captures=4 drops=1 nn_jobs=0 recycle_checked=1",INPUT_REGION_CASE);
            $finish;
        end
        if(INPUT_REGION_CASE!=0) begin
            if(INPUT_REGION_CASE==4) begin
                wait(boardless_start_valid);
                @(negedge clk);boardless_busy=1;
            end else wait(input_ready_count==1);
            if(!dut.input_region_valid_q[0] || dut.input_region_base_q[0]!==32'h00100000)
                $fatal(1,"completed capture lost its reserved physical region");
            capture_table_response_base=(INPUT_REGION_CASE==2) ? 64'h01000000 : 64'h00100010;
            capture_frame_waiting=1;
            wait(capture_table_request_valid);
            @(negedge clk);capture_table_response_valid=1;
            @(posedge clk);while(!capture_table_response_ready) @(posedge clk);
            @(negedge clk);capture_table_response_valid=0;
            if(INPUT_REGION_CASE==2) begin
                wait(capture_begin_frame);
                if(!capture_writer_start || capture_writer_base!=32'h01000000 ||
                   !dut.input_region_valid_q[0] || errors!=0 || nn_launches!=0)
                    $fatal(1,"disjoint capture blocked by ready frame");
            end else begin
                repeat(2000) begin
                    if(capture_writer_start || capture_begin_frame)
                        $fatal(1,"capture overwrote reserved input frame mode=%0d",INPUT_REGION_CASE);
                    @(negedge clk);
                end
                if(errors!=1 || error_code!=8'h31 || error_address!=32'h00100010 ||
                   nn_launches!=(INPUT_REGION_CASE==4 ? 1 : 0))
                    $fatal(1,"input region alias did not report precise error");
            end
            $display("C1_INPUT_REGION_PASS mode=%0d ready_or_processing_preserved=1",INPUT_REGION_CASE);
            $finish;
        end
        wait (boardless_start_valid);
        $display("SOC_STEP boardless_start t=%0t", $time);
        tensor_base_addr = 32'h0400_0000;
        if (boardless_input_table_base != input_table_base ||
            boardless_x_step_q16 !== (DIFFERENT_RESOLVED_GEOMETRY ? -32'sh18000 : 32'sh10000) ||
            boardless_y_step_q16 !== (DIFFERENT_RESOLVED_GEOMETRY ? 32'sh20000 : 32'sh10000) ||
            boardless_x_phase0_q16 !== (DIFFERENT_RESOLVED_GEOMETRY ? 32'sh7fffffff : 32'sd0) ||
            boardless_y_phase0_q16 !== (DIFFERENT_RESOLVED_GEOMETRY ? -32'sh8000 : 32'sd0) ||
            boardless_input_width != ORIGINAL_WIDTH || boardless_input_height != ORIGINAL_HEIGHT ||
            boardless_frame_width != 640 || boardless_frame_height != 480 ||
            boardless_output_table_base != output_table_base ||
            boardless_descriptor_count != 22 ||
            boardless_tensor_base_addr != 32'h0200_0000)
            $fatal(1, "boardless command snapshot mismatch");
        @(negedge clk);
        boardless_busy = 1'b1;
        if(WRITE_REGION_CASE!=0) begin : write_admission_test
            logic [31:0] candidate_capture;
            boardless_resolved_output_base=32'h04000000;
            boardless_resolved_preview_base=32'h06000000;
            boardless_resolved_preview_stride=2560;
            if(WRITE_REGION_CASE==1) boardless_resolved_output_base=32'h00100010;
            if(WRITE_REGION_CASE==2) boardless_resolved_preview_base=32'h00100010;
            if(WRITE_REGION_CASE==11) boardless_resolved_output_base=32'h02000010;
            if(WRITE_REGION_CASE==12) boardless_resolved_preview_base=32'h03000010;
            if(WRITE_REGION_CASE>=15&&WRITE_REGION_CASE<=18) boardless_resolved_output_base=32'h0c000010;
            if(WRITE_REGION_CASE>=19&&WRITE_REGION_CASE<=22) boardless_resolved_preview_base=32'h0c000010;
            if(WRITE_REGION_CASE==5) begin
                boardless_resolved_output_base=32'h01000010;
                fork
                    reserve_ready_input(32'h01000000,1);
                    begin
                        wait(dut.capture_state_q==dut.CAP_GUARD_PREP);
                        @(negedge clk);boardless_region_request=1;
                        if(dut.region_check_busy) $fatal(1,"compute stole active capture admission");
                    end
                join
            end else if(WRITE_REGION_CASE==8) begin
                // Table response and compute admission arrive on the same
                // edge. Capture must wait for the accepted compute check.
                capture_frame_waiting=1;capture_table_response_base=32'h04000010;
                wait(capture_table_request_valid);
                @(negedge clk);capture_table_response_valid=1;boardless_region_request=1;
                @(posedge clk);while(!capture_table_response_ready) @(posedge clk);
                @(negedge clk);capture_table_response_valid=0;
            end else begin
                @(negedge clk);boardless_region_request=1;
            end
            wait(boardless_region_response);
            if(WRITE_REGION_CASE>=15&&WRITE_REGION_CASE<=22) begin
                if(boardless_region_error_code!==8'h39||boardless_region_error_address!==32'h0c000010||
                   dut.output_region_valid_q!=0)
                    $fatal(1,"image writer overwrote static artifact");
                $display("C1_SOC_WRITE_REGION_PASS mode=%0d static_writer_rejected=1 artifact=%0d",WRITE_REGION_CASE,static_test_index);
                $finish;
            end
            if(WRITE_REGION_CASE==11||WRITE_REGION_CASE==12) begin
                if(boardless_region_error_code!==8'h37 || dut.output_region_valid_q!=0 ||
                   boardless_region_error_address!==(WRITE_REGION_CASE==11 ? 32'h02000010 : 32'h03000010))
                    $fatal(1,"tensor arena alias was admitted or wrong diagnostic");
                $display("C1_SOC_WRITE_REGION_PASS mode=%0d rejected_tensor_alias=1",WRITE_REGION_CASE);
                $finish;
            end
            if(WRITE_REGION_CASE==1||WRITE_REGION_CASE==2||WRITE_REGION_CASE==5) begin
                if(boardless_region_error_code!==8'h35 || dut.output_region_valid_q!=0 ||
                   boardless_region_error_address!==(WRITE_REGION_CASE==5 ? 32'h01000010 : 32'h00100010))
                    $fatal(1,"compute alias was admitted or wrong diagnostic");
                $display("C1_SOC_WRITE_REGION_PASS mode=%0d rejected_compute=1 captures=%0d",WRITE_REGION_CASE,captures);
                $finish;
            end
            if(boardless_region_error_code!=0) $fatal(1,"legal compute admission rejected");
            repeat(2) @(negedge clk);
            if(!dut.output_region_valid_q[0] || dut.output_region_base_q[0]!==32'h04000000 ||
               dut.preview_region_base_q[0]!==32'h06000000)
                $fatal(1,"accepted compute did not retain both writer regions");
            boardless_region_request=0;
            repeat(3) @(negedge clk);
            if(WRITE_REGION_CASE>=35) begin
                if(dut.static_region_end[static_test_index]!==33'h100000000 || errors!=0)
                    $fatal(1,"legal static 4-GiB exclusive end rejected");
                $display("C1_SOC_WRITE_REGION_PASS mode=%0d static_4g_end_accepted=1 artifact=%0d",WRITE_REGION_CASE,static_test_index);
                $finish;
            end
            if(WRITE_REGION_CASE==14) begin
                // A new run can select a different tensor arena while the
                // old display survives abort. Its physical image still owns
                // memory and must be checked against the NEW tensor writer.
                boardless_busy=0;boardless_done=1;
                @(negedge clk);boardless_done=0;
                wait(display_prefetch_start_valid);
                @(negedge clk);display_prefetch_start_ready=1;
                @(negedge clk);display_prefetch_busy=1;display_prefetch_primed=1;
                @(negedge clk);display_frame_start_event=1;
                @(negedge clk);display_frame_start_event=0;
                wait(display_swap_event);
                @(negedge clk);display_prefetch_busy=0;display_prefetch_primed=0;display_prefetch_done=1;
                @(negedge clk);display_prefetch_done=0;display_prefetch_start_ready=0;
                if(DRAIN_CASE==4) fabric_read_quiescent=0;
                abort_pulse=1;boardless_start_ready=0;
                @(negedge clk);abort_pulse=0;
                if(DRAIN_CASE==4) begin
                    repeat(10) begin
                        @(negedge clk);
                        if(!status_busy||display_prefetch_start_valid||!dut.current_pair_valid_q||!dut.output_region_valid_q[0])
                            $fatal(1,"background display escaped shared drain barrier");
                    end
                    fabric_read_quiescent=1;
                end
                wait(!status_busy);repeat(4) @(negedge clk);
                if(!dut.current_pair_valid_q||dut.output_region_valid_q!==2'b01)
                    $fatal(1,"new tensor run lost retained display region");
                if(DRAIN_CASE==4) begin
                    wait(display_prefetch_start_valid);
                    fabric_read_quiescent=0;
                    repeat(3) begin @(negedge clk);if(status_busy)
                        $fatal(1,"ordinary background read incorrectly held foreground BUSY");end
                    fabric_read_quiescent=1;
                    $display("C1_SOC_SHARED_DRAIN_PASS mode=4 display_resumed=1 background_not_foreground=1");
                end
                tensor_base_addr=32'h04000000;pulse_start();
                reserve_ready_input(32'h01000000,1);
                display_prefetch_start_ready=1;
                boardless_start_ready=1;wait(boardless_start_valid);
                @(negedge clk);boardless_busy=1;
                if(boardless_tensor_base_addr!==32'h04000000) $fatal(1,"new tensor arena not snapshotted");
                boardless_resolved_input_base=32'h01000000;
                boardless_resolved_output_base=32'h08000000;
                boardless_resolved_preview_base=32'h0a000000;
                boardless_region_request=1;
                wait(boardless_region_response);
                if(boardless_region_error_code!==8'h37||boardless_region_error_address!==32'h04000000||
                   dut.output_region_valid_q!==2'b01)
                    $fatal(1,"new tensor arena overwrote retained display");
            end else if(WRITE_REGION_CASE==7) begin
                abort_pulse=1;@(negedge clk);abort_pulse=0;
                repeat(20) begin
                    @(negedge clk);
                    if(!dut.output_region_valid_q[0] || dut.output_owned_mask!=0 || !status_busy)
                        $fatal(1,"compute region released before cancellation drain");
                end
                if(DRAIN_CASE!=0) begin
                    fabric_read_quiescent=(DRAIN_CASE==2);
                    fabric_write_quiescent=(DRAIN_CASE==1);
                    fabric_write_busy=(DRAIN_CASE!=1);
                end
                boardless_busy=0;boardless_aborted=1;
                @(negedge clk);boardless_aborted=0;
                if(DRAIN_CASE!=0) begin
                    repeat(10) begin
                        @(negedge clk);
                        if(!status_busy||!dut.output_region_valid_q[0]||!dut.input_region_valid_q[0]||
                           parameter_start_valid||capture_table_request_valid||boardless_start_valid)
                            $fatal(1,"shared drain released ownership early mode=%0d busy=%b input=%b output=%b",
                                DRAIN_CASE,status_busy,dut.input_region_valid_q,dut.output_region_valid_q);
                    end
                    if(DRAIN_CASE==3) begin
                        fabric_read_quiescent=1;
                        repeat(5) begin @(negedge clk);if(!status_busy||!dut.output_region_valid_q[0])
                            $fatal(1,"write tail ignored after read drain");end
                    end
                    fabric_read_quiescent=1;fabric_write_quiescent=1;fabric_write_busy=0;
                end
                wait(!status_busy);repeat(4) @(negedge clk);
                if(dut.output_region_valid_q!=0) $fatal(1,"drained output region leaked");
                if(DRAIN_CASE!=0) $display("C1_SOC_SHARED_DRAIN_PASS mode=%0d held_until_fabric_retired=1",DRAIN_CASE);
            end else if(WRITE_REGION_CASE==6||WRITE_REGION_CASE==9) begin
                reserve_ready_input(32'h01000000,1);
                if(!boardless_busy || captures!=2 || !dut.output_region_valid_q[0])
                    $fatal(1,"legal capture did not run concurrently with compute");
                if(WRITE_REGION_CASE==9) begin
                    // Publish the first result. The scheduler intentionally
                    // does not launch the next NN while publication is pending.
                    boardless_busy=0;boardless_done=1;
                    @(negedge clk);boardless_done=0;
                    wait(display_prefetch_start_valid);
                    @(negedge clk);display_prefetch_start_ready=1;
                    @(negedge clk);display_prefetch_busy=1;display_prefetch_primed=1;
                    @(negedge clk);display_frame_start_event=1;
                    @(negedge clk);display_frame_start_event=0;
                    wait(display_swap_event);
                    @(negedge clk);display_prefetch_busy=0;display_prefetch_primed=0;display_prefetch_done=1;
                    @(negedge clk);display_prefetch_done=0;
                    wait(boardless_start_valid);
                    @(negedge clk);boardless_busy=1;
                    boardless_resolved_input_base=32'h01000000;
                    boardless_resolved_output_base=32'h04000010;
                    boardless_resolved_preview_base=32'h08000000;
                    boardless_region_request=1;
                    wait(boardless_region_response);
                    if(boardless_region_error_code!==8'h35 || boardless_region_error_address!==32'h04000010 ||
                       dut.output_region_valid_q!==2'b01 || !dut.current_pair_valid_q)
                        $fatal(1,"current output overwritten by next job");
                end
            end else begin
                candidate_capture=WRITE_REGION_CASE==4 ? 32'h06000010 : 32'h04000010;
                if(WRITE_REGION_CASE==13) candidate_capture=32'h02000010;
                if(WRITE_REGION_CASE>=23&&WRITE_REGION_CASE<=26) candidate_capture=32'h0c000010;
                if(WRITE_REGION_CASE==10) begin
                    boardless_busy=0;boardless_done=1;
                    @(negedge clk);boardless_done=0;
                    repeat(3) @(negedge clk);
                    if(!dut.pending_pair_valid_q || !dut.output_region_valid_q[0])
                        $fatal(1,"READY_DISPLAY region released when DMA became idle");
                end
                if(WRITE_REGION_CASE!=8) begin
                    capture_frame_waiting=1;capture_table_response_base=candidate_capture;
                    wait(capture_table_request_valid);
                    @(negedge clk);capture_table_response_valid=1;
                    @(posedge clk);while(!capture_table_response_ready) @(posedge clk);
                    @(negedge clk);capture_table_response_valid=0;
                end
                repeat(2000) begin
                    if(capture_writer_start||capture_begin_frame) $fatal(1,"capture overwrote in-flight compute output");
                    @(negedge clk);
                end
                if(errors!=1 || error_code!==8'h31 || error_address!==candidate_capture ||
                   (WRITE_REGION_CASE!=10 && !dut.output_region_valid_q[0]) || captures!=1)
                    $fatal(1,"capture alias diagnostic/drain reservation mismatch");
            end
            $display("C1_SOC_WRITE_REGION_PASS mode=%0d captures=%0d output_lifetime_checked=1",WRITE_REGION_CASE,captures);
            $finish;
        end
        tick(5);
        @(negedge clk);
        boardless_busy = 1'b0;
        boardless_done = 1'b1;
        @(negedge clk);
        boardless_done = 1'b0;
        // Poison live resolver outputs after completion. Both pending and
        // current display tickets must retain the completed pair, not these.
        boardless_resolved_input_base = 32'hdead_0000;
        boardless_resolved_preview_base=32'hbad00000;
        boardless_resolved_preview_stride=16;
        boardless_resolved_input_stride = 32'd16;
        boardless_resolved_input_width = 16'd1;
        boardless_resolved_input_height = 16'd2;
        boardless_resolved_output_base = 32'hbeef_0000;
        boardless_resolved_output_stride = 32'd32;
        boardless_resolved_output_width = 16'd3;
        boardless_resolved_output_height = 16'd4;

        wait (display_prefetch_start_valid);
        $display("SOC_STEP display_prefetch_new t=%0t", $time);
        repeat (5) begin
            @(negedge clk);
            if (!display_prefetch_start_valid)
                $fatal(1,"display ticket withdrawn while stalled");
            check_display_pair();
        end
        display_prefetch_start_ready = 1'b1;
        if (display_original_base != DISPLAY_BASE ||
            display_styled_base != 32'h0020_0000)
            $fatal(1, "display did not use boardless resolved snapshot");
        @(negedge clk);
        display_prefetch_busy = 1'b1;
        display_prefetch_primed = 1'b1;
        tick(3);
        @(negedge clk);
        display_frame_start_event = 1'b1;
        @(negedge clk);
        display_frame_start_event = 1'b0;
        if(SWAP_ABORT_COLLISION==1) begin
            // Manager ownership committed on the preceding rising edge;
            // the controller consumes that registered swap on the next edge.
            // Cancel between these edges must preserve the committed metadata.
            if(!dut.manager_display_swap || dut.current_pair_valid_q)
                $fatal(1,"swap cancellation test missed ownership/metadata boundary");
            abort_pulse=1;
            display_flush_busy=1;
            @(posedge clk); #1;
            if(!dut.current_pair_valid_q ||
               dut.current_original_base_q!==DISPLAY_BASE ||
               dut.current_original_stride_q!==DISPLAY_STRIDE ||
               dut.current_original_width_q!==DISPLAY_W ||
               dut.current_original_height_q!==DISPLAY_H ||
               dut.current_styled_base_q!==32'h00200000 ||
               dut.current_styled_stride_q!==2560 ||
               dut.current_width_q!==640 || dut.current_height_q!==480 ||
               !dut.u_frame_manager.display_active || display_frame_id!==0)
                $fatal(1,"committed swap lost metadata on cancellation preview=%0d",PREVIEW_DISPLAY);
            @(negedge clk);abort_pulse=0;display_flush_busy=0;
            $display("C1_SOC_SWAP_ABORT_METADATA_PASS preview=%0d ticket=%0d",PREVIEW_DISPLAY,REGISTER_FATAL_TICKET_CFG);
        end
        wait (display_swap_event);
        $display("SOC_STEP display_swap t=%0t", $time);
        if (!display_feed_active)
            $fatal(1, "display feed did not become active");

        @(negedge clk);
        display_prefetch_primed = 1'b0;
        display_prefetch_busy = 1'b0;
        display_prefetch_done = 1'b1;
        @(negedge clk);
        display_prefetch_done = 1'b0;
        @(negedge clk);
        display_flush_busy = 1'b1;
        abort_pulse = 1'b1;
        @(posedge clk);
        if (!display_flush_request || !display_prefetch_abort)
            $fatal(1, "abort did not fence display");
        @(negedge clk);
        abort_pulse = 1'b0;

        tick(2);
        if (!status_busy)
            $fatal(1, "abort cleanup was not reflected in BUSY");
        @(negedge clk);
        display_flush_busy = 1'b0;

        tick(5);
        begin : wait_repeat_prefetch
            integer repeat_wait;
            repeat_wait = 0;
            while ((prefetch_launches < 2) && (repeat_wait < 20)) begin
                tick(1);
                repeat_wait = repeat_wait + 1;
            end
            if (prefetch_launches < 2)
                $fatal(1, "background display repeat did not recover after abort");
        end
        $display("SOC_STEP display_repeat t=%0t", $time);
        check_display_pair();
        $display("C1_DISPLAY_PAIR_GEOMETRY_PASS original=%0dx%0d styled=640x480 stride=%0d/2560 stalled=5 abort_repeat=1",
                 DISPLAY_W, DISPLAY_H, DISPLAY_STRIDE);
        if(PREVIEW_DISPLAY)
            $display("C1_PREVIEW_DISPLAY_METADATA_PASS preview_base=00300000 stride=4096 geometry=640x480 source_unchanged=1 stall=5 abort_repeat=1");
        if (display_original_base != DISPLAY_BASE ||
            display_styled_base != 32'h0020_0000)
            $fatal(1, "repeat pair address mismatch");

        if (capture_requests != 1 || nn_launches != 1 ||
            prefetch_launches < 2 || swaps != 1 || errors != 0)
            $fatal(1, "unexpected lifecycle counts");

        if(SWAP_ABORT_COLLISION>=2 || CAPTURE_DISPLAY_ALIAS!=0 || CAPTURE_GUARD_CANCEL || CAPTURE_GUARD_PUBLISH!=0) begin : second_committed_pair
            // Complete a real second manager allocation without resetting it.
            // Compute/capture/display clients remain behavioral in this TB.
            wait(!status_busy);
            continuous_mode=(CAPTURE_GUARD_PUBLISH!=0);
            pulse_start();
            // The previous 0x00400000 fixture overlapped the first preview's
            // 0x00300000 + 480 rows * 4096-byte stride envelope/active rows.
            capture_table_response_base=64'h01000000;
            if(CAPTURE_DISPLAY_ALIAS!=0) begin
                if(!dut.manager_display_active) $fatal(1,"alias probe requires live display");
                capture_table_response_base=(CAPTURE_DISPLAY_ALIAS==1) ?
                    {32'd0,dut.current_original_base_q} :
                    {32'd0,dut.current_styled_base_q}+(CAPTURE_DISPLAY_ALIAS==3 ? 64'd16 : 64'd0);
            end
            capture_frame_waiting=1;
            wait(capture_table_request_valid);
            @(negedge clk);capture_table_response_valid=1;
            @(posedge clk);while(!capture_table_response_ready) @(posedge clk);
            @(negedge clk);capture_table_response_valid=0;
            if(CAPTURE_GUARD_CANCEL) begin
                wait(dut.capture_guard_req && dut.capture_guard_ready);
                @(negedge clk);abort_pulse=1;capture_frame_waiting=0;
                @(negedge clk);abort_pulse=0;
                repeat(80) begin
                    @(negedge clk);
                    if(capture_writer_start || capture_begin_frame || dut.capture_guard_response ||
                       !dut.manager_display_active || dut.current_styled_base_q!==32'h00200000)
                        $fatal(1,"canceled capture guard launched work or lost display");
                end
                if(errors!=0) $fatal(1,"cancel-only range check reported a fault");
                $display("C1_CAPTURE_GUARD_CANCEL_PASS preview=%0d ticket=%0d no_writer_start=1 no_late_response=1 retained_display=1",
                    PREVIEW_DISPLAY,REGISTER_FATAL_TICKET_CFG);
                $finish;
            end
            if(CAPTURE_DISPLAY_ALIAS!=0) begin
                repeat(2000) begin
                    if(capture_writer_start || capture_begin_frame)
                        $fatal(1,"C1_CAPTURE_DISPLAY_ALIAS_UNPROTECTED mode=%0d preview=%0d base=%h displayed_original=%h displayed_styled=%h",
                            CAPTURE_DISPLAY_ALIAS,PREVIEW_DISPLAY,capture_writer_base,
                            dut.current_original_base_q,dut.current_styled_base_q);
                    @(negedge clk);
                end
                if(errors!=1 || error_code!=8'h31 ||
                   error_address!==capture_table_response_base[31:0] ||
                   !dut.manager_display_active || dut.current_styled_base_q!==32'h00200000)
                    $fatal(1,"alias rejection did not report fault while preserving display");
                $display("C1_CAPTURE_DISPLAY_ALIAS_GUARD_PASS mode=%0d preview=%0d",CAPTURE_DISPLAY_ALIAS,PREVIEW_DISPLAY);
                $finish;
            end
            wait(capture_begin_frame);
            if(capture_writer_base!==32'h01000000)
                $fatal(1,"second capture address mismatch");
            capture_frame_waiting=0;capture_writer_busy=1;
            repeat(3) @(negedge clk);
            capture_ingress_done=1;
            @(negedge clk);capture_ingress_done=0;
            capture_writer_busy=0;capture_writer_done=1;
            @(negedge clk);capture_writer_done=0;
            wait(boardless_start_valid);
            if(boardless_output_index!==1 || dut.u_frame_manager.display_output_index!==0 ||
               boardless_frame_width!==640 || boardless_frame_height!==480)
                $fatal(1,"second job reused displayed slot");
            @(negedge clk);boardless_busy=1;display_prefetch_start_ready=0;
            boardless_resolved_input_base=32'h01000000;
            boardless_resolved_input_stride=ORIGINAL_STRIDE;
            boardless_resolved_input_width=ORIGINAL_WIDTH;
            boardless_resolved_input_height=ORIGINAL_HEIGHT;
            boardless_resolved_preview_base=32'h00500000;
            boardless_resolved_preview_stride=8192;
            boardless_resolved_output_base=32'h00600000;
            boardless_resolved_output_stride=4096;
            boardless_resolved_output_width=640;
            boardless_resolved_output_height=480;
            if(CAPTURE_GUARD_PUBLISH!=0) begin : concurrent_capture_publication
                integer initial_checks;
                // NN job 2 really owns input/output slot 1. Capture 3 uses
                // the remaining input slot while job 2 is still active.
                if(CAPTURE_GUARD_PUBLISH==3 || CAPTURE_GUARD_PUBLISH>=5) begin
                    @(negedge clk);boardless_busy=0;boardless_done=1;
                    @(negedge clk);boardless_done=0;
                end
                if(CAPTURE_GUARD_PUBLISH>=5) begin
                    wait(display_prefetch_start_valid);
                    check_second_pair_ticket();
                    @(negedge clk);display_prefetch_start_ready=1;
                    @(posedge clk);while(!display_prefetch_start_valid) @(posedge clk);
                    @(negedge clk);display_prefetch_start_ready=0;
                    display_prefetch_busy=1;display_prefetch_primed=1;
                end
                initial_checks=guard_requests;
                capture_table_response_base=(CAPTURE_GUARD_PUBLISH==4 || CAPTURE_GUARD_PUBLISH==6) ? 64'h03000000 : 64'h00600010;
                capture_frame_waiting=1;
                wait(capture_table_request_valid);
                @(negedge clk);capture_table_response_valid=1;
                @(posedge clk);while(!capture_table_response_ready) @(posedge clk);
                @(negedge clk);capture_table_response_valid=0;
                if(CAPTURE_GUARD_PUBLISH>=5) begin
                    wait(dut.u_capture_display_guard.busy);
                    repeat(3) @(negedge clk);
                    display_frame_start_event=1;
                    @(negedge clk);display_frame_start_event=0;
                    if(!dut.manager_display_swap)
                        $fatal(1,"guard VSYNC fixture did not commit real manager ownership");
                    // current commits one edge later; the registered software
                    // swap event is counted by the scoreboard one edge after it.
                    repeat(2) @(negedge clk);
                    if(dut.current_styled_base_q!==32'h00600000 ||
                       dut.u_frame_manager.display_output_index!==1 || swaps!=2)
                        $fatal(1,"guard VSYNC did not commit matching current metadata");
                    if(dut.input_region_valid_q[0] || !dut.input_region_valid_q[1] ||
                       dut.input_region_base_q[1]!==32'h01000000)
                        $fatal(1,"VSYNC released new input reservation or leaked the old one");
                end else if(CAPTURE_GUARD_PUBLISH!=3) begin
                    if(CAPTURE_GUARD_PUBLISH==1) begin
                        wait(dut.u_capture_display_guard.busy);
                        repeat(3) @(negedge clk);
                    end else begin
                        wait(dut.capture_state_q==dut.CAP_GUARD_COMMIT);
                        @(negedge clk);
                    end
                    if(capture_writer_start || capture_begin_frame)
                        $fatal(1,"publication fixture arrived after capture start");
                    boardless_busy=0;boardless_done=1;
                    @(negedge clk);boardless_done=0;
                end
                // Only the accepted completion snapshot is authoritative.
                boardless_resolved_output_base=32'hbeef0000;
                if(CAPTURE_GUARD_PUBLISH==4 || CAPTURE_GUARD_PUBLISH==6) begin
                    wait(capture_writer_start);
                    if(!capture_begin_frame || capture_writer_base!=32'h03000000 || errors!=0 ||
                       guard_requests-initial_checks!=(CAPTURE_GUARD_PUBLISH==6 ? 3 : 5) ||
                       dut.pending_pair_valid_q!==(CAPTURE_GUARD_PUBLISH!=6) ||
                       swaps!=(CAPTURE_GUARD_PUBLISH==6 ? 2 : 1) || nn_launches!=2 || capture_requests!=3)
                        $fatal(1,"legal publication retry rejected/corrupted capture");
                    $display("C1_CAPTURE_GUARD_PUBLISH_PASS mode=%0d preview=%0d ticket=%0d checks=%0d swaps=%0d legal_retry_started=1",
                        CAPTURE_GUARD_PUBLISH,PREVIEW_DISPLAY,REGISTER_FATAL_TICKET_CFG,guard_requests-initial_checks,swaps);
                    $finish;
                end
                repeat(2000) begin
                    if(capture_writer_start || capture_begin_frame)
                        $fatal(1,"new pending display escaped capture range recheck mode=%0d",CAPTURE_GUARD_PUBLISH);
                    @(negedge clk);
                end
                if(errors!=1 || error_code!=8'h31 || error_address!=32'h00600010 ||
                   swaps!=(CAPTURE_GUARD_PUBLISH==5 ? 2 : 1) || nn_launches!=2 || capture_requests!=3 ||
                   !dut.manager_display_active || dut.current_styled_base_q!==(CAPTURE_GUARD_PUBLISH==5 ? 32'h00600000 : 32'h00200000) ||
                   guard_requests-initial_checks < ((CAPTURE_GUARD_PUBLISH==3 || CAPTURE_GUARD_PUBLISH==5) ? 2 : 3))
                    $fatal(1,"capture publication coverage/fault mismatch checks=%0d",guard_requests-initial_checks);
                $display("C1_CAPTURE_GUARD_PUBLISH_PASS mode=%0d preview=%0d ticket=%0d checks=%0d swaps=%0d nn_jobs=2 captures=3 no_writer_start=1 committed_display_retained=1",
                    CAPTURE_GUARD_PUBLISH,PREVIEW_DISPLAY,REGISTER_FATAL_TICKET_CFG,guard_requests-initial_checks,swaps);
                $finish;
            end
            repeat(3) @(negedge clk);
            boardless_busy=0;boardless_done=1;
            @(negedge clk);boardless_done=0;
            // Poison the live result immediately; only completed snapshots count.
            boardless_resolved_input_base=32'hdead0000;
            boardless_resolved_preview_base=32'hbad00000;
            boardless_resolved_output_base=32'hbeef0000;
            wait(display_prefetch_start_valid);
            repeat(5) begin
                @(negedge clk);
                check_second_pair_ticket();
                if(dut.current_original_base_q!==DISPLAY_BASE ||
                   dut.u_frame_manager.display_output_index!==0 || swaps!=1)
                    $fatal(1,"uncommitted second ticket replaced displayed pair");
            end
            display_prefetch_start_ready=1;
            @(negedge clk);display_prefetch_busy=1;display_prefetch_primed=1;
            repeat(3) @(negedge clk);
            display_frame_start_event=1;
            if(SWAP_ABORT_COLLISION==3) begin
                // The opposite side of the boundary: this cancellation wins
                // BEFORE the manager commits, so the old displayed pair stays.
                abort_pulse=!SWAP_ERROR_COLLISION;
                display_prefetch_error=SWAP_ERROR_COLLISION;
                display_flush_busy=1;display_prefetch_start_ready=0;
                display_prefetch_done=SWAP_ERROR_COLLISION;
                #1;
                if(SWAP_ERROR_COLLISION && display_prefetch_new_done_event)
                    $fatal(1,"failed display terminal counted as completed new frame");
                @(posedge clk);#1;
                if(dut.manager_display_swap || display_frame_id!==0 ||
                   dut.u_frame_manager.display_output_index!==0 ||
                   !dut.current_pair_valid_q || dut.current_original_base_q!==DISPLAY_BASE ||
                   dut.current_styled_base_q!==32'h00200000)
                    $fatal(1,"uncommitted pair escaped cancellation on VSYNC");
                @(negedge clk);abort_pulse=0;display_frame_start_event=0;display_prefetch_done=0;
                repeat(8) begin
                    @(negedge clk);
                    if(display_prefetch_start_valid || !status_busy || swaps!=1 ||
                       dut.current_original_base_q!==DISPLAY_BASE)
                        $fatal(1,"pending pair cancel lost old frame/drain fence");
                end
                display_prefetch_error=0;
                display_flush_busy=0;display_prefetch_busy=0;display_prefetch_primed=0;
                display_prefetch_aborted=1;
                @(negedge clk);display_prefetch_aborted=0;
                wait(display_prefetch_start_valid);check_display_pair();
                if(capture_requests!=2 || nn_launches!=2 || swaps!=1 || errors!=(SWAP_ERROR_COLLISION ? 1 : 0) ||
                   dut.prefetch_request_is_new_q)
                    $fatal(1,"pending pair cancel recovery counts/tag mismatch");
                if(SWAP_ERROR_COLLISION && (error_code!==8'h70 ||
                   error_address!==(PREVIEW_DISPLAY ? 32'h00500000 : 32'h01000000)))
                    $fatal(1,"pending swap error lost source address/code");
                if(qos_frame_active || qos_completed_frames!==1 || qos_protocol_errors!==0)
                    $fatal(1,"pending-frame cancellation corrupted QoS lifecycle");
                $display("C1_SOC_CANCEL_QOS_PASS boundary=before completed=1 active=0 protocol_errors=0");
                $display("C1_SOC_PENDING_SWAP_ABORT_PASS preview=%0d ticket=%0d jobs=2 swaps=1 canceled_slot=1 retained_slot=0 drain_hold=8",
                    PREVIEW_DISPLAY,REGISTER_FATAL_TICKET_CFG);
                if(SWAP_ERROR_COLLISION)
                    $display("C1_SOC_PENDING_SWAP_ERROR_PASS preview=%0d ticket=%0d errors=1 swaps=1 retained_slot=0",PREVIEW_DISPLAY,REGISTER_FATAL_TICKET_CFG);
                $finish;
            end
            @(negedge clk);display_frame_start_event=0;
            if(!dut.manager_display_swap || display_frame_id!==1 ||
               dut.u_frame_manager.display_output_index!==1 ||
               dut.current_original_base_q!==DISPLAY_BASE)
                $fatal(1,"second swap test missed ownership/metadata boundary");
            abort_pulse=!SWAP_ERROR_COLLISION;
            display_prefetch_error=SWAP_ERROR_COLLISION;
            display_flush_busy=1;display_prefetch_start_ready=0;
            display_prefetch_done=SWAP_ERROR_COLLISION;
            #1;
            if(SWAP_ERROR_COLLISION && display_prefetch_new_done_event)
                $fatal(1,"failed committed-frame terminal counted as successful completion");
            @(posedge clk);#1;
            check_second_pair_current();
            @(negedge clk);abort_pulse=0;display_prefetch_done=0;
            repeat(8) begin
                @(negedge clk);
                check_second_pair_current();
                if(display_prefetch_start_valid || !status_busy)
                    $fatal(1,"new display request before canceled reader drained");
            end
            display_prefetch_error=0;
            display_flush_busy=0;display_prefetch_busy=0;display_prefetch_primed=0;
            display_prefetch_aborted=1;
            @(negedge clk);display_prefetch_aborted=0;
            wait(display_prefetch_start_valid);
            check_second_pair_ticket();
            if(capture_requests!=2 || nn_launches!=2 || swaps!=2 || errors!=(SWAP_ERROR_COLLISION ? 1 : 0) ||
               dut.prefetch_request_is_new_q)
                $fatal(1,"second pair recovery counts/tag mismatch");
            if(SWAP_ERROR_COLLISION && (error_code!==8'h70 ||
               error_address!==(PREVIEW_DISPLAY ? 32'h00500000 : 32'h01000000)))
                $fatal(1,"committed swap error lost source address/code");
            if(qos_frame_active || qos_completed_frames!==1 || qos_protocol_errors!==0)
                $fatal(1,"committed-frame cancellation corrupted QoS lifecycle");
            $display("C1_SOC_CANCEL_QOS_PASS boundary=after completed=1 active=0 protocol_errors=0");
            $display("C1_SOC_SECOND_SWAP_ABORT_PASS preview=%0d ticket=%0d jobs=2 swaps=2 slots=0,1 new_ticket_stall=5 drain_hold=8 old_metadata_rejected=1",
                PREVIEW_DISPLAY,REGISTER_FATAL_TICKET_CFG);
            if(SWAP_ERROR_COLLISION)
                $display("C1_SOC_COMMITTED_SWAP_ERROR_PASS preview=%0d ticket=%0d errors=1 swaps=2 retained_slot=1",PREVIEW_DISPLAY,REGISTER_FATAL_TICKET_CFG);
            $finish;
        end

        // Directed capture fault.  The legacy path broadcasts immediately;
        // the registered build must capture an atomic code/address ticket,
        // present abort for the following complete cycle, and report exactly
        // once.  The earlier manual-abort check remains common to both modes
        // and proves software cancellation was not delayed.
        wait (!status_busy);
        pulse_start();
        @(negedge clk);
        capture_error_code = 8'h05;
        capture_error = 1'b1;
        #1;
        if (REGISTER_FATAL_TICKET_CFG != 0) begin
            if (capture_abort_frame || boardless_abort || error_event)
                $fatal(1, "registered fatal ticket leaked combinational abort");
        end else if (!capture_abort_frame || !boardless_abort) begin
            $fatal(1, "legacy fatal path did not broadcast immediately");
        end

        @(posedge clk); #1;
        if (REGISTER_FATAL_TICKET_CFG != 0) begin
            if (error_event)
                $fatal(1, "registered fatal ticket reported too early");
        end else if (!error_event || error_code != 8'h45 ||
                     error_address != 32'd0) begin
            $fatal(1, "legacy fatal report payload mismatch");
        end

        @(negedge clk); #1;
        if (REGISTER_FATAL_TICKET_CFG != 0 &&
            (!capture_abort_frame || !boardless_abort ||
             !display_prefetch_abort))
            $fatal(1, "registered fatal ticket did not broadcast for a full cycle");

        @(posedge clk); #1;
        if (REGISTER_FATAL_TICKET_CFG != 0 &&
            (!error_event || error_code != 8'h45 ||
             error_address != 32'd0))
            $fatal(1, "registered fatal report payload mismatch");

        @(negedge clk);
        capture_error = 1'b0;
        capture_error_code = 8'd0;
        tick(3);
        if (errors != 1)
            $fatal(1, "fatal ticket did not report exactly once");

        // A disabled armed transaction must still broadcast cancellation in
        // the same cycle.  This protects the immediate system-disable
        // contract while allowing RTL to qualify it with registered
        // ownership instead of feeding child busy back into the abort tree.
        wait (!status_busy);
        pulse_start();
        #1;
        if (!status_busy)
            $fatal(1, "disable-abort setup did not arm a transaction");
        boardless_busy = 1'b1;
        system_enable = 1'b0;
        #1;
        if (!parameter_abort_request || !capture_abort_frame ||
            !boardless_abort || !display_prefetch_abort)
            $fatal(1, "system disable did not broadcast immediate abort");
        @(posedge clk);
        @(negedge clk);
        boardless_busy = 1'b0;
        system_enable = 1'b1;
        tick(2);

        // No foreground job is armed, but a background display failure must
        // still report and trigger the same abort/flush broadcast.
        if (dut.run_armed_q) $fatal(1,"background fault setup still armed");
        display_prefetch_error = 1'b1;
        begin : background_fault_check
            integer broadcasts;
            broadcasts=0;
            repeat(8) begin
                @(negedge clk);
                if(display_prefetch_abort && display_flush_request) broadcasts++;
            end
            if(errors!=2 || broadcasts==0)
                $fatal(1,"background display error lost errors=%0d broadcasts=%0d",errors,broadcasts);
        end
        display_prefetch_error = 1'b0;
        tick(3);
        $display("C1_BACKGROUND_DISPLAY_ERROR_PASS fatal_ticket=%0d",REGISTER_FATAL_TICKET_CFG);
        $display("C1_R1_SOC_CONTROL_PASS capture=%0d nn=%0d prefetch=%0d swaps=%0d repeats=%0d errors=%0d fatal_ticket=%0d disable_abort=1",
                 capture_requests, nn_launches, prefetch_launches,
                 swaps, repeats, errors, REGISTER_FATAL_TICKET_CFG);
        if (DIFFERENT_RESOLVED_GEOMETRY) begin : reject_bad_source
            integer n, errors_before, launches_before;
            for (n=0;n<5;n++) begin
                @(negedge clk); rst=1;
                repeat(3) @(negedge clk);
                rst=0;
                input_frame_width = (n==0) ? 0 : ((n==1) ? ORIGINAL_WIDTH-4 : ORIGINAL_WIDTH);
                input_frame_height = (n==2) ? 0 : ((n==3) ? ORIGINAL_HEIGHT-1 : ORIGINAL_HEIGHT);
                errors_before=errors; launches_before=nn_launches;
                resize_y_step_q16 = (n==4) ? -1 : 32'sh10000;
                capture_frame_waiting=1;
                start_pulse=1;
                @(negedge clk);start_pulse=0;
                repeat(10) begin
                    @(negedge clk);
                    if (capture_writer_start || capture_table_request_valid ||
                        boardless_start_valid || parameter_start_valid)
                        $fatal(1,"invalid source geometry launched work");
                end
                if (errors!=errors_before+1 || error_code!=8'h12 || nn_launches!=launches_before)
                    $fatal(1,"invalid source geometry not rejected exactly once n=%0d",n);
                capture_frame_waiting=0;
            end
            $display("C1_SOC_INPUT_GEOMETRY_PASS source=%0dx%0d target=640x480 snapshot=1 invalid=5 resize_snapshot=1",ORIGINAL_WIDTH,ORIGINAL_HEIGHT);
        end
        // A child completion can coincide with the software ABORT edge.
        // The pending pair is discarded on that edge, so reporting DONE to
        // software would falsely advertise a frame that cannot be displayed.
        @(negedge clk);rst=1;
        repeat(2) @(negedge clk);rst=0;
        abort_pulse=1;boardless_done=1;
        @(posedge clk);#1;
        if(done_event || dut.pending_pair_valid_q || dut.manager_nn_done)
            $fatal(1,"ABORT and child DONE collision published success");
        @(negedge clk);abort_pulse=0;boardless_done=0;
        tick(2);
        $display("C1_SOC_ABORT_DONE_PRIORITY_PASS ticket=%0d no_false_done=1",REGISTER_FATAL_TICKET_CFG);

        // A registered fatal ticket delays cancellation, not the decision
        // whether the coincident result may be published as successful.
        begin : fatal_done_collision
            integer kind,errors_before;
            for(kind=0;kind<2;kind++) begin
                @(negedge clk);rst=1;
                repeat(2) @(negedge clk);rst=0;
                errors_before=errors;
                boardless_done=1;
                parameter_error=(kind==0);
                parameter_error_code=4'h3;
                parameter_error_address=32'h12345670;
                display_prefetch_error=(kind==1);
                @(posedge clk);#1;
                if(done_event || dut.pending_pair_valid_q || dut.manager_nn_done)
                    $fatal(1,"fatal and DONE collision published success kind=%0d ticket=%0d",kind,REGISTER_FATAL_TICKET_CFG);
                @(negedge clk);boardless_done=0;
                parameter_error=0;display_prefetch_error=0;
                repeat(4) begin
                    @(posedge clk);#1;
                    if(done_event || dut.pending_pair_valid_q || dut.manager_nn_done)
                        $fatal(1,"fatal collision published delayed success");
                end
                if(errors!=errors_before+1 || error_code!=(kind==0 ? 8'h23 : 8'h70))
                    $fatal(1,"fatal collision lost error report");
            end
            $display("C1_SOC_FATAL_DONE_PRIORITY_PASS ticket=%0d cases=2 no_false_done=1 error_once=1",REGISTER_FATAL_TICKET_CFG);
        end

        // A pulse protocol fault must permanently close admission, while
        // accepted fabric work still contributes to APB busy until retired.
        begin
            integer errors_before;
            @(negedge clk);errors_before=errors;
            fabric_write_busy=1;fabric_write_protocol_error=1;
            start_pulse=1;capture_frame_waiting=1;
            @(negedge clk);fabric_write_protocol_error=0;start_pulse=0;
            repeat(12) begin
                @(negedge clk);
                if(!status_busy || !capture_writer_cancel || !boardless_abort || !display_prefetch_abort ||
                   parameter_start_valid || boardless_start_valid || capture_table_request_valid || display_prefetch_start_valid)
                    $fatal(1,"fabric fault failed admission lock/drain fence");
            end
            if(errors!=errors_before+1 || error_code!=8'h14 || error_address!=0)
                $fatal(1,"fabric protocol error not reported exactly once");
            fabric_write_busy=0;capture_frame_waiting=0;
            repeat(4) @(negedge clk);
            // ABORT, disable/re-enable and fresh START cannot repair AXI state.
            abort_pulse=1;@(negedge clk);abort_pulse=0;
            system_enable=0;@(negedge clk);system_enable=1;
            pulse_start();
            repeat(6) begin
                @(negedge clk);
                if(parameter_start_valid || boardless_start_valid || display_prefetch_start_valid ||
                   !boardless_abort || dut.run_armed_q) $fatal(1,"fabric lock bypassed without reset");
            end
            rst=1;repeat(2) @(negedge clk);rst=0;
            pulse_start();@(negedge clk);
            if(dut.fabric_fault_active || !dut.run_armed_q || boardless_abort)
                $fatal(1,"common reset did not release fabric lock");
            $display("C1_SOC_FABRIC_FAULT_PASS ticket=%0d code=14 pulse_latched=1 pending_busy=1 reset_only_unlock=1",REGISTER_FATAL_TICKET_CFG);
        end
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "soc control timeout write_case=%0d cap_state=%0d status_busy=%b armed=%b input_ready=%0d nn_pending=%b nn_active=%b req=%b rsp=%b parameter_start=%b display_pending=%b prefetch_pending=%b",
            WRITE_REGION_CASE,dut.capture_state_q,status_busy,dut.run_armed_q,input_ready_count,
            dut.nn_launch_pending_q,dut.manager_nn_active,boardless_region_request,boardless_region_response,
            parameter_start_valid,dut.pending_pair_valid_q,dut.prefetch_request_pending_q);
    end
endmodule
