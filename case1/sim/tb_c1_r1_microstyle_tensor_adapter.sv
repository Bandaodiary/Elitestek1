`timescale 1ns/1ps

module tb_c1_r1_microstyle_tensor_adapter #(
    parameter integer PIPELINED_WRITES = 0,
    parameter integer RESPONSE_DEPTH = PIPELINED_WRITES ? 8 : 1,
    parameter integer RUN_WRITE_DRAIN_SCENARIOS = 1,
    parameter integer PREFETCH_TAP_ADDRESS = 0,
    parameter integer FIXED_READ_DELAY = -1,
    parameter integer HORIZONTAL_REUSE = 0,
    parameter integer FRAME_W = 8,
    parameter integer FRAME_H = 4,
    parameter integer BANK_BYTES = (FRAME_W*FRAME_H*16 < 1024) ?
                                   1024 : FRAME_W*FRAME_H*16,
    parameter integer COLUMN_READS = 0,
    parameter integer PRECLAMPED_SCALAR_TAPS = 0,
    parameter integer COLUMN_OWNER = 0,
    parameter bit VIRTUAL_UPSAMPLE = 0,
    parameter bit COLUMN_WRITE_OVERLAP = 0,
    parameter bit POINTWISE_COLUMNS = 0,
    parameter bit COLUMN_RESPONSE_BYPASS = 0,
    parameter bit COLUMN_LOOKUP_READS = 0,
    parameter bit PIXEL_COLUMN_PREFETCH = 0,
    parameter bit SOURCE_PIPELINE = 0,
    parameter bit ALL_PIXEL_GROUPS = 0,
    parameter bit FUSE_FINAL = 0,
    parameter integer FUSION_CASE = 0
);
`ifdef C1_PIPELINED_DESCRIPTOR_VALIDATION
    localparam integer PIPELINED_DESCRIPTOR_VALIDATION_CFG = 1;
`else
    localparam integer PIPELINED_DESCRIPTOR_VALIDATION_CFG = 0;
`endif
`ifdef C1_NARROW_DESCRIPTOR_SIZE_CHECK
    localparam integer NARROW_DESCRIPTOR_SIZE_CHECK_CFG = 1;
`else
    localparam integer NARROW_DESCRIPTOR_SIZE_CHECK_CFG = 0;
`endif
`ifdef C1_PIPELINED_DESCRIPTOR_SIZE_ARITH
    localparam integer PIPELINED_DESCRIPTOR_SIZE_ARITH_CFG = 1;
`else
    localparam integer PIPELINED_DESCRIPTOR_SIZE_ARITH_CFG = 0;
`endif
`ifdef C1_FIXED_DESCRIPTOR_SIZE_LIMITS
    localparam integer FIXED_DESCRIPTOR_SIZE_LIMITS_CFG = 1;
`else
    localparam integer FIXED_DESCRIPTOR_SIZE_LIMITS_CFG = 0;
`endif
`ifdef C1_PIPELINED_DESCRIPTOR_PIXEL_COUNT
    localparam integer PIPELINED_DESCRIPTOR_PIXEL_COUNT_CFG = 1;
`else
    localparam integer PIPELINED_DESCRIPTOR_PIXEL_COUNT_CFG = 0;
`endif
`ifdef C1_ITERATIVE_DESCRIPTOR_PIXEL_COUNT
    localparam integer ITERATIVE_DESCRIPTOR_PIXEL_COUNT_CFG = 1;
`else
    localparam integer ITERATIVE_DESCRIPTOR_PIXEL_COUNT_CFG = 0;
`endif
`ifdef C1_PIPELINED_TENSOR_ADDRESS
    localparam integer PIPELINED_TENSOR_ADDRESS_CFG = 1;
`else
    localparam integer PIPELINED_TENSOR_ADDRESS_CFG = 0;
`endif
`ifdef C1_PIPELINED_TENSOR_PIXEL_INDEX
    localparam integer PIPELINED_TENSOR_PIXEL_INDEX_CFG = 1;
`else
    localparam integer PIPELINED_TENSOR_PIXEL_INDEX_CFG = 0;
