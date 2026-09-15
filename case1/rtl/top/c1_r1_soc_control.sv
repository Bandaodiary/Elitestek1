// Board-independent lifecycle controller for the final case-1 portable SoC.
// It coordinates parameter replacement, capture ownership/table lookup,
// frame jobs and tear-free display prefetch around c1_frame_manager.
module c1_r1_soc_control #(
    parameter integer REQUIRED_STAGES = 22,
    parameter logic [31:0] JOB_CYCLE_BUDGET = 32'd12000000,
    parameter integer REQUIRED_FRAME_WIDTH = 640,
    parameter integer REQUIRED_FRAME_HEIGHT = 480,
    // Optional synthesis-only fanout replication experiment.  It preserves
    // the cycle-accurate abort contract while allowing Vivado to build a
    // local broadcast tree for the high-fanout cancellation net.
    parameter integer REPLICATE_ABORT_CONTROL = 0,
    // Optional one-cycle fault ticket between combinational subsystem error
    // classification and the global abort broadcast.  Software ABORT and
    // system-disable cancellation remain immediate.  The ticket captures
    // code/address atomically, converts pulse errors into a full-cycle abort,
    // and cuts the long capture-error -> all-clients control path.
    parameter integer REGISTER_FATAL_TICKET = 0,
    // Requires burst-credit display response FIFOs in the integration.
    parameter integer CONCURRENT_DISPLAY_PREFETCH = 0,
    parameter integer SEPARATE_INPUT_GEOMETRY = 0,
    parameter integer REQUIRED_INPUT_WIDTH = REQUIRED_FRAME_WIDTH,
    parameter integer REQUIRED_INPUT_HEIGHT = REQUIRED_FRAME_HEIGHT,
    parameter integer CONFIGURABLE_RESIZE = 0,
    parameter integer ENABLE_FABRIC_FAULT = 0,
    // Static display-source selection. The producer must provide a completed
    // preview bound to the same output-slot lifetime, not live next-job CSR.
    parameter bit DISPLAY_RESIZED_PREVIEW = 1'b0,
    parameter bit CHECK_WRITE_REGIONS = 1'b0,
    parameter bit RESERVE_PREVIEW = DISPLAY_RESIZED_PREVIEW,
    parameter bit CHECK_TENSOR_ARENA = CHECK_WRITE_REGIONS,
    parameter bit CHECK_STATIC_ARENAS = CHECK_WRITE_REGIONS,
    parameter bit FENCE_FABRIC_DRAIN = 1'b0
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          system_enable,
    input  logic          continuous_mode,
    input  logic          drop_oldest_mode,
    input  logic          start_pulse,
    input  logic          abort_pulse,
    input  logic [15:0]   frame_width,
    input  logic [15:0]   frame_height,
    input  logic [3:0]    input_pixel_format,
    input  logic [3:0]    output_pixel_format,
    input  logic [63:0]   input_table_base,
    input  logic [63:0]   output_table_base,
    input  logic [63:0]   descriptor_base,
    input  logic [15:0]   descriptor_count,
    input  logic [63:0]   weight_base,
    input  logic [31:0]   tensor_base_addr,

    output logic          status_busy,
    output logic          done_event,
    output logic          error_event,
    output logic [7:0]    error_code,
    output logic [31:0]   error_address,
    output logic          capture_drop_event,
    output logic          display_swap_event,
    // Pulses only when a newly completed CNN output pair (rather than a
    // background refresh of the currently displayed pair) has drained.
    // This is the unambiguous terminal event for per-job QoS accounting.
    output logic          display_prefetch_new_done_event,
    output logic [2:0]    input_ready_count,
    output logic [1:0]    output_ready_count,
    output logic [31:0]   display_frame_id,
    output logic          display_feed_active,
    output logic          display_hold_requests,

    // Parameter loader/bank lifecycle.
    output logic          parameter_start_valid,
    input  logic          parameter_start_ready,
    output logic [31:0]   parameter_base_addr,
    output logic          parameter_abort_request,
    input  logic          parameter_abort_pending,
    input  logic          parameter_busy,
    input  logic          parameter_done,
    input  logic          parameter_error,
    input  logic          parameter_aborted,
    input  logic [3:0]    parameter_error_code,
    input  logic [31:0]   parameter_error_address,
    input  logic          parameter_active_valid,
    input  logic [31:0]   parameter_generation,
    output logic [31:0]   active_parameter_generation,

    // Capture frontend/table reader/writer lifecycle.
    input  logic          capture_frame_waiting,
    input  logic          capture_begin_ready,
    output logic          capture_begin_frame,
    output logic          capture_drop_frame,
    output logic          capture_abort_frame,
    output logic          capture_clear_error,
    output logic          capture_discard_idle,
    input  logic          capture_cleanup_busy,
    input  logic          capture_ingress_done,
    input  logic          capture_frame_dropped,
    input  logic          capture_frame_aborted,
    input  logic          capture_error,
    input  logic [7:0]    capture_error_code,

    output logic          capture_table_request_valid,
    input  logic          capture_table_request_ready,
    output logic [63:0]   capture_table_request_base,
    output logic [1:0]    capture_table_request_index,
    input  logic          capture_table_response_valid,
    output logic          capture_table_response_ready,
    input  logic          capture_table_response_error,
    input  logic [63:0]   capture_table_response_base,
    input  logic [31:0]   capture_table_response_stride,
    input  logic [15:0]   capture_table_response_width,
    input  logic [15:0]   capture_table_response_height,
    output logic          capture_table_abort_request,
    input  logic          capture_table_abort_pending,

    output logic          capture_writer_start,
    output logic          capture_writer_cancel,
    output logic [31:0]   capture_writer_base,
    output logic [31:0]   capture_writer_stride,
    output logic [15:0]   capture_writer_width,
    output logic [15:0]   capture_writer_height,
    input  logic          capture_writer_busy,
    input  logic          capture_writer_done,
    input  logic          capture_writer_error,

    // Boardless frame job.
    output logic          boardless_start_valid,
    input  logic          boardless_start_ready,
    output logic          boardless_abort,
    output logic [1:0]    boardless_input_index,
    output logic [1:0]    boardless_output_index,
    output logic [63:0]   boardless_input_table_base,
    output logic [63:0]   boardless_output_table_base,
    output logic [15:0]   boardless_frame_width,
    output logic [15:0]   boardless_frame_height,
    output logic [31:0]   boardless_descriptor_base,
    output logic [15:0]   boardless_descriptor_count,
    output logic [31:0]   boardless_cycle_budget,
    output logic [31:0]   boardless_tensor_base_addr,
    input  logic          boardless_busy,
    input  logic          boardless_done,
    input  logic          boardless_error,
    input  logic          boardless_aborted,
    input  logic [7:0]    boardless_error_code,
    input  logic [31:0]   boardless_error_address,
    input  logic [31:0]   boardless_resolved_input_base,
    input  logic [31:0]   boardless_resolved_input_stride,
    input  logic [15:0]   boardless_resolved_input_width,
    input  logic [15:0]   boardless_resolved_input_height,
    input  logic [31:0]   boardless_resolved_output_base,
    input  logic [31:0]   boardless_resolved_output_stride,
    input  logic [15:0]   boardless_resolved_output_width,
    input  logic [15:0]   boardless_resolved_output_height,

    // Display pair prefetch. display_frame_start_event is a core-clock pulse
    // crossed from pixel-domain x=0/y=0, leaving 120 active lines before the
    // compositor first requests image data.
    input  logic          display_frame_start_event,
    output logic          display_prefetch_start_valid,
    input  logic          display_prefetch_start_ready,
    output logic          display_prefetch_abort,
    output logic          display_flush_request,
    input  logic          display_flush_busy,
    output logic [31:0]   display_original_base,
    output logic [31:0]   display_original_stride,
    output logic [31:0]   display_styled_base,
    output logic [31:0]   display_styled_stride,
    output logic [15:0]   display_width,
    output logic [15:0]   display_height,
    input  logic          display_prefetch_busy,
    input  logic          display_prefetch_done,
    input  logic          display_prefetch_aborted,
    input  logic          display_prefetch_error,
    input  logic          display_prefetch_primed,
    // Original-frame geometry belongs to the same ownership snapshot as its
    // address/stride. display_width/height retain their styled-frame meaning.
    output logic [15:0]   display_original_width,
    output logic [15:0]   display_original_height,
    // frame_width/height remain the target dimensions. Source dimensions
    // are sampled atomically at accepted START only in separate mode.
    input  logic [15:0]   input_frame_width,
    input  logic [15:0]   input_frame_height,
    output logic [15:0]   boardless_input_width,
    output logic [15:0]   boardless_input_height,
    input logic signed [31:0] resize_x_step_q16,
    output logic signed [31:0] boardless_x_step_q16,
    input logic signed [31:0] resize_y_step_q16,
    output logic signed [31:0] boardless_y_step_q16,
    input logic signed [31:0] resize_x_phase0_q16,
    output logic signed [31:0] boardless_x_phase0_q16,
    input logic signed [31:0] resize_y_phase0_q16,
    output logic signed [31:0] boardless_y_phase0_q16,
    input logic fabric_write_protocol_error,
    input logic fabric_write_busy,
    input logic [31:0] boardless_resolved_preview_base,
    input logic [31:0] boardless_resolved_preview_stride,
    output wire [96:0] boardless_expected_input,
    input logic boardless_region_request,boardless_region_cancel,
    output wire boardless_region_response,
    output wire [7:0] boardless_region_error_code,
    output wire [31:0] boardless_region_error_address,
    input logic fabric_read_quiescent,fabric_write_quiescent
);

    localparam logic [7:0] ERR_WEIGHT_ADDRESS = 8'h11;
    localparam logic [7:0] ERR_DESCRIPTOR_ADDRESS = 8'h12;
    localparam logic [7:0] ERR_TENSOR_ADDRESS = 8'h13;
    localparam logic [7:0] ERR_FABRIC_WRITE = 8'h14;
    localparam logic [7:0] ERR_STATIC_MEMORY = 8'h15;
    localparam logic [7:0] ERR_PARAMETER = 8'h20;
    localparam logic [7:0] ERR_CAPTURE_TABLE = 8'h30;
    localparam logic [7:0] ERR_CAPTURE_CONFIG = 8'h31;
    localparam logic [7:0] ERR_CAPTURE_FRONTEND = 8'h40;
    localparam logic [7:0] ERR_CAPTURE_WRITER = 8'h50;
    localparam logic [7:0] ERR_DISPLAY = 8'h70;

    typedef enum logic [2:0] {
        CAP_IDLE,
        CAP_WAIT_ALLOCATION,
        CAP_TABLE_REQUEST,
        CAP_TABLE_RESPONSE,
        CAP_STREAM,
        CAP_GUARD_PREP,
        CAP_GUARD_WAIT,
        CAP_GUARD_COMMIT
    } capture_state_t;

    capture_state_t capture_state_q;
    logic run_armed_q;
    logic [63:0] loaded_weight_base_q;
    logic [63:0] parameter_load_base_q;
    logic [15:0] cfg_frame_width_q;
    logic [15:0] cfg_frame_height_q;
    logic [15:0] cfg_input_width_q, cfg_input_height_q;
    logic signed [31:0] cfg_x_step_q;
    logic signed [31:0] cfg_y_step_q;
    logic signed [31:0] cfg_x_phase0_q;
    logic signed [31:0] cfg_y_phase0_q;
    logic cfg_continuous_mode_q;
    logic cfg_drop_oldest_mode_q;
    logic [3:0] cfg_input_pixel_format_q;
    logic [3:0] cfg_output_pixel_format_q;
    logic [63:0] cfg_input_table_base_q;
    logic [63:0] cfg_output_table_base_q;
    logic [63:0] cfg_descriptor_base_q;
    logic [15:0] cfg_descriptor_count_q;
    logic [63:0] cfg_weight_base_q;
    logic [31:0] cfg_tensor_base_q;
    logic parameter_matches;
    logic weight_address_legal;
    logic descriptor_address_legal;
    logic tensor_address_legal;
    logic job_config_legal;
    logic fatal_now;
    logic [7:0] fatal_code;
    logic [31:0] fatal_address;
    logic fatal_abort_now;
    logic fatal_report_now;
    logic fabric_fault_q, fabric_fault_active;
    assign fabric_fault_active = (ENABLE_FABRIC_FAULT != 0) &&
                                 (fabric_fault_q || fabric_write_protocol_error);
    // Protocol corruption is not a recoverable image/job error. Only reset
    // of the common fabric/control domain releases this admission lock.
    always_ff @(posedge clk) begin
        if (rst) fabric_fault_q <= 1'b0;
        else if (ENABLE_FABRIC_FAULT != 0 && fabric_write_protocol_error)
            fabric_fault_q <= 1'b1;
    end
    logic [7:0] fatal_report_code;
    logic [31:0] fatal_report_address;
    logic manager_abort;
    logic manager_abort_raw;
    // Keep the attribute on the actual high-fanout cancellation branch, not
    // on a one-sink raw-to-alias net.  The disabled branch is a direct alias
    // and is optimized to the historical netlist.
    generate
        if (REPLICATE_ABORT_CONTROL != 0) begin : g_abort_replicated
            (* keep = "true", max_fanout = 16 *) logic manager_abort_rep;
            assign manager_abort_rep = manager_abort_raw;
            assign manager_abort = manager_abort_rep;
        end else begin : g_abort_direct
            assign manager_abort = manager_abort_raw;
        end
    endgenerate

    generate
        if (REGISTER_FATAL_TICKET != 0) begin : g_registered_fatal_ticket
            logic fatal_ticket_valid_q;
            logic fatal_ticket_seen_q;
            logic [7:0] fatal_ticket_code_q;
            logic [31:0] fatal_ticket_address_q;

            assign fatal_abort_now = fatal_ticket_valid_q;
            assign fatal_report_now = fatal_ticket_valid_q;
            assign fatal_report_code = fatal_ticket_code_q;
            assign fatal_report_address = fatal_ticket_address_q;

            always_ff @(posedge clk) begin
                if (rst || abort_pulse || !system_enable) begin
                    fatal_ticket_valid_q <= 1'b0;
                    fatal_ticket_seen_q <= 1'b0;
                    fatal_ticket_code_q <= 8'd0;
                    fatal_ticket_address_q <= 32'd0;
                end else begin
                    // A ticket is presented for one complete cycle.  Sticky
                    // sources cannot retrigger until they have deasserted;
                    // pulse sources are retained by the ticket itself.
                    if (fatal_ticket_valid_q)
                        fatal_ticket_valid_q <= 1'b0;
                    if (!fatal_now)
                        fatal_ticket_seen_q <= 1'b0;
                    if (fatal_now && !fatal_ticket_seen_q &&
                        !fatal_ticket_valid_q) begin
                        fatal_ticket_valid_q <= 1'b1;
                        fatal_ticket_seen_q <= 1'b1;
                        fatal_ticket_code_q <= fatal_code;
                        fatal_ticket_address_q <= fatal_address;
                    end
                end
            end
        end else begin : g_direct_fatal
            logic fatal_report_seen_q;
            assign fatal_abort_now = fatal_now;
            // Preserve immediate level cancellation, but report a sticky
            // fault only once until it clears (same event contract as tickets).
            assign fatal_report_now = fatal_now && !fatal_report_seen_q;
            assign fatal_report_code = fatal_code;
            assign fatal_report_address = fatal_address;
            always_ff @(posedge clk) begin
                if (rst || abort_pulse || !system_enable || !fatal_now)
                    fatal_report_seen_q <= 1'b0;
                else
                    fatal_report_seen_q <= 1'b1;
            end
        end
    endgenerate

    logic manager_cap_start;
    logic manager_cap_done;
    logic manager_cap_accept;
    logic manager_cap_drop;
    logic [1:0] manager_cap_index;
    logic [31:0] manager_cap_frame_id;
    logic manager_nn_request;
    logic manager_nn_done;
    logic manager_nn_grant;
    logic [1:0] manager_nn_input_index;
    logic manager_nn_output_index;
    logic [31:0] manager_nn_frame_id;
    logic [31:0] manager_display_frame_id;
    logic manager_display_vsync;
    logic manager_display_swap;
    logic [1:0] manager_display_input_index;
    logic manager_display_output_index;
    logic manager_display_active;
    logic manager_capture_active;
    logic manager_nn_active;
    logic [31:0] manager_dropped_count;

    logic capture_ingress_done_seen_q;
    logic capture_writer_done_seen_q;
    logic capture_table_fault_now;
    logic capture_table_config_fault_now;
    logic capture_complete_now;
    logic nn_launch_pending_q;
    logic [1:0] nn_input_index_q;
    logic [1:0] nn_output_index_q;
    logic [31:0] nn_frame_id_q;

    logic pending_pair_valid_q;
    logic [1:0] pending_input_index_q;
    logic pending_output_index_q;
    logic [31:0] pending_frame_id_q;
    logic [31:0] pending_original_base_q;
    logic [31:0] pending_original_stride_q;
    logic [31:0] pending_styled_base_q;
    logic [31:0] pending_styled_stride_q;
    logic [15:0] pending_width_q;
    logic [15:0] pending_height_q;
    logic [15:0] pending_original_width_q, pending_original_height_q;

    logic current_pair_valid_q;
    logic [31:0] current_original_base_q;
    logic [31:0] current_original_stride_q;
    logic [31:0] current_styled_base_q;
    logic [31:0] current_styled_stride_q;
    logic [15:0] current_width_q;
    logic [15:0] current_height_q;
    logic [15:0] current_original_width_q, current_original_height_q;

    logic prefetch_request_pending_q;
    logic prefetch_request_is_new_q;
    logic [31:0] prefetch_request_original_base_q;
    logic [31:0] prefetch_request_original_stride_q;
    logic [31:0] prefetch_request_styled_base_q;
    logic [31:0] prefetch_request_styled_stride_q;
    logic [15:0] prefetch_request_width_q;
    logic [15:0] prefetch_request_height_q;
    logic [15:0] prefetch_request_original_width_q;
    logic [15:0] prefetch_request_original_height_q;
    logic prefetch_loading_new_q;
    // Transaction-local tag.  prefetch_loading_new_q is an ownership flag
    // and may be cleared by VSYNC before the reader/FIFO drain pulse arrives;
    // keep this independent tag until that active prefetch actually finishes.
    logic prefetch_active_is_new_q;
    logic display_swap_requested_q;

    // prefetch_active_is_new_q is latched at each prefetch start and retained
    // across the VSYNC ownership commit.  It is cleared only by the matching
    // done/abort pulse, so a periodic refresh of current_pair cannot look like
    // an additional CNN job completion. Reader done also marks failed/aborted
    // terminals; only success may close a completed-frame QoS sample. A raw
    // fault veto must not wait for the optional registered cleanup ticket.
    assign display_prefetch_new_done_event =
        display_prefetch_done && prefetch_active_is_new_q &&
        !display_prefetch_aborted && !display_prefetch_error &&
        !manager_abort && !fatal_now;

    logic operation_enable;
    logic capture_admission_open;
    logic single_capture_admitted_q;
    logic parameter_reload_needed;
    logic parameter_start_fire;
    logic boardless_start_fire;
    logic display_prefetch_start_fire;
    logic abort_due_disable;
    logic capture_cleanup_fence_q;

    logic [3:0] capture_guard_phase_q;
    localparam logic [3:0] CAPTURE_LAST_REGION = CHECK_STATIC_ARENAS ? 4'd9 :
        (CHECK_TENSOR_ARENA ? 4'd5 : (CHECK_WRITE_REGIONS ? 4'd4 : 4'd2));
    // Matches the portable SoC adapter: three fixed 8-MiB tensor banks.
    wire [32:0] tensor_region_begin={1'b0,cfg_tensor_base_q};
    wire [32:0] tensor_region_end={1'b0,cfg_tensor_base_q}+33'h1800000;
    // Four read-only artifacts with lengths dictated by the actual readers:
    // parameter image, descriptors, three input entries, two output entries.
    wire [3:0][32:0] static_region_begin,static_region_end;
    assign static_region_begin={{1'b0,cfg_output_table_base_q[31:0]},
        {1'b0,cfg_input_table_base_q[31:0]},{1'b0,cfg_descriptor_base_q[31:0]},
        {1'b0,cfg_weight_base_q[31:0]}};
    assign static_region_end[0]=static_region_begin[0]+33'd16896;
    assign static_region_end[1]=static_region_begin[1]+{11'd0,cfg_descriptor_count_q,6'd0};
    assign static_region_end[2]=static_region_begin[2]+33'd48;
    assign static_region_end[3]=static_region_begin[3]+33'd32;
    logic static_memory_legal;
    logic [31:0] static_bad_address;
    logic static_memory_legal_d;
    logic [31:0] static_bad_address_d;
    wire [3:0][32:0] start_static_begin,start_static_end;
    wire [32:0] start_tensor_begin={1'b0,tensor_base_addr};
    wire [32:0] start_tensor_end={1'b0,tensor_base_addr}+33'h1800000;
    assign start_static_begin={{1'b0,output_table_base[31:0]},{1'b0,input_table_base[31:0]},
                              {1'b0,descriptor_base[31:0]},{1'b0,weight_base[31:0]}};
    assign start_static_end[0]=start_static_begin[0]+33'd16896;
    assign start_static_end[1]=start_static_begin[1]+{11'd0,descriptor_count,6'd0};
    assign start_static_end[2]=start_static_begin[2]+33'd48;
    assign start_static_end[3]=start_static_begin[3]+33'd32;
    always_comb begin
        static_memory_legal_d=1;static_bad_address_d=0;
        for(integer r=0;r<4;r=r+1) begin
            if(CHECK_STATIC_ARENAS && static_memory_legal_d &&
               (start_static_begin[r]>=start_static_end[r] ||
                start_static_end[r]>33'h100000000 ||
                (start_static_begin[r]<start_tensor_end && start_tensor_begin<start_static_end[r]))) begin
                static_memory_legal_d=0;static_bad_address_d=32'(start_static_begin[r]);
            end
        end
    end
    // Validate and snapshot on the SAME accepted START edge as cfg_*.
    // The wide comparisons are not recomputed on the running abort/start
    // fanout path, and subsequent live CSR edits cannot change this decision.
    always_ff @(posedge clk) begin
        if(rst) begin static_memory_legal<=1;static_bad_address<=0;end
        else if(system_enable&&!abort_pulse&&!fabric_fault_active&&start_pulse&&!status_busy) begin
            static_memory_legal<=static_memory_legal_d;static_bad_address<=static_bad_address_d;
        end
    end
    logic capture_guard_dirty_q;
    logic [2:0] input_owned_mask, input_region_valid_q;
    logic [2:0][31:0] input_region_base_q,input_region_stride_q;
    logic [2:0][15:0] input_region_width_q,input_region_height_q;
    logic input_region_cancel_hold_q;
    logic [1:0] input_region_left,input_region_right;
    logic input_region_any;
    wire [1:0] output_owned_mask;
    logic [1:0] output_region_valid_q;
    logic [1:0][31:0] output_region_base_q,output_region_stride_q;
    logic [1:0][31:0] preview_region_base_q,preview_region_stride_q;
    logic [1:0][15:0] output_region_width_q,output_region_height_q;
    wire region_check_busy,region_check_response;
    wire region_check_cancel=!CHECK_WRITE_REGIONS||rst||manager_abort||
                            boardless_region_cancel||!boardless_region_request;
    wire capture_admission_busy=(capture_state_q==CAP_GUARD_PREP)||
        (capture_state_q==CAP_GUARD_WAIT)||(capture_state_q==CAP_GUARD_COMMIT);
    wire region_check_request=CHECK_WRITE_REGIONS&&boardless_region_request&&
        !capture_admission_busy&&!capture_writer_start&&!region_check_cancel;
    logic region_committed_q;
    logic [6:0] held_image_valid;
    logic [6:0][31:0] held_image_base,held_image_stride;
    logic [6:0][15:0] held_image_width,held_image_height;
    always_comb begin
        held_image_valid='0;held_image_base='0;held_image_stride='0;
        held_image_width='0;held_image_height='0;
        for(integer r=0;r<3;r=r+1) begin
            held_image_valid[r]=input_region_valid_q[r];
            held_image_base[r]=input_region_base_q[r];held_image_stride[r]=input_region_stride_q[r];
            held_image_width[r]=input_region_width_q[r];held_image_height[r]=input_region_height_q[r];
        end
        for(integer r=0;r<2;r=r+1) begin
            held_image_valid[3+r]=output_region_valid_q[r]&&(nn_output_index_q!=r);
            held_image_valid[5+r]=held_image_valid[3+r]&&RESERVE_PREVIEW;
            held_image_base[3+r]=output_region_base_q[r];held_image_stride[3+r]=output_region_stride_q[r];
            held_image_base[5+r]=preview_region_base_q[r];held_image_stride[5+r]=preview_region_stride_q[r];
            held_image_width[3+r]=output_region_width_q[r];held_image_height[3+r]=output_region_height_q[r];
            held_image_width[5+r]=output_region_width_q[r];held_image_height[5+r]=output_region_height_q[r];
        end
    end
    c1_frame_write_region_guard #(.CHECK_TENSOR_ARENA(CHECK_TENSOR_ARENA),
                                .CHECK_STATIC_ARENAS(CHECK_STATIC_ARENAS)) u_write_region_guard (
        .tensor_begin(tensor_region_begin),.tensor_end(tensor_region_end),
        .static_begin(static_region_begin),.static_end(static_region_end),
        .clk(clk),.rst(rst),.cancel(region_check_cancel),.req_valid(region_check_request),
        .busy(region_check_busy),.writer_valid({RESERVE_PREVIEW,1'b1}),
        .writer_base({boardless_resolved_preview_base,boardless_resolved_output_base}),
        .writer_stride({boardless_resolved_preview_stride,boardless_resolved_output_stride}),
        .writer_width({2{boardless_resolved_output_width}}),.writer_height({2{boardless_resolved_output_height}}),
        .held_valid(held_image_valid),.held_base(held_image_base),.held_stride(held_image_stride),
        .held_width(held_image_width),.held_height(held_image_height),
        .rsp_valid(region_check_response),.error_code(boardless_region_error_code),
        .error_address(boardless_region_error_address)
    );
    assign boardless_region_response=region_check_response&&!region_check_cancel;
    // Reserve at acceptance, not at final DMA completion. The frame-manager
    // ownership bit retains READY_DISPLAY/current-display contents. On abort,
    // reuse the input directory's drain hold before releasing freed slots.
    always_ff @(posedge clk) begin
        if(rst) begin
            output_region_valid_q<=0;region_committed_q<=0;
            output_region_base_q<='0;output_region_stride_q<='0;
            preview_region_base_q<='0;preview_region_stride_q<='0;
            output_region_width_q<='0;output_region_height_q<='0;
        end else begin
            if(region_check_cancel) region_committed_q<=0;
            for(integer r=0;r<2;r=r+1)
                if(!output_owned_mask[r]&&!manager_abort&&!input_region_cancel_hold_q)
                    output_region_valid_q[r]<=0;
            if(boardless_region_response&&boardless_region_error_code==0&&!region_committed_q) begin
                region_committed_q<=1;
                output_region_valid_q[nn_output_index_q[0]]<=1;
                output_region_base_q[nn_output_index_q[0]]<=boardless_resolved_output_base;
                output_region_stride_q[nn_output_index_q[0]]<=boardless_resolved_output_stride;
                preview_region_base_q[nn_output_index_q[0]]<=boardless_resolved_preview_base;
                preview_region_stride_q[nn_output_index_q[0]]<=boardless_resolved_preview_stride;
                output_region_width_q[nn_output_index_q[0]]<=boardless_resolved_output_width;
                output_region_height_q[nn_output_index_q[0]]<=boardless_resolved_output_height;
            end
        end
    end
    assign boardless_expected_input={input_region_valid_q[nn_input_index_q],
        input_region_base_q[nn_input_index_q],input_region_stride_q[nn_input_index_q],
        input_region_width_q[nn_input_index_q],input_region_height_q[nn_input_index_q]};
    // Physical snapshots survive abort's control-register clear. Logical
    // FREE is sufficient normally, but cancellation also requires DMA drain.
    always_ff @(posedge clk) begin
        if(rst) begin
            input_region_valid_q<=0;input_region_cancel_hold_q<=0;
            input_region_base_q<='0;input_region_stride_q<='0;
            input_region_width_q<='0;input_region_height_q<='0;
        end else begin
            if(manager_abort) input_region_cancel_hold_q<=1;
            else if(!capture_writer_busy && !boardless_busy && !capture_cleanup_fence_q &&
                    (!FENCE_FABRIC_DRAIN || (fabric_read_quiescent && fabric_write_quiescent &&
                     !parameter_busy && !parameter_abort_pending && capture_table_request_ready &&
                     !capture_table_abort_pending && !display_prefetch_busy && !display_flush_busy)))
                input_region_cancel_hold_q<=0;
            for(integer r=0;r<3;r=r+1) begin
                if(!input_owned_mask[r] && !manager_abort && !input_region_cancel_hold_q)
                    input_region_valid_q[r]<=0;
            end
            if(capture_writer_start && !manager_abort) begin
                input_region_valid_q[manager_cap_index]<=1;
                input_region_base_q[manager_cap_index]<=capture_writer_base;
                input_region_stride_q[manager_cap_index]<=capture_writer_stride;
                input_region_width_q[manager_cap_index]<=capture_writer_width;
                input_region_height_q[manager_cap_index]<=capture_writer_height;
            end
        end
    end
    // At most two OTHER input slots can be reserved. Duplicate the one
    // remaining reader when only one exists; read/read alias is permitted.
    always_comb begin
        input_region_left=0;input_region_right=0;input_region_any=0;
        for(integer r=0;r<3;r=r+1) begin
            if(input_region_valid_q[r] && r!=manager_cap_index) begin
                if(!input_region_any) input_region_left=2'(r);
                input_region_right=2'(r);input_region_any=1;
            end
        end
    end
    logic capture_guard_req, capture_guard_ready, capture_guard_response;
    logic [1:0] capture_guard_code;
    wire capture_layout_ready,capture_layout_response,capture_arena_ready,capture_arena_response;
    wire [1:0] capture_layout_code,capture_arena_code;
    assign capture_guard_ready=capture_guard_phase_q>=5 ? capture_arena_ready : capture_layout_ready;
    assign capture_guard_response=capture_guard_phase_q>=5 ? capture_arena_response : capture_layout_response;
    assign capture_guard_code=capture_guard_phase_q>=5 ? capture_arena_code : capture_layout_code;
    logic [2:0][31:0] capture_guard_base, capture_guard_stride;
    logic [2:0][15:0] capture_guard_width, capture_guard_height;
    wire capture_guard_changed = manager_display_swap || boardless_done;
    wire capture_guard_pair_valid = capture_guard_phase_q>=5 ?
        (capture_guard_phase_q!=5 || CHECK_TENSOR_ARENA) :
        capture_guard_phase_q>=3 ? output_region_valid_q[capture_guard_phase_q==4] :
        capture_guard_phase_q==2 ? input_region_any :
        (capture_guard_phase_q==1 ? pending_pair_valid_q : current_pair_valid_q);
    // No generation counter can wrap while a long row comparison is stalled.
    // Any publication during checking forces a fresh pass over all groups.
    always_ff @(posedge clk) begin
        if(rst || manager_abort) capture_guard_dirty_q<=0;
        else if(capture_guard_changed) capture_guard_dirty_q<=1;
        else if(capture_state_q==CAP_GUARD_PREP && !capture_guard_phase_q &&
                (!capture_guard_pair_valid || capture_guard_ready)) capture_guard_dirty_q<=0;
    end
    always_comb begin
        capture_guard_req=(capture_state_q==CAP_GUARD_PREP) && capture_guard_pair_valid && !manager_abort && !region_check_busy;
        capture_guard_base[0]=capture_writer_base;
        capture_guard_stride[0]=capture_writer_stride;
        capture_guard_width[0]=capture_writer_width;
        capture_guard_height[0]=capture_writer_height;
        capture_guard_base[1]=capture_guard_phase_q ? pending_original_base_q : current_original_base_q;
        capture_guard_stride[1]=capture_guard_phase_q ? pending_original_stride_q : current_original_stride_q;
        capture_guard_width[1]=capture_guard_phase_q ? pending_original_width_q : current_original_width_q;
        capture_guard_height[1]=capture_guard_phase_q ? pending_original_height_q : current_original_height_q;
        capture_guard_base[2]=capture_guard_phase_q ? pending_styled_base_q : current_styled_base_q;
        capture_guard_stride[2]=capture_guard_phase_q ? pending_styled_stride_q : current_styled_stride_q;
        capture_guard_width[2]=capture_guard_phase_q ? pending_width_q : current_width_q;
        capture_guard_height[2]=capture_guard_phase_q ? pending_height_q : current_height_q;
        if(capture_guard_phase_q==2) begin
            capture_guard_base[1]=input_region_base_q[input_region_left];
            capture_guard_stride[1]=input_region_stride_q[input_region_left];
            capture_guard_width[1]=input_region_width_q[input_region_left];
            capture_guard_height[1]=input_region_height_q[input_region_left];
            capture_guard_base[2]=input_region_base_q[input_region_right];
            capture_guard_stride[2]=input_region_stride_q[input_region_right];
            capture_guard_width[2]=input_region_width_q[input_region_right];
            capture_guard_height[2]=input_region_height_q[input_region_right];
        end
        if(capture_guard_phase_q>=3) begin
            capture_guard_base[1]=output_region_base_q[capture_guard_phase_q==4];
            capture_guard_stride[1]=output_region_stride_q[capture_guard_phase_q==4];
            capture_guard_width[1]=output_region_width_q[capture_guard_phase_q==4];
            capture_guard_height[1]=output_region_height_q[capture_guard_phase_q==4];
            capture_guard_base[2]=RESERVE_PREVIEW ? preview_region_base_q[capture_guard_phase_q==4] : capture_guard_base[1];
            capture_guard_stride[2]=RESERVE_PREVIEW ? preview_region_stride_q[capture_guard_phase_q==4] : capture_guard_stride[1];
            capture_guard_width[2]=capture_guard_width[1];
            capture_guard_height[2]=capture_guard_height[1];
        end
    end
    c1_frame_triple_layout_check #(.CHECK_PAIR_MASK(3'b011)) u_capture_display_guard (
        .clk(clk),.rst(rst),.cancel(manager_abort),
        .req_valid(capture_guard_req&&capture_guard_phase_q<5),.req_ready(capture_layout_ready),
        .frame_base(capture_guard_base),.frame_stride(capture_guard_stride),
        .frame_width(capture_guard_width),.frame_height(capture_guard_height),
        .busy(),.rsp_valid(capture_layout_response),.rsp_ready(1'b1),
        .error_code(capture_layout_code),.error_index()
    );
    c1_frames_arena_check u_capture_tensor_guard (
        .clk(clk),.rst(rst),.cancel(manager_abort),
        .req_valid(capture_guard_req&&capture_guard_phase_q>=5),.req_ready(capture_arena_ready),
        .arena_begin(capture_guard_phase_q==5 ? tensor_region_begin : static_region_begin[capture_guard_phase_q-4'd6]),
        .arena_end(capture_guard_phase_q==5 ? tensor_region_end : static_region_end[capture_guard_phase_q-4'd6]),.frame_valid(1'b1),
        .frame_base(capture_writer_base),.frame_stride(capture_writer_stride),
        .frame_width(capture_writer_width),.frame_height(capture_writer_height),
        .busy(),.rsp_valid(capture_arena_response),.rsp_ready(1'b1),
        .error_code(capture_arena_code),.error_index()
    );

    always_comb begin
        operation_enable = system_enable && run_armed_q && !fabric_fault_active;
        weight_address_legal = (cfg_weight_base_q[63:32] == 0) &&
                               (cfg_weight_base_q[3:0] == 0);
        descriptor_address_legal =
            (cfg_descriptor_base_q[63:32] == 0) &&
            (cfg_descriptor_base_q[5:0] == 0) &&
            (cfg_descriptor_count_q == REQUIRED_STAGES);
        tensor_address_legal = (cfg_tensor_base_q[22:0] == 0) &&
            (cfg_tensor_base_q <= 32'hfe80_0000);
        job_config_legal =
            !cfg_y_step_q[31] &&
            (cfg_frame_width_q == REQUIRED_FRAME_WIDTH) &&
            (cfg_frame_height_q == REQUIRED_FRAME_HEIGHT) &&
            (cfg_input_width_q != 0) && (cfg_input_height_q != 0) &&
            (cfg_input_width_q == (SEPARATE_INPUT_GEOMETRY ? REQUIRED_INPUT_WIDTH : REQUIRED_FRAME_WIDTH)) &&
            (cfg_input_height_q == (SEPARATE_INPUT_GEOMETRY ? REQUIRED_INPUT_HEIGHT : REQUIRED_FRAME_HEIGHT)) &&
            (cfg_input_pixel_format_q == 4'd2) &&
            (cfg_output_pixel_format_q == 4'd2) &&
            (cfg_input_table_base_q[63:32] == 0) &&
            (cfg_output_table_base_q[63:32] == 0) &&
            (cfg_input_table_base_q[3:0] == 0) &&
            (cfg_output_table_base_q[3:0] == 0) &&
            descriptor_address_legal && tensor_address_legal;
        capture_admission_open = operation_enable && job_config_legal && static_memory_legal &&
            (cfg_continuous_mode_q || !single_capture_admitted_q);
        parameter_matches = parameter_active_valid &&
                            (loaded_weight_base_q == cfg_weight_base_q);
        // parameter_done and loaded_weight_base_q are both registered.  On
        // the commit edge parameter_matches still reflects the old loaded
        // base, so without this fence the controller can launch a second
        // reload in the one-cycle gap before loaded_weight_base_q updates.
        // That would increment the parameter generation while a boardless
        // job is already consuming the first bank.  Treat the completion
        // pulse as an in-flight transaction until the sampled base catches
        // up on the following clock.
        parameter_reload_needed = operation_enable &&
                                  !parameter_matches &&
                                  !parameter_busy &&
                                  !parameter_done &&
                                  !boardless_busy;
        // A registered fatal ticket delays the abort broadcast by one cycle.
        // Reject invalid launch contracts here, before any external work.
        parameter_start_valid = parameter_reload_needed &&
                                weight_address_legal && job_config_legal && static_memory_legal;
        parameter_base_addr = cfg_weight_base_q[31:0];
        parameter_start_fire =
            parameter_start_valid && parameter_start_ready;
        active_parameter_generation = parameter_generation;

        // The portable DDR seam currently has one global ID-less read
        // response owner.  Display prefetch is a background service, but a
        // stalled display R beat can hold that owner while the tensor engine
        // waits for a cache miss.  Admit a foreground CNN job only after the
        // background pair service is quiescent; this preserves forward
        // progress without pretending the single-outstanding fabric supports
        // independent read responses. The optional concurrent policy removes
        // this background-only exclusion when the integration provides full
        // burst response credit. Pending/new pair ownership remains fenced.
        manager_nn_request = operation_enable && parameter_matches &&
                             job_config_legal && static_memory_legal &&
                             !pending_pair_valid_q &&
                             !nn_launch_pending_q &&
                             ((CONCURRENT_DISPLAY_PREFETCH != 0) ||
                              (!display_prefetch_busy && !prefetch_request_pending_q)) &&
                             !prefetch_loading_new_q &&
                             boardless_start_ready;
        boardless_start_valid = nn_launch_pending_q && !fabric_fault_active;
        boardless_start_fire =
            boardless_start_valid && boardless_start_ready;
        boardless_input_index = nn_input_index_q;
        boardless_output_index = nn_output_index_q;
        boardless_input_table_base = cfg_input_table_base_q;
        boardless_output_table_base = cfg_output_table_base_q;
        boardless_frame_width = cfg_frame_width_q;
        boardless_frame_height = cfg_frame_height_q;
        boardless_input_width = cfg_input_width_q;
        boardless_input_height = cfg_input_height_q;
        boardless_x_step_q16 = cfg_x_step_q;
        boardless_y_step_q16 = cfg_y_step_q;
        boardless_x_phase0_q16 = cfg_x_phase0_q;
        boardless_y_phase0_q16 = cfg_y_phase0_q;
        boardless_descriptor_base = cfg_descriptor_base_q[31:0];
        boardless_descriptor_count = cfg_descriptor_count_q;
        boardless_cycle_budget = JOB_CYCLE_BUDGET;
        boardless_tensor_base_addr = cfg_tensor_base_q;

        capture_table_request_valid =
            (capture_state_q == CAP_TABLE_REQUEST) && !fabric_fault_active;
        capture_table_request_base = cfg_input_table_base_q;
        capture_table_request_index = manager_cap_index;
        capture_table_fault_now = (capture_state_q == CAP_TABLE_RESPONSE) &&
                                  capture_table_response_valid &&
                                  capture_table_response_ready &&
                                  capture_table_response_error;
        capture_table_config_fault_now =
            (capture_state_q == CAP_TABLE_RESPONSE) &&
            capture_table_response_valid &&
            capture_table_response_ready &&
            !capture_table_response_error &&
            ((capture_table_response_base[63:32] != 0) ||
             (capture_table_response_width != cfg_input_width_q) ||
             (capture_table_response_height != cfg_input_height_q));
        if (capture_table_response_error)
            capture_table_response_ready =
                (capture_state_q == CAP_TABLE_RESPONSE);
        else
            capture_table_response_ready =
                (capture_state_q == CAP_TABLE_RESPONSE) &&
                capture_begin_ready && !capture_writer_busy;

        capture_complete_now = (capture_state_q == CAP_STREAM) &&
            (capture_ingress_done_seen_q || capture_ingress_done) &&
            (capture_writer_done_seen_q || capture_writer_done) &&
            !capture_error && !capture_writer_error;

        display_prefetch_start_valid = prefetch_request_pending_q && !fabric_fault_active;
        display_original_base = prefetch_request_original_base_q;
        display_original_stride = prefetch_request_original_stride_q;
        display_styled_base = prefetch_request_styled_base_q;
        display_styled_stride = prefetch_request_styled_stride_q;
        display_width = prefetch_request_width_q;
        display_height = prefetch_request_height_q;
        display_original_width = prefetch_request_original_width_q;
        display_original_height = prefetch_request_original_height_q;
        display_prefetch_start_fire =
            display_prefetch_start_valid &&
            display_prefetch_start_ready;
        fatal_now = 1'b0;
        fatal_code = 8'h00;
        fatal_address = 32'd0;
        if (fabric_fault_active) begin
            fatal_now = 1'b1;
            fatal_code = ERR_FABRIC_WRITE;
            // No trustworthy offending address is supplied by the arbiter.
            fatal_address = 32'd0;
        end else if (operation_enable && parameter_reload_needed &&
            !weight_address_legal) begin
            fatal_now = 1'b1;
            fatal_code = ERR_WEIGHT_ADDRESS;
            fatal_address = cfg_weight_base_q[31:0];
        end else if (operation_enable && !tensor_address_legal) begin
            fatal_now = 1'b1;
            fatal_code = ERR_TENSOR_ADDRESS;
            fatal_address = cfg_tensor_base_q;
        end else if (operation_enable && !job_config_legal) begin
            fatal_now = 1'b1;
            fatal_code = ERR_DESCRIPTOR_ADDRESS;
            fatal_address = cfg_descriptor_base_q[31:0];
        end else if (operation_enable && !static_memory_legal) begin
            fatal_now = 1'b1;
            fatal_code = ERR_STATIC_MEMORY;
            fatal_address = static_bad_address;
        end else if (parameter_error) begin
            fatal_now = 1'b1;
            fatal_code = ERR_PARAMETER | {4'd0, parameter_error_code};
            fatal_address = parameter_error_address;
        end else if (capture_table_fault_now) begin
            fatal_now = 1'b1;
            fatal_code = ERR_CAPTURE_TABLE;
            fatal_address = cfg_input_table_base_q[31:0] +
                            ({30'd0, manager_cap_index} << 4);
        end else if (capture_table_config_fault_now) begin
            fatal_now = 1'b1;
            fatal_code = ERR_CAPTURE_CONFIG;
            fatal_address = capture_table_response_base[31:0];
        end else if(capture_state_q==CAP_GUARD_WAIT && capture_guard_response &&
                    !capture_guard_dirty_q && !capture_guard_changed && capture_guard_code!=0) begin
            fatal_now = 1'b1;
            fatal_code = ERR_CAPTURE_CONFIG;
            fatal_address = capture_writer_base;
        end else if (operation_enable && capture_error) begin
            fatal_now = 1'b1;
            fatal_code = ERR_CAPTURE_FRONTEND |
                         {4'd0, capture_error_code[3:0]};
            fatal_address = 32'd0;
        end else if (capture_writer_done && capture_writer_error) begin
            fatal_now = 1'b1;
            fatal_code = ERR_CAPTURE_WRITER;
            fatal_address = capture_writer_base;
        end else if (operation_enable && boardless_error) begin
            fatal_now = 1'b1;
            fatal_code = boardless_error_code;
            fatal_address = boardless_error_address;
        // Display remains a background service after one-shot CNN DONE has
        // cleared run_armed_q. Its errors still require global reporting and
        // cleanup; foreground operation_enable would silently lose them.
        end else if (system_enable && display_prefetch_error) begin
            fatal_now = 1'b1;
            fatal_code = ERR_DISPLAY;
            fatal_address = display_original_base;
        end

        // A registered fault ticket delays cleanup, not the decision to
        // publish a new display slot. Reject a coincident raw fault before
        // the manager commits; an already registered swap is still honored
        // by the current-metadata block below.
        manager_display_vsync = display_frame_start_event &&
                                prefetch_loading_new_q &&
                                display_prefetch_primed &&
                                pending_pair_valid_q &&
                                !display_swap_requested_q && !fatal_now;

        // run_armed_q is the registered ownership contract for every
        // foreground transaction.  Qualifying disable-abort with child busy
        // signals fed a job-controller state back through manager_abort and
        // the complete CNN ready tree.  The registered owner preserves the
        // same immediate disable semantics without that cross-hierarchy
        // combinational loop; the following clock clears run_armed_q after
        // all synchronous children have sampled the abort.
        abort_due_disable = !system_enable && run_armed_q;
        manager_abort_raw = abort_pulse || fatal_abort_now || fabric_fault_active ||
                            abort_due_disable;
        parameter_abort_request = manager_abort;
        capture_table_abort_request = manager_abort;
        capture_abort_frame = manager_abort;
        capture_writer_cancel = manager_abort;
        display_prefetch_abort = manager_abort;
        display_flush_request = manager_abort;
        boardless_abort = manager_abort;
        capture_clear_error = manager_abort;
        // Keep the shallow camera FIFO close to real time whenever no new
        // frame may be admitted.  Do not discard while an admitted frame is
        // waiting for table lookup/begin_frame in a one-shot transaction.
        capture_discard_idle = !capture_admission_open &&
                               (capture_state_q == CAP_IDLE);

        // Current-pair display refresh is a background service and must not
        // make a completed one-shot job look permanently busy to software.
        // A new pair remains foreground through prefetch and frame-boundary
        // swap via pending_pair_valid_q.  run_armed_q also covers the interval
        // in which a continuous/single job waits for a captured frame.
        status_busy = run_armed_q || parameter_busy || manager_capture_active ||
                      manager_nn_active || nn_launch_pending_q ||
                      boardless_busy || pending_pair_valid_q ||
                      (display_prefetch_busy && prefetch_loading_new_q) ||
                      (prefetch_request_pending_q &&
                       prefetch_request_is_new_q) ||
                      parameter_abort_pending ||
                      capture_table_abort_pending ||
                      !capture_table_request_ready || capture_writer_busy ||
                      display_flush_busy || capture_cleanup_fence_q ||
                      (FENCE_FABRIC_DRAIN && input_region_cancel_hold_q) ||
                      ((ENABLE_FABRIC_FAULT != 0) && fabric_write_busy);
        display_feed_active = manager_display_active;
        // The line stores are shared by the currently displayed pair and the
        // pending pair being prefetched.  Once a new pair has started, hold
        // pixel-side requests until the frame-boundary ownership swap; this
        // keeps the pending pair primed instead of letting the current raster
        // consume its first two lines before VSYNC.
        display_hold_requests = current_pair_valid_q &&
                                prefetch_loading_new_q;
        display_frame_id = manager_display_frame_id;
    end

    // Silent idle discard is a background sensor service and must not make
    // APB START randomly fail while a free-running camera is between EOFs.
    // Only cleanup caused by aborting an owned capture is a foreground fence.
    always_ff @(posedge clk) begin
        if (rst) begin
            capture_cleanup_fence_q <= 1'b0;
        end else begin
            if (manager_abort &&
                (manager_capture_active ||
                 (capture_state_q != CAP_IDLE) || capture_writer_busy ||
                 !capture_table_request_ready)) begin
                capture_cleanup_fence_q <= 1'b1;
            end else if (capture_cleanup_fence_q &&
                         !capture_cleanup_busy && !capture_writer_busy &&
                         capture_table_request_ready &&
                         !capture_table_abort_pending) begin
                capture_cleanup_fence_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            run_armed_q <= 1'b0;
            loaded_weight_base_q <= 64'd0;
            parameter_load_base_q <= 64'd0;
            cfg_frame_width_q <= REQUIRED_FRAME_WIDTH;
            cfg_frame_height_q <= REQUIRED_FRAME_HEIGHT;
            cfg_x_step_q <= 32'sh00010000;
            cfg_y_step_q <= 32'sh00010000;
            cfg_x_phase0_q <= 32'sd0;
            cfg_y_phase0_q <= 32'sd0;
            cfg_input_width_q <= SEPARATE_INPUT_GEOMETRY ? REQUIRED_INPUT_WIDTH : REQUIRED_FRAME_WIDTH;
            cfg_input_height_q <= SEPARATE_INPUT_GEOMETRY ? REQUIRED_INPUT_HEIGHT : REQUIRED_FRAME_HEIGHT;
            cfg_continuous_mode_q <= 1'b0;
            cfg_drop_oldest_mode_q <= 1'b1;
            cfg_input_pixel_format_q <= 4'd2;
            cfg_output_pixel_format_q <= 4'd2;
            cfg_input_table_base_q <= 64'd0;
            cfg_output_table_base_q <= 64'd0;
            cfg_descriptor_base_q <= 64'd0;
            cfg_descriptor_count_q <= 16'd0;
            cfg_weight_base_q <= 64'd0;
            cfg_tensor_base_q <= 32'd0;
            done_event <= 1'b0;
            error_event <= 1'b0;
            error_code <= 8'd0;
            error_address <= 32'd0;
            capture_drop_event <= 1'b0;
            display_swap_event <= 1'b0;
        end else begin
            done_event <= 1'b0;
            error_event <= 1'b0;
            capture_drop_event <= 1'b0;
            display_swap_event <= 1'b0;

            if (!system_enable || abort_pulse || fabric_fault_active)
                run_armed_q <= 1'b0;
            else if (start_pulse && !status_busy) begin
                run_armed_q <= 1'b1;
                cfg_frame_width_q <= frame_width;
                cfg_frame_height_q <= frame_height;
                cfg_x_step_q <= CONFIGURABLE_RESIZE ? resize_x_step_q16 : 32'sh00010000;
                cfg_y_step_q <= CONFIGURABLE_RESIZE ? resize_y_step_q16 : 32'sh00010000;
                cfg_x_phase0_q <= CONFIGURABLE_RESIZE ? resize_x_phase0_q16 : 32'sd0;
                cfg_y_phase0_q <= CONFIGURABLE_RESIZE ? resize_y_phase0_q16 : 32'sd0;
                cfg_input_width_q <= SEPARATE_INPUT_GEOMETRY ? input_frame_width : frame_width;
                cfg_input_height_q <= SEPARATE_INPUT_GEOMETRY ? input_frame_height : frame_height;
                cfg_continuous_mode_q <= continuous_mode;
                cfg_drop_oldest_mode_q <= drop_oldest_mode;
                cfg_input_pixel_format_q <= input_pixel_format;
                cfg_output_pixel_format_q <= output_pixel_format;
                cfg_input_table_base_q <= input_table_base;
                cfg_output_table_base_q <= output_table_base;
                cfg_descriptor_base_q <= descriptor_base;
                cfg_descriptor_count_q <= descriptor_count;
                cfg_weight_base_q <= weight_base;
                cfg_tensor_base_q <= tensor_base_addr;
            end

            if (parameter_start_fire)
                parameter_load_base_q <= cfg_weight_base_q;

            if (parameter_done)
                loaded_weight_base_q <= parameter_load_base_q;

            if (fatal_report_now) begin
                error_event <= 1'b1;
                error_code <= fatal_report_code;
                error_address <= fatal_report_address;
                run_armed_q <= 1'b0;
            end

            // Cancellation also discards the pending frame below. Match that
            // priority here: software must not observe success for a child
            // completion canceled on the very same sampling edge.
            // A registered fatal ticket delays the broadcast by one cycle;
            // raw classification must still veto success on this edge.
            if (boardless_done && !manager_abort && !fatal_now) begin
                done_event <= 1'b1;
                if (!cfg_continuous_mode_q)
                    run_armed_q <= 1'b0;
            end

            if (manager_cap_drop || capture_frame_dropped) begin
                capture_drop_event <= 1'b1;
            end
            if (manager_display_swap) begin
                display_swap_event <= 1'b1;
            end
        end
    end

    // A one-shot START owns exactly one captured frame.  Without this latch,
    // the camera path could fill the remaining manager buffers while the first
    // CNN job was running; those READY_NN frames would then leak into a later
    // START. Continuous mode deliberately keeps admission open.
    always_ff @(posedge clk) begin
        if (rst || manager_abort)
            single_capture_admitted_q <= 1'b0;
        else begin
            if (start_pulse && !status_busy)
                single_capture_admitted_q <= 1'b0;
            if (manager_cap_accept && !cfg_continuous_mode_q)
                single_capture_admitted_q <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst || manager_abort) begin
            capture_state_q <= CAP_IDLE;
            capture_guard_phase_q <= 0;
            capture_begin_frame <= 1'b0;
            capture_drop_frame <= 1'b0;
            capture_writer_start <= 1'b0;
            capture_writer_base <= 32'd0;
            capture_writer_stride <= 32'd0;
            capture_writer_width <= 16'd0;
            capture_writer_height <= 16'd0;
            capture_ingress_done_seen_q <= 1'b0;
            capture_writer_done_seen_q <= 1'b0;
            manager_cap_start <= 1'b0;
            manager_cap_done <= 1'b0;
        end else begin
            capture_begin_frame <= 1'b0;
            capture_drop_frame <= 1'b0;
            capture_writer_start <= 1'b0;
            manager_cap_start <= 1'b0;
            manager_cap_done <= 1'b0;

            case (capture_state_q)
                CAP_IDLE: begin
                    capture_ingress_done_seen_q <= 1'b0;
                    capture_writer_done_seen_q <= 1'b0;
                    if (capture_admission_open && capture_frame_waiting) begin
                        manager_cap_start <= 1'b1;
                        capture_state_q <= CAP_WAIT_ALLOCATION;
                    end
                end
                CAP_WAIT_ALLOCATION: begin
                    if (manager_cap_accept)
                        capture_state_q <= CAP_TABLE_REQUEST;
                    else if (manager_cap_drop) begin
                        capture_drop_frame <= 1'b1;
                        capture_state_q <= CAP_IDLE;
                    end
                end
                CAP_TABLE_REQUEST: begin
                    if (capture_table_request_valid &&
                        capture_table_request_ready)
                        capture_state_q <= CAP_TABLE_RESPONSE;
                end
                CAP_TABLE_RESPONSE: begin
                    if (capture_table_response_valid &&
                        capture_table_response_ready) begin
                        if (capture_table_response_error ||
                            (capture_table_response_base[63:32] != 0) ||
                            (capture_table_response_width != cfg_input_width_q) ||
                            (capture_table_response_height != cfg_input_height_q)) begin
                            capture_drop_frame <= 1'b1;
                            capture_state_q <= CAP_IDLE;
                        end else begin
                            capture_writer_base <=
                                capture_table_response_base[31:0];
                            capture_writer_stride <=
                                capture_table_response_stride;
                            capture_writer_width <=
                                capture_table_response_width;
                            capture_writer_height <=
                                capture_table_response_height;
                            capture_guard_phase_q <= 0;
                            capture_state_q <= CAP_GUARD_PREP;
                        end
                    end
                end
                CAP_GUARD_PREP: begin
                    if(!region_check_busy && !capture_guard_pair_valid) begin
                        if(capture_guard_phase_q==CAPTURE_LAST_REGION) capture_state_q<=CAP_GUARD_COMMIT;
                        else capture_guard_phase_q<=capture_guard_phase_q+1'b1;
                    end else if(capture_guard_req && capture_guard_ready)
                        capture_state_q<=CAP_GUARD_WAIT;
                end
                CAP_GUARD_WAIT: if(capture_guard_response) begin
                    if(capture_guard_dirty_q || capture_guard_changed) begin
                        capture_guard_phase_q<=0;capture_state_q<=CAP_GUARD_PREP;
                    end else if(capture_guard_code!=0) begin
                        capture_drop_frame<=1;capture_state_q<=CAP_IDLE;
                    end else if(capture_guard_phase_q==CAPTURE_LAST_REGION) capture_state_q<=CAP_GUARD_COMMIT;
                    else begin capture_guard_phase_q<=capture_guard_phase_q+1'b1;capture_state_q<=CAP_GUARD_PREP;end
                end
                CAP_GUARD_COMMIT: begin
                    if(capture_guard_dirty_q || capture_guard_changed) begin
                        capture_guard_phase_q<=0;capture_state_q<=CAP_GUARD_PREP;
                    end else if(capture_begin_ready && !capture_writer_busy && !fatal_now && !region_check_busy) begin
                        capture_writer_start<=1;capture_begin_frame<=1;
                        capture_ingress_done_seen_q<=0;capture_writer_done_seen_q<=0;
                        capture_state_q<=CAP_STREAM;
                    end
                end
                CAP_STREAM: begin
                    if (capture_ingress_done)
                        capture_ingress_done_seen_q <= 1'b1;
                    if (capture_writer_done)
                        capture_writer_done_seen_q <= 1'b1;
                    if (capture_complete_now) begin
                        manager_cap_done <= 1'b1;
                        capture_state_q <= CAP_IDLE;
                    end
                end
                default: capture_state_q <= CAP_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst || manager_abort) begin
            nn_launch_pending_q <= 1'b0;
            nn_input_index_q <= 2'd0;
            nn_output_index_q <= 2'd0;
            nn_frame_id_q <= 32'd0;
            manager_nn_done <= 1'b0;
            pending_pair_valid_q <= 1'b0;
            pending_input_index_q <= 2'd0;
            pending_output_index_q <= 1'b0;
            pending_frame_id_q <= 32'd0;
            pending_original_base_q <= 32'd0;
            pending_original_stride_q <= 32'd0;
            pending_styled_base_q <= 32'd0;
            pending_styled_stride_q <= 32'd0;
            pending_width_q <= 16'd0;
            pending_height_q <= 16'd0;
            pending_original_width_q <= 16'd0;
            pending_original_height_q <= 16'd0;
        end else begin
            manager_nn_done <= 1'b0;
            if (manager_nn_grant) begin
                nn_launch_pending_q <= 1'b1;
                nn_input_index_q <= manager_nn_input_index;
                nn_output_index_q <= {1'b0, manager_nn_output_index};
                nn_frame_id_q <= manager_nn_frame_id;
            end
            if (boardless_start_fire)
                nn_launch_pending_q <= 1'b0;

            // Keep ownership publication consistent with the software DONE
            // veto even before a registered fatal broadcast reaches us.
            if (boardless_done && !fatal_now) begin
                manager_nn_done <= 1'b1;
                pending_pair_valid_q <= 1'b1;
                pending_input_index_q <= nn_input_index_q;
                pending_output_index_q <= nn_output_index_q[0];
                pending_frame_id_q <= nn_frame_id_q;
                pending_original_base_q <=
                    DISPLAY_RESIZED_PREVIEW ? boardless_resolved_preview_base : boardless_resolved_input_base;
                pending_original_stride_q <=
                    DISPLAY_RESIZED_PREVIEW ? boardless_resolved_preview_stride : boardless_resolved_input_stride;
                pending_styled_base_q <=
                    boardless_resolved_output_base;
                pending_styled_stride_q <=
                    boardless_resolved_output_stride;
                pending_width_q <= boardless_resolved_output_width;
                pending_height_q <= boardless_resolved_output_height;
                pending_original_width_q <= DISPLAY_RESIZED_PREVIEW ? boardless_resolved_output_width : boardless_resolved_input_width;
                pending_original_height_q <= DISPLAY_RESIZED_PREVIEW ? boardless_resolved_output_height : boardless_resolved_input_height;
            end

            if (manager_display_swap)
                pending_pair_valid_q <= 1'b0;
        end
    end

    // The manager's swap pulse acknowledges ownership committed on the
    // PREVIOUS edge. Cancellation now may flush uncommitted work, but cannot
    // undo that ownership. Commit its matching metadata even on manager_abort;
    // pending registers are still available until this edge's NBA updates.
    always_ff @(posedge clk) begin
        if (rst) begin
            current_pair_valid_q <= 1'b0;
            current_original_base_q <= 32'd0;
            current_original_stride_q <= 32'd0;
            current_styled_base_q <= 32'd0;
            current_styled_stride_q <= 32'd0;
            current_width_q <= 16'd0;
            current_height_q <= 16'd0;
            current_original_width_q <= 16'd0;
            current_original_height_q <= 16'd0;
        end else if (manager_display_swap) begin
            current_pair_valid_q <= 1'b1;
            current_original_base_q <= pending_original_base_q;
            current_original_stride_q <= pending_original_stride_q;
            current_styled_base_q <= pending_styled_base_q;
            current_styled_stride_q <= pending_styled_stride_q;
            current_width_q <= pending_width_q;
            current_height_q <= pending_height_q;
            current_original_width_q <= pending_original_width_q;
            current_original_height_q <= pending_original_height_q;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            prefetch_request_pending_q <= 1'b0;
            prefetch_request_is_new_q <= 1'b0;
            prefetch_request_original_base_q <= 32'd0;
            prefetch_request_original_stride_q <= 32'd0;
            prefetch_request_styled_base_q <= 32'd0;
            prefetch_request_styled_stride_q <= 32'd0;
            prefetch_request_width_q <= 16'd0;
            prefetch_request_height_q <= 16'd0;
            prefetch_request_original_width_q <= 16'd0;
            prefetch_request_original_height_q <= 16'd0;
            prefetch_loading_new_q <= 1'b0;
            prefetch_active_is_new_q <= 1'b0;
            display_swap_requested_q <= 1'b0;
        end else if (manager_abort) begin
            // c1_frame_manager deliberately preserves the currently
            // displayed ownership pair on abort. Preserve its address
            // snapshot too; after all display AXI traffic drains the same
            // pair can be prefetched again instead of leaving a black screen.
            prefetch_request_pending_q <= 1'b0;
            prefetch_request_is_new_q <= 1'b0;
            prefetch_loading_new_q <= 1'b0;
            prefetch_active_is_new_q <= 1'b0;
            display_swap_requested_q <= 1'b0;
        end else begin
            // A new pair remains in-flight until the frame manager observes
            // its VSYNC swap.  Do not requeue the same table pair each time
            // the two-line readers finish; repeated starts would consume and
            // refill the shared stores forever without ever presenting a
            // stable primed pair at the next frame boundary.
            if (!prefetch_request_pending_q &&
                (!FENCE_FABRIC_DRAIN || !input_region_cancel_hold_q) &&
                !display_prefetch_busy &&
                !prefetch_loading_new_q &&
                ((CONCURRENT_DISPLAY_PREFETCH != 0) || (!boardless_busy &&
                !manager_nn_active &&
                !nn_launch_pending_q &&
                !manager_nn_request))) begin
                if (pending_pair_valid_q) begin
                    prefetch_request_pending_q <= 1'b1;
                    prefetch_request_is_new_q <= 1'b1;
                    prefetch_request_original_base_q <=
                        pending_original_base_q;
                    prefetch_request_original_stride_q <=
                        pending_original_stride_q;
                    prefetch_request_styled_base_q <=
                        pending_styled_base_q;
                    prefetch_request_styled_stride_q <=
                        pending_styled_stride_q;
                    prefetch_request_width_q <= pending_width_q;
                    prefetch_request_height_q <= pending_height_q;
                    prefetch_request_original_width_q <= pending_original_width_q;
                    prefetch_request_original_height_q <= pending_original_height_q;
                end else if (current_pair_valid_q) begin
                    prefetch_request_pending_q <= 1'b1;
                    prefetch_request_is_new_q <= 1'b0;
                    prefetch_request_original_base_q <=
                        current_original_base_q;
                    prefetch_request_original_stride_q <=
                        current_original_stride_q;
                    prefetch_request_styled_base_q <=
                        current_styled_base_q;
                    prefetch_request_styled_stride_q <=
                        current_styled_stride_q;
                    prefetch_request_width_q <= current_width_q;
                    prefetch_request_height_q <= current_height_q;
                    prefetch_request_original_width_q <= current_original_width_q;
                    prefetch_request_original_height_q <= current_original_height_q;
                end
            end

            if (display_prefetch_start_fire) begin
                prefetch_request_pending_q <= 1'b0;
                prefetch_loading_new_q <= prefetch_request_is_new_q;
                prefetch_active_is_new_q <= prefetch_request_is_new_q;
                display_swap_requested_q <= 1'b0;
            end

            if (manager_display_vsync)
                display_swap_requested_q <= 1'b1;

            if (manager_display_swap) begin
                prefetch_loading_new_q <= 1'b0;
                display_swap_requested_q <= 1'b0;
            end

            if (display_prefetch_done && !prefetch_loading_new_q)
                prefetch_loading_new_q <= 1'b0;

            // Keep the transaction-local tag through a VSYNC swap; clear it
            // only after the active reader/FIFO pair has actually reported
            // completion (or an abort), so background refreshes cannot be
            // mistaken for a second job boundary.
            if (display_prefetch_done || display_prefetch_aborted)
                prefetch_active_is_new_q <= 1'b0;
        end
    end

    c1_frame_manager u_frame_manager (
        .clk(clk),
        .rst_n(~rst),
        .abort(manager_abort),
        .drop_oldest_mode(cfg_drop_oldest_mode_q),
        .cap_frame_start(manager_cap_start),
        .cap_frame_done(manager_cap_done),
        .cap_accept_pulse(manager_cap_accept),
        .cap_drop_pulse(manager_cap_drop),
        .cap_input_index(manager_cap_index),
        .cap_frame_id(manager_cap_frame_id),
        .nn_job_request(manager_nn_request),
        .nn_done(manager_nn_done),
        .nn_job_grant(manager_nn_grant),
        .nn_input_index(manager_nn_input_index),
        .nn_output_index(manager_nn_output_index),
        .nn_frame_id(manager_nn_frame_id),
        .display_vsync(manager_display_vsync),
        .display_swap_pulse(manager_display_swap),
        .display_input_index(manager_display_input_index),
        .display_output_index(manager_display_output_index),
        .display_frame_id(manager_display_frame_id),
        .display_active(manager_display_active),
        .input_ready_count(input_ready_count),
        .output_ready_count(output_ready_count),
        .capture_active_out(manager_capture_active),
        .nn_active_out(manager_nn_active),
        .dropped_frame_count(manager_dropped_count),
        .input_owned_mask(input_owned_mask),.output_owned_mask(output_owned_mask)
    );

endmodule
