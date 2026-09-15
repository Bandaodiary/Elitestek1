`timescale 1ns/1ps

module tb_c1_r1_microstyle_engine #(parameter bit POINTWISE_STREAM=0, REQUANT_OVERLAP=0, DOT_PIXELS=0,
    parameter bit DW_PIXELS=0, parameter integer DW_PREFETCH_GROUPS=2,
    parameter bit ALL_DOT_GROUPS=0, parameter bit DOT_NEXT_ALL_INPUTS=1,
    parameter bit PACK_RGB=0, parameter bit DENSE_RGB=0, parameter bit ELIDE_VIEWS=0,
    parameter bit FUSE_FINAL=0, parameter bit DW_FRAME=0,
    parameter bit SMALL_FRAME=0);
`ifdef C1_STREAM_DW_GROUPS
    localparam bit STREAM_DW_GROUPS=1;
`else
    localparam bit STREAM_DW_GROUPS=0;
`endif
    initial begin
        if(dut.u_engine.STREAM_DW_GROUPS!=STREAM_DW_GROUPS ||
           dut.u_engine.u_dw_core.PER_BEAT_CONFIG!=STREAM_DW_GROUPS)
            $fatal(1,"DW streaming option did not reach the actual engine/core");
        $display("C1_ENGINE_DW_STREAM_OPTION enabled=%0d",STREAM_DW_GROUPS);
    end
`ifdef C1_PIPELINED_DOT_TREE
    localparam integer PIPELINED_DOT_TREE = 1;
`else
    localparam integer PIPELINED_DOT_TREE = 0;
`endif
`ifdef C1_PIPELINED_DOT_TREE_FULL
    localparam integer PIPELINED_DOT_TREE_FULL = 1;
`else
    localparam integer PIPELINED_DOT_TREE_FULL = 0;
`endif
`ifdef C1_CACHE_DW_WEIGHT_TILES
    localparam integer CACHE_DW_WEIGHT_TILES = 1;
`else
    localparam integer CACHE_DW_WEIGHT_TILES = 0;
`endif
`ifdef C1_MAC_PREFETCH_OVERLAP
    localparam integer MAC_PREFETCH_OVERLAP = 1;
`else
    localparam integer MAC_PREFETCH_OVERLAP = 0;
`endif
`ifdef C1_PACKED_AFFINE_CACHE
    localparam integer PACKED_AFFINE_CACHE = 1;
`else
    localparam integer PACKED_AFFINE_CACHE = 0;
`endif
`ifdef C1_PIPELINED_DECODER_VALIDATION
    localparam integer PIPELINED_DECODER_VALIDATION = 1;
`else
    localparam integer PIPELINED_DECODER_VALIDATION = 0;
`endif
`ifdef C1_NONZERO_CYCLE_BUDGET
    localparam logic [31:0] TEST_CYCLE_BUDGET = 32'd10000;
`else
    localparam logic [31:0] TEST_CYCLE_BUDGET = 32'd0;
