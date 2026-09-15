`timescale 1ns/1ps

// Reuses the complete legacy adapter testbench, overriding only the DUT's
// optional cache-sideband parameter and its newly connected ready input.  This
// keeps the old test sequence/scoreboards unchanged while adding checks for the
// extra stage handshake and per-request metadata.
module tb_c1_r1_microstyle_tensor_adapter_cache_sideband;
    localparam integer BANK_BYTES = 1024;
    localparam logic [31:0] BASE_ADDR = 32'h0000_1000;

    tb_c1_r1_microstyle_tensor_adapter base();
    defparam base.dut.ENABLE_WINDOW_CACHE_SIDEBAND = 1;

    integer stage_wait_cycles = 0;
    integer stage_config_count = 0;
    integer stage_stall_count = 0;
    integer cacheable_read_count = 0;
    integer bypass_read_count = 0;
    integer signed raw_x;
    integer signed raw_y;
    integer signed expected_raw_x;
    integer signed expected_raw_y;
    integer clamped_x;
    integer clamped_y;
    integer groups;
    integer expected_addr;
    logic stage_hold_q = 1'b0;
    logic [68:0] stage_payload_q = 69'd0;

    // Each stage config is deliberately stalled for two complete cycles.  The
    // hierarchical force only drives the otherwise standalone TB signal added
    // for this optional port; all pre-existing stimulus remains owned by base.
    always @(negedge base.clk) begin
        if (base.rst || !base.cache_stage_start_valid) begin
            stage_wait_cycles = 0;
            force base.cache_stage_start_ready = 1'b0;
        end else if (stage_wait_cycles < 2) begin
            stage_wait_cycles = stage_wait_cycles + 1;
            force base.cache_stage_start_ready = 1'b0;
        end else begin
            force base.cache_stage_start_ready = 1'b1;
        end
    end

    always @(posedge base.clk) begin
        if (!base.rst) begin
            if (stage_hold_q) begin
                if (!base.cache_stage_start_valid)
                    $fatal(1, "cache stage valid withdrew while stalled");
                if ({base.cache_stage_enable,
                     base.cache_stage_base_addr,
                     base.cache_stage_width,
                     base.cache_stage_height,
                     base.cache_stage_groups} != stage_payload_q)
                    $fatal(1, "cache stage payload changed while stalled");
            end
            stage_hold_q = base.cache_stage_start_valid &&
                           !base.cache_stage_start_ready;
            stage_payload_q = {
                base.cache_stage_enable,
                base.cache_stage_base_addr,
                base.cache_stage_width,
                base.cache_stage_height,
                base.cache_stage_groups};
            if (stage_hold_q)
                stage_stall_count = stage_stall_count + 1;

            if (base.cache_stage_start_valid &&
                base.cache_stage_start_ready) begin
                if (base.active_stage_index != stage_config_count[4:0])
                    $fatal(1, "cache stage order mismatch got=%0d expected=%0d",
                           base.active_stage_index, stage_config_count);
                if (base.cache_stage_enable !=
                    ((base.active_stage_opcode == 8'd1) ||
                     (base.active_stage_opcode == 8'd3)))
                    $fatal(1, "cache stage enable/opcode mismatch");
                if (base.cache_stage_base_addr !=
                    BASE_ADDR + base.active_input_bank * BANK_BYTES)
                    $fatal(1, "cache stage input-bank base mismatch");
                if ((base.cache_stage_width != base.dut.input_width_q) ||
                    (base.cache_stage_height != base.dut.input_height_q) ||
                    (base.cache_stage_groups != base.dut.input_groups_q))
                    $fatal(1, "cache stage geometry mismatch");

                stage_config_count = stage_config_count + 1;
                if (base.active_stage_index == 5'd21) begin
                    if ((stage_config_count != 22) ||
                        (stage_stall_count < 44) ||
                        (cacheable_read_count != 1512) ||
                        (bypass_read_count != 266))
                        $fatal(1, "cache sideband coverage incomplete");
                    $display("C1_R1_MICROSTYLE_TENSOR_ADAPTER_CACHE_SIDEBAND_PASS configs=%0d config_stalls=%0d cacheable_reads=%0d bypass_reads=%0d",
                             stage_config_count, stage_stall_count,
                             cacheable_read_count, bypass_read_count);
                end
            end

            if (base.mem_req_valid && base.mem_req_ready) begin
                if (base.mem_req_cacheable) begin
                    if (base.mem_req_write ||
                        !((base.active_stage_opcode == 8'd1) ||
                          (base.active_stage_opcode == 8'd3)))
                        $fatal(1, "illegal cacheable request classification");

                    raw_x = $signed(base.mem_req_cache_x);
                    raw_y = $signed(base.mem_req_cache_y);
                    expected_raw_x = base.dut.output_x_q;
                    expected_raw_x =
                        (expected_raw_x * base.dut.stride_x_q) +
                        (base.dut.tap_q % 3) - 1;
                    expected_raw_y = base.dut.output_y_q;
                    expected_raw_y =
                        (expected_raw_y * base.dut.stride_y_q) +
                        (base.dut.tap_q / 3) - 1;
                    if ((raw_x != expected_raw_x) ||
                        (raw_y != expected_raw_y))
                        $fatal(1, "unclamped cache tap coordinate mismatch");
                    if (base.mem_req_cache_group != base.dut.input_group_q)
                        $fatal(1, "cache tap group mismatch");

                    if (raw_x < 0)
                        clamped_x = 0;
                    else if (raw_x >= base.dut.input_width_q)
                        clamped_x = base.dut.input_width_q - 1;
                    else
                        clamped_x = raw_x;
                    if (raw_y < 0)
                        clamped_y = 0;
                    else if (raw_y >= base.dut.input_height_q)
                        clamped_y = base.dut.input_height_q - 1;
                    else
                        clamped_y = raw_y;
                    groups = base.dut.input_groups_q;
                    expected_addr = BASE_ADDR +
                                    base.active_input_bank * BANK_BYTES +
                                    (((clamped_y * base.dut.input_width_q +
                                       clamped_x) * groups +
                                      base.mem_req_cache_group) * 8);
                    if (base.mem_req_addr != expected_addr[31:0])
                        $fatal(1, "cache sideband/address mismatch");
                    cacheable_read_count = cacheable_read_count + 1;
                end else if (!base.mem_req_write) begin
                    bypass_read_count = bypass_read_count + 1;
                end
            end
        end
    end
endmodule