`endif
    localparam integer STAGES = 22;
    localparam integer FRAME_SCALE = (FRAME_W*FRAME_H+31)/32;
    localparam integer JOB_TIMEOUT = 300000*FRAME_SCALE;
    localparam logic [31:0] BASE_ADDR = 32'h0000_1000;
    localparam integer MEMORY_WORDS = (3 * BANK_BYTES) / 8;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic adapter_start_valid;
    logic adapter_start_ready;
    logic adapter_abort;
    logic adapter_stage_config_valid;
    logic adapter_stage_config_ready;
    logic [15:0] adapter_stage_config_index;
    logic [511:0] adapter_stage_config_descriptor;
    logic [7:0] adapter_stage_config_generation;
    wire view_commit_valid,view_commit_ready;
    wire [4:0] view_commit_stage;
    wire [7:0] view_commit_generation;
    logic [7:0] fusion_generation=0;
    logic fusion_committed=0;
    integer fusion_prepare_cycles=0,fusion_eof_cycles=0,fusion_commits=0;
    logic fusion_block_commit=0,fusion_block_final=0;
    logic fusion_hold_result=0;
    integer fusion_bad_field=-1;
    logic adapter_error;
    logic [7:0] adapter_error_code;
    logic adapter_source_valid;
    logic adapter_source_ready;
    logic [63:0] adapter_source_data_s8;
    logic [15:0] adapter_source_x, adapter_source_y;
    logic adapter_source_sof, adapter_source_eol, adapter_source_eof;
    logic adapter_engine_valid;
    logic adapter_engine_ready;
    logic [575:0] adapter_engine_window_s8;
    logic [63:0] adapter_engine_residual_s8;
    logic [2:0] adapter_engine_group_index;
    logic adapter_engine_group_last;
    logic [15:0] adapter_engine_x, adapter_engine_y;
    logic adapter_engine_sof, adapter_engine_eol, adapter_engine_eof;
    logic adapter_result_valid;
    logic adapter_result_ready;
    logic [63:0] adapter_result_data_s8;
    logic [2:0] adapter_result_group_index;
    logic adapter_result_group_last;
    logic [15:0] adapter_result_x, adapter_result_y;
    logic adapter_result_sof, adapter_result_eol, adapter_result_eof;
    logic adapter_final_valid;
    logic adapter_final_ready;
    logic [63:0] adapter_final_data_s8;
    logic [15:0] adapter_final_x, adapter_final_y;
    logic adapter_final_sof, adapter_final_eol, adapter_final_eof;
    logic [31:0] tensor_base_addr;
    logic cache_stage_start_valid, cache_stage_start_ready;
    logic cache_stage_enable;
    logic [31:0] cache_stage_base_addr;
    logic [15:0] cache_stage_width, cache_stage_height;
    logic [3:0] cache_stage_groups;
    logic mem_req_valid, mem_req_ready, mem_req_write;
    logic [31:0] mem_req_addr;
    logic [63:0] mem_req_wdata;
    logic [7:0] mem_req_wstrb;
    logic mem_req_cacheable;
    logic signed [16:0] mem_req_cache_x, mem_req_cache_y;
    logic [2:0] mem_req_cache_group;
    logic mem_rsp_valid, mem_rsp_ready, mem_rsp_error;
    logic [63:0] mem_rsp_rdata;
    logic adapter_busy, adapter_done, adapter_aborted;
    logic adapter_config_complete;
    logic [4:0] active_stage_index;
    logic [7:0] active_stage_opcode;
    logic [1:0] active_input_bank, active_output_bank;
    logic [1:0] active_residual_bank;
    wire column_req_valid,column_req_ready,column_rsp_valid,column_rsp_ready,column_rsp_error;
    wire column_allow_pending_writes;
    wire mem_req_end;
    wire signed [16:0] column_req_x,column_req_center_y;
    wire [2:0] column_req_group;
    wire [191:0] column_rsp_data_s8;
    bit block_column_requests=0,hold_column_responses=0,inject_column_refill_error=0;
    bit block_column_backend=0;
    wire owner_backend_offered,owner_backend_fence;
    wire column_response_offered,column_provider_busy;
    integer column_request_count=0,column_response_count=0,column_config_count=0;
    integer pixel_pf_requests=0,pixel_pf_responses=0,pixel_pf_uses=0,pixel_pf_early=0;
    always @(posedge clk) if(!rst) begin
        if(dut.pixel_prefetch_state_q==dut.PF_REQUEST && column_req_valid && column_req_ready) pixel_pf_requests++;
        if(dut.pixel_prefetch_state_q==dut.PF_RESPONSE && column_rsp_valid && column_rsp_ready) begin
            pixel_pf_responses++;
            if(dut.state_q!=dut.ST_READ_RSP) pixel_pf_early++;
        end
        if(dut.pixel_prefetch_take) pixel_pf_uses++;
    end

    c1_r1_microstyle_tensor_adapter #(
        .REQUIRED_STAGES(STAGES),
        .TENSOR_BANK_BYTES(BANK_BYTES),
        .PIPELINED_RESULT_WRITES(PIPELINED_WRITES),
        .PIPELINED_DESCRIPTOR_VALIDATION(PIPELINED_DESCRIPTOR_VALIDATION_CFG),
        .NARROW_DESCRIPTOR_SIZE_CHECK(NARROW_DESCRIPTOR_SIZE_CHECK_CFG),
        .PIPELINED_TENSOR_ADDRESS(PIPELINED_TENSOR_ADDRESS_CFG),
        .PIPELINED_TENSOR_PIXEL_INDEX(PIPELINED_TENSOR_PIXEL_INDEX_CFG),
        .PREFETCH_NEXT_TAP_ADDRESS(PREFETCH_TAP_ADDRESS),
        .REUSE_HORIZONTAL_WINDOW(HORIZONTAL_REUSE),
        .ENABLE_COLUMN_READS(COLUMN_READS),
        .VIRTUAL_UPSAMPLE_TENSORS(VIRTUAL_UPSAMPLE),
        .OVERLAP_COLUMN_WRITEBACK(COLUMN_WRITE_OVERLAP),
        .POINTWISE_COLUMN_READS(POINTWISE_COLUMNS),
        .PREFETCH_NEXT_PIXEL_COLUMN(PIXEL_COLUMN_PREFETCH),
        .PREFETCH_ALL_PIXEL_GROUPS(ALL_PIXEL_GROUPS),
        .PIPELINED_SOURCE_WRITES(SOURCE_PIPELINE),
        .FUSE_FINAL_OUTPUT(FUSE_FINAL),
        .ENABLE_WINDOW_CACHE_SIDEBAND(COLUMN_READS!=0),
        .PRECLAMPED_TAP_COORDS(PRECLAMPED_SCALAR_TAPS),
        .PIPELINED_DESCRIPTOR_SIZE_ARITH(PIPELINED_DESCRIPTOR_SIZE_ARITH_CFG),
        .FIXED_DESCRIPTOR_SIZE_LIMITS(FIXED_DESCRIPTOR_SIZE_LIMITS_CFG),
        .PIPELINED_DESCRIPTOR_PIXEL_COUNT(PIPELINED_DESCRIPTOR_PIXEL_COUNT_CFG),
        .ITERATIVE_DESCRIPTOR_PIXEL_COUNT(ITERATIVE_DESCRIPTOR_PIXEL_COUNT_CFG)
    ) dut (
        .clk(clk), .rst(rst),
        .view_commit_valid,.view_commit_ready,.view_commit_stage,.view_commit_generation,
        .adapter_start_valid(adapter_start_valid),
        .adapter_start_ready(adapter_start_ready),
        .adapter_abort(adapter_abort),
        .adapter_stage_config_valid(adapter_stage_config_valid),
        .adapter_stage_config_ready(adapter_stage_config_ready),
        .adapter_stage_config_index(adapter_stage_config_index),
        .adapter_stage_config_descriptor(adapter_stage_config_descriptor),
        .adapter_stage_config_generation(adapter_stage_config_generation),
        .adapter_error(adapter_error),
        .adapter_error_code(adapter_error_code),
        .adapter_source_valid(adapter_source_valid),
        .adapter_source_ready(adapter_source_ready),
        .adapter_source_data_s8(adapter_source_data_s8),
        .adapter_source_x(adapter_source_x),
        .adapter_source_y(adapter_source_y),
        .adapter_source_sof(adapter_source_sof),
        .adapter_source_eol(adapter_source_eol),
        .adapter_source_eof(adapter_source_eof),
        .adapter_engine_valid(adapter_engine_valid),
        .adapter_engine_ready(adapter_engine_ready),
        .adapter_engine_window_s8(adapter_engine_window_s8),
        .adapter_engine_residual_s8(adapter_engine_residual_s8),
        .adapter_engine_group_index(adapter_engine_group_index),
        .adapter_engine_group_last(adapter_engine_group_last),
        .adapter_engine_x(adapter_engine_x),
        .adapter_engine_y(adapter_engine_y),
        .adapter_engine_sof(adapter_engine_sof),
        .adapter_engine_eol(adapter_engine_eol),
        .adapter_engine_eof(adapter_engine_eof),
        .adapter_result_valid(adapter_result_valid),
        .adapter_result_ready(adapter_result_ready),
        .adapter_result_data_s8(adapter_result_data_s8),
        .adapter_result_group_index(adapter_result_group_index),
        .adapter_result_group_last(adapter_result_group_last),
        .adapter_result_x(adapter_result_x),
        .adapter_result_y(adapter_result_y),
        .adapter_result_sof(adapter_result_sof),
        .adapter_result_eol(adapter_result_eol),
        .adapter_result_eof(adapter_result_eof),
        .adapter_final_valid(adapter_final_valid),
        .adapter_final_ready(adapter_final_ready),
        .adapter_final_data_s8(adapter_final_data_s8),
        .adapter_final_x(adapter_final_x),
        .adapter_final_y(adapter_final_y),
        .adapter_final_sof(adapter_final_sof),
        .adapter_final_eol(adapter_final_eol),
        .adapter_final_eof(adapter_final_eof),
        .tensor_base_addr(tensor_base_addr),
        .cache_stage_start_valid(cache_stage_start_valid),
        .cache_stage_start_ready(cache_stage_start_ready),
        .cache_stage_enable(cache_stage_enable),
        .cache_stage_base_addr(cache_stage_base_addr),
        .cache_stage_width(cache_stage_width),
        .cache_stage_height(cache_stage_height),
        .cache_stage_groups(cache_stage_groups),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_end(mem_req_end),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_req_wstrb(mem_req_wstrb),
        .mem_req_cacheable(mem_req_cacheable),
        .mem_req_cache_x(mem_req_cache_x),
        .mem_req_cache_y(mem_req_cache_y),
        .mem_req_cache_group(mem_req_cache_group),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_error(mem_rsp_error),
        .mem_rsp_rdata(mem_rsp_rdata),
        .adapter_busy(adapter_busy),
        .adapter_done(adapter_done),
        .adapter_aborted(adapter_aborted),
        .adapter_config_complete(adapter_config_complete),
        .active_stage_index(active_stage_index),
        .active_stage_opcode(active_stage_opcode),
        .active_input_bank(active_input_bank),
        .active_output_bank(active_output_bank),
        .active_residual_bank(active_residual_bank),
        .column_req_valid(column_req_valid), .column_req_ready(column_req_ready),
        .column_req_x(column_req_x), .column_req_center_y(column_req_center_y),
        .column_req_group(column_req_group), .column_rsp_valid(column_rsp_valid),
        .column_rsp_ready(column_rsp_ready), .column_rsp_data_s8(column_rsp_data_s8),
        .column_rsp_error(column_rsp_error), .column_allow_pending_writes(column_allow_pending_writes)
    );

    logic [63:0] memory [0:MEMORY_WORDS-1];
    logic [31:0] lfsr_q;
    logic response_pending_q;
    logic [7:0] response_delay_q;
    logic response_error_q;
    logic [63:0] response_data_q;
    logic hold_responses;
    logic force_request_ready;
    logic inject_response_error;
    bit block_requests=0, inject_write_completion_error=0;
    integer response_count=0, response_head=0, response_tail=0;
    integer max_response_count=0;
    logic [7:0] queued_delay [0:RESPONSE_DEPTH-1];
    logic queued_error [0:RESPONSE_DEPTH-1];
    logic [63:0] queued_data [0:RESPONSE_DEPTH-1];
    assign response_pending_q = response_count != 0;
    assign response_delay_q = queued_delay[response_head];
    assign response_error_q = queued_error[response_head];
    assign response_data_q = queued_data[response_head];

    integer request_count;
    integer read_count;
    integer write_count;
    integer request_stall_count;
    integer response_gap_count;
    integer abort_drain_count;
    integer memory_index;
    integer byte_lane;
    integer adjacent_pairable_count;
    integer adjacent_same_base_count;
    logic have_prev_request;
    logic [31:0] prev_request_addr;
    logic prev_request_write;

    // Production column cache; only its refill source is a memory BFM. The
    // same independent arena used for scalar reads/writes feeds complete rows.
    // The owner drains adapter requests/responses before reconfiguring this
    // cache, rather than forwarding adapter_abort into a stalled request.
    generate if(COLUMN_READS!=0) begin : g_column_provider
        wire cache_ready,cache_rsp_valid,cache_rsp_ready,cache_rsp_error;
        wire [191:0] cache_rsp_data;
        wire backend_req_valid,backend_req_ready,backend_rsp_valid,backend_rsp_ready,backend_rsp_error;
        wire raw_backend_ready;
        wire signed [16:0] backend_x,backend_y;
        wire [2:0] backend_group;
        wire [191:0] backend_data;
        wire backend_abort,backend_flush,backend_abort_done,backend_flush_done;
        wire backend_idle,backend_busy,config_permit,backend_config_ready;
        wire refill_valid,refill_ready,word_ready,cache_config_valid;
        wire [15:0] refill_row,refill_words;
        wire word_valid;
        logic row_active=0;
        integer row_index=0,row_count=0,row_number=0;
        logic [31:0] stage_base_q=0;
        integer row_words_q=0;
        wire [31:0] word_addr=stage_base_q+(row_number*row_words_q+row_index)*8;
        wire [63:0] word_data=memory[(word_addr-BASE_ADDR)>>3];
        assign refill_ready=!row_active && lfsr_q[0];
        assign word_valid=row_active && lfsr_q[1];
        assign column_req_ready=cache_ready && !block_column_requests;
        assign column_rsp_valid=cache_rsp_valid && !hold_column_responses;
        assign cache_rsp_ready=column_rsp_ready && !hold_column_responses;
        assign column_rsp_error=cache_rsp_error;
        assign column_rsp_data_s8=cache_rsp_data;
        assign column_response_offered=cache_rsp_valid;
        assign backend_req_ready=raw_backend_ready && !block_column_backend;
        assign owner_backend_offered=backend_req_valid;
        assign owner_backend_fence=backend_abort || backend_flush;
        assign cache_stage_start_ready=backend_config_ready && config_permit;
        if(COLUMN_OWNER) begin : g_owner
            c1_column_transaction_owner owner (
                .clk(clk),.rst(rst),
                .s_req_valid(column_req_valid && !block_column_requests),.s_req_ready(cache_ready),
                .s_req_x(column_req_x),.s_req_center_y(column_req_center_y),.s_req_group(column_req_group),
                .s_rsp_valid(cache_rsp_valid),.s_rsp_ready(cache_rsp_ready),
                .s_rsp_data(cache_rsp_data),.s_rsp_error(cache_rsp_error),
                .m_req_valid(backend_req_valid),.m_req_ready(backend_req_ready),
                .m_req_x(backend_x),.m_req_center_y(backend_y),.m_req_group(backend_group),
                .m_rsp_valid(backend_rsp_valid),.m_rsp_ready(backend_rsp_ready),
                .m_rsp_data(backend_data),.m_rsp_error(backend_rsp_error),
                .abort_req(adapter_abort),.flush_req(1'b0),
                .m_abort_req(backend_abort),.m_flush_req(backend_flush),
                .m_abort_done(backend_abort_done),.m_flush_done(backend_flush_done),
                .backend_config_valid(cache_config_valid),.backend_quiescent(backend_idle),
                .config_pending(cache_stage_start_valid),.config_permit(config_permit),
                .busy(column_provider_busy)
            );
        end else begin : g_direct
            assign backend_req_valid=column_req_valid && !block_column_requests;
            assign cache_ready=backend_req_ready;
            assign {backend_x,backend_y,backend_group}={column_req_x,column_req_center_y,column_req_group};
            assign cache_rsp_valid=backend_rsp_valid;
            assign backend_rsp_ready=cache_rsp_ready;
            assign cache_rsp_data=backend_data;
            assign cache_rsp_error=backend_rsp_error;
            assign backend_abort=0;
            assign backend_flush=0;
            assign config_permit=1;
            assign column_provider_busy=backend_busy;
        end
        c1_column_line_cache_c8 #(.MAX_ROW_WORDS(FRAME_W*8),
            .RESPONSE_BYPASS(COLUMN_RESPONSE_BYPASS),.READ_ON_LOOKUP(COLUMN_LOOKUP_READS)) cache (
            .clk(clk),.rst(rst),.group_start_valid(cache_stage_start_valid && config_permit),
            .group_start_ready(backend_config_ready),.frame_width(cache_stage_width),
            .frame_height(cache_stage_height),.frame_groups(cache_stage_groups),
            .config_valid(cache_config_valid),.abort_req(backend_abort),.flush_req(backend_flush),
            .abort_done(backend_abort_done),.flush_done(backend_flush_done),.quiescent(backend_idle),
            .column_valid(backend_req_valid && !block_column_backend),.column_ready(raw_backend_ready),
            .column_x(backend_x),.column_y(backend_y),.column_group(backend_group),
            .column_rsp_valid(backend_rsp_valid),.column_rsp_ready(backend_rsp_ready),
            .column_rsp_data_s8(backend_data),.column_rsp_error(backend_rsp_error),
            .refill_req_valid(refill_valid),.refill_req_ready(refill_ready),
            .refill_req_row(refill_row),.refill_req_word_count(refill_words),
            .refill_word_valid(word_valid),.refill_word_ready(word_ready),
            .refill_word_data_s8(word_data),.refill_word_last(row_index==row_count-1),
            .refill_word_error(inject_column_refill_error && row_index==0),
            .busy(backend_busy)
        );
        always @(posedge clk) begin
            if(rst) begin
                row_active<=0;column_request_count<=0;column_response_count<=0;column_config_count<=0;
            end else begin
                if(cache_stage_start_valid && cache_stage_start_ready) begin
                    if(row_active || column_request_count!=column_response_count ||
                        cache_stage_width!=(stage_iw_fn(active_stage_index) >>
                            ((VIRTUAL_UPSAMPLE && (active_stage_index==15 || active_stage_index==18))?1:0)) ||
                        cache_stage_height!=(stage_ih_fn(active_stage_index) >>
                            ((VIRTUAL_UPSAMPLE && (active_stage_index==15 || active_stage_index==18))?1:0)) ||
                        cache_stage_groups!=(stage_cin_fn(active_stage_index)+7)/8 ||
                        cache_stage_base_addr!=BASE_ADDR+input_bank_fn(active_stage_index)*BANK_BYTES)
                        $fatal(1,"column cache stage geometry/bank/ownership mismatch");
                    stage_base_q<=cache_stage_base_addr;
                    row_words_q<=cache_stage_width*cache_stage_groups;
                    column_config_count<=column_config_count+1;
                end
                if(column_req_valid && column_req_ready) begin
                    if(column_request_count!=column_response_count ||
                        (response_pending_q && !column_allow_pending_writes) ||
                        !cache_stage_enable || (!COLUMN_OWNER && !cache_config_valid))
                        $fatal(1,"column crossed scalar response/stage ownership");
                    column_request_count<=column_request_count+1;
                end
                if(column_rsp_valid && column_rsp_ready)
                    column_response_count<=column_response_count+1;
                if(refill_valid && refill_ready) begin
                    if(refill_words!=row_words_q) $fatal(1,"column refill geometry mismatch");
                    row_active<=1;row_number<=refill_row;row_count<=refill_words;row_index<=0;
                end
                if(word_valid && word_ready) begin
                    if(word_addr<BASE_ADDR || word_addr>=BASE_ADDR+3*BANK_BYTES)
                        $fatal(1,"column refill outside tensor arena");
                    if(row_index==row_count-1) row_active<=0;
                    else row_index<=row_index+1;
                end
                if(mem_req_valid && !mem_req_write && mem_req_cacheable)
                    $fatal(1,"column mode emitted a scalar 3x3 tap request");
            end
        end
    end else begin : g_no_column_provider
        assign owner_backend_offered=0;
        assign owner_backend_fence=0;
        assign cache_stage_start_ready=1'b0;
        assign column_req_ready=1'b0;
        assign column_rsp_valid=1'b0;
        assign column_rsp_error=1'b0;
        assign column_rsp_data_s8='0;
        assign column_response_offered=1'b0;
        assign column_provider_busy=1'b0;
    end endgenerate

    assign mem_req_ready = !block_requests && (response_count < RESPONSE_DEPTH) &&
                           (force_request_ready || lfsr_q[0]);
    assign mem_rsp_valid = response_pending_q &&
                           (response_delay_q == 0) && !hold_responses;
    logic inject_tap_read_error = 0;
    assign mem_rsp_error = response_error_q || inject_tap_read_error ||
                          (inject_write_completion_error &&
                           (dut.result_writes_pending_q != 0 || dut.source_writes_pending_q != 0));
    assign mem_rsp_rdata = response_data_q;
    logic queued_is_write[0:RESPONSE_DEPTH-1];
    integer source_raster_requests=0;
    always @(posedge clk) begin
        if(rst || (adapter_start_valid && adapter_start_ready)) source_raster_requests=0;
        else if(mem_req_valid && mem_req_ready && dut.state_q==3) begin
            if(mem_req_addr!=BASE_ADDR+8*source_raster_requests ||
               mem_req_wdata!==source_data_fn(source_raster_requests%FRAME_W,source_raster_requests/FRAME_W) ||
               mem_req_end!==(!SOURCE_PIPELINE || (source_raster_requests%FRAME_W)%8==7 ||
                              source_raster_requests%FRAME_W==FRAME_W-1))
                $fatal(1,"source independent raster/data/end budget mismatch");
            source_raster_requests++;
        end
    end
    logic [63:0] queued_write_data[0:RESPONSE_DEPTH-1];
    integer queued_write_index[0:RESPONSE_DEPTH-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            lfsr_q <= 32'h5a17_03c9;
            response_count <= 0;
            response_head <= 0;
            response_tail <= 0;
            max_response_count <= 0;
            request_count <= 0;
            read_count <= 0;
            write_count <= 0;
            request_stall_count <= 0;
            response_gap_count <= 0;
            adjacent_pairable_count <= 0;
            adjacent_same_base_count <= 0;
            have_prev_request <= 1'b0;
            prev_request_addr <= 32'd0;
            prev_request_write <= 1'b0;
        end else begin
            if (response_count > max_response_count)
                max_response_count <= response_count;
            case ({mem_req_valid && mem_req_ready, mem_rsp_valid && mem_rsp_ready})
                2'b10: response_count <= response_count + 1;
                2'b01: response_count <= response_count - 1;
                default: ;
            endcase
            lfsr_q <= {lfsr_q[30:0],
                       lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
            if (mem_req_valid && !mem_req_ready)
                request_stall_count <= request_stall_count + 1;
            if (response_pending_q && !mem_rsp_valid)
                response_gap_count <= response_gap_count + 1;

            if (response_pending_q && (response_delay_q != 0) &&
                !hold_responses)
                queued_delay[response_head] <= response_delay_q - 1'b1;

            if (mem_req_valid && mem_req_ready) begin
                if (response_pending_q &&
                    ((!PIPELINED_WRITES && !(SOURCE_PIPELINE && dut.state_q==3)) || !mem_req_write))
                    $fatal(1, "memory BFM accepted an unfenced request");
                if (mem_req_addr[2:0] != 0 || mem_req_addr < BASE_ADDR ||
                    mem_req_addr >= BASE_ADDR + 3 * BANK_BYTES)
                    $fatal(1, "memory address out of tensor arena: %h",
                           mem_req_addr);
                memory_index = (mem_req_addr - BASE_ADDR) >> 3;
                request_count <= request_count + 1;
                // This observes address adjacency, not physical AXI packing.
                // The optional writer now permits coexistence, while the
                // default adapter still admits only one request at a time.
                if (have_prev_request &&
                    (mem_req_addr[31:4] == prev_request_addr[31:4]) &&
                    (mem_req_addr[2:0] == 3'b000) &&
                    (prev_request_addr[2:0] == 3'b000) &&
                    (mem_req_addr[3] != prev_request_addr[3]) &&
                    (mem_req_write == prev_request_write)) begin
                    adjacent_pairable_count <= adjacent_pairable_count + 1;
                end
                if (have_prev_request &&
                    (mem_req_addr[31:4] == prev_request_addr[31:4]))
                    adjacent_same_base_count <= adjacent_same_base_count + 1;
                have_prev_request <= 1'b1;
                prev_request_addr <= mem_req_addr;
                prev_request_write <= mem_req_write;
                response_tail <= (response_tail + 1) % RESPONSE_DEPTH;
                queued_delay[response_tail] <= ((PIPELINED_WRITES || SOURCE_PIPELINE) && mem_req_write) ?
                                               8'd20 :
                    ((!mem_req_write && FIXED_READ_DELAY >= 0) ?
                     FIXED_READ_DELAY : {6'd0, lfsr_q[3:2]});
                queued_error[response_tail] <= inject_response_error;
                queued_is_write[response_tail] <= mem_req_write;
                queued_write_index[response_tail] <= memory_index;
                queued_write_data[response_tail] <= mem_req_wdata;
                if (mem_req_write) begin
                    write_count <= write_count + 1;
                    if (mem_req_wstrb != 8'hff)
                        $fatal(1, "tensor write did not cover one C8 beat");
                    for (byte_lane = 0; byte_lane < 8;
                         byte_lane = byte_lane + 1)
                        if (mem_req_wstrb[byte_lane] && !COLUMN_WRITE_OVERLAP && !POINTWISE_COLUMNS && !SOURCE_PIPELINE)
                            memory[memory_index][byte_lane*8 +: 8] <=
                                mem_req_wdata[byte_lane*8 +: 8];
                    queued_data[response_tail] <= 64'd0;
                end else begin
                    read_count <= read_count + 1;
                    if (mem_req_wstrb != 0)
                        $fatal(1, "tensor read carried nonzero byte strobes");
                    queued_data[response_tail] <= memory[memory_index];
                end
            end

            if (mem_rsp_valid && mem_rsp_ready) begin
                // Overlap tests commit only at real logical write retirement,
                // so an illegal cross-stage read cannot see early source data.
                if((COLUMN_WRITE_OVERLAP || POINTWISE_COLUMNS || SOURCE_PIPELINE) && queued_is_write[response_head])
                    memory[queued_write_index[response_head]] <= queued_write_data[response_head];
                response_head <= (response_head + 1) % RESPONSE_DEPTH;
            end
        end
    end

    function automatic logic [7:0] stage_opcode_fn(input integer stage);
        begin
            case (stage)
                0, 1, 20: stage_opcode_fn = 8'd1;
                2, 4, 6, 8, 10, 12, 16, 19:
                    stage_opcode_fn = 8'd2;
                3, 7, 11, 15, 18: stage_opcode_fn = 8'd3;
                14, 17: stage_opcode_fn = 8'd4;
                5, 9, 13: stage_opcode_fn = 8'd5;
                21: stage_opcode_fn = 8'd6;
                default: stage_opcode_fn = 8'hff;
            endcase
        end
    endfunction

    function automatic integer stage_cin_fn(input integer stage);
        begin
            case (stage)
                0: stage_cin_fn = 3;
                1: stage_cin_fn = 12;
                2, 5, 6, 9, 10, 13, 14, 15, 16:
                    stage_cin_fn = 24;
                3, 4, 7, 8, 11, 12: stage_cin_fn = 48;
                17, 18, 19: stage_cin_fn = 16;
                20: stage_cin_fn = 8;
                21: stage_cin_fn = 3;
                default: stage_cin_fn = 0;
            endcase
        end
    endfunction

    function automatic integer stage_cout_fn(input integer stage);
        begin
            case (stage)
                0: stage_cout_fn = 12;
                1, 4, 5, 8, 9, 12, 13, 14, 15:
                    stage_cout_fn = 24;
                2, 3, 6, 7, 10, 11: stage_cout_fn = 48;
                16, 17, 18: stage_cout_fn = 16;
                19: stage_cout_fn = 8;
                20, 21: stage_cout_fn = 3;
                default: stage_cout_fn = 0;
            endcase
        end
    endfunction

    function automatic integer stage_iw_fn(input integer stage);
        begin
            if (stage == 0)
                stage_iw_fn = FRAME_W;
            else if (stage == 1)
                stage_iw_fn = FRAME_W / 2;
            else if (stage <= 14)
                stage_iw_fn = FRAME_W / 4;
            else if (stage <= 17)
                stage_iw_fn = FRAME_W / 2;
            else
                stage_iw_fn = FRAME_W;
        end
    endfunction

    function automatic integer stage_ih_fn(input integer stage);
        begin
            if (stage == 0)
                stage_ih_fn = FRAME_H;
            else if (stage == 1)
                stage_ih_fn = FRAME_H / 2;
            else if (stage <= 14)
                stage_ih_fn = FRAME_H / 4;
            else if (stage <= 17)
                stage_ih_fn = FRAME_H / 2;
            else
                stage_ih_fn = FRAME_H;
        end
    endfunction

    function automatic integer stage_ow_fn(input integer stage);
        begin
            if (stage == 0)
                stage_ow_fn = FRAME_W / 2;
            else if (stage <= 13)
                stage_ow_fn = FRAME_W / 4;
            else if (stage <= 16)
                stage_ow_fn = FRAME_W / 2;
            else
                stage_ow_fn = FRAME_W;
        end
    endfunction

    function automatic integer stage_oh_fn(input integer stage);
        begin
            if (stage == 0)
                stage_oh_fn = FRAME_H / 2;
            else if (stage <= 13)
                stage_oh_fn = FRAME_H / 4;
            else if (stage <= 16)
                stage_oh_fn = FRAME_H / 2;
            else
                stage_oh_fn = FRAME_H;
        end
    endfunction

    function automatic integer input_bank_fn(input integer stage);
        begin
            case (stage)
                0: input_bank_fn = 0;
                1: input_bank_fn = 1;
                2: input_bank_fn = 0;
                3: input_bank_fn = 1;
                4: input_bank_fn = 2;
                5: input_bank_fn = 1;
                6: input_bank_fn = 2;
                7: input_bank_fn = 0;
                8: input_bank_fn = 1;
                9: input_bank_fn = 0;
                10: input_bank_fn = 1;
                11: input_bank_fn = 2;
                12: input_bank_fn = 0;
                13: input_bank_fn = 2;
                14: input_bank_fn = 0;
                15: input_bank_fn = 1;
                16: input_bank_fn = 0;
                17: input_bank_fn = 1;
                18: input_bank_fn = 0;
                19: input_bank_fn = 1;
                20: input_bank_fn = 0;
                21: input_bank_fn = 1;
                default: input_bank_fn = 0;
            endcase
            if(VIRTUAL_UPSAMPLE) case(stage)
                15,17: input_bank_fn=0;
                16: input_bank_fn=1;
                default: ;
            endcase
        end
    endfunction

    function automatic integer output_bank_fn(input integer stage);
        begin
            case (stage)
                0: output_bank_fn = 1;
                1: output_bank_fn = 0;
                2: output_bank_fn = 1;
                3: output_bank_fn = 2;
                4: output_bank_fn = 1;
                5: output_bank_fn = 2;
                6: output_bank_fn = 0;
                7: output_bank_fn = 1;
                8: output_bank_fn = 0;
                9: output_bank_fn = 1;
                10: output_bank_fn = 2;
                11: output_bank_fn = 0;
                12: output_bank_fn = 2;
                13: output_bank_fn = 0;
                14: output_bank_fn = 1;
                15: output_bank_fn = 0;
                16: output_bank_fn = 1;
                17: output_bank_fn = 0;
                18: output_bank_fn = 1;
                19: output_bank_fn = 0;
                20: output_bank_fn = 1;
                default: output_bank_fn = 3;
            endcase
            if(VIRTUAL_UPSAMPLE) case(stage)
                14,17: output_bank_fn=3;
                15: output_bank_fn=1;
                16: output_bank_fn=0;
                default: ;
            endcase
        end
    endfunction

    function automatic integer residual_bank_fn(input integer stage);
        begin
            case (stage)
                5: residual_bank_fn = 0;
                9: residual_bank_fn = 2;
                13: residual_bank_fn = 1;
                default: residual_bank_fn = 3;
            endcase
        end
    endfunction

    function automatic logic [511:0] descriptor_fn(input integer stage);
        logic [511:0] d;
        integer op, iw, ih, ow, oh, ci, co;
        integer kw, kh, sx, sy, flags, activation;
        begin
            d = 512'd0;
            op = stage_opcode_fn(stage);
            iw = stage_iw_fn(stage);
            ih = stage_ih_fn(stage);
            ow = stage_ow_fn(stage);
            oh = stage_oh_fn(stage);
            ci = stage_cin_fn(stage);
            co = stage_cout_fn(stage);
            kw = ((op == 1) || (op == 3)) ? 3 : 1;
            kh = kw;
            sx = ((stage == 0) || (stage == 1) ||
                  (op == 4)) ? 2 : 1;
            sy = sx;
            flags = (((op == 1) || (op == 3)) ? 1 : 0) |
                    ((op == 5) ? 2 : 0) |
                    ((stage == 0) ? 4 : 0) |
                    ((stage == 21) ? 8 : 0);
            activation = ((stage == 4) || (stage == 8) ||
                          (stage == 12) || (stage == 14) ||
                          (stage == 17) || (stage >= 20)) ? 0 : 1;
            d[7:0] = op[7:0];
            d[9:8] = activation[1:0];
            d[15:10] = flags[5:0];
            d[23:16] = 8'd1;
            d[31:24] = 8'd16;
            d[47:32] = iw[15:0];
            d[63:48] = ih[15:0];
            d[79:64] = ow[15:0];
            d[95:80] = oh[15:0];
            d[111:96] = ci[15:0];
            d[127:112] = co[15:0];
            d[423:416] = kw[7:0];
            d[431:424] = kh[7:0];
            d[439:432] = sx[7:0];
            d[447:440] = sy[7:0];
            d[455:448] = 8'd1;
            d[463:456] = 8'd1;
            d[471:464] = 8'd1;
            d[479:472] = 8'd1;
            d[511:480] = 32'd1000000;
            descriptor_fn = d;
        end
    endfunction

    function automatic logic [63:0] source_data_fn(
        input integer x, input integer y
    );
        logic [63:0] value;
        integer lane;
        begin
            value = 64'd0;
            for (lane = 0; lane < 3; lane = lane + 1)
                value[lane*8 +: 8] = (8'h31 + x*7 + y*11 + lane*17) & 8'hff;
            source_data_fn = value;
        end
    endfunction

    function automatic logic [63:0] result_data_fn(
        input integer stage,
        input integer x,
        input integer y,
        input integer group_index
    );
        logic [63:0] value;
        integer lane;
        integer channel;
        integer producer, px, py;
        begin
            // Unlike the arithmetic stand-in for convolution, UPSAMPLE must
            // obey nearest-neighbour identity in BOTH physical layouts.
            producer=stage; px=x; py=y;
            if(stage==14 || stage==17) begin
                producer=stage-1; px=x/2; py=y/2;
            end
            // OUTPUT_RGB is an identity in signed C8 space, not another
            // arithmetic stand-in. Conversion to u8 belongs to the egress.
            if(stage==21) producer=20;
            value = 64'd0;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                channel = group_index * 8 + lane;
                if (channel < stage_cout_fn(stage))
                    value[lane*8 +: 8] =
                        (producer*13 + px*7 + py*5 +
                         group_index*23 + lane*3 + 8'h19) & 8'hff;
            end
            result_data_fn = value;
        end
    endfunction

    integer expected_stage_q;
    integer expected_x_q, expected_y_q, expected_input_group_q;
    logic result_active_q;
    logic result_valid_q;
    integer result_stage_q, result_x_q, result_y_q, result_group_q;
    integer engine_stall_count;
    integer final_stall_count;
    integer engine_operand_count;
    integer final_count;
    integer stage_seen [0:STAGES-1];
    integer op_seen [1:6];
    integer border_window_count;
    integer upsample_operand_count;
    integer residual_operand_count;
    integer residual_bank_seen [0:2];

    assign adapter_engine_ready = !result_active_q && !result_valid_q &&
                                  lfsr_q[5];
    assign adapter_result_valid = result_valid_q && !fusion_hold_result;
    assign adapter_result_data_s8 = result_data_fn(
        result_stage_q, result_x_q, result_y_q, result_group_q) ^
        ((fusion_bad_field==0)?64'h0000_0000_0100_0000:64'd0);
    assign adapter_result_group_index = result_group_q[2:0] ^ ((fusion_bad_field==2)?3'd1:3'd0);
    assign adapter_result_group_last =
        (result_group_q == ((stage_cout_fn(result_stage_q) + 7) / 8) - 1) && fusion_bad_field!=6;
    assign adapter_result_x = result_x_q[15:0]+((fusion_bad_field==1)?16'd1:16'd0);
    assign adapter_result_y = result_y_q[15:0]+((fusion_bad_field==7)?16'd1:16'd0);
    assign adapter_result_sof = (result_group_q == 0) &&
                                (result_x_q == 0) && (result_y_q == 0) && fusion_bad_field!=3;
    assign adapter_result_eol = (adapter_result_group_last &&
                                (result_x_q == stage_ow_fn(result_stage_q)-1)) ^ (fusion_bad_field==4);
    assign adapter_result_eof = (adapter_result_eol &&
                                (result_y_q == stage_oh_fn(result_stage_q)-1)) ^ (fusion_bad_field==5);
    assign view_commit_ready = FUSE_FINAL && expected_stage_q==21 &&
        !result_active_q && !result_valid_q && fusion_prepare_cycles>=6 &&
        !fusion_block_commit && !adapter_abort;
    assign adapter_final_ready = lfsr_q[7] && (!FUSE_FINAL ||
        (!fusion_block_final && (!adapter_final_eof || (fusion_committed && fusion_eof_cycles>=8))));
    always @(posedge clk) begin
        if(rst || adapter_abort || (adapter_start_valid && adapter_start_ready)) begin
            fusion_committed<=0;fusion_prepare_cycles<=0;fusion_eof_cycles<=0;
        end else begin
            if(adapter_stage_config_valid && adapter_stage_config_ready)
                fusion_generation<=adapter_stage_config_generation;
            if(FUSE_FINAL && view_commit_valid)fusion_prepare_cycles<=fusion_prepare_cycles+1;
            if(FUSE_FINAL && view_commit_valid && view_commit_ready) begin
                if(view_commit_stage!=21 || view_commit_generation!=fusion_generation ||
                   !adapter_final_valid || !adapter_final_eof || fusion_committed ||
                   adapter_engine_valid || mem_req_valid || column_req_valid)
                    $fatal(1,"invalid fused final commit/held EOF/ownership");
                fusion_committed<=1;fusion_commits<=fusion_commits+1;
            end
            if(fusion_committed && adapter_final_valid && adapter_final_eof)
                fusion_eof_cycles<=fusion_eof_cycles+1;
        end
    end

    task automatic check_engine_operand;
        integer stage, x, y, group_index;
        integer iw, ih, groups, op, stride;
        integer tap, sx, sy, dx, dy;
        logic [63:0] expected_word;
        begin
            stage = expected_stage_q;
            x = expected_x_q;
            y = expected_y_q;
            group_index = expected_input_group_q;
            iw = stage_iw_fn(stage);
            ih = stage_ih_fn(stage);
            groups = (stage_cin_fn(stage) + 7) / 8;
            op = stage_opcode_fn(stage);
            stride = ((stage == 0) || (stage == 1)) ? 2 : 1;

            if (active_stage_index !== stage[4:0] ||
                active_stage_opcode !== op[7:0] ||
                adapter_engine_group_index !== group_index[2:0] ||
                adapter_engine_group_last !== (group_index == groups-1) ||
                adapter_engine_x !== x[15:0] ||
                adapter_engine_y !== y[15:0])
                $fatal(1, "engine operand sequence mismatch stage=%0d x=%0d y=%0d g=%0d",
                       stage, x, y, group_index);
            if (adapter_engine_sof !== ((x == 0) && (y == 0)) ||
                adapter_engine_eol !== (x == stage_ow_fn(stage)-1) ||
                adapter_engine_eof !== ((x == stage_ow_fn(stage)-1) &&
                                        (y == stage_oh_fn(stage)-1)))
                $fatal(1, "engine input marker mismatch");
            if (active_input_bank !== input_bank_fn(stage) ||
                active_output_bank !== output_bank_fn(stage) ||
                active_residual_bank !== residual_bank_fn(stage))
                $fatal(1, "published tensor bank map mismatch");

            for (tap = 0; tap < 9; tap = tap + 1) begin
                if ((op == 1) || (op == 3)) begin
                    dx = (tap % 3) - 1;
                    dy = (tap / 3) - 1;
                    sx = x * stride + dx;
                    sy = y * stride + dy;
                    if (sx < 0) sx = 0;
                    if (sy < 0) sy = 0;
                    if (sx >= iw) sx = iw - 1;
                    if (sy >= ih) sy = ih - 1;
                    // Golden is the independently defined LOGICAL producer,
                    // not a read of the same mutable physical DDR bank.
                    // Wrong bank writes cannot make a wrong operand self-pass.
                    expected_word = (stage==0) ? source_data_fn(sx,sy) :
                        result_data_fn(stage-1,sx,sy,group_index);
                end else if (tap == 4) begin
                    if (op == 4) begin
                        sx = x / 2;
                        sy = y / 2;
                    end else begin
                        sx = x;
                        sy = y;
                    end
                    expected_word = result_data_fn(stage-1,sx,sy,group_index);
                end else begin
                    expected_word = 64'd0;
                end
                if (adapter_engine_window_s8[tap*64 +: 64] !==
                    expected_word)
                    $fatal(1, "window mismatch stage=%0d x=%0d y=%0d g=%0d tap=%0d got=%h exp=%h",
                           stage, x, y, group_index, tap,
                           adapter_engine_window_s8[tap*64 +: 64],
                           expected_word);
            end

            if (op == 5) begin
                expected_word = result_data_fn((stage==5)?1:((stage==9)?5:9),
                    x,y,group_index);
                if (adapter_engine_residual_s8 !== expected_word)
                    $fatal(1, "residual operand mismatch stage=%0d", stage);
            end else if (adapter_engine_residual_s8 !== 0) begin
                $fatal(1, "non-residual stage carried residual data");
            end
        end
    endtask

    integer model_i;
    always_ff @(posedge clk) begin
        if (rst) begin
            expected_stage_q <= 0;
            expected_x_q <= 0;
            expected_y_q <= 0;
            expected_input_group_q <= 0;
            result_active_q <= 1'b0;
            result_valid_q <= 1'b0;
            result_stage_q <= 0;
            result_x_q <= 0;
            result_y_q <= 0;
            result_group_q <= 0;
            engine_stall_count <= 0;
            final_stall_count <= 0;
            engine_operand_count <= 0;
            final_count <= 0;
            border_window_count <= 0;
            upsample_operand_count <= 0;
            residual_operand_count <= 0;
            for (model_i = 0; model_i < STAGES; model_i = model_i + 1)
                stage_seen[model_i] <= 0;
            for (model_i = 1; model_i <= 6; model_i = model_i + 1)
                op_seen[model_i] <= 0;
            for (model_i = 0; model_i < 3; model_i = model_i + 1)
                residual_bank_seen[model_i] <= 0;
        end else begin
            if(FUSE_FINAL && view_commit_valid && view_commit_ready) expected_stage_q<=STAGES;
            if (adapter_engine_valid && !adapter_engine_ready)
                engine_stall_count <= engine_stall_count + 1;
            if (adapter_final_valid && !adapter_final_ready)
                final_stall_count <= final_stall_count + 1;

            if (adapter_engine_valid && adapter_engine_ready) begin
                check_engine_operand();
                engine_operand_count <= engine_operand_count + 1;
                stage_seen[expected_stage_q] <=
                    stage_seen[expected_stage_q] + 1;
                op_seen[stage_opcode_fn(expected_stage_q)] <=
                    op_seen[stage_opcode_fn(expected_stage_q)] + 1;
                if (((stage_opcode_fn(expected_stage_q) == 1) ||
                     (stage_opcode_fn(expected_stage_q) == 3)) &&
                    ((expected_x_q == 0) || (expected_y_q == 0) ||
                     (expected_x_q == stage_ow_fn(expected_stage_q)-1) ||
                     (expected_y_q == stage_oh_fn(expected_stage_q)-1)))
                    border_window_count <= border_window_count + 1;
                if (stage_opcode_fn(expected_stage_q) == 4)
                    upsample_operand_count <= upsample_operand_count + 1;
                if (stage_opcode_fn(expected_stage_q) == 5) begin
                    residual_operand_count <= residual_operand_count + 1;
                    residual_bank_seen[residual_bank_fn(expected_stage_q)] <=
                        residual_bank_seen[residual_bank_fn(expected_stage_q)] + 1;
                end

                if (expected_input_group_q ==
                    ((stage_cin_fn(expected_stage_q) + 7) / 8) - 1) begin
                    result_active_q <= 1'b1;
                    result_stage_q <= expected_stage_q;
                    result_x_q <= expected_x_q;
                    result_y_q <= expected_y_q;
                    result_group_q <= 0;
                end else begin
                    expected_input_group_q <= expected_input_group_q + 1;
                end
            end

            if (result_active_q && !result_valid_q && lfsr_q[9])
                result_valid_q <= 1'b1;

            if (adapter_result_valid && adapter_result_ready) begin
                result_valid_q <= 1'b0;
                if (adapter_result_group_last) begin
                    result_active_q <= 1'b0;
                    expected_input_group_q <= 0;
                    if (adapter_result_eof) begin
                        expected_stage_q <= expected_stage_q + 1;
                        expected_x_q <= 0;
                        expected_y_q <= 0;
                    end else if (expected_x_q ==
                                 stage_ow_fn(expected_stage_q)-1) begin
                        expected_x_q <= 0;
                        expected_y_q <= expected_y_q + 1;
                    end else begin
                        expected_x_q <= expected_x_q + 1;
                    end
                end else begin
                    result_group_q <= result_group_q + 1;
                end
            end

            if (adapter_final_valid && adapter_final_ready) begin
                if (adapter_final_data_s8 !== result_data_fn(
                        21, adapter_final_x, adapter_final_y, 0))
                    $fatal(1, "final C8 data mismatch");
                if (adapter_final_sof !==
                        ((adapter_final_x == 0) && (adapter_final_y == 0)) ||
                    adapter_final_eol !== (adapter_final_x == FRAME_W-1) ||
                    adapter_final_eof !==
                        ((adapter_final_x == FRAME_W-1) &&
                         (adapter_final_y == FRAME_H-1)))
                    $fatal(1, "final marker mismatch");
                final_count <= final_count + 1;
            end
        end
    end

    task automatic reset_engine_model;
        begin
            @(negedge clk);
            expected_stage_q = 0;
            expected_x_q = 0;
            expected_y_q = 0;
            expected_input_group_q = 0;
            result_active_q = 1'b0;
            result_valid_q = 1'b0;
            result_stage_q = 0;
            result_x_q = 0;
            result_y_q = 0;
            result_group_q = 0;
        end
    endtask

    task automatic start_job;
        begin
            @(negedge clk);
            tensor_base_addr = BASE_ADDR;
            adapter_start_valid = 1'b1;
            do @(posedge clk); while (!adapter_start_ready);
            @(negedge clk);
            adapter_start_valid = 1'b0;
        end
    endtask

    task automatic send_all_descriptors(input logic [7:0] generation);
        integer stage;
        begin
            for (stage = 0; stage < STAGES; stage = stage + 1) begin
                repeat (lfsr_q[1:0]) @(posedge clk);
                @(negedge clk);
                adapter_stage_config_index = stage[15:0];
                adapter_stage_config_descriptor = descriptor_fn(stage);
                adapter_stage_config_generation = generation;
                adapter_stage_config_valid = 1'b1;
                do @(posedge clk); while (!adapter_stage_config_ready);
                @(negedge clk);
                adapter_stage_config_valid = 1'b0;
            end
        end
    endtask

    task automatic send_source_beat(input integer x, input integer y);
        begin
            repeat (lfsr_q[3:2]) @(posedge clk);
            @(negedge clk);
            adapter_source_data_s8 = source_data_fn(x, y);
            adapter_source_x = x[15:0];
            adapter_source_y = y[15:0];
            adapter_source_sof = (x == 0) && (y == 0);
            adapter_source_eol = (x == FRAME_W-1);
            adapter_source_eof = (x == FRAME_W-1) && (y == FRAME_H-1);
            adapter_source_valid = 1'b1;
            do @(posedge clk); while (!adapter_source_ready);
            @(negedge clk);
            adapter_source_valid = 1'b0;
        end
    endtask

    task automatic send_source_frame;
        integer x, y;
        begin
            for (y = 0; y < FRAME_H; y = y + 1)
                for (x = 0; x < FRAME_W; x = x + 1)
                    send_source_beat(x, y);
        end
    endtask

    task automatic pulse_abort;
        begin
            @(negedge clk);
            adapter_abort = 1'b1;
            @(negedge clk);
            adapter_abort = 1'b0;
        end
    endtask

    task automatic check_tap_prefetch_drain(input integer phase, input bit fault,
                                          input bit held_request = 1);
        integer guard, accepted_before;
        begin
            reset_engine_model();
            start_job();
            send_all_descriptors(8'h32);
            send_source_frame();
            guard = 0;
            while (dut.state_q != 7) begin
                @(negedge clk);
                guard++;
                if (guard > 200) $fatal(1,"prefetch drain did not reach read request");
            end
            block_requests = 1;
            hold_responses = 1;
            accepted_before = request_count + 1;
            if (!held_request) begin
                block_requests = 0;
                do @(posedge clk); while (!mem_req_ready);
                @(negedge clk);
            end
            guard = 0;
            while (dut.tap_addr_prefetch_phase_q != phase) begin
                @(negedge clk);
                guard++;
                if (guard > 10) $fatal(1,"prefetch drain phase not reached");
            end
            if (fault) begin
                if (held_request) begin
                    block_requests = 0;
                    do @(posedge clk); while (!mem_req_ready);
                    @(negedge clk);
                end
                inject_tap_read_error = 1;
                hold_responses = 0;
                guard = 0;
                while (!adapter_error) begin
                    @(negedge clk);
                    guard++;
                    if (guard > 100) $fatal(1,"prefetched read error not reported");
                end
                if (adapter_error_code != 8'h07 || response_pending_q)
                    $fatal(1,"prefetched read error did not retire correctly");
                inject_tap_read_error = 0;
                pulse_abort();
            end else begin
                // Assert at this falling edge, before the chosen phase advances.
                adapter_abort = 1;
                @(negedge clk);
                adapter_abort = 0;
                repeat (6) begin
                    @(negedge clk);
                    if (!adapter_busy || adapter_aborted ||
                        mem_req_valid != held_request ||
                        adapter_engine_valid)
                        $fatal(1,"prefetch abort leaked work or retired before response");
                end
                if (held_request) begin
                    block_requests = 0;
                    do @(posedge clk); while (!mem_req_ready);
                    @(negedge clk);
                    repeat (6) begin
                        @(negedge clk);
                        if (!adapter_busy || adapter_aborted || mem_req_valid)
                            $fatal(1,"prefetch abort did not drain accepted held request");
                    end
                end
                hold_responses = 0;
            end
            guard = 0;
            while (adapter_busy) begin
                @(negedge clk);
                guard++;
                if (guard > 100) $fatal(1,"prefetch cancellation did not drain");
            end
            // pulse_abort may return on the very edge that lowers abort;
            // observe combinational start_ready after that input settles.
            @(negedge clk);
            if (request_count != accepted_before || response_pending_q ||
                adapter_error || !adapter_start_ready)
                $fatal(1,"prefetch drain requests=%0d expected=%0d pending=%0b error=%0b ready=%0b",
                    request_count, accepted_before, response_pending_q,
                    adapter_error, adapter_start_ready);
            $display("C1_ADAPTER_TAP_DRAIN_PASS phase=%0d fault=%0d restart_ready=1 held_request=%0d",phase,fault,held_request);
        end
    endtask

    task automatic check_horizontal_reuse_restart;
        integer guard, final_before;
        begin
            reset_engine_model();
            start_job();
            send_all_descriptors(8'h32);
            send_source_frame();
            guard=0;
            while (!(dut.state_q==6 && dut.window_reuse_admit)) begin
                @(negedge clk); guard++;
                if(guard>20000) $fatal(1,"reuse cancel never reached a populated history");
            end
            if(dut.window_history_valid_q==0) $fatal(1,"reuse cancel history empty");
            adapter_abort=1;
            @(negedge clk); adapter_abort=0;
            @(negedge clk);
            if(COLUMN_WRITE_OVERLAP) begin
                guard=0;
                while(adapter_busy) begin
                    if(adapter_engine_valid || column_req_valid || mem_req_valid || adapter_start_ready)
                        $fatal(1,"reuse cancel admitted work while writes drain");
                    @(negedge clk);guard++;
                    if(guard>200) $fatal(1,"reuse cancel write drain timed out");
                end
            end
            if(adapter_busy || adapter_error || dut.window_history_valid_q!=0 || response_pending_q)
                $fatal(1,"reuse cancel did not invalidate idle history");
            reset_engine_model();
            final_before=final_count;
            start_job();
            send_all_descriptors(8'h32);
            send_source_frame();
            guard=0;
            while(!adapter_done) begin
                @(negedge clk); guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"reuse restart did not finish");
            end
            if(adapter_error || adapter_busy || final_count-final_before != FRAME_W*FRAME_H)
                $fatal(1,"reuse restart final frame mismatch");
            $display("C1_ADAPTER_REUSE_RESTART_PASS populated_cancel=1 invalidated=1 full_restart=1 reset=0");
        end
    endtask

    // An older accepted write and a newer offered payload coexist here.
    // Check both cancel and late write-error while the new VALID is held.
    task automatic check_source_pipeline_drain(input bit fault, input bit held_request);
        integer guard, expected_requests;
        logic [104:0] held_payload;
        begin
            reset_engine_model();start_job();send_all_descriptors(8'h61);
            hold_responses=1;force_request_ready=1;
            send_source_beat(0,0);
            guard=0;
            while(dut.source_writes_pending_q==0) begin
                @(negedge clk);guard++;if(guard>100) $fatal(1,"source older write missing");
            end
            block_requests=held_request;
            send_source_beat(1,0);
            guard=0;
            while(held_request ? !mem_req_valid : dut.source_writes_pending_q!=2) begin
                @(negedge clk);guard++;if(guard>100) $fatal(1,"source newer write missing");
            end
            held_payload={mem_req_addr,mem_req_wdata,mem_req_wstrb,mem_req_end};
            expected_requests=request_count+(held_request?1:0);
            if(fault) begin
                inject_write_completion_error=1;hold_responses=0;guard=0;
                while(!adapter_error) begin
                    @(negedge clk);guard++;if(guard>100) $fatal(1,"source write error lost");
                end
                hold_responses=1;inject_write_completion_error=0;
                if(adapter_error_code!=8'h07) $fatal(1,"wrong source write error code");
            end
            pulse_abort();
            repeat(6) begin
                @(negedge clk);
                if(adapter_source_ready || adapter_engine_valid || adapter_aborted || !adapter_busy)
                    $fatal(1,"source cancel crossed outstanding fence");
                if(held_request && (!mem_req_valid ||
                    {mem_req_addr,mem_req_wdata,mem_req_wstrb,mem_req_end}!==held_payload))
                    $fatal(1,"source cancel/error withdrew offered write");
            end
            block_requests=0;hold_responses=0;guard=0;
            while(!adapter_aborted) begin
                @(negedge clk);guard++;if(guard>300) $fatal(1,"source cancel drain timeout");
            end
            if(adapter_busy || adapter_error || response_count!=0 ||
               dut.source_writes_pending_q!=0 || request_count!=expected_requests)
                $fatal(1,"source write drain conservation mismatch");
            force_request_ready=0;
            $display("C1_SOURCE_PIPELINE_DRAIN_PASS fault=%0d held=%0d reset=0",fault,held_request);
        end
    endtask

    task automatic check_source_pipeline_protocol(input integer bad_field);
        integer guard;
        begin
            reset_engine_model();start_job();send_all_descriptors(8'h63);
            hold_responses=1;force_request_ready=1;send_source_beat(0,0);
            guard=0;
            while(!adapter_source_ready) begin
                @(negedge clk);guard++;if(guard>100) $fatal(1,"source protocol precondition missing");
            end
            adapter_source_x=1;adapter_source_y=0;
            adapter_source_sof=bad_field==0;adapter_source_eol=bad_field==1;
            adapter_source_eof=bad_field==2;adapter_source_valid=1;
            @(posedge clk);@(negedge clk);adapter_source_valid=0;
            if(!adapter_error || adapter_error_code!=8'h05 || !adapter_busy || mem_req_valid)
                $fatal(1,"bad source metadata not rejected with writes pending");
            pulse_abort();repeat(5) begin
                @(negedge clk);if(!adapter_busy || adapter_aborted) $fatal(1,"metadata error discarded write debt");
            end
            hold_responses=0;guard=0;
            while(!adapter_aborted) begin
                @(negedge clk);guard++;if(guard>100) $fatal(1,"source metadata drain timeout");
            end
            if(response_count || dut.source_writes_pending_q || adapter_error)
                $fatal(1,"source metadata drain left debt");
            force_request_ready=0;
            $display("C1_SOURCE_PIPELINE_PROTOCOL_PASS bad_field=%0d reset=0",bad_field);
        end
    endtask

    task automatic check_source_pipeline_eof(input bit fault);
        integer n,guard,final_before;
        begin
            reset_engine_model();final_before=final_count;
            start_job();send_all_descriptors(8'h64);
            for(n=0;n<FRAME_W*FRAME_H-1;n++) send_source_beat(n%FRAME_W,n/FRAME_W);
            guard=0;
            while(dut.source_writes_pending_q!=0 || !adapter_source_ready) begin
                @(negedge clk);guard++;if(guard>600) $fatal(1,"source EOF prefix drain timeout");
            end
            hold_responses=1;force_request_ready=1;
            send_source_beat(FRAME_W-1,FRAME_H-1);
            guard=0;
            while(dut.source_writes_pending_q!=1) begin
                @(negedge clk);guard++;if(guard>100) $fatal(1,"source EOF missing write");
            end
            repeat(7) begin
                @(negedge clk);
                if(dut.state_q!=4 || adapter_engine_valid || cache_stage_start_valid || adapter_source_ready || adapter_done)
                    $fatal(1,"source EOF crossed final physical write fence");
            end
            inject_write_completion_error=fault;hold_responses=0;guard=0;
            while(fault ? !adapter_error : !adapter_done) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"source EOF continuation timeout");
            end
            inject_write_completion_error=0;force_request_ready=0;
            if(fault) begin
                if(adapter_error_code!=8'h07 || final_count!=final_before)
                    $fatal(1,"failed source EOF emitted compute output");
                pulse_abort();@(negedge clk);
            end else if(final_count-final_before!=FRAME_W*FRAME_H)
                $fatal(1,"source EOF restart output mismatch");
            if(adapter_busy || adapter_error || dut.source_writes_pending_q || response_count)
                $fatal(1,"source EOF failed to retire cleanly");
            $display("C1_SOURCE_PIPELINE_EOF_PASS fault=%0d held=7 reset=0",fault);
        end
    endtask

    task automatic check_source_pipeline_credit;
        integer n,guard;
        begin
            reset_engine_model();start_job();send_all_descriptors(8'h62);
            hold_responses=1;force_request_ready=1;
            for(n=0;n<15;n++) send_source_beat(n%FRAME_W,n/FRAME_W);
            guard=0;
            while(dut.source_writes_pending_q!=15) begin
                @(negedge clk);guard++;if(guard>100) $fatal(1,"source credit limit not reached");
            end
            adapter_source_valid=1;
            repeat(8) begin
                @(negedge clk);
                if(adapter_source_ready || mem_req_valid || dut.source_writes_pending_q!=15)
                    $fatal(1,"source credit limit did not backpressure ingress");
            end
            adapter_source_valid=0;pulse_abort();hold_responses=0;guard=0;
            while(!adapter_aborted) begin
                @(negedge clk);guard++;if(guard>600) $fatal(1,"source 15-credit drain timeout");
            end
            if(response_count || dut.source_writes_pending_q || adapter_error)
                $fatal(1,"source credit drain left debt");
            force_request_ready=0;
            $display("C1_SOURCE_PIPELINE_CREDIT_PASS peak=15 reset=0");
        end
    endtask

    task automatic column_full_restart;
        integer guard,final_before;
        begin
            guard=0;
            while(column_provider_busy) begin
                @(negedge clk);guard++;
                if(guard>200) $fatal(1,"column owner restart drain timeout");
            end
            reset_engine_model();final_before=final_count;
            start_job();send_all_descriptors(8'h72);send_source_frame();
            guard=0;
            while(!adapter_done) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"column full restart timeout");
            end
            if(adapter_error || adapter_busy || column_provider_busy ||
                column_request_count!=column_response_count ||
                final_count-final_before!=FRAME_W*FRAME_H)
                $fatal(1,"column restart lost ownership/final pixels");
        end
    endtask
    task automatic check_fused_eof_cancel(input bit after_commit);
        integer guard,before_final,before_requests,before_columns,before_commits;
        logic [98:0] held_payload;
        begin
            reset_engine_model();before_final=final_count;before_commits=fusion_commits;
            fusion_block_commit=!after_commit;
            start_job();send_all_descriptors(8'h81);send_source_frame();guard=0;
            while(!(adapter_final_valid && adapter_final_eof &&
                    (after_commit ? fusion_committed : view_commit_valid))) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT)$fatal(1,"fused EOF cancel boundary missing");
            end
            fusion_block_final=1;
            held_payload={adapter_final_data_s8,adapter_final_x,adapter_final_y,
                adapter_final_sof,adapter_final_eol,adapter_final_eof};
            before_requests=request_count;before_columns=column_request_count;
            repeat(12) begin
                @(negedge clk);
                if(!adapter_busy || adapter_done || adapter_error || !adapter_final_valid ||
                   adapter_final_ready || adapter_engine_valid || mem_req_valid || column_req_valid ||
                   held_payload!=={adapter_final_data_s8,adapter_final_x,adapter_final_y,
                       adapter_final_sof,adapter_final_eol,adapter_final_eof} ||
                   final_count-before_final!=FRAME_W*FRAME_H-1 ||
                   fusion_commits-before_commits!=int'(after_commit))
                    $fatal(1,"held fused EOF crossed the commit/completion barrier");
            end
            pulse_abort();@(negedge clk);
            if(adapter_busy || adapter_error || adapter_final_valid || view_commit_valid ||
               adapter_result_ready || request_count!=before_requests || column_request_count!=before_columns)
                $fatal(1,"fused EOF cancel leaked output/ownership");
            fusion_block_commit=0;fusion_block_final=0;
            column_full_restart();
            $display("C1_ADAPTER_FINAL_CANCEL_PASS after_commit=%0d held=12 full_restart=1 reset=0",after_commit);
        end
    endtask

    task automatic check_fused_result_fault(input integer bad_field,input bit held_request);
        integer guard,before_final,expected_requests,expected_columns;
        logic [36:0] held_column;
        logic [31:0] held_scalar;
        begin
            reset_engine_model();before_final=final_count;
            start_job();send_all_descriptors(8'h82);send_source_frame();guard=0;
            // Hold a real first result until the next raster window has an
            // actual offered/accepted read. No forced DUT state or fake ACK.
            while(!(active_stage_index==20 && adapter_engine_valid && adapter_engine_ready &&
                    adapter_engine_group_last && adapter_engine_x==0 && adapter_engine_y==0)) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT)$fatal(1,"fused fault input boundary missing");
            end
            fusion_hold_result=1;block_requests=held_request;block_column_requests=held_request;
            hold_responses=1;hold_column_responses=1;force_request_ready=1;guard=0;
            while(!(result_valid_q && (held_request ?
                    (COLUMN_READS ? column_req_valid : mem_req_valid) :
                    (COLUMN_READS ? column_request_count>column_response_count : response_pending_q)))) begin
                @(negedge clk);guard++;
                if(guard>300)$fatal(1,"fused fault lacked independent real read debt");
            end
            held_column={column_req_x,column_req_center_y,column_req_group};held_scalar=mem_req_addr;
            expected_requests=request_count+int'(held_request && !COLUMN_READS);
            expected_columns=column_request_count+int'(held_request && COLUMN_READS);
            fusion_bad_field=bad_field;fusion_hold_result=0;
            @(posedge clk);
            if(!adapter_result_valid || !adapter_result_ready)$fatal(1,"bad fused result not tested at acceptance");
            @(negedge clk);fusion_bad_field=-1;
            repeat(8) begin
                if(!adapter_error || adapter_error_code!=8'h06 || !adapter_busy || adapter_done ||
                   adapter_final_valid || adapter_engine_valid || adapter_result_ready || final_count!=before_final)
                    $fatal(1,"fused result fault escaped quarantine code=%h",adapter_error_code);
                if(held_request && (COLUMN_READS ?
                    (!column_req_valid || held_column!=={column_req_x,column_req_center_y,column_req_group}) :
                    (!mem_req_valid || mem_req_write || mem_req_addr!==held_scalar)))
                    $fatal(1,"bad fused result withdrew/changed prior read request");
                @(negedge clk);
            end
            block_requests=0;block_column_requests=0;hold_responses=0;hold_column_responses=0;guard=0;
            while(response_pending_q || column_provider_busy || dut.state_q!=dut.ST_ERROR) begin
                @(negedge clk);guard++;
                if(guard>400)$fatal(1,"fused result error did not drain real read before abort");
            end
            if(!adapter_error || request_count!=expected_requests || column_request_count!=expected_columns ||
               column_request_count!=column_response_count || final_count!=before_final)
                $fatal(1,"fused error read conservation mismatch");
            pulse_abort();@(negedge clk);force_request_ready=0;
            if(adapter_busy || adapter_error || !adapter_start_ready)$fatal(1,"fused error abort not idle");
            // A late producer packet must not be accepted with stale stage20
            // index after abort, even when downstream is ready.
            result_valid_q=1;
            repeat(5) begin
                @(negedge clk);
                if(adapter_result_ready || adapter_final_valid || adapter_error || adapter_done)
                    $fatal(1,"idle adapter accepted a stale final-convolution result");
            end
            result_valid_q=0;
            column_full_restart();
            $display("C1_ADAPTER_FINAL_FAULT_PASS field=%0d held=%0d drain_before_abort=1 idle_stale_rejected=1 full_restart=1 reset=0",bad_field,held_request);
        end
    endtask

    task automatic check_virtual_result_abort(input integer target_stage,input bit at_eof);
        integer guard, before_requests;
        begin
            reset_engine_model();
            start_job();send_all_descriptors(8'h75);send_source_frame();
            guard=0;
            while(!(active_stage_index==target_stage && adapter_result_valid && adapter_result_ready &&
                    (at_eof ? adapter_result_eof : !adapter_result_group_last))) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"virtual result abort boundary not reached");
            end
            before_requests=request_count;
            // Already on the falling edge: cancel THIS offered result before
            // its rising-edge handshake, including the stage17 EOF boundary.
            adapter_abort=1;
            #1;
            if(adapter_result_ready || mem_req_valid || adapter_engine_valid)
                $fatal(1,"virtual result cancellation admitted a new transfer");
            @(negedge clk);
            if(!adapter_aborted || adapter_busy || adapter_done || adapter_error ||
               active_stage_index!=target_stage || request_count!=before_requests || response_pending_q)
                $fatal(1,"virtual result cancel crossed stage/memory ownership boundary");
            adapter_abort=0;
            column_full_restart();
            $display("C1_VIRTUAL_UPSAMPLE_RESULT_ABORT_PASS stage=%0d eof=%0d no_stage_advance=1 full_restart=1 reset=0",target_stage,at_eof);
        end
    endtask
    task automatic check_column_abort(input bit held_request,input bit fault,
                                      input integer target_stage=0);
        integer guard,before_columns;
        logic [36:0] payload;
        begin
            reset_engine_model();
            start_job();send_all_descriptors(8'h71);send_source_frame();
            guard=0;
            while(!(cache_stage_start_valid && active_stage_index==target_stage)) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"target column abort stage not reached");
            end
            block_column_requests=held_request;hold_column_responses=1;
            inject_column_refill_error=fault;
            before_columns=column_request_count;
            guard=0;
            while(held_request ? !column_req_valid : !column_response_offered) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"column abort stimulus not reached");
            end
            payload={column_req_x,column_req_center_y,column_req_group};
            pulse_abort();
            repeat(7) begin
                @(posedge clk);#1;
                if(!adapter_busy || adapter_aborted || adapter_engine_valid || mem_req_valid)
                    $fatal(1,"column abort acknowledged before pending work drained");
                if(held_request && (!column_req_valid || column_req_ready ||
                    {column_req_x,column_req_center_y,column_req_group}!==payload))
                    $fatal(1,"column abort withdrew/changed an unaccepted request");
            end
            @(negedge clk);block_column_requests=0;
            guard=0;
            while(!column_response_offered) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"column abort request failed to reach response");
            end
            repeat(7) begin
                @(posedge clk);#1;
                if(!adapter_busy || adapter_aborted || !column_rsp_ready || column_rsp_valid)
                    $fatal(1,"column abort did not wait for held response");
            end
            @(negedge clk);hold_column_responses=0;
            guard=0;
            while(!adapter_aborted) begin
                @(negedge clk);guard++;
                if(guard>200) $fatal(1,"column abort did not complete after response");
            end
            guard=0;
            while(column_provider_busy) begin
                @(negedge clk);guard++;
                if(guard>200) $fatal(1,"column owner cancel drain timeout");
            end
            if(adapter_busy || adapter_error || column_provider_busy ||
                column_request_count-before_columns!=1 ||
                column_request_count!=column_response_count || dut.window_history_valid_q!=0)
                $fatal(1,"column abort left error/history/ownership behind");
            inject_column_refill_error=0;
            column_full_restart();
            $display("C1_ADAPTER_COLUMN_ABORT_PASS held_request=%0d fault=%0d accepted=1 retired=1 full_restart=1 reset=0",held_request,fault);
            if(target_stage==19)
                $display("C1_POINTWISE_COLUMN_ABORT_PASS stage=19 held=%0d fault=%0d full_restart=1 reset=0",held_request,fault);
            else if(target_stage!=0)
                $display("C1_VIRTUAL_UPSAMPLE_ABORT_PASS stage=%0d held=%0d fault=%0d full_restart=1",target_stage,held_request,fault);
        end
    endtask
    task automatic check_column_owner_stall;
        integer guard,before_columns;
        begin
            reset_engine_model();block_column_backend=1;hold_column_responses=1;
            before_columns=column_request_count;
            start_job();send_all_descriptors(8'h74);send_source_frame();
            guard=0;
            while(column_request_count==before_columns) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"owner request handoff timeout");
            end
            pulse_abort();
            repeat(7) begin @(negedge clk);
                if(!owner_backend_offered || owner_backend_fence || adapter_aborted || !column_provider_busy)
                    $fatal(1,"owner fenced before real cache accepted request");
            end
            block_column_backend=0;guard=0;
            while(!column_response_offered) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"owner real cache cancellation response timeout");
            end
            repeat(7) begin @(negedge clk);
                if(!column_provider_busy || adapter_aborted)
                    $fatal(1,"owner completed before adapter response retirement");
            end
            hold_column_responses=0;guard=0;
            while(!adapter_aborted) begin
                @(negedge clk);guard++;
                if(guard>200) $fatal(1,"owner adapter abort timeout");
            end
            column_full_restart();
            $display("C1_ADAPTER_COLUMN_OWNER_STALL_PASS deferred_fence=1 real_cache=1 full_restart=1");
        end
    endtask
    task automatic check_column_error(input integer target_stage=0);
        integer guard;
        begin
            reset_engine_model();
            start_job();send_all_descriptors(8'h73);send_source_frame();
            guard=0;
            while(!(cache_stage_start_valid && active_stage_index==target_stage)) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"column error target stage not reached");
            end
            inject_column_refill_error=1;
            guard=0;
            while(!adapter_error) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"column error was not reported");
            end
            if(adapter_error_code!=8'h07 || column_request_count!=column_response_count ||
                adapter_engine_valid || column_provider_busy)
                $fatal(1,"column error escaped memory-error quarantine");
            repeat(5) begin @(posedge clk);#1;
                if(!adapter_error || column_req_valid || mem_req_valid || adapter_final_valid)
                    $fatal(1,"column error admitted subsequent work");
            end
            pulse_abort();
            @(negedge clk);inject_column_refill_error=0;
            column_full_restart();
            $display("C1_ADAPTER_COLUMN_ERROR_PASS memory_error=7 drained=1 full_restart=1 reset=0");
            if(target_stage==19)
                $display("C1_POINTWISE_COLUMN_ERROR_PASS stage=19 memory_error=7 full_restart=1 reset=0");
        end
    endtask

    task automatic check_column_write_dual_drain(input bit held_request,
        input bit write_fault,input bit column_first,input integer target_stage=0);
        integer guard,before_columns,expected_columns;
        logic [36:0] payload;
        begin
            reset_engine_model();start_job();send_all_descriptors(8'h73);send_source_frame();
            guard=0;
            while(active_stage_index!=target_stage || dut.result_writes_pending_q==0) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"dual drain never reached result writes");
            end
            hold_responses=1;
            // Stage 19 emits only one C8 result per pixel. Retain two
            // different pixels before the fault consumes one response,
            // otherwise "column first" has no remaining write to drain.
            if(target_stage==19) begin
                guard=0;
                while(dut.result_writes_pending_q<2) begin
                    @(negedge clk);guard++;
                    if(guard>JOB_TIMEOUT) $fatal(1,"pointwise dual drain requires two real pending writes");
                end
            end
            block_column_requests=held_request;hold_column_responses=1;
            before_columns=column_request_count;
            guard=0;
            while(held_request ? !column_req_valid : !column_response_offered) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"dual drain missing overlapped column");
            end
            if(!column_allow_pending_writes || active_input_bank==active_output_bank ||
               dut.result_writes_pending_q==0) $fatal(1,"dual drain overlap precondition missing");
            // Prefetch may already have accepted the held response's request
            // before old writes became pending. Snapshot at the actual held
            // obligation: only an unaccepted request adds one more handshake.
            expected_columns=column_request_count+(held_request?1:0);
            if(!held_request && column_request_count-column_response_count!=1)
                $fatal(1,"dual drain held response has no unique accepted request");
            payload={column_req_x,column_req_center_y,column_req_group};
            if(write_fault) begin
                inject_write_completion_error=1;hold_responses=0;guard=0;
                while(!adapter_error) begin
                    @(negedge clk);guard++;
                    if(guard>200) $fatal(1,"dual drain missing write fault");
                end
                hold_responses=1;inject_write_completion_error=0;
            end else pulse_abort();
            repeat(7) begin
                @(negedge clk);
                if(!adapter_busy || adapter_aborted || adapter_start_ready ||
                   adapter_engine_valid || mem_req_valid)
                    $fatal(1,"dual drain escaped held obligation");
                if(held_request && (!column_req_valid || column_req_ready ||
                    {column_req_x,column_req_center_y,column_req_group}!==payload))
                    $fatal(1,"write fault/cancel withdrew held column request");
            end
            if(!column_first) begin
                hold_responses=0;guard=0;
                while(response_pending_q) begin
                    @(negedge clk);guard++;
                    if(adapter_aborted || adapter_start_ready || guard>300)
                        $fatal(1,"dual drain did not retain held column after writes");
                end
            end
            block_column_requests=0;guard=0;
            while(!column_response_offered) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"dual drain column did not reach response");
            end
            hold_column_responses=0;
            @(negedge clk);
            if(column_first) begin
                if(dut.result_writes_pending_q==0) $fatal(1,"column-first drain lacked pending writes");
                repeat(7) begin
                    @(negedge clk);
                    if(adapter_aborted || adapter_start_ready || column_req_valid || mem_req_valid || !adapter_busy)
                        $fatal(1,"column-first drain lost older writes");
                end
                hold_responses=0;
            end
            guard=0;
            while(response_pending_q || (write_fault ? !adapter_error : !adapter_aborted)) begin
                @(negedge clk);guard++;
                if(guard>400) $fatal(1,"dual drain did not terminate");
            end
            if(write_fault) begin
                if(adapter_error_code!=7 || column_req_valid || mem_req_valid)
                    $fatal(1,"dual drain write error not sticky/quiescent");
                pulse_abort();
            end
            guard=0;
            while(adapter_busy || column_provider_busy) begin
                @(negedge clk);guard++;
                if(guard>400) $fatal(1,"dual drain owner failed to quiesce");
            end
            if(dut.result_writes_pending_q!=0 || column_request_count!=column_response_count ||
               column_request_count!=expected_columns || adapter_error || dut.window_history_valid_q!=0)
                $fatal(1,"dual drain outstanding/history mismatch");
            column_full_restart();
            $display("C1_COLUMN_WRITE_DUAL_DRAIN_PASS held_request=%0d write_fault=%0d column_first=%0d real_commit=1 reset=0",
                held_request,write_fault,column_first);
            if(target_stage==19)
                $display("C1_POINTWISE_COLUMN_DUAL_DRAIN_PASS stage=19 held=%0d fault=%0d column_first=%0d reset=0",
                    held_request,write_fault,column_first);
        end
    endtask

    // Stop the old pixel's first write and the next row's first-column
    // prefetch independently. Moving to a new row forces a genuine refill
    // (including stage 19), so injected faults cannot be hidden by a hit.
    task automatic prepare_pixel_prefetch_hold(input bit held_request,input bit fault,input bit late_group=0);
        integer guard,target;
        begin
            target=late_group?18:(POINTWISE_COLUMNS?19:0);
            reset_engine_model();start_job();send_all_descriptors(8'h75);send_source_frame();
            guard=0;
            while(!(active_stage_index==target && adapter_engine_valid && adapter_engine_group_last &&
                    adapter_engine_y==0 && adapter_engine_x==stage_ow_fn(target)-1)) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"pixel prefetch seed point timeout");
            end
            block_requests=1;hold_responses=1;
            if(late_group) begin
                // Let group 0 return while the old pixel's write is blocked.
                // Then hold group 1, leaving a real buffered predecessor.
                block_column_requests=0;hold_column_responses=0;guard=0;
                while(!(dut.pixel_prefetch_state_q==dut.PF_REQUEST && dut.pixel_prefetch_issue_group_q==1)) begin
                    @(negedge clk);guard++;
                    if(guard>JOB_TIMEOUT)$fatal(1,"second-group prefetch never became offered");
                end
                if(!ALL_PIXEL_GROUPS || !dut.pixel_prefetch_valid_q[0] || dut.pixel_prefetch_consumed_q!=0)
                    $fatal(1,"second-group cancellation lacked a buffered predecessor");
            end
            block_column_requests=held_request;hold_column_responses=1;
            inject_column_refill_error=fault;guard=0;
            while(held_request ? !(dut.pixel_prefetch_state_q==dut.PF_REQUEST && column_req_valid) :
                  !(dut.pixel_prefetch_state_q==dut.PF_RESPONSE && column_response_offered)) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"pixel prefetch held transaction timeout");
            end
            guard=0;
            while(!mem_req_valid) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"pixel prefetch did not overlap the old pixel write");
            end
            if(!mem_req_write || dut.state_q!=dut.ST_WRITE_REQ || !dut.pixel_prefetch_busy)
                $fatal(1,"pixel prefetch dual-request setup missing");
        end
    endtask

    task automatic prepare_pixel_prefetch_write_fault(input bit held_request);
        integer guard,target;
        begin
            target=POINTWISE_COLUMNS?19:0;
            reset_engine_model();start_job();send_all_descriptors(8'h76);send_source_frame();
            guard=0;
            while(!(cache_stage_start_valid && active_stage_index==target)) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"prefetch write fault stage timeout");
            end
            hold_responses=1;
            // One-group stage19 needs the SECOND pixel to provide both an
            // earlier accepted write and a newer held write. Stage0 has
            // multiple result groups, so its first pixel already provides both.
            guard=0;
            while(!(adapter_engine_valid && adapter_engine_group_last &&
                    adapter_engine_x==(POINTWISE_COLUMNS?1:0) && adapter_engine_y==0)) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"prefetch write fault seed timeout");
            end
            block_column_requests=held_request;hold_column_responses=1;
            if(!POINTWISE_COLUMNS) begin
                guard=0;
                while(dut.result_writes_pending_q==0) begin
                    @(negedge clk);guard++;
                    if(guard>JOB_TIMEOUT) $fatal(1,"prefetch write fault missing earlier result");
                end
            end
            block_requests=1;guard=0;
            while(!mem_req_valid || (held_request ?
                   !(dut.pixel_prefetch_state_q==dut.PF_REQUEST && column_req_valid) :
                   !(dut.pixel_prefetch_state_q==dut.PF_RESPONSE && column_response_offered))) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"prefetch write fault missing two held obligations");
            end
            if(dut.result_writes_pending_q==0 || !mem_req_write)
                $fatal(1,"prefetch write fault has no earlier write to fail");
            inject_write_completion_error=1;hold_responses=0;guard=0;
            while(!adapter_error) begin
                @(negedge clk);guard++;
                if(guard>400) $fatal(1,"prefetch write completion error missing");
            end
            hold_responses=1;inject_write_completion_error=0;
            if(adapter_error_code!=7 || !mem_req_valid || !dut.pixel_prefetch_busy)
                $fatal(1,"prefetch write error lost held newer read/write");
        end
    endtask

    task automatic check_pixel_prefetch_cancel(input bit held_request,input bit column_first,input bit write_fault=0,input bit late_group=0);
        integer guard;
        logic [104:0] write_payload;
        logic [36:0] read_payload;
        begin
            if(write_fault) prepare_pixel_prefetch_write_fault(held_request);
            else prepare_pixel_prefetch_hold(held_request,held_request && !late_group,late_group);
            write_payload={mem_req_addr,mem_req_wdata,mem_req_wstrb,mem_req_end};
            read_payload={column_req_x,column_req_center_y,column_req_group};
            pulse_abort();
            repeat(7) begin
                @(negedge clk);
                if(!adapter_busy || adapter_aborted || !mem_req_valid ||
                    {mem_req_addr,mem_req_wdata,mem_req_wstrb,mem_req_end}!==write_payload ||
                    (held_request && (!column_req_valid ||
                        {column_req_x,column_req_center_y,column_req_group}!==read_payload)))
                    $fatal(1,"pixel prefetch cancel withdrew an offered read/write");
            end
            if(!column_first) begin
                block_requests=0;hold_responses=0;guard=0;
                while(mem_req_valid || dut.result_writes_pending_q!=0) begin
                    @(negedge clk);guard++;
                    if(adapter_aborted || guard>400) $fatal(1,"pixel prefetch lost held read after write drain");
                end
            end
            block_column_requests=0;guard=0;
            while(!column_response_offered) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"pixel prefetch cancelled read response missing");
            end
            hold_column_responses=0;guard=0;
            while(dut.pixel_prefetch_busy) begin
                @(negedge clk);guard++;
                if(guard>400) $fatal(1,"pixel prefetch response failed to drain");
            end
            if(column_first) begin
                repeat(7) begin
                    @(negedge clk);
                    if(adapter_aborted || !mem_req_valid ||
                        {mem_req_addr,mem_req_wdata,mem_req_wstrb,mem_req_end}!==write_payload)
                        $fatal(1,"pixel prefetch lost held write after read drain");
                end
                block_requests=0;hold_responses=0;
            end
            guard=0;
            while(!adapter_aborted || column_provider_busy) begin
                @(negedge clk);guard++;
                if(guard>400) $fatal(1,"pixel prefetch dual cancel failed to complete");
            end
            if(adapter_busy || adapter_error || dut.result_writes_pending_q!=0 ||
                column_request_count!=column_response_count || dut.pixel_prefetch_busy)
                $fatal(1,"pixel prefetch cancel left ownership behind");
            inject_column_refill_error=0;
            column_full_restart();
            $display("C1_PIXEL_PREFETCH_CANCEL_PASS held=%0d column_first=%0d refill_fault=%0d dual_request=1 reset=0",
                held_request,column_first,held_request && !write_fault && !late_group);
            if(late_group)
                $display("C1_PIXEL_GROUP_PREFETCH_CANCEL_PASS group=1 held=%0d column_first=%0d buffered0=1 reset=0",held_request,column_first);
            if(write_fault)
                $display("C1_PIXEL_PREFETCH_WRITE_ERROR_PASS held=%0d column_first=%0d newer_write_preserved=1 reset=0",held_request,column_first);
        end
    endtask

    // Buffered group 1 must not disguise the ownership of an ordinary
    // later column of group 0. Abort preserves the real demand obligation.
    task automatic check_pixel_buffered_demand_cancel(input bit held_request,input bit write_fault=0);
        integer guard,before_requests;
        logic [36:0] payload;
        begin
            reset_engine_model();start_job();send_all_descriptors(8'h78);send_source_frame();
            if(write_fault) begin
                guard=0;
                while(!(active_stage_index==18 && dut.state_q==dut.ST_WRITE_REQ &&
                        dut.result_group_last_q && dut.output_x_q==stage_ow_fn(18)-1 && dut.output_y_q==0)) begin
                    @(negedge clk);guard++;
                    if(guard>JOB_TIMEOUT)$fatal(1,"buffered-demand earlier write point missing");
                end
                // Freeze write responses after the final old-pixel write is accepted;
                // freezing earlier may fill the tiny test FIFO and prevent
                // the next pixel from reaching the intended demand point.
                do @(posedge clk); while(!mem_req_ready);
                @(negedge clk);hold_responses=1;
            end
            guard=0;
            while(!(active_stage_index==18 && dut.output_x_q==0 && dut.output_y_q==1 &&
                    dut.input_group_q==0 && dut.tap_q==1 && dut.state_q==dut.ST_READ_REQ &&
                    dut.pixel_prefetch_state_q==dut.PF_READY && dut.pixel_prefetch_valid_q[1])) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT)$fatal(1,"buffered-group demand ownership point missing state=%0d x=%0d y=%0d pending=%0d pf=%0d",dut.state_q,dut.output_x_q,dut.output_y_q,dut.result_writes_pending_q,dut.pixel_prefetch_state_q);
            end
            before_requests=column_request_count;
            block_column_requests=held_request;hold_column_responses=1;
            payload={column_req_x,column_req_center_y,column_req_group};
            if(!held_request) begin
                guard=0;
                while(!column_response_offered) begin
                    @(negedge clk);guard++;
                    if(guard>JOB_TIMEOUT)$fatal(1,"buffered-group demand response missing");
                end
            end
            if(write_fault) begin
                if(dut.result_writes_pending_q==0)$fatal(1,"buffered-demand missing true pending write");
                inject_write_completion_error=1;hold_responses=0;guard=0;
                while(!adapter_error) begin
                    @(negedge clk);guard++;
                    if(guard>400)$fatal(1,"buffered-demand true write error missing");
                end
                inject_write_completion_error=0;
            end else pulse_abort();
            repeat(7) begin
                @(negedge clk);
                if(!adapter_busy || adapter_aborted ||
                   (held_request && (!column_req_valid ||
                    {column_req_x,column_req_center_y,column_req_group}!==payload)))
                    $fatal(1,"buffered group hid an outstanding demand on abort");
            end
            block_column_requests=0;guard=0;
            while(!column_response_offered) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT)$fatal(1,"buffered-group demand cancel response missing");
            end
            hold_column_responses=0;guard=0;
            while((write_fault ? (dut.state_q!=dut.ST_ERROR || dut.result_writes_pending_q!=0 || dut.pixel_prefetch_busy) : !adapter_aborted) || column_provider_busy) begin
                @(negedge clk);guard++;
                if(guard>400)$fatal(1,"buffered-group demand failed to drain");
            end
            if(write_fault) begin
                if(!adapter_error || adapter_error_code!=7)$fatal(1,"buffered-demand write error diagnostic lost");
                pulse_abort();wait(adapter_aborted);@(negedge clk);
            end
            if(adapter_busy || adapter_error || dut.pixel_prefetch_busy ||
               column_request_count!=before_requests+1 || column_request_count!=column_response_count)
                $fatal(1,"buffered-group demand left stale ownership");
            column_full_restart();
            $display("C1_PIXEL_BUFFERED_DEMAND_CANCEL_PASS held=%0d group=0 tap=1 buffered1=1 reset=0",held_request);
            if(write_fault)$display("C1_PIXEL_BUFFERED_DEMAND_WRITE_ERROR_PASS held=%0d accepted_write_response=1 reset=0",held_request);
        end
    endtask

    task automatic check_pixel_blocked_demand_cancel;
        integer guard,before_requests;
        begin
            reset_engine_model();start_job();send_all_descriptors(8'h79);send_source_frame();guard=0;
            while(!(active_stage_index==18 && dut.pixel_prefetch_output_x_q==0 &&
                    dut.pixel_prefetch_output_y_q==1 && dut.pixel_prefetch_issue_group_q==1 &&
                    dut.pixel_prefetch_state_q==dut.PF_REQUEST)) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT)$fatal(1,"blocked-demand prefetch group1 setup missing");
            end
            hold_column_responses=1;guard=0;
            while(!(dut.state_q==dut.ST_READ_REQ && dut.output_x_q==0 && dut.output_y_q==1 &&
                    dut.input_group_q==0 && dut.tap_q==1 && column_response_offered)) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT)$fatal(1,"prefetch did not block unoffered demand");
            end
            if(column_req_valid || dut.pixel_prefetch_state_q!=dut.PF_RESPONSE)
                $fatal(1,"blocked demand unexpectedly owned the column port");
            before_requests=column_request_count;pulse_abort();
            repeat(7) begin
                @(negedge clk);
                if(!adapter_busy || adapter_aborted || column_request_count!=before_requests)
                    $fatal(1,"blocked-demand abort lost prefetch owner");
            end
            hold_column_responses=0;guard=0;
            while(!adapter_aborted || column_provider_busy) begin
                @(negedge clk);guard++;
                if(guard>400)$fatal(1,"blocked-demand abort invented response debt");
            end
            if(column_request_count!=before_requests || column_request_count!=column_response_count ||
               adapter_error || adapter_busy || dut.pixel_prefetch_busy)
                $fatal(1,"blocked-demand abort issued a new request or leaked debt");
            column_full_restart();
            $display("C1_PIXEL_BLOCKED_DEMAND_CANCEL_PASS unoffered_demand=1 extra_reads=0 reset=0");
        end
    endtask

    task automatic check_pixel_prefetch_error;
        integer guard;
        logic [104:0] payload;
        begin
            prepare_pixel_prefetch_hold(0,1);
            payload={mem_req_addr,mem_req_wdata,mem_req_wstrb,mem_req_end};
            hold_column_responses=0;guard=0;
            while(!adapter_error) begin
                @(negedge clk);guard++;
                if(guard>400) $fatal(1,"prefetch refill error was not reported before use");
            end
            repeat(7) begin
                @(negedge clk);
                if(adapter_error_code!=7 || !mem_req_valid || !adapter_busy || adapter_engine_valid ||
                    {mem_req_addr,mem_req_wdata,mem_req_wstrb,mem_req_end}!==payload)
                    $fatal(1,"prefetch fault withdrew held old-pixel write or admitted compute");
            end
            // Earlier pixels may already occupy the finite response FIFO.
            // Retire those credits while accepting the held write, then
            // freeze again before that newly accepted write can complete.
            block_requests=0;hold_responses=0;guard=0;
            while(mem_req_valid) begin
                @(negedge clk);guard++;
                if(guard>400) $fatal(1,"prefetch fault old write acceptance timeout pending=%0d count=%0d ready=%0d state=%0d",
                    dut.result_writes_pending_q,response_count,mem_req_ready,dut.state_q);
            end
            hold_responses=1;
            pulse_abort();
            repeat(7) begin @(negedge clk);
                if(adapter_aborted || !adapter_busy || dut.result_writes_pending_q==0)
                    $fatal(1,"prefetch fault ignored unretired old write");
            end
            hold_responses=0;guard=0;
            while(!adapter_aborted || column_provider_busy) begin
                @(negedge clk);guard++;
                if(guard>400) $fatal(1,"prefetch fault recovery failed to drain");
            end
            inject_column_refill_error=0;
            column_full_restart();
            $display("C1_PIXEL_PREFETCH_ERROR_PASS real_refill=1 held_write_preserved=1 reset=0");
        end
    endtask

    task automatic check_column_write_credit;
        integer guard;
        begin
            reset_engine_model();start_job();send_all_descriptors(8'h74);send_source_frame();
            guard=0;
            while(dut.result_writes_pending_q==0) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"credit test missing write");
            end
            hold_responses=1;guard=0;
            while(!(dut.result_writes_pending_q==15 && adapter_result_valid && !adapter_result_ready)) begin
                @(negedge clk);guard++;
                if(guard>JOB_TIMEOUT) $fatal(1,"write credit limit not reached");
            end
            repeat(12) begin
                @(negedge clk);
                if(dut.result_writes_pending_q!=15 || adapter_result_ready || mem_req_valid ||
                   column_req_valid || adapter_engine_valid || active_stage_index!=0)
                    $fatal(1,"write credit saturation crossed a request/stage boundary");
            end
            pulse_abort();repeat(5) @(negedge clk);
            if(adapter_aborted || adapter_start_ready || !adapter_busy)
                $fatal(1,"credit saturation abort forgot pending writes");
            hold_responses=0;guard=0;
            while(adapter_busy || column_provider_busy) begin
                @(negedge clk);guard++;
                if(guard>1000) $fatal(1,"credit saturation abort failed to drain");
            end
            if(response_pending_q || adapter_error || dut.result_writes_pending_q!=0)
                $fatal(1,"credit saturation lost responses");
            column_full_restart();
            $display("C1_COLUMN_WRITE_CREDIT_PASS limit=15 held=12 drained=15 reset=0");
        end
    endtask

    task automatic check_pipelined_write_drain(input bit fault);
        integer guard;
        logic [103:0] held;
        begin
            reset_engine_model();
            start_job();
            send_all_descriptors(8'h32);
            send_source_frame();
            guard=0;
            // Stall a presented later write while earlier writes still await
            // real completion. This also checks no-withdrawal on failure.
            while (!(dut.result_writes_pending_q >= 2 && mem_req_valid && mem_req_write)) begin
                @(negedge clk);
                guard=guard+1;
                if (guard>10000) $fatal(1,"missing overlapping result writes");
            end
            block_requests=1;
            held={mem_req_addr,mem_req_wdata,mem_req_wstrb};
            if (fault) begin
                inject_write_completion_error=1;
                guard=0;
                while (!adapter_error) begin
                    @(negedge clk);
                    guard=guard+1;
                    if (guard>200) $fatal(1,"missing deferred write error");
                end
            end else begin
                hold_responses=1;
                pulse_abort();
            end
            repeat (12) begin
                @(negedge clk);
                if (!mem_req_valid || {mem_req_addr,mem_req_wdata,mem_req_wstrb} !== held ||
                    adapter_aborted || !adapter_busy)
                    $fatal(1,"write fence withdrew held request or completed early");
            end
            block_requests=0;
            hold_responses=0;
            guard=0;
            while ((fault ? (response_count!=0 || mem_req_valid) : !adapter_aborted)) begin
                @(negedge clk);
                guard=guard+1;
                if (guard>500) $fatal(1,"pending write drain timeout fault=%0b",fault);
            end
            inject_write_completion_error=0;
            if (response_count!=0 || dut.result_writes_pending_q!=0)
                $fatal(1,"write fence lost outstanding completions");
            if (fault) begin
                if (!adapter_error || adapter_error_code != 8'h07)
                    $fatal(1,"write error did not remain sticky code=%h",adapter_error_code);
                pulse_abort();
                repeat (4) @(negedge clk);
            end
            if (adapter_busy || adapter_error || !adapter_start_ready)
                $fatal(1,"write fence did not restore restart readiness");
            $display("C1_ADAPTER_WRITE_DRAIN_PASS fault=%0b held_cycles=12",fault);
        end
    endtask

    integer timeout;
    integer success_final_start;
    integer run_cycle_count = 0;
    integer success_cycle_start;
    integer prefetch_hit_count = 0;
    integer reuse_stride1_count = 0, reuse_stride2_count = 0;
    integer reuse_reads_saved = 0;
    integer prefetch_fallback_count = 0;
    always @(posedge clk) begin
        run_cycle_count <= run_cycle_count + 1;
        if (!rst && dut.state_q == 6 && dut.window_reuse_admit &&
            !adapter_abort && !dut.abort_pending_q) begin
            if (dut.stride_x_q == 1) begin
                reuse_stride1_count <= reuse_stride1_count + 1;
                reuse_reads_saved <= reuse_reads_saved + 6;
            end else begin
                reuse_stride2_count <= reuse_stride2_count + 1;
                reuse_reads_saved <= reuse_reads_saved + 3;
            end
        end
        if (!rst && dut.state_q == 8 && mem_rsp_valid && mem_rsp_ready &&
            !mem_rsp_error && dut.windowed_opcode && dut.tap_q != 8 &&
            !adapter_abort && !dut.abort_pending_q) begin
            if (dut.tap_addr_prefetch_phase_q == 3 || dut.tap_addr_prefetch_phase_q == 4)
                prefetch_hit_count <= prefetch_hit_count + 1;
            else
                prefetch_fallback_count <= prefetch_fallback_count + 1;
        end
    end
    integer success_request_start;
    integer success_write_start;
    integer success_read_start;
    integer success_column_start,success_column_configs;
    integer success_pf_requests,success_pf_responses,success_pf_uses,success_pf_early;
    integer engine_before_error;
    integer check_i;
    initial begin
        adapter_start_valid = 1'b0;
        adapter_abort = 1'b0;
        adapter_stage_config_valid = 1'b0;
        adapter_stage_config_index = 16'd0;
        adapter_stage_config_descriptor = 512'd0;
        adapter_stage_config_generation = 8'd0;
        adapter_source_valid = 1'b0;
        adapter_source_data_s8 = 64'd0;
        adapter_source_x = 16'd0;
        adapter_source_y = 16'd0;
        adapter_source_sof = 1'b0;
        adapter_source_eol = 1'b0;
        adapter_source_eof = 1'b0;
        tensor_base_addr = BASE_ADDR;
        hold_responses = 1'b0;
        force_request_ready = 1'b0;
        inject_response_error = 1'b0;
        abort_drain_count = 0;
        for (check_i = 0; check_i < MEMORY_WORDS; check_i = check_i + 1)
            memory[check_i] = 64'd0;

        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        if(FUSE_FINAL && FUSION_CASE>0) begin
            if(FUSION_CASE<=2)check_fused_eof_cancel(FUSION_CASE==2);
            else check_fused_result_fault(FUSION_CASE-3,(FUSION_CASE%2)==1);
            $display("C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS fusion_case=%0d columns=%0d",FUSION_CASE,COLUMN_READS);
            $finish;
        end

        // Abort with a source write outstanding.  The request must not be
        // withdrawn and the response must be drained before aborted pulses.
        start_job();
        send_all_descriptors(8'h31);
        // Optional pipelined descriptor validation commits a few cycles after
        // the final descriptor handshake.  Wait on the architectural
        // completion flag instead of assuming the legacy same-cycle commit.
        timeout = 0;
        while (!adapter_config_complete && timeout < 256) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!adapter_config_complete)
            $fatal(1, "descriptor snapshot did not complete");
        hold_responses = 1'b1;
        force_request_ready = 1'b1;
        fork
            send_source_beat(0, 0);
        join
        timeout = 0;
        while (!response_pending_q && timeout < 100) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!response_pending_q)
            $fatal(1, "abort test never created an outstanding write");
        pulse_abort();
        repeat (5) begin
            @(posedge clk);
            if (!adapter_busy)
                $fatal(1, "adapter retired abort before memory drain");
            abort_drain_count = abort_drain_count + 1;
        end
        hold_responses = 1'b0;
        force_request_ready = 1'b0;
        timeout = 0;
        while (!adapter_aborted && timeout < 100) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!adapter_aborted || adapter_busy || adapter_error)
            $fatal(1, "protocol-safe abort did not retire cleanly");

        if(SOURCE_PIPELINE && RESPONSE_DEPTH>=3) begin
            check_source_pipeline_drain(0,0);check_source_pipeline_drain(0,1);
            check_source_pipeline_drain(1,0);check_source_pipeline_drain(1,1);
            if(RESPONSE_DEPTH>=15) check_source_pipeline_credit();
        end
        if(SOURCE_PIPELINE) begin
            check_source_pipeline_protocol(0);check_source_pipeline_protocol(1);check_source_pipeline_protocol(2);
        end

        // Full 22-stage restart with randomized memory, engine, result and
        // final-stream stalls.  The engine BFM checks every operand window.
        reset_engine_model();
        success_final_start = final_count;
        success_cycle_start = run_cycle_count;
        success_request_start = request_count;
        success_write_start = write_count;
        success_read_start = read_count;
        success_column_start = column_request_count;
        success_column_configs = column_config_count;
        success_pf_requests=pixel_pf_requests;success_pf_responses=pixel_pf_responses;
        success_pf_uses=pixel_pf_uses;success_pf_early=pixel_pf_early;
        start_job();
        send_all_descriptors(8'h32);
        send_source_frame();
        timeout = 0;
        while (!adapter_done && timeout < JOB_TIMEOUT) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!adapter_done)
            $fatal(1, "full MicroStyle tensor schedule timed out");
        if (adapter_error || adapter_busy)
            $fatal(1, "successful schedule retired with error/busy");
        if (HORIZONTAL_REUSE && (reuse_stride1_count == 0 || reuse_stride2_count == 0))
            $fatal(1,"horizontal reuse stride coverage missing");
        begin : independent_read_budget
            integer dense, saved, groups, pixels, op, window_dense, columns, scalar, writes, elided, pointwise, prefetches;
            dense=0; saved=0; window_dense=0; writes=FRAME_W*FRAME_H; elided=0; pointwise=0;
            prefetches=0;
            for(integer si=0;si<STAGES;si++) begin
                groups=(stage_cin_fn(si)+7)/8;
                pixels=stage_ow_fn(si)*stage_oh_fn(si);
                op=stage_opcode_fn(si);
                if(si<21 && !(FUSE_FINAL && si==20)) begin
                    if(VIRTUAL_UPSAMPLE && (si==14 || si==17))
                        elided+=pixels*((stage_cout_fn(si)+7)/8);
                    else writes+=pixels*((stage_cout_fn(si)+7)/8);
                end
                if(!(FUSE_FINAL && si==21)) dense+=pixels*groups*((op==1 || op==3)?9:((op==5)?2:1));
                if(op==1 || op==3) window_dense+=pixels*groups*9;
                if(POINTWISE_COLUMNS && op==2) pointwise+=pixels*groups;
                if(PIXEL_COLUMN_PREFETCH && input_bank_fn(si)!=output_bank_fn(si) &&
                    (op==1 || op==3 || (POINTWISE_COLUMNS && op==2))) prefetches+=(pixels-1)*(ALL_PIXEL_GROUPS?groups:1);
                if(HORIZONTAL_REUSE && (op==1 || op==3) && input_bank_fn(si)!=output_bank_fn(si))
                    saved+=(stage_ow_fn(si)-1)*stage_oh_fn(si)*groups*((si==0 || si==1)?3:6);
            end
            columns=COLUMN_READS ? (window_dense-saved)/3+pointwise : 0;
            if(pixel_pf_requests-success_pf_requests!=prefetches || pixel_pf_responses-success_pf_responses!=prefetches ||
               pixel_pf_uses-success_pf_uses!=prefetches || (PIXEL_COLUMN_PREFETCH && pixel_pf_early==success_pf_early))
                $fatal(1,"pixel prefetch changed first-column budget/ownership or never overlapped results");
            if(PIXEL_COLUMN_PREFETCH)
                $display("C1_PIXEL_PREFETCH_BUDGET_PASS first_columns=%0d early=%0d",prefetches,pixel_pf_early-success_pf_early);
            scalar=COLUMN_READS ? dense-window_dense-pointwise : dense-saved;
            if(read_count-success_read_start != scalar || reuse_reads_saved!=saved ||
                column_request_count-success_column_start!=columns ||
                column_request_count!=column_response_count)
                $fatal(1,"read budget mismatch actual=%0d dense=%0d saved=%0d observed_saved=%0d",
                    read_count-success_read_start,dense,saved,reuse_reads_saved);
            $display("C1_ADAPTER_READ_BUDGET_PASS dense=%0d actual=%0d saved=%0d",
                dense,read_count-success_read_start+3*(column_request_count-success_column_start)-2*pointwise,saved);
            if(POINTWISE_COLUMNS)
                $display("C1_POINTWISE_COLUMN_BUDGET_PASS operands=%0d scalar_reads=%0d columns=%0d",pointwise,scalar,columns);
            if(COLUMN_READS) begin
                if(column_config_count-success_column_configs!=STAGES)
                    $fatal(1,"column cache did not observe all 22 stage configurations");
                $display("C1_ADAPTER_COLUMN_BUDGET_PASS columns=%0d scalar_reads=%0d payload_c8=%0d stages=22",
                    columns,scalar,scalar+3*columns);
            end
            $display("C1_ADAPTER_GEOMETRY_PASS width=%0d height=%0d bank_bytes=%0d reuse=%0d",
                FRAME_W,FRAME_H,BANK_BYTES,HORIZONTAL_REUSE);
            if(write_count-success_write_start != writes)
                $fatal(1,"independent tensor write budget mismatch expected=%0d actual=%0d",writes,write_count-success_write_start);
            $display("C1_VIRTUAL_UPSAMPLE_BUDGET_PASS enabled=%0d writes=%0d elided=%0d stages=22 independent_logical_operands=1",
                VIRTUAL_UPSAMPLE,writes,elided);
        end
        $display("C1_ADAPTER_HORIZONTAL_REUSE_PASS enabled=%0d stride1=%0d stride2=%0d saved=%0d reads=%0d operands=%0d",
            HORIZONTAL_REUSE,reuse_stride1_count,reuse_stride2_count,reuse_reads_saved,
            read_count-success_read_start,engine_operand_count);
        if (PREFETCH_TAP_ADDRESS && PIPELINED_TENSOR_ADDRESS_CFG && !COLUMN_READS) begin
            if (FIXED_READ_DELAY >= 8 && prefetch_hit_count == 0)
                $fatal(1, "tap address prefetch fast path untested");
            if (FIXED_READ_DELAY == 0 && PIPELINED_TENSOR_PIXEL_INDEX_CFG &&
                prefetch_fallback_count == 0)
                $fatal(1, "tap address prefetch fallback untested");
        end
        $display("C1_ADAPTER_TAP_ADDRESS_PASS enabled=%0d pixel_pipeline=%0d read_delay=%0d hits=%0d fallback=%0d cycles=%0d",
            PREFETCH_TAP_ADDRESS, PIPELINED_TENSOR_PIXEL_INDEX_CFG,
            FIXED_READ_DELAY, prefetch_hit_count, prefetch_fallback_count,
            run_cycle_count - success_cycle_start);
        if (final_count - success_final_start != FRAME_W * FRAME_H)
            $fatal(1, "final frame beat count mismatch");
        if (request_count <= success_request_start ||
            write_count <= success_write_start ||
            read_count <= success_read_start)
            $fatal(1, "full schedule did not exercise read/write traffic");
        for (check_i = 0; check_i < STAGES; check_i = check_i + 1)
            if (stage_seen[check_i] == 0 && !(FUSE_FINAL && check_i==21))
                $fatal(1, "stage %0d had no engine operands", check_i);
        for (check_i = 1; check_i <= 6; check_i = check_i + 1)
            if (op_seen[check_i] == 0 && !(FUSE_FINAL && check_i==6))
                $fatal(1, "opcode %0d was not covered", check_i);
        for (check_i = 0; check_i < 3; check_i = check_i + 1)
            if (residual_bank_seen[check_i] == 0)
                $fatal(1, "residual bank %0d was not covered", check_i);
        if (border_window_count == 0 || upsample_operand_count == 0 ||
            residual_operand_count == 0 || request_stall_count == 0 ||
            response_gap_count == 0 || engine_stall_count == 0 ||
            final_stall_count == 0)
            $fatal(1, "required scheduler/backpressure coverage missing");

        // Run the additional complete EOF job after the first-job budget
        // snapshot; the legacy reuse counters below are cumulative monitors.
        if(SOURCE_PIPELINE) begin
            check_source_pipeline_eof(1);check_source_pipeline_eof(0);
        end

        // A real memory response error is sticky and prevents any compute
        // operand from being launched for that failed job.
        start_job();
        send_all_descriptors(8'h33);
        engine_before_error = engine_operand_count;
        force_request_ready = 1'b1;
        inject_response_error = 1'b1;
        success_request_start = request_count;
        send_source_beat(0, 0);
        timeout = 0;
        while ((request_count == success_request_start) && timeout < 100) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        @(negedge clk);
        inject_response_error = 1'b0;
        force_request_ready = 1'b0;
        timeout = 0;
        while (!adapter_error && timeout < 100) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!adapter_error || adapter_error_code != 8'h07 ||
            engine_operand_count != engine_before_error)
            $fatal(1, "memory error was not propagated by the adapter");
        pulse_abort();
        @(posedge clk);
        if (adapter_error || adapter_busy)
            $fatal(1, "memory-error abort did not restore idle");

        // A descriptor generation change is rejected and remains sticky until
        // explicit abort.  No source/engine launch is possible in this state.
        start_job();
        @(negedge clk);
        adapter_stage_config_index = 16'd0;
        adapter_stage_config_descriptor = descriptor_fn(0);
        adapter_stage_config_generation = 8'h44;
        adapter_stage_config_valid = 1'b1;
        do @(posedge clk); while (!adapter_stage_config_ready);
        @(negedge clk);
        adapter_stage_config_valid = 1'b0;
        @(negedge clk);
        adapter_stage_config_index = 16'd1;
        adapter_stage_config_descriptor = descriptor_fn(1);
        adapter_stage_config_generation = 8'h45;
        adapter_stage_config_valid = 1'b1;
        do @(posedge clk); while (!adapter_stage_config_ready);
        @(negedge clk);
        adapter_stage_config_valid = 1'b0;
        repeat (3) @(posedge clk);
        if (!adapter_error || adapter_error_code != 8'h03 ||
            adapter_source_ready || adapter_engine_valid)
            $fatal(1, "generation mismatch was not safely quarantined");
        pulse_abort();
        @(posedge clk);
        if (adapter_error || adapter_busy || !adapter_start_ready)
            $fatal(1, "error abort did not restore restart readiness");

        if(FUSE_FINAL && fusion_commits==0)$fatal(1,"no fused final commit exercised");
        $display("C1_ADAPTER_FINAL_FUSION_PASS enabled=%0d commits=%0d",FUSE_FINAL,fusion_commits);
        $display("C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS requests=%0d reads=%0d writes=%0d operands=%0d final=%0d mem_stall=%0d rsp_gap=%0d engine_stall=%0d final_stall=%0d borders=%0d upsample=%0d residual=%0d drains=%0d adjacent_same_base=%0d adjacent_pairable=%0d pipeline=%0d descriptor_pipeline=%0d narrow=%0d size_arith=%0d fixed_limits=%0d pixel_count_pipeline=%0d iterative_descriptor_pixel_count=%0d",
                 request_count, read_count, write_count,
                 engine_operand_count, final_count,
                 request_stall_count, response_gap_count,
                 engine_stall_count, final_stall_count,
                 border_window_count, upsample_operand_count,
                 residual_operand_count, abort_drain_count,
                 adjacent_same_base_count, adjacent_pairable_count,
                 PIPELINED_TENSOR_ADDRESS_CFG,
                 PIPELINED_DESCRIPTOR_VALIDATION_CFG,
                 NARROW_DESCRIPTOR_SIZE_CHECK_CFG,
                 PIPELINED_DESCRIPTOR_SIZE_ARITH_CFG,
                 FIXED_DESCRIPTOR_SIZE_LIMITS_CFG,
                 PIPELINED_DESCRIPTOR_PIXEL_COUNT_CFG,
                 ITERATIVE_DESCRIPTOR_PIXEL_COUNT_CFG);
        if (PIPELINED_WRITES) begin
            if (RESPONSE_DEPTH >= 2 && RUN_WRITE_DRAIN_SCENARIOS) begin
                check_pipelined_write_drain(1'b0);
                check_pipelined_write_drain(1'b1);
            end
            if (max_response_count < ((RESPONSE_DEPTH<3)?RESPONSE_DEPTH:3) || response_count != 0)
                $fatal(1,"pipelined writes did not overlap/drain max=%0d left=%0d",
                       max_response_count,response_count);
            $display("C1_ADAPTER_PIPELINED_WRITES_PASS max_pending=%0d drained=1",max_response_count);
        end
        if (PREFETCH_TAP_ADDRESS && PIPELINED_TENSOR_ADDRESS_CFG && !COLUMN_READS) begin
            check_tap_prefetch_drain(1, 0);
            if (PIPELINED_TENSOR_PIXEL_INDEX_CFG)
                check_tap_prefetch_drain(2, 0);
            check_tap_prefetch_drain(3, 0);
            check_tap_prefetch_drain(4, 0);
            check_tap_prefetch_drain(4, 1);
            check_tap_prefetch_drain(4, 0, 0);
            check_tap_prefetch_drain(4, 1, 0);
        end
        if(HORIZONTAL_REUSE) check_horizontal_reuse_restart();
        if(COLUMN_READS) begin
            if(PIXEL_COLUMN_PREFETCH) begin
                for(integer held=0;held<2;held++)
                    for(integer first=0;first<2;first++) begin
                        check_pixel_prefetch_cancel(held!=0,first!=0);
                        check_pixel_prefetch_cancel(held!=0,first!=0,1);
                        if(ALL_PIXEL_GROUPS) check_pixel_prefetch_cancel(held!=0,first!=0,0,1);
                    end
                check_pixel_prefetch_error();
                if(ALL_PIXEL_GROUPS) begin
                    check_pixel_buffered_demand_cancel(0);
                    check_pixel_buffered_demand_cancel(1);
                    check_pixel_buffered_demand_cancel(0,1);
                    check_pixel_buffered_demand_cancel(1,1);
                    check_pixel_blocked_demand_cancel();
                end
            end
            if(COLUMN_WRITE_OVERLAP && !PIXEL_COLUMN_PREFETCH) begin
                for(integer held=0;held<2;held++)
                    for(integer fault=0;fault<2;fault++)
                        for(integer first=0;first<2;first++)
                            check_column_write_dual_drain(held!=0,fault!=0,first!=0);
                if(RESPONSE_DEPTH>=16) check_column_write_credit();
            end
            for(integer held=0;held<2;held++)
                for(integer fault=0;fault<2;fault++) check_column_abort(held!=0,fault!=0);
            if(VIRTUAL_UPSAMPLE) begin
                check_column_abort(0,0,15);
                check_column_abort(1,1,18);
                check_virtual_result_abort(14,0);
                check_virtual_result_abort(17,1);
            end
            if(COLUMN_OWNER) check_column_owner_stall();
            check_column_error();
            if(POINTWISE_COLUMNS) begin
                for(integer held=0;held<2;held++)
                    for(integer fault=0;fault<2;fault++) check_column_abort(held!=0,fault!=0,19);
                check_column_error(19);
                if(COLUMN_WRITE_OVERLAP && !PIXEL_COLUMN_PREFETCH)
                    for(integer held=0;held<2;held++)
                        for(integer fault=0;fault<2;fault++)
                            for(integer first=0;first<2;first++)
                                check_column_write_dual_drain(held!=0,fault!=0,first!=0,19);
            end
        end
        $finish;
    end

    initial begin
        // Prefetch adds five late-stage prefix + full no-reset restart cases.
        #(5000000*FRAME_SCALE*(PIXEL_COLUMN_PREFETCH?2:1));
        $fatal(1, "global tensor-adapter timeout");
    end

    initial begin
        if(FRAME_W<4 || FRAME_H<4 || FRAME_W%4!=0 || FRAME_H%4!=0)
            $fatal(1,"test graph geometry must be positive multiples of four");
    end

endmodule