`endif
    localparam integer PARAM_BYTES = 16896;
    localparam integer PARAM_ADDR_W = 11;
    localparam integer STAGES = 22;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst, abort;
    logic job_start_valid, job_start_ready;
    logic [15:0] job_stage_count;
    logic [7:0] config_generation;
    logic parameter_active_valid;
    logic [31:0] parameter_generation;
    logic busy, done, aborted, error;
    logic [7:0] error_code;

    logic stage_config_valid, stage_config_ready;
    logic [15:0] stage_config_index;
    logic [511:0] stage_config_descriptor;
    logic [7:0] stage_config_generation;

    logic param_rd_en;
    logic [PARAM_ADDR_W-1:0] param_rd_addr;
    logic param_rd_valid, param_rd_error;
    logic [127:0] param_rd_data;

    logic in_valid, in_ready;
    logic [575:0] in_window_s8;
    logic [63:0] in_residual_s8;
    logic [2:0] in_group_index;
    logic in_group_last;
    logic [15:0] in_x, in_y;
    logic in_sof, in_eol, in_eof;

    logic out_valid, out_ready;
    logic out_ready_pattern;
    logic [63:0] out_data_s8;
    logic [2:0] out_group_index;
    logic out_group_last;
    logic [15:0] out_x, out_y;
    logic out_sof, out_eol, out_eof;
    logic [4:0] stage_index;
    logic [7:0] stage_opcode;
    logic stage_active, adapter_required, stage_done, overflow_seen;
    logic config_capture_complete;
    integer dw_frame_eof_hold=0;
    wire dw_frame_hold_eof = DW_FRAME && stage_index==18 && out_valid && out_eof && dw_frame_eof_hold<12;
    assign out_ready = out_ready_pattern && !dw_frame_hold_eof;
    always @(posedge clk) begin
        if(rst || (job_start_valid && job_start_ready)) dw_frame_eof_hold<=0;
        else if(dw_frame_hold_eof && !abort) begin
            if(done || stage_done || !busy || !dut.u_engine.dw_busy)
                $fatal(1,"DW frame completion escaped a held actual layer EOF");
            dw_frame_eof_hold<=dw_frame_eof_hold+1;
        end
    end
    logic view_commit_valid=0,view_commit_ready;
    logic [4:0] view_commit_stage=0;
    logic [7:0] view_commit_generation=0;
    integer view_commit_count=0;
    integer view_wait_cycles=0;
    bit view_held=0;
    logic [12:0] view_held_packet;
    always @(posedge clk) begin
        if(rst || abort) view_held<=0;
        else begin
            if(view_held && (!view_commit_valid || {view_commit_stage,view_commit_generation}!==view_held_packet))
                $fatal(1,"view packet changed while waiting for descriptor validation");
            view_held<=view_commit_valid && !view_commit_ready;
            view_held_packet<={view_commit_stage,view_commit_generation};
            if(view_commit_valid && !view_commit_ready)view_wait_cycles++;
        end
    end
    always @(posedge clk) if(!rst && !abort && view_commit_valid && view_commit_ready)
        view_commit_count++;


    logic [511:0] descriptors [0:STAGES-1];
    logic [7:0] parameter_bytes [0:PARAM_BYTES-1];
    integer stage_ow [0:STAGES-1];
    integer stage_oh [0:STAGES-1];
    integer stage_cin [0:STAGES-1];
    integer stage_cout [0:STAGES-1];
    integer stage_op [0:STAGES-1];
    integer stage_act [0:STAGES-1];
    integer observed_outputs [0:STAGES-1];

    function automatic integer expected_stage_results(input integer si);
        expected_stage_results=((ELIDE_VIEWS && (si==14 || si==17)) || (FUSE_FINAL && si==21)) ? 0 :
            stage_ow[si]*stage_oh[si]*((stage_cout[si]+7)/8);
    endfunction

    integer parameter_read_count;
    integer output_count;
    integer mac_output_count;
    integer dw_output_count;
    integer bypass_output_count;
    integer stage_done_count;
    integer abort_count;
    integer injected_fault_count;
    integer output_stall_count;
    integer cycle_count;
    integer pending_delay;
    integer pending_addr;
    integer first_run_start_cycle;
    integer first_run_cycles;
    logic parameter_pending;
    logic inject_param_error_once;
    logic hold_output_for_abort = 1'b0;
    integer dw_frame_starts[0:21],dw_frame_input_ends[0:21],dw_frame_output_ends[0:21];
    integer dw_frame_feeds[0:21],dw_frame_continues[0:21];
    always @(posedge clk) begin
        if(rst || (job_start_valid && job_start_ready)) begin
            for(integer n=0;n<22;n++) begin
                dw_frame_starts[n]=0;dw_frame_input_ends[n]=0;dw_frame_output_ends[n]=0;
                dw_frame_feeds[n]=0;dw_frame_continues[n]=0;
            end
        end else if(DW_FRAME && !abort && stage_index<22) begin
            if(dut.u_engine.dw_start_valid && dut.u_engine.dw_start_ready)dw_frame_starts[stage_index]++;
            if(dut.u_engine.u_dw_core.in_valid && dut.u_engine.u_dw_core.in_ready) begin
                dw_frame_feeds[stage_index]++;
                if(dut.u_engine.u_dw_core.in_eof)dw_frame_input_ends[stage_index]++;
            end
            if(dut.u_engine.u_dw_core.out_valid && dut.u_engine.u_dw_core.out_ready && dut.u_engine.u_dw_core.out_eof)
                dw_frame_output_ends[stage_index]++;
            if(dut.u_engine.state_q==dut.u_engine.ST_DW_START && dut.u_engine.dw_frame_continue)
                dw_frame_continues[stage_index]++;
        end
    end

    c1_r1_microstyle_cnn_top #(
        .REQUIRED_STAGES(STAGES),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .PARAM_ARENA_BYTES(PARAM_BYTES),
        .MAX_CHANNELS(48),
        .MAX_WEIGHT_BYTES(2592),
        .PIPELINED_DOT_TREE(PIPELINED_DOT_TREE),
        .PIPELINED_DOT_TREE_FULL(PIPELINED_DOT_TREE_FULL),
        .PIPELINED_DECODER_VALIDATION(PIPELINED_DECODER_VALIDATION),
        .CACHE_DW_WEIGHT_TILES(CACHE_DW_WEIGHT_TILES),
        .STREAM_DW_GROUPS(STREAM_DW_GROUPS),
        .MAC_PREFETCH_OVERLAP(MAC_PREFETCH_OVERLAP),
        .STREAM_POINTWISE_REDUCTION(POINTWISE_STREAM),
        .OVERLAP_MAC_REQUANTIZATION(REQUANT_OVERLAP),
        .PIPELINE_DOT_PIXELS(DOT_PIXELS),
        .PIPELINE_DW_PIXELS(DW_PIXELS),
        .STREAM_DW_FRAME(DW_FRAME),
        .PIPELINE_ALL_DOT_GROUPS(ALL_DOT_GROUPS),
        .PACK_RGB_CONV_REDUCTION(PACK_RGB),
        .ELIDE_VIRTUAL_UPSAMPLE(ELIDE_VIEWS),
        .FUSE_FINAL_OUTPUT(FUSE_FINAL),
        .PACKED_AFFINE_CACHE(PACKED_AFFINE_CACHE)
    ) dut (
        .view_commit_valid,.view_commit_ready,.view_commit_stage,.view_commit_generation,
        .clk, .rst, .abort,
        .start_valid(job_start_valid), .start_ready(job_start_ready),
        .stage_count(job_stage_count),
        .config_generation, .parameter_active_valid,
        .parameter_generation, .busy, .done, .aborted, .error,
        .error_code,
        .stage_config_valid, .stage_config_ready,
        .stage_config_index, .stage_config_descriptor,
        .stage_config_generation,
        .param_rd_en, .param_rd_addr, .param_rd_valid,
        .param_rd_error, .param_rd_data,
        .in_valid, .in_ready, .in_window_s8, .in_residual_s8,
        .in_group_index, .in_group_last, .in_x, .in_y,
        .in_sof, .in_eol, .in_eof,
        .out_valid, .out_ready, .out_data_s8, .out_group_index,
        .out_group_last, .out_x, .out_y, .out_sof, .out_eol,
        .out_eof, .stage_index, .stage_opcode, .stage_active,
        .adapter_required, .stage_done, .overflow_seen,
        .config_capture_complete
    );

    function automatic integer align16(input integer value);
        align16 = (value + 15) & ~15;
    endfunction

    function automatic integer align64(input integer value);
        align64 = (value + 63) & ~63;
    endfunction

    function automatic integer layer_weight_bytes(
        input integer op,
        input integer cin,
        input integer cout
    );
        begin
            case (op)
                1: layer_weight_bytes = cin * cout * 9;
                2: layer_weight_bytes = cin * cout;
                3: layer_weight_bytes = cin * 9;
                default: layer_weight_bytes = 0;
            endcase
        end
    endfunction

    function automatic logic signed [7:0] input_value(
        input integer si,
        input integer px,
        input integer py,
        input integer channel
    );
        integer value;
        begin
            value = ((si * 3 + px + py + channel) % 31) - 15;
            input_value = value;
        end
    endfunction

    function automatic logic [7:0] residual_expected(
        input logic signed [7:0] value
    );
        integer sum;
        begin
            sum = value + 1;
            if (sum < 0)
                sum = 0;
            else if (sum > 127)
                sum = 127;
            residual_expected = sum[7:0];
        end
    endfunction

    function automatic integer rgb_weight(input integer oc, ic, tap);
        rgb_weight = ((oc*7 + ic*5 + tap*3) % 7) - 3;
    endfunction
    function automatic integer rgb_activation(input integer px, py, ic, tap);
        rgb_activation = ((px*19 + py*23 + ic*7 + tap*11) % 31) - 15;
    endfunction
    integer rgb_first_beats=0;
    bit rgb_first_done=0;
    bit rgb_held=0;
    logic [584:0] rgb_held_payload;
    always @(posedge clk) begin
        if(rst || abort || dut.u_engine.generation_changed) rgb_held<=0;
        else begin
            if(!rgb_first_done && stage_index==0 &&
               dut.u_engine.dot_in_valid && dut.u_engine.dot_in_ready)
                rgb_first_beats++;
            if(rgb_held && (!dut.u_engine.dot_in_valid ||
               {dut.u_engine.dot_in_activations,dut.u_engine.dot_in_weights,
                dut.u_engine.dot_in_lane_mask,dut.u_engine.dot_in_last} !== rgb_held_payload))
                $fatal(1,"RGB reduction input changed under backpressure");
            rgb_held <= PACK_RGB && stage_index==0 && dut.u_engine.dot_in_valid && !dut.u_engine.dot_in_ready;
            rgb_held_payload <= {dut.u_engine.dot_in_activations,dut.u_engine.dot_in_weights,
                                 dut.u_engine.dot_in_lane_mask,dut.u_engine.dot_in_last};
            if(PACK_RGB && stage_index==0 && dut.u_engine.dot_in_valid &&
               dut.u_engine.dot_in_lane_mask !== (dut.u_engine.dot_in_last ? 8'h07 : 8'hff))
                $fatal(1,"RGB reduction mask/tail mismatch");
        end
    end
    integer dw_center_scale=1;
    integer changed_weight_witnesses=0;
    function automatic logic [7:0] mac_expected(
        input integer si,
        input integer px,
        input integer py,
        input integer channel,
        input integer dw_scale
    );
        integer value, ic, tap;
        begin
            value = si + channel + 1;
            if (DENSE_RGB && si==0) begin
                // Independent OIHW scalar sum, not the packed-bank mapping.
                for(ic=0;ic<3;ic++) for(tap=0;tap<9;tap++)
                    value += rgb_activation(px,py,ic,tap)*rgb_weight(channel,ic,tap);
            end else if (((si == 0) && (channel == 0)) ||
                (si == 18) || (si == 19) || (si == 20))
                value = value + ((si==18)?dw_scale:1) *
                    $signed(input_value(si, px, py, channel));
            if (value > 127)
                value = 127;
            else if (value < -128)
                value = -128;
            if ((stage_act[si] == 1) && (value < 0))
                value = 0;
            mac_expected = value[7:0];
        end
    endfunction

    task automatic put_u32(input integer address, input integer value);
        begin
            parameter_bytes[address + 0] = value[7:0];
            parameter_bytes[address + 1] = value[15:8];
            parameter_bytes[address + 2] = value[23:16];
            parameter_bytes[address + 3] = value[31:24];
        end
    endtask

    task automatic set_stage_shape(
        input integer si,
        input integer op,
        input integer iw,
        input integer ih,
        input integer ow,
        input integer oh,
        input integer cin,
        input integer cout,
        input integer act
    );
        begin
            stage_op[si] = op;
            stage_ow[si] = ow;
            stage_oh[si] = oh;
            stage_cin[si] = cin;
            stage_cout[si] = cout;
            stage_act[si] = act;
            descriptors[si] = '0;
            descriptors[si][7:0] = op;
            descriptors[si][9:8] = act;
            descriptors[si][23:16] = 8'd1;
            descriptors[si][31:24] = 8'd16;
            descriptors[si][47:32] = iw;
            descriptors[si][63:48] = ih;
            descriptors[si][79:64] = ow;
            descriptors[si][95:80] = oh;
            descriptors[si][111:96] = cin;
            descriptors[si][127:112] = cout;
            descriptors[si][455:448] = 8'd8;
            descriptors[si][463:456] = 8'd1;
            descriptors[si][471:464] = 8'd1;
            descriptors[si][479:472] = 8'd1;
            if ((op == 1) || (op == 3)) begin
                descriptors[si][423:416] = 8'd3;
                descriptors[si][431:424] = 8'd3;
                descriptors[si][10] = 1'b1;
            end else begin
                descriptors[si][423:416] = 8'd1;
                descriptors[si][431:424] = 8'd1;
            end
            if ((si == 0) || (si == 1)) begin
                descriptors[si][439:432] = 8'd2;
                descriptors[si][447:440] = 8'd2;
            end else if (op == 4) begin
                descriptors[si][439:432] = 8'd2;
                descriptors[si][447:440] = 8'd2;
            end else begin
                descriptors[si][439:432] = 8'd1;
                descriptors[si][447:440] = 8'd1;
            end
            if (op == 5)
                descriptors[si][11] = 1'b1;
            if (si == 0)
                descriptors[si][12] = 1'b1;
            if (si == STAGES-1)
                descriptors[si][13] = 1'b1;
            // Optional margin gate: stage 18 is the largest legal MAC/DW
            // shape in this TB.  A finite budget exercises the engine's
            // cycle-budget comparator without changing the default test.
            if ((TEST_CYCLE_BUDGET != 0) && (si == 18))
                descriptors[si][511:480] = TEST_CYCLE_BUDGET;
        end
    endtask

    task automatic build_layout;
        integer i, j, cursor, weight_count;
        integer weight_offset, bias_offset, mult_offset, shift_offset;
        begin
            for (i = 0; i < PARAM_BYTES; i = i + 1)
                parameter_bytes[i] = 8'd0;
            for (i = 0; i < STAGES; i = i + 1) begin
                descriptors[i] = '0;
                observed_outputs[i] = 0;
            end

            set_stage_shape(0, 1, 8, 8, 4, 4, 3, 12, 1);
            set_stage_shape(1, 1, 4, 4, 2, 2, 12, 24, 1);
            set_stage_shape(2, 2, 2, 2, 2, 2, 24, 48, 1);
            set_stage_shape(3, 3, 2, 2, 2, 2, 48, 48, 1);
            set_stage_shape(4, 2, 2, 2, 2, 2, 48, 24, 0);
            set_stage_shape(5, 5, 2, 2, 2, 2, 24, 24, 1);
            set_stage_shape(6, 2, 2, 2, 2, 2, 24, 48, 1);
            set_stage_shape(7, 3, 2, 2, 2, 2, 48, 48, 1);
            set_stage_shape(8, 2, 2, 2, 2, 2, 48, 24, 0);
            set_stage_shape(9, 5, 2, 2, 2, 2, 24, 24, 1);
            set_stage_shape(10, 2, 2, 2, 2, 2, 24, 48, 1);
            set_stage_shape(11, 3, 2, 2, 2, 2, 48, 48, 1);
            set_stage_shape(12, 2, 2, 2, 2, 2, 48, 24, 0);
            set_stage_shape(13, 5, 2, 2, 2, 2, 24, 24, 1);
            set_stage_shape(14, 4, 2, 2, 4, 4, 24, 24, 0);
            set_stage_shape(15, 3, 4, 4, 4, 4, 24, 24, 1);
            set_stage_shape(16, 2, 4, 4, 4, 4, 24, 16, 1);
            set_stage_shape(17, 4, 4, 4, 8, 8, 16, 16, 0);
            set_stage_shape(18, 3, 8, 8, 8, 8, 16, 16, 1);
            set_stage_shape(19, 2, 8, 8, 8, 8, 16, 8, 1);
            set_stage_shape(20, 1, 8, 8, 8, 8, 8, 3, 0);
            set_stage_shape(21, 6, 8, 8, 8, 8, 3, 3, 0);

            if(SMALL_FRAME) begin
                // 4x4 input: DW stages 3/7/11 are single-pixel cold-only
                // layers. Keep channel/topology ABI unchanged.
                for(i=0;i<STAGES;i++)
                    set_stage_shape(i,stage_op[i],descriptors[i][47:32]/2,
                        descriptors[i][63:48]/2,stage_ow[i]/2,stage_oh[i]/2,
                        stage_cin[i],stage_cout[i],stage_act[i]);
            end

            cursor = 0;
            for (i = 0; i < STAGES; i = i + 1) begin
                weight_count = layer_weight_bytes(
                    stage_op[i], stage_cin[i], stage_cout[i]);
                if (weight_count != 0) begin
                    cursor = align64(cursor);
                    weight_offset = cursor;
                    if (i == 0)
                        parameter_bytes[weight_offset + 4] = 8'd1;
                    if (i == 0 && DENSE_RGB)
                        for(j=0;j<weight_count;j++)
                            parameter_bytes[weight_offset+j] = rgb_weight(j/27,(j/9)%3,j%9);
                    if (i == 18)
                        for (j = 0; j < stage_cout[i]; j = j + 1)
                            parameter_bytes[weight_offset + j*9 + 4] = 8'd1;
                    if (i == 19)
                        for (j = 0; j < stage_cout[i]; j = j + 1)
                            parameter_bytes[weight_offset + j*stage_cin[i] + j] = 8'd1;
                    if (i == 20)
                        for (j = 0; j < stage_cout[i]; j = j + 1)
                            parameter_bytes[weight_offset +
                                            (j*stage_cin[i] + j)*9 + 4] = 8'd1;
                    cursor = cursor + weight_count;
                    cursor = align16(cursor);
                    bias_offset = cursor;
                    for (j = 0; j < stage_cout[i]; j = j + 1)
                        put_u32(cursor + j*4, i + j + 1);
                    cursor = align16(cursor + stage_cout[i]*4);
                    mult_offset = cursor;
                    for (j = 0; j < stage_cout[i]; j = j + 1)
                        put_u32(cursor + j*4, 1);
                    cursor = align16(cursor + stage_cout[i]*4);
                    shift_offset = cursor;
                    for (j = 0; j < stage_cout[i]; j = j + 1)
                        parameter_bytes[cursor + j] = 8'd0;
                    cursor = align16(cursor + stage_cout[i]);

                    descriptors[i][255:224] = weight_offset;
                    descriptors[i][287:256] = bias_offset;
                    descriptors[i][319:288] = mult_offset;
                    descriptors[i][351:320] = shift_offset;
                end
            end
            if (cursor > PARAM_BYTES)
                $fatal(1, "test parameter layout overflowed arena: %0d", cursor);
        end
    endtask

    task automatic pulse_job_start;
        begin
            @(negedge clk);
            job_start_valid = 1'b1;
            while (!job_start_ready)
                @(negedge clk);
            @(negedge clk);
            job_start_valid = 1'b0;
        end
    endtask

    task automatic send_descriptor(
        input integer index,
        input logic [511:0] value
    );
        begin
            @(negedge clk);
            stage_config_index = index;
            stage_config_descriptor = value;
            stage_config_generation = config_generation;
            stage_config_valid = 1'b1;
            while (!stage_config_ready)
                @(negedge clk);
            @(negedge clk);
            stage_config_valid = 1'b0;
        end
    endtask

    task automatic send_input_group(
        input integer si,
        input integer px,
        input integer py,
        input integer group_index,
        input bit corrupt_group
    );
        logic [575:0] window_value;
        logic [63:0] residual_value;
        logic signed [7:0] lane_value;
        integer tap, lane, global_channel;
        begin
            window_value = '0;
            residual_value = '0;
            for (tap = 0; tap < 9; tap = tap + 1) begin
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    global_channel = group_index * 8 + lane;
                    if (DENSE_RGB && si==0 && global_channel<3)
                        lane_value = rgb_activation(px,py,global_channel,tap);
                    else if (DENSE_RGB && si==0)
                        lane_value = -8'sd99; // Invalid C8 padding must not contribute.
                    else if (global_channel < stage_cin[si])
                        lane_value = input_value(si, px, py, global_channel);
                    else
                        lane_value = 8'sd0;
                    window_value[(tap*8 + lane)*8 +: 8] = lane_value;
                end
            end
            for (lane = 0; lane < 8; lane = lane + 1)
                residual_value[lane*8 +: 8] = 8'sd1;

            @(negedge clk);
            in_window_s8 = window_value;
            in_residual_s8 = residual_value;
            in_group_index = corrupt_group ? group_index + 1 : group_index;
            in_group_last =
                (group_index == ((stage_cin[si] + 7) / 8) - 1);
            in_x = px;
            in_y = py;
            in_sof = (px == 0) && (py == 0);
            in_eol = (px == stage_ow[si] - 1);
            in_eof = in_eol && (py == stage_oh[si] - 1);
            in_valid = 1'b1;
            while (!in_ready)
                @(negedge clk);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic check_pointwise_partial(input integer fault);
        integer si,guard,outputs_before;
        begin
            pulse_job_start();
            for(si=0;si<STAGES;si++) send_descriptor(si,descriptors[si]);
            run_stage(0);run_stage(1);
            send_input_group(2,0,0,0,0);
            guard=0;
            while(!(dut.u_engine.pointwise_stream_q && in_ready && dut.u_engine.dot_busy)) begin
                @(negedge clk);guard++;if(guard>200) $fatal(1,"partial pointwise MAC did not start before group 1");
            end
            outputs_before=output_count;
            repeat(16) begin
                @(negedge clk);
                if(out_valid || !in_ready || !dut.u_engine.dot_busy || error || !busy)
                    $fatal(1,"partial pointwise transaction escaped missing-input fence");
            end
            if(fault==1) send_input_group(2,0,0,1,1);
            if(fault==2) parameter_generation=parameter_generation+1;
            if(fault!=0) begin
                guard=0;
                while(!error) begin
                    @(negedge clk);guard++;if(guard>100) $fatal(1,"partial pointwise error missing");
                end
                // The CNN wrapper owns live generation faults (E3), while
                // malformed C8 metadata propagates the engine's 07 code.
                if(error_code!=(fault==1 ? 8'h07 : 8'he3)) $fatal(1,"wrong partial pointwise error code=%0h",error_code);
            end
            if(output_count!=outputs_before) $fatal(1,"partial pointwise emitted an incomplete result");
            abort=1;@(negedge clk);abort=0;@(negedge clk);
            if(!job_start_ready || busy || error || out_valid || dut.u_engine.dot_busy || dut.u_engine.pointwise_stream_q)
                $fatal(1,"partial pointwise abort failed to quiesce");
            if(fault==2) parameter_generation=parameter_generation-1;
            $display("C1_POINTWISE_PARTIAL_DRAIN_PASS fault=%0d held_input=16 reset=0",fault);
        end
    endtask

    task automatic check_pointwise_output_hold;
        integer si,group_i,guard;
        logic [102:0] payload;
        begin
            pulse_job_start();
            for(si=0;si<STAGES;si++) send_descriptor(si,descriptors[si]);
            run_stage(0);run_stage(1);
            hold_output_for_abort=1;
            for(group_i=0;group_i<(stage_cin[2]+7)/8;group_i++) send_input_group(2,0,0,group_i,0);
            guard=0;
            while(!out_valid) begin
                @(negedge clk);guard++;if(guard>100) $fatal(1,"pointwise output hold missing result");
            end
            payload={out_data_s8,out_group_index,out_group_last,out_x,out_y,out_sof,out_eol,out_eof};
            repeat(8) begin
                @(negedge clk);
                if(!out_valid || out_ready || (!ALL_DOT_GROUPS && in_ready) || (!REQUANT_OVERLAP && !dut.u_engine.pointwise_stream_q) ||
                   {out_data_s8,out_group_index,out_group_last,out_x,out_y,out_sof,out_eol,out_eof}!==payload)
                    $fatal(1,"pointwise output changed under backpressure");
            end
            if(REQUANT_OVERLAP) begin
                guard=0;
                while(dut.u_engine.u_dot_core.transactions_pending_q!=6 || !dut.u_engine.dot_issue_done_q) begin
                    @(negedge clk);guard++;
                    if(guard>1000 || !out_valid ||
                       {out_data_s8,out_group_index,out_group_last,out_x,out_y,out_sof,out_eol,out_eof}!==payload)
                        $fatal(1,"requant six-group output hold failed");
                end
                if(ALL_DOT_GROUPS) begin
                    // Six old groups remain held. Reuse the old window for
                    // one or all input groups of x=1 without changing x=0's
                    // result metadata, padding mask, payload or ownership.
                    // Pointwise streaming needs a free core START before
                    // input group1. Six held transactions fill that core;
                    // only group0 fits until an old result is released.
                    for(group_i=0;group_i<((DOT_NEXT_ALL_INPUTS && !POINTWISE_STREAM) ? (stage_cin[2]+7)/8 : 1);group_i++)
                        send_input_group(2,1,0,group_i,0);
                    if(dut.u_engine.meta_x_q!=1 || out_x!=0 || out_group_index!=0 || !dut.u_engine.dot_busy)
                        $fatal(1,"multi-group dot reused input cursor as output ownership");
                    $display("C1_ENGINE_ALL_DOT_NEXT_HOLD_PASS old_groups=6 next_inputs=%0d old_x=0 next_x=1 reset=0",
                        (DOT_NEXT_ALL_INPUTS && !POINTWISE_STREAM) ? (stage_cin[2]+7)/8 : 1);
                end
                repeat(12)begin
                    @(negedge clk);
                    if(ALL_DOT_GROUPS && (dut.u_engine.u_dot_core.transactions_pending_q!=6 ||
                       dut.u_engine.dot_start_ready || ((POINTWISE_STREAM || DOT_NEXT_ALL_INPUTS) && in_ready)))
                        $fatal(1,"all dot groups exceeded held core or prepared-window capacity");
                    if((!ALL_DOT_GROUPS && (in_ready || dut.u_engine.dot_start_valid)) || !out_valid ||
                       {out_data_s8,out_group_index,out_group_last,out_x,out_y,out_sof,out_eol,out_eof}!==payload)
                        $fatal(1,"requant full pixel fence failed");
                end
                $display("C1_ENGINE_REQUANT_FULL_HOLD_PASS groups=6 retired=0");
            end
            abort=1;@(negedge clk);abort=0;hold_output_for_abort=0;@(negedge clk);
            if(!job_start_ready || busy || error || out_valid || dut.u_engine.dot_busy)
                $fatal(1,"held pointwise output did not cancel cleanly");
            $display("C1_POINTWISE_OUTPUT_HOLD_PASS cycles=8 canceled=1 reset=0");
        end
    endtask

    task automatic run_stage(input integer si);
        integer px, py, group_index, input_groups;
        begin
            while (!stage_active) begin
                if (error)
                    $fatal(1, "engine rejected legal stage %0d code=%0h",
                           si, error_code);
                @(negedge clk);
            end
            if (!adapter_required)
                $fatal(1, "stage %0d did not advertise tensor adapter contract", si);
            input_groups = (stage_cin[si] + 7) / 8;
            if((ELIDE_VIEWS && (si==14 || si==17)) || (FUSE_FINAL && si==21)) begin
                @(negedge clk);
                view_commit_stage=si;view_commit_generation=config_generation;
                view_commit_valid=1;
                while(!view_commit_ready) begin
                    if(error)$fatal(1,"view commit preparation fault");
                    @(negedge clk);
                end
                if(in_ready || out_valid)$fatal(1,"view commit overlapped data transfer");
                @(negedge clk);
                view_commit_valid=0;
                if(!stage_done || error)$fatal(1,"view commit did not complete the logical layer");
            end else begin
            for (py = 0; py < stage_oh[si]; py = py + 1)
                for (px = 0; px < stage_ow[si]; px = px + 1)
                    for (group_index = 0; group_index < input_groups;
                         group_index = group_index + 1) begin
                        // Force an old group-0 result to remain visible while
                        // the issue cursor is group 1 and state is COLLECT.
                        // This must work even with RGB packing DISABLED.
                        if(DENSE_RGB && ALL_DOT_GROUPS && !rgb_first_done &&
                           si==0 && px==2 && py==2 && group_index==0) begin
                            while(dut.u_engine.dot_busy) @(negedge clk);
                            hold_output_for_abort=1;
                            repeat(2) @(negedge clk);
                        end
                        send_input_group(si, px, py, group_index, 1'b0);
                        if(DENSE_RGB && ALL_DOT_GROUPS && !rgb_first_done &&
                           si==0 && px==2 && py==2 && group_index==0) begin
                            while(!(dut.u_engine.state_q==dut.u_engine.ST_COLLECT &&
                                    dut.u_engine.dot_issue_done_q)) @(negedge clk);
                            while(!out_valid) @(negedge clk);
                            repeat(12) begin
                                if(!out_valid || out_ready || out_group_index!=0 ||
                                   out_x!=2 || out_y!=2 || dut.u_engine.output_group_q!=1 ||
                                   out_data_s8[4*8 +:8] !== mac_expected(0,2,2,4,dw_center_scale))
                                    $fatal(1,"COLLECT used issue-group mask for old group-0 RGB result");
                                @(negedge clk);
                            end
                            $display("C1_ENGINE_RGB_COLLECT_MASK_PASS pack=%0d old_group=0 issue_group=1 lane4=%0d cycles=12",PACK_RGB,$signed(out_data_s8[4*8 +:8]));
                            hold_output_for_abort=0;
                            while(dut.u_engine.dot_busy) @(negedge clk);
                        end
                    end
            while (!stage_done) begin
                if (error)
                    $fatal(1, "engine faulted in legal stage %0d code=%0h",
                           si, error_code);
                @(negedge clk);
            end
            end
        end
    endtask

    always @(posedge clk) begin
        param_rd_valid <= 1'b0;
        param_rd_error <= 1'b0;
        if (rst || abort) begin
            parameter_pending <= 1'b0;
            pending_delay <= 0;
            pending_addr <= 0;
            param_rd_data <= '0;
        end else begin
            if (param_rd_en) begin
                if (parameter_pending)
                    $fatal(1, "engine issued a second parameter read");
                parameter_pending <= 1'b1;
                pending_addr <= param_rd_addr;
                pending_delay <= (parameter_read_count % 3) + 1;
                parameter_read_count <= parameter_read_count + 1;
            end
            if (parameter_pending) begin
                if (pending_delay == 0) begin
                    if (inject_param_error_once) begin
                        param_rd_error <= 1'b1;
                        inject_param_error_once <= 1'b0;
                    end else begin
                        for (integer byte_lane = 0; byte_lane < 16;
                             byte_lane = byte_lane + 1)
                            param_rd_data[byte_lane*8 +: 8] <=
                                parameter_bytes[pending_addr*16 + byte_lane];
                        param_rd_valid <= 1'b1;
                    end
                    parameter_pending <= 1'b0;
                end else begin
                    pending_delay <= pending_delay - 1;
                end
            end
        end
    end

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        out_ready_pattern <= !hold_output_for_abort && ((cycle_count % 7) != 2) &&
                     ((cycle_count % 11) != 5);
        if (out_valid && !out_ready)
            output_stall_count <= output_stall_count + 1;

        if (out_valid && out_ready) begin
            integer lane;
            integer global_channel;
            logic [7:0] expected_value;
            logic signed [7:0] source_value;
            output_count <= output_count + 1;
            observed_outputs[stage_index] <=
                observed_outputs[stage_index] + 1;
            if ((stage_opcode == 1) || (stage_opcode == 2))
                mac_output_count <= mac_output_count + 1;
            else if (stage_opcode == 3)
                dw_output_count <= dw_output_count + 1;
            else
                bypass_output_count <= bypass_output_count + 1;

            if ((out_x >= stage_ow[stage_index]) ||
                (out_y >= stage_oh[stage_index]))
                $fatal(1, "output coordinate out of range stage=%0d", stage_index);
            if (out_group_last !=
                (out_group_index == ((stage_cout[stage_index] + 7) / 8) - 1))
                $fatal(1, "output group-last mismatch stage=%0d", stage_index);
            if (out_sof != ((out_x == 0) && (out_y == 0) &&
                           (out_group_index == 0)))
                $fatal(1, "output SOF mismatch stage=%0d", stage_index);
            if (out_eol != ((out_x == stage_ow[stage_index]-1) &&
                           out_group_last))
                $fatal(1, "output EOL mismatch stage=%0d", stage_index);
            if (out_eof != ((out_x == stage_ow[stage_index]-1) &&
                           (out_y == stage_oh[stage_index]-1) &&
                           out_group_last))
                $fatal(1, "output EOF mismatch stage=%0d", stage_index);

            for (lane = 0; lane < 8; lane = lane + 1) begin
                global_channel = out_group_index * 8 + lane;
                if (global_channel >= stage_cout[stage_index]) begin
                    expected_value = 8'd0;
                end else if ((stage_opcode == 1) ||
                             (stage_opcode == 2) ||
                             (stage_opcode == 3)) begin
                    expected_value = mac_expected(
                        stage_index, out_x, out_y, global_channel,dw_center_scale);
                end else begin
                    source_value = input_value(
                        stage_index, out_x, out_y, global_channel);
                    if (stage_opcode == 5)
                        expected_value = residual_expected(source_value);
                    else
                        expected_value = source_value;
                end
                if(dw_center_scale==-1 && stage_index==18 && global_channel<stage_cout[18] &&
                   expected_value!==mac_expected(18,out_x,out_y,global_channel,1))
                    changed_weight_witnesses++;
                if (out_data_s8[lane*8 +: 8] !== expected_value)
                    $fatal(1,
                           "data mismatch stage=%0d xy=%0d,%0d group=%0d lane=%0d got=%0d expected=%0d",
                           stage_index, out_x, out_y, out_group_index, lane,
                           $signed(out_data_s8[lane*8 +: 8]),
                           $signed(expected_value));
            end
        end
        if (stage_done)
            stage_done_count <= stage_done_count + 1;
        if (overflow_seen)
            $fatal(1, "unexpected accumulator overflow");
    end

    initial begin : main_test
        integer i;
        integer warm_outputs, restart_stages, restart_witnesses;
        integer restart_outputs [0:STAGES-1];
        logic [102:0] held_output;
        logic [511:0] bad_descriptor;
        rst = 1'b1;
        abort = 1'b0;
        job_start_valid = 1'b0;
        job_stage_count = STAGES;
        config_generation = 8'd7;
        parameter_active_valid = 1'b1;
        parameter_generation = 32'd9;
        stage_config_valid = 1'b0;
        stage_config_index = 16'd0;
        stage_config_descriptor = '0;
        stage_config_generation = 8'd0;
        in_valid = 1'b0;
        in_window_s8 = '0;
        in_residual_s8 = '0;
        in_group_index = '0;
        in_group_last = 1'b0;
        in_x = '0;
        in_y = '0;
        in_sof = 1'b0;
        in_eol = 1'b0;
        in_eof = 1'b0;
        param_rd_valid = 1'b0;
        param_rd_error = 1'b0;
        param_rd_data = '0;
        parameter_pending = 1'b0;
        inject_param_error_once = 1'b0;
        parameter_read_count = 0;
        output_count = 0;
        mac_output_count = 0;
        dw_output_count = 0;
        bypass_output_count = 0;
        stage_done_count = 0;
        abort_count = 0;
        injected_fault_count = 0;
        output_stall_count = 0;
        cycle_count = 0;
        out_ready_pattern = 1'b0;

        build_layout();
        repeat (8) @(negedge clk);
        rst = 1'b0;

        first_run_start_cycle = cycle_count;
        pulse_job_start();
        for (i = 0; i < STAGES; i = i + 1)
            send_descriptor(i, descriptors[i]);
        for (i = 0; i < STAGES; i = i + 1)
            run_stage(i);
        while (!done)
            @(negedge clk);
        first_run_cycles = cycle_count - first_run_start_cycle;
        if(DW_FRAME) begin
            for(i=0;i<22;i++) if(stage_op[i]==3) begin
                if(dw_frame_starts[i]!=((stage_cin[i]+7)/8+(stage_ow[i]*stage_oh[i]>1 ? 1 : 0)) ||
                   dw_frame_input_ends[i]!=dw_frame_starts[i] || dw_frame_output_ends[i]!=dw_frame_starts[i] ||
                   dw_frame_feeds[i]!=expected_stage_results(i) ||
                   dw_frame_continues[i]!=(stage_ow[i]*stage_oh[i]>2 ? stage_ow[i]*stage_oh[i]-2 : 0))
                    $fatal(1,"DW frame batch/EOF/continuation ownership mismatch stage=%0d",i);
            end
            if(dw_frame_eof_hold!=12)$fatal(1,"DW frame missing actual layer EOF hold witness");
            $display("C1_ENGINE_DW_FRAME_BATCH_PASS layers=5 small=%0d cold_only=%0d eof_join=1 held_eof=12",SMALL_FRAME,SMALL_FRAME?3:0);
        end
        if(view_commit_count!=((ELIDE_VIEWS?2:0)+(FUSE_FINAL?1:0)))$fatal(1,"view commit count mismatch");
        if(ELIDE_VIEWS && view_wait_cycles==0)$fatal(1,"view test lacked real preparation backpressure");
        $display("C1_ENGINE_VIEW_COMMIT_PASS enabled=%0d commits=%0d waits=%0d",ELIDE_VIEWS,view_commit_count,view_wait_cycles);
        $display("C1_ENGINE_FINAL_FUSION_PASS enabled=%0d final_data_results=%0d",FUSE_FINAL,expected_stage_results(21));
        rgb_first_done=1;
        if(rgb_first_beats!=stage_ow[0]*stage_oh[0]*((stage_cout[0]+7)/8)*(PACK_RGB?4:9))
            $fatal(1,"RGB reduction accepted-beat budget mismatch: %0d",rgb_first_beats);
        $display("C1_ENGINE_RGB_REDUCTION_PASS enabled=%0d dense=%0d beats=%0d",PACK_RGB,DENSE_RGB,rgb_first_beats);
        repeat (2) @(negedge clk);
        if (stage_done_count != STAGES)
            $fatal(1, "stage completion count mismatch got=%0d", stage_done_count);
        for (i = 0; i < STAGES; i = i + 1)
            if (observed_outputs[i] !=
                expected_stage_results(i))
                $fatal(1, "stage %0d output count mismatch got=%0d", i,
                       observed_outputs[i]);

        // A new generation changes actual DW weights, not just metadata.
        // No reset: stale weight tiles must not survive into this job.
        parameter_generation=32'd10;dw_center_scale=-1;
        for(i=0;i<stage_cout[18];i++)
            parameter_bytes[descriptors[18][255:224]+i*9+4]=8'hff;
        pulse_job_start();
        for(i=0;i<STAGES;i++) send_descriptor(i,descriptors[i]);
        for(i=0;i<STAGES;i++) run_stage(i);
        while(!done) @(negedge clk);
        repeat(2) @(negedge clk);
        if(stage_done_count!=2*STAGES)
            $fatal(1,"new parameter generation did not complete all stages");
        for(i=0;i<STAGES;i++)
            if(observed_outputs[i]!=2*expected_stage_results(i))
                $fatal(1,"new generation output count mismatch stage=%0d",i);
        $display("C1_ENGINE_GENERATION_RELOAD_PASS old=9 new=10 dw_center=-1 stages=22 reset=0");
        if(changed_weight_witnesses==0)
            $fatal(1,"weight reload test cannot distinguish old and new weights");
        $display("C1_ENGINE_WEIGHT_WITNESS_PASS changed_lanes=%0d",changed_weight_witnesses);
        // Restore the original fixture for the subsequent independent faults.
        parameter_generation=32'd9;dw_center_scale=1;
        for(i=0;i<stage_cout[18];i++)
            parameter_bytes[descriptors[18][255:224]+i*9+4]=8'd1;

        // Reach a real, populated DW cache before cancellation. The SoC
        // bus-debt abort tests can cancel stage 0, before any DW tile exists.
        pulse_job_start();
        for(i=0;i<STAGES;i++) send_descriptor(i,descriptors[i]);
        for(i=0;i<18;i++) run_stage(i);
        warm_outputs=observed_outputs[18];
        for(i=0;i<2;i++) send_input_group(18,0,0,i,1'b0);
        while(observed_outputs[18]!=warm_outputs+2) @(negedge clk);
        if(CACHE_DW_WEIGHT_TILES &&
           dut.u_engine.dw_group_tile_valid_q !== 6'b000011)
            $fatal(1,"warm abort did not populate both DW output-group tiles");
        hold_output_for_abort=1'b1;
        for(i=0;i<2;i++) send_input_group(18,1,0,i,1'b0);
        while(!out_valid) @(negedge clk);
        if(STREAM_DW_GROUPS && (!dut.u_engine.dw_feed_done_q ||
            dut.u_engine.dw_feed_group_q!=1 || dut.u_engine.output_group_q!=0 || !dut.u_engine.dw_busy))
            $fatal(1,"DW stream warm abort did not contain two accepted unretired groups");
        held_output={out_data_s8,out_group_index,out_group_last,
                     out_x,out_y,out_sof,out_eol,out_eof};
        if(DW_PIXELS) begin
            // Preserve an old quantized result while new input metadata and
            // one or ALL next-pixel windows overwrite the old collect cache.
            for(i=0;i<DW_PREFETCH_GROUPS;i++) send_input_group(18,2,0,i,1'b0);
            if(dut.u_engine.meta_x_q!=2 || out_x!=1 || !dut.u_engine.dw_busy)
                $fatal(1,"DW pixel overlap failed to separate old/new metadata");
            if(DW_PREFETCH_GROUPS==2 && in_ready)
                $fatal(1,"DW pixel overlap accepted more than one prepared next pixel");
            $display("C1_ENGINE_DW_PIXEL_NEXT_HOLD_PASS groups=%0d old_x=1 next_x=2 reset=0",DW_PREFETCH_GROUPS);
            if(DW_FRAME && DW_PREFETCH_GROUPS==2) begin
                // Keep pixel 1's old output stalled while pixels 2 AND 3
                // bind new weights/bias/affine/coordinates into real stages.
                for(i=0;i<2;i++) send_input_group(18,3,0,i,1'b0);
                repeat(12) @(negedge clk);
                if(dw_frame_starts[18]!=3 || dw_frame_feeds[18]<6 ||
                   dw_frame_input_ends[18]!=2 || dw_frame_output_ends[18]!=2 ||
                   dw_frame_continues[18]<2 || out_x!=1 || !dut.u_engine.dw_busy)
                    $fatal(1,"DW frame held-output continuation failed to exercise real pipeline ownership");
                $display("C1_ENGINE_DW_FRAME_HELD_PASS starts=3 fed=%0d old_x=1 next_x=3 actual_ends=2 reset=0",dw_frame_feeds[18]);
            end
        end
        repeat(8) begin
            @(negedge clk);
            if(!out_valid || out_ready || stage_index!=18 ||
               observed_outputs[18]!=warm_outputs+2 ||
               {out_data_s8,out_group_index,out_group_last,
                out_x,out_y,out_sof,out_eol,out_eof} !== held_output)
                $fatal(1,"warm DW output changed or retired under backpressure");
        end
        abort=1'b1;
        @(negedge clk);
        abort=1'b0;
        abort_count++;
        repeat(2) @(negedge clk);
        if(!job_start_ready || busy || error || out_valid || param_rd_en ||
           dut.u_engine.dw_group_tile_valid_q !== '0)
            $fatal(1,"warm DW abort failed to clear cached ownership/output");
        hold_output_for_abort=1'b0;
        if(STREAM_DW_GROUPS) $display("C1_ENGINE_DW_STREAM_ABORT_PASS pending_groups=2 drained=1 reset=0");
        $display("C1_ENGINE_WARM_ABORT_PASS cache_dw=%0d mac_overlap=%0d stage=18 valid_groups=%0d held_cycles=8 reset=0",
                 CACHE_DW_WEIGHT_TILES,MAC_PREFETCH_OVERLAP,
                 CACHE_DW_WEIGHT_TILES ? 2 : 0);

        // Change bytes as well as generation. Complete and count every
        // stage after restart; the ordinary lane scoreboard remains active.
        restart_stages=stage_done_count;
        restart_witnesses=changed_weight_witnesses;
        for(i=0;i<STAGES;i++) restart_outputs[i]=observed_outputs[i];
        parameter_generation=32'd11;dw_center_scale=-1;
        for(i=0;i<stage_cout[18];i++)
            parameter_bytes[descriptors[18][255:224]+i*9+4]=8'hff;
        pulse_job_start();
        for(i=0;i<STAGES;i++) send_descriptor(i,descriptors[i]);
        for(i=0;i<STAGES;i++) run_stage(i);
        while(!done) @(negedge clk);
        repeat(2) @(negedge clk);
        if(stage_done_count!=restart_stages+STAGES ||
           changed_weight_witnesses<=restart_witnesses)
            $fatal(1,"warm abort restart lacks complete stages/changed-weight witnesses");
        for(i=0;i<STAGES;i++)
            if(observed_outputs[i]!=restart_outputs[i]+
               expected_stage_results(i))
                $fatal(1,"warm abort restart output count mismatch stage=%0d",i);
        $display("C1_ENGINE_WARM_RESTART_PASS generation=11 stages=22 changed_lanes=%0d reset=0",
                 changed_weight_witnesses-restart_witnesses);
        parameter_generation=32'd9;dw_center_scale=1;
        for(i=0;i<stage_cout[18];i++)
            parameter_bytes[descriptors[18][255:224]+i*9+4]=8'd1;

        if(POINTWISE_STREAM || REQUANT_OVERLAP) begin
            if(POINTWISE_STREAM) begin
                check_pointwise_partial(0);check_pointwise_partial(1);check_pointwise_partial(2);
            end
            check_pointwise_output_hold();
            restart_stages=stage_done_count;
            for(i=0;i<STAGES;i++) restart_outputs[i]=observed_outputs[i];
            pulse_job_start();
            for(i=0;i<STAGES;i++) send_descriptor(i,descriptors[i]);
            for(i=0;i<STAGES;i++) run_stage(i);
            while(!done) @(negedge clk);
            repeat(2) @(negedge clk);
            if(stage_done_count-restart_stages!=STAGES) $fatal(1,"pointwise restart omitted a stage");
            for(i=0;i<STAGES;i++)
                if(observed_outputs[i]-restart_outputs[i]!=expected_stage_results(i))
                    $fatal(1,"pointwise restart output count mismatch");
            $display("C1_POINTWISE_PARTIAL_RESTART_PASS stages=22 reset=0");
        end

        if(ELIDE_VIEWS || FUSE_FINAL) begin
            for(integer view_fault=0;view_fault<3;view_fault++) begin
                integer accepted_before,view_target;
                view_target=FUSE_FINAL?21:((view_fault==0)?14:17);
                pulse_job_start();
                for(i=0;i<STAGES;i++)send_descriptor(i,descriptors[i]);
                for(i=0;i<view_target;i++)run_stage(i);
                accepted_before=view_commit_count;
                if(view_fault<2) begin
                    while(stage_index!=view_target || !stage_active)@(negedge clk);
                    view_commit_stage=(view_fault==0)?(FUSE_FINAL?20:15):view_target;
                    view_commit_generation=config_generation+((view_fault==1)?1:0);
                    view_commit_valid=1;
                    while(!view_commit_ready)@(negedge clk);
                    @(negedge clk);view_commit_valid=0;
                    while(!error)@(negedge clk);
                    if(error_code!=8'h07 || stage_index!=view_target || stage_done || out_valid || done)
                        $fatal(1,"bad view identity advanced layer or escaped protocol rejection");
                    injected_fault_count++;
                    $display("C1_ENGINE_VIEW_REJECT_PASS field=%0d code=07 stage=%0d",view_fault,view_target);
                end else begin
                    view_commit_stage=view_target;view_commit_generation=config_generation;view_commit_valid=1;
                    if(view_commit_ready)$fatal(1,"view cancellation was not offered during preparation");
                    @(negedge clk);
                    if(view_commit_count!=accepted_before)$fatal(1,"view cancellation unexpectedly committed");
                end
                abort=1;
                @(negedge clk);view_commit_valid=0;abort=0;abort_count++;
                @(negedge clk);
                if(!job_start_ready || busy || error || out_valid)$fatal(1,"view lifecycle did not quiesce");
                if(view_fault==2) begin
                    if(FUSE_FINAL)$display("C1_ENGINE_FINAL_CANCEL_PASS stage=21 accepted=0 reset=0");
                    else $display("C1_ENGINE_VIEW_CANCEL_PASS accepted=0 prior_view_stage=14 canceled_stage=17 reset=0");
                end
            end
            restart_stages=stage_done_count;
            for(i=0;i<STAGES;i++)restart_outputs[i]=observed_outputs[i];
            pulse_job_start();
            for(i=0;i<STAGES;i++)send_descriptor(i,descriptors[i]);
            for(i=0;i<STAGES;i++)run_stage(i);
            while(!done)@(negedge clk);
            repeat(2)@(negedge clk);
            if(stage_done_count-restart_stages!=STAGES)$fatal(1,"view restart omitted logical layer completion");
            for(i=0;i<STAGES;i++)
                if(observed_outputs[i]-restart_outputs[i]!=expected_stage_results(i))$fatal(1,"view restart physical result mismatch");
            $display("C1_ENGINE_VIEW_RESTART_PASS logical_stages=22 data_stages=%0d reset=0",22-(ELIDE_VIEWS?2:0)-(FUSE_FINAL?1:0));
        end

        // Abort while the first stage is loading parameters, then restart.
        pulse_job_start();
        for (i = 0; i < STAGES; i = i + 1)
            send_descriptor(i, descriptors[i]);
        repeat (5) @(negedge clk);
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        abort_count = abort_count + 1;
        @(negedge clk);
        if (!job_start_ready || error)
            $fatal(1, "engine did not recover from parameter-load abort");

        // Abort after the linear ABI weights have entered the sequential
        // lane-bank repack phase.  This specifically covers the new local
        // prefetch/repack machinery rather than only the parameter reader.
        pulse_job_start();
        for (i = 0; i < STAGES; i = i + 1)
            send_descriptor(i, descriptors[i]);
        while (dut.u_engine.repack_linear_index_q < 16)
            @(negedge clk);
        if (!stage_active || in_ready)
            $fatal(1, "unexpected interface state during weight repack");
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        abort_count = abort_count + 1;
        @(negedge clk);
        if (!job_start_ready || busy || error || out_valid || param_rd_en)
            $fatal(1, "engine did not quiesce after weight-repack abort");

        // Live parameter generation is part of the atomic job snapshot.
        pulse_job_start();
        parameter_generation = 32'd10;
        while (!error)
            @(negedge clk);
        if (error_code != 8'he3)
            $fatal(1, "wrong parameter-generation fault code %0h", error_code);
        injected_fault_count = injected_fault_count + 1;
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        parameter_generation = 32'd9;
        abort_count = abort_count + 1;

        // A descriptor may be ABI-legal but not the frozen MicroStyle graph.
        pulse_job_start();
        bad_descriptor = descriptors[0];
        bad_descriptor[111:96] = 16'd4;
        send_descriptor(0, bad_descriptor);
        for (i = 1; i < STAGES; i = i + 1)
            send_descriptor(i, descriptors[i]);
        while (!error)
            @(negedge clk);
        if (error_code != 8'h02)
            $fatal(1, "wrong topology fault code %0h", error_code);
        injected_fault_count = injected_fault_count + 1;
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        abort_count = abort_count + 1;

        // Input C8 groups must be strictly ordered for every output site.
        pulse_job_start();
        for (i = 0; i < STAGES; i = i + 1)
            send_descriptor(i, descriptors[i]);
        while (!stage_active)
            @(negedge clk);
        send_input_group(0, 0, 0, 0, 1'b1);
        while (!error)
            @(negedge clk);
        if (error_code != 8'h07)
            $fatal(1, "wrong input-protocol fault code %0h", error_code);
        injected_fault_count = injected_fault_count + 1;
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        abort_count = abort_count + 1;

        // Dispatcher-facing capture must be strictly ordered 0..21.
        pulse_job_start();
        send_descriptor(1, descriptors[0]);
        while (!error)
            @(negedge clk);
        if (error_code != 8'he1)
            $fatal(1, "wrong config-order fault code %0h", error_code);
        injected_fault_count = injected_fault_count + 1;
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        abort_count = abort_count + 1;

        // A parameter-bank read fault tears down the active layer snapshot.
        pulse_job_start();
        for (i = 0; i < STAGES; i = i + 1)
            send_descriptor(i, descriptors[i]);
        inject_param_error_once = 1'b1;
        while (!error)
            @(negedge clk);
        if (error_code != 8'h57)
            $fatal(1, "wrong parameter-read fault code %0h", error_code);
        injected_fault_count = injected_fault_count + 1;
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        abort_count = abort_count + 1;

        // Exported u6 shifts are checked after the affine cache is filled.
        parameter_bytes[descriptors[0][351:320]] = 8'd48;
        pulse_job_start();
        for (i = 0; i < STAGES; i = i + 1)
            send_descriptor(i, descriptors[i]);
        while (!error)
            @(negedge clk);
        if (error_code != 8'h06)
            $fatal(1, "wrong affine-format fault code %0h", error_code);
        parameter_bytes[descriptors[0][351:320]] = 8'd0;
        injected_fault_count = injected_fault_count + 1;
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        abort_count = abort_count + 1;

        repeat (5) @(negedge clk);
        $display("C1_R1_MICROSTYLE_ENGINE_PASS stages=%0d outputs=%0d mac=%0d dw=%0d bypass=%0d param_reads=%0d stalls=%0d aborts=%0d faults=%0d cache_dw=%0d mac_overlap=%0d first_run_cycles=%0d",
                 stage_done_count, output_count, mac_output_count,
                 dw_output_count, bypass_output_count,
                 parameter_read_count, output_stall_count,
                 abort_count, injected_fault_count,
                 CACHE_DW_WEIGHT_TILES, MAC_PREFETCH_OVERLAP,
                 first_run_cycles);
        $finish;
    end

    initial begin
        repeat (1500000) @(posedge clk);
        $fatal(1, "MicroStyle engine test timeout");
    end

endmodule
