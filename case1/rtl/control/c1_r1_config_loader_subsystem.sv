`timescale 1ns/1ps

// Board-independent R1 descriptor preloader:
//
//   AXI128 descriptor reader/scheduler -> semantic decoder -> double bank
//
// The existing scheduler permits exactly one layer command outstanding.  Its
// command index is captured when the decoder accepts the matching descriptor.
// A decoder output is acknowledged only when the stage bank really accepts
// it.  One cycle later this bridge reports layer_done to the scheduler, after
// checking the bank's registered error/commit result.  Therefore the final
// descriptor commits the shadow bank before the scheduler emits done_pulse.
//
// descriptor_base/count are snapshotted on an accepted idle start.  Invalid
// descriptors, AXI errors, bank protocol errors, and abort all leave the active
// bank untouched; partial shadow state is explicitly discarded.  The opaque
// descriptor is decoded exactly once by c1_layer_command_decoder.
//
// command_accept_enable is a normal flow-control gate between decoder and
// bank.  Tie it high when no arbitration/pause is required.  Deasserting it
// holds decoder valid/payload and exercises no side effect in the bank.
module c1_r1_config_loader_subsystem #(
    parameter integer MAX_STAGES = 22,
    parameter integer COUNT_BITS = 16,
    parameter integer GENERATION_BITS = 8,
    parameter bit     SYNC_READ = 1'b1,
    parameter bit     FAST_WIDE = 1'b0,
    // Loading at most MAX_STAGES descriptors is startup work.  Spend two
    // clocks per descriptor to isolate the wide semantic validation tree from
    // the scheduler replay boundary and the decoder's 512-bit payload CE.
    parameter integer PIPELINED_VALIDATION = 1
) (
    input  logic                         clk,
    input  logic                         rst,

    input  logic                         start_pulse,
    input  logic                         abort_pulse,
    input  logic [COUNT_BITS-1:0]        descriptor_count,
    input  logic [31:0]                  descriptor_base,
    input  logic                         command_accept_enable,

    output logic                         busy,
    output logic                         done_pulse,
    output logic                         error_pulse,
    output logic                         aborted_pulse,
    output logic                         config_loading,
    output logic                         config_commit_pulse,
    output logic                         active_bank,
    output logic [COUNT_BITS-1:0]        active_count,
    output logic [GENERATION_BITS-1:0]   generation,

    input  logic                         engine_read_enable,
    input  logic [COUNT_BITS-1:0]        engine_read_index,
    output logic                         engine_read_ready,
    output logic                         engine_read_busy,
    output logic                         engine_read_valid,
    output logic [511:0]                 engine_read_descriptor,
    output logic [GENERATION_BITS-1:0]   engine_read_generation,

    output logic [31:0]                  m_axi_araddr,
    output logic [7:0]                   m_axi_arlen,
    output logic [2:0]                   m_axi_arsize,
    output logic [1:0]                   m_axi_arburst,
    output logic                         m_axi_arvalid,
    input  logic                         m_axi_arready,

    input  logic [127:0]                 m_axi_rdata,
    input  logic [1:0]                   m_axi_rresp,
    input  logic                         m_axi_rlast,
    input  logic                         m_axi_rvalid,
    output logic                         m_axi_rready
);

    logic [COUNT_BITS-1:0] job_count_q;
    logic [31:0] job_base_q;

    logic scheduler_layer_valid;
    logic scheduler_layer_ready;
    logic [COUNT_BITS-1:0] scheduler_layer_index;
    logic [511:0] scheduler_layer_descriptor;
    logic scheduler_layer_done;
    logic scheduler_layer_error;
    logic scheduler_busy;
    logic scheduler_done;
    logic scheduler_error;
    logic scheduler_aborted;
    logic [COUNT_BITS-1:0] scheduler_active_index;

    logic decoder_descriptor_ready;
    logic decoder_command_valid;
    logic decoder_command_ready;
    logic [511:0] decoder_command_descriptor;
    logic decoder_error_pulse;
    logic [4:0] decoder_error_code;
    logic [COUNT_BITS-1:0] decoder_index_q;

    logic bank_command_valid;
    logic bank_command_ready;
    logic bank_loading;
    logic [COUNT_BITS-1:0] bank_shadow_count;
    logic bank_load_complete;
    logic bank_error_pulse;
    logic [2:0] bank_error_code;
    logic bank_load_abort;
    logic bank_command_fire;

    logic bank_result_pending_q;
    logic bank_result_final_q;
    logic bank_result_error;
    logic pipeline_abort;
    logic scheduler_to_decoder_fire;

    always_comb begin
        busy = scheduler_busy;
        done_pulse = scheduler_done;
        error_pulse = scheduler_error;
        aborted_pulse = scheduler_aborted;
        config_loading = bank_loading;
        config_commit_pulse = bank_load_complete;

        scheduler_layer_ready = decoder_descriptor_ready;
        scheduler_to_decoder_fire = scheduler_layer_valid &&
                                    scheduler_layer_ready;

        pipeline_abort = abort_pulse || scheduler_error;
        bank_load_abort = pipeline_abort || decoder_error_pulse;

        // Gate valid and ready together: when paused, neither endpoint may
        // infer a transfer and the decoder's elastic output remains stable.
        bank_command_valid = decoder_command_valid &&
                             command_accept_enable &&
                             !bank_result_pending_q && !bank_load_abort;
        decoder_command_ready = bank_command_ready &&
                                command_accept_enable &&
                                !bank_result_pending_q && !bank_load_abort;
        bank_command_fire = bank_command_valid && bank_command_ready;

        // The bank reports its decision in registered pulses one cycle after
        // command_fire.  Commit must occur exactly for the final descriptor.
        bank_result_error = bank_result_pending_q &&
                            (bank_error_pulse ||
                             (bank_load_complete != bank_result_final_q));
        scheduler_layer_error = decoder_error_pulse || bank_result_error;
        scheduler_layer_done = bank_result_pending_q && !bank_result_error;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            job_count_q <= '0;
            job_base_q <= 32'd0;
            decoder_index_q <= '0;
            bank_result_pending_q <= 1'b0;
            bank_result_final_q <= 1'b0;
        end else begin
            if (start_pulse && !scheduler_busy && !abort_pulse) begin
                job_count_q <= descriptor_count;
                job_base_q <= descriptor_base;
            end

            if (scheduler_to_decoder_fire)
                decoder_index_q <= scheduler_layer_index;

            if (bank_result_pending_q)
                bank_result_pending_q <= 1'b0;

            if (bank_command_fire) begin
                bank_result_pending_q <= 1'b1;
                bank_result_final_q <=
                    (decoder_index_q == (job_count_q - 1'b1));
            end

            if (pipeline_abort || decoder_error_pulse) begin
                decoder_index_q <= '0;
                bank_result_pending_q <= 1'b0;
                bank_result_final_q <= 1'b0;
            end
        end
    end

    c1_descriptor_scheduler_subsystem #(
        .COUNT_BITS(COUNT_BITS)
    ) u_descriptor_scheduler (
        .clk(clk),
        .rst(rst),
        .start_pulse(start_pulse && !abort_pulse),
        .abort_pulse(abort_pulse),
        .descriptor_count(descriptor_count),
        .descriptor_base(job_base_q),
        .layer_command_valid(scheduler_layer_valid),
        .layer_command_ready(scheduler_layer_ready),
        .layer_command_index(scheduler_layer_index),
        .layer_command_descriptor(scheduler_layer_descriptor),
        .layer_done_pulse(scheduler_layer_done),
        .layer_error_pulse(scheduler_layer_error),
        .busy(scheduler_busy),
        .done_pulse(scheduler_done),
        .error_pulse(scheduler_error),
        .aborted_pulse(scheduler_aborted),
        .active_layer_index(scheduler_active_index),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    c1_layer_command_decoder #(
        .PIPELINED_VALIDATION(PIPELINED_VALIDATION)
    ) u_decoder (
        .clk(clk),
        .rst(rst),
        .abort(pipeline_abort),
        .descriptor_valid(scheduler_layer_valid),
        .descriptor_ready(decoder_descriptor_ready),
        .descriptor_data(scheduler_layer_descriptor),
        .descriptor_error_override(5'd0),
        .command_valid(decoder_command_valid),
        .command_ready(decoder_command_ready),
        .command_descriptor(decoder_command_descriptor),
        .command_opcode(),
        .command_activation(),
        .command_flags(),
        .command_version(),
        .command_words(),
        .command_input_width(),
        .command_input_height(),
        .command_output_width(),
        .command_output_height(),
        .command_input_channels(),
        .command_output_channels(),
        .command_input_offset(),
        .command_output_offset(),
        .command_residual_offset(),
        .command_weight_offset(),
        .command_bias_offset(),
        .command_multiplier_offset(),
        .command_shift_offset(),
        .command_input_row_stride(),
        .command_output_row_stride(),
        .command_kernel_width(),
        .command_kernel_height(),
        .command_stride_x(),
        .command_stride_y(),
        .command_channel_block(),
        .command_mac_lanes(),
        .command_tile_width(),
        .command_tile_height(),
        .command_cycle_budget(),
        .error_pulse(decoder_error_pulse),
        .error_code(decoder_error_code)
    );

    c1_r1_stage_config_bank #(
        .MAX_STAGES(MAX_STAGES),
        .INDEX_BITS(COUNT_BITS),
        .GENERATION_BITS(GENERATION_BITS),
        .SYNC_READ(SYNC_READ),
        .FAST_WIDE(FAST_WIDE)
    ) u_stage_bank (
        .clk(clk),
        .rst(rst),
        .load_abort(bank_load_abort),
        .load_count(job_count_q),
        .layer_command_valid(bank_command_valid),
        .layer_command_ready(bank_command_ready),
        .layer_command_index(decoder_index_q),
        .layer_command_descriptor(decoder_command_descriptor),
        .loading(bank_loading),
        .shadow_count(bank_shadow_count),
        .load_complete_pulse(bank_load_complete),
        .error_pulse(bank_error_pulse),
        .error_code(bank_error_code),
        .active_bank(active_bank),
        .active_count(active_count),
        .generation(generation),
        .engine_read_enable(engine_read_enable),
        .engine_read_index(engine_read_index),
        .engine_read_ready(engine_read_ready),
        .engine_read_busy(engine_read_busy),
        .engine_read_valid(engine_read_valid),
        .engine_read_descriptor(engine_read_descriptor),
        .engine_read_generation(engine_read_generation)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (scheduler_layer_done && scheduler_layer_error)
                $fatal(1, "config loader generated layer done and error together");
            if (bank_command_fire && bank_result_pending_q)
                $fatal(1, "config loader accepted a command with result pending");
            if (bank_load_complete && bank_error_pulse)
                $fatal(1, "stage bank committed and errored together");
        end
    end
`endif

endmodule
