`timescale 1ns/1ps

// Vendor-independent, double-buffered R1 stage-descriptor store.
//
// A transaction starts with index zero and must continue 0..load_count-1.
// The active bank changes only after the complete final descriptor has been
// stored.  Abort or any order/count/range error discards shadow state without
// modifying active_count, generation, or the active bank.
//
// Descriptors remain opaque; semantic decoding belongs upstream.
//
// Storage/read modes:
//   SYNC_READ=1, FAST_WIDE=0 (default): two explicit 32-bit SDP RAMs, each
//     MAX_STAGES*16 words deep.  A descriptor is serialized into 16 writes
//     before layer_command_ready acknowledges it.  Engine reads accept only
//     when engine_read_ready and assemble 16 synchronous words before pulsing
//     engine_read_valid.  This mode avoids severe block-RAM width fragmentation.
//   SYNC_READ=1, FAST_WIDE=1: two explicit 512-bit SDP RAMs with one-cycle
//     pipelined reads.  This is faster but may consume many physical RAM blocks.
//   SYNC_READ=0: combinational arrays for small instances or simulation.
//
// No RAM contents are reset.  In narrow mode, at most one 512-bit holding
// register is used while the shadow descriptor is serialized.
module c1_r1_stage_config_bank #(
    parameter integer MAX_STAGES = 22,
    parameter integer INDEX_BITS = 16,
    parameter integer GENERATION_BITS = 8,
    parameter bit     SYNC_READ = 1'b1,
    parameter bit     FAST_WIDE = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst,

    input  logic                         load_abort,
    input  logic [INDEX_BITS-1:0]        load_count,
    input  logic                         layer_command_valid,
    output logic                         layer_command_ready,
    input  logic [INDEX_BITS-1:0]        layer_command_index,
    input  logic [511:0]                 layer_command_descriptor,

    output logic                         loading,
    output logic [INDEX_BITS-1:0]        shadow_count,
    output logic                         load_complete_pulse,
    output logic                         error_pulse,
    output logic [2:0]                   error_code,

    output logic                         active_bank,
    output logic [INDEX_BITS-1:0]        active_count,
    output logic [GENERATION_BITS-1:0]   generation,

    input  logic                         engine_read_enable,
    input  logic [INDEX_BITS-1:0]        engine_read_index,
    output logic                         engine_read_ready,
    output logic                         engine_read_busy,
    output logic                         engine_read_valid,
    output logic [511:0]                 engine_read_descriptor,
    output logic [GENERATION_BITS-1:0]   engine_read_generation
);

    localparam logic [2:0] ERROR_NONE = 3'd0;
    localparam logic [2:0] ERROR_START_INDEX = 3'd1;
    localparam logic [2:0] ERROR_ORDER = 3'd2;
    localparam logic [2:0] ERROR_INDEX_RANGE = 3'd3;
    localparam logic [2:0] ERROR_COUNT_ZERO = 3'd4;
    localparam logic [2:0] ERROR_COUNT_RANGE = 3'd5;
    localparam logic [2:0] ERROR_COUNT_CHANGED = 3'd6;

    localparam integer WIDE_ADDR_BITS =
        (MAX_STAGES <= 1) ? 1 : $clog2(MAX_STAGES);
    localparam integer NARROW_DEPTH = MAX_STAGES * 16;
    localparam integer NARROW_ADDR_BITS =
        (NARROW_DEPTH <= 1) ? 1 : $clog2(NARROW_DEPTH);

    logic [INDEX_BITS-1:0] expected_index_q;
    logic [INDEX_BITS-1:0] load_count_q;
    logic input_protocol_valid;
    logic [2:0] input_error_code;
    logic command_fire;
    logic storage_write_fire;
    logic engine_index_in_range;

    // Only the default narrow mode uses these controls.  They are declared at
    // module scope so the mode-specific ready equation remains explicit.
    logic narrow_write_active_q;
    logic narrow_write_prepared_q;
    logic narrow_read_busy_q;

    always_comb begin
        input_protocol_valid = 1'b0;
        input_error_code = ERROR_NONE;
        if (!loading) begin
            if (layer_command_index != {INDEX_BITS{1'b0}})
                input_error_code = ERROR_START_INDEX;
            else if (load_count == {INDEX_BITS{1'b0}})
                input_error_code = ERROR_COUNT_ZERO;
            else if ($unsigned(load_count) > MAX_STAGES)
                input_error_code = ERROR_COUNT_RANGE;
            else
                input_protocol_valid = 1'b1;
        end else begin
            if (load_count != load_count_q)
                input_error_code = ERROR_COUNT_CHANGED;
            else if ($unsigned(layer_command_index) >= MAX_STAGES)
                input_error_code = ERROR_INDEX_RANGE;
            else if (layer_command_index != expected_index_q)
                input_error_code = ERROR_ORDER;
            else
                input_protocol_valid = 1'b1;
        end

        command_fire = layer_command_valid && layer_command_ready;
        storage_write_fire = command_fire && input_protocol_valid;
        engine_index_in_range = (engine_read_index < active_count) &&
                                ($unsigned(engine_read_index) < MAX_STAGES);
    end

    generate
        if (!SYNC_READ) begin : g_combinational_small_array
            logic [511:0] bank0_memory [0:MAX_STAGES-1];
            logic [511:0] bank1_memory [0:MAX_STAGES-1];

            always_comb begin
                layer_command_ready = !rst && !load_abort;
                engine_read_ready = !rst;
                engine_read_busy = 1'b0;
                engine_read_valid = engine_read_enable &&
                                    engine_index_in_range;
                engine_read_descriptor = '0;
                engine_read_generation = generation;
                if (engine_read_enable && engine_index_in_range) begin
                    if (active_bank)
                        engine_read_descriptor =
                            bank1_memory[engine_read_index[WIDE_ADDR_BITS-1:0]];
                    else
                        engine_read_descriptor =
                            bank0_memory[engine_read_index[WIDE_ADDR_BITS-1:0]];
                end
            end

            always_ff @(posedge clk) begin
                if (storage_write_fire) begin
                    if (active_bank)
                        bank0_memory[layer_command_index[WIDE_ADDR_BITS-1:0]] <=
                            layer_command_descriptor;
                    else
                        bank1_memory[layer_command_index[WIDE_ADDR_BITS-1:0]] <=
                            layer_command_descriptor;
                end
            end

            always_comb begin
                narrow_write_active_q = 1'b0;
                narrow_write_prepared_q = 1'b0;
                narrow_read_busy_q = 1'b0;
            end

        end else if (FAST_WIDE) begin : g_synchronous_fast_wide
            logic [511:0] bank0_read_data;
            logic [511:0] bank1_read_data;
            logic read_valid_q;
            logic read_bank_q;
            logic [GENERATION_BITS-1:0] read_generation_q;
            logic [WIDE_ADDR_BITS-1:0] read_address;
            logic [WIDE_ADDR_BITS-1:0] write_address;

            always_comb begin
                layer_command_ready = !rst && !load_abort;
                engine_read_ready = !rst;
                engine_read_busy = 1'b0;
                read_address = engine_read_index[WIDE_ADDR_BITS-1:0];
                write_address =
                    layer_command_index[WIDE_ADDR_BITS-1:0];
                engine_read_valid = read_valid_q;
                engine_read_descriptor = '0;
                engine_read_generation = read_generation_q;
                if (read_valid_q) begin
                    if (read_bank_q)
                        engine_read_descriptor = bank1_read_data;
                    else
                        engine_read_descriptor = bank0_read_data;
                end
            end

            c1_ram_sdp_read_first #(
                .DATA_WIDTH(512), .DEPTH(MAX_STAGES),
                .ADDR_WIDTH(WIDE_ADDR_BITS)
            ) u_bank0_ram (
                .clk(clk),
                .rd_en(engine_read_enable && engine_index_in_range),
                .rd_addr(read_address), .rd_data(bank0_read_data),
                .wr_en(storage_write_fire && active_bank),
                .wr_addr(write_address),
                .wr_data(layer_command_descriptor)
            );

            c1_ram_sdp_read_first #(
                .DATA_WIDTH(512), .DEPTH(MAX_STAGES),
                .ADDR_WIDTH(WIDE_ADDR_BITS)
            ) u_bank1_ram (
                .clk(clk),
                .rd_en(engine_read_enable && engine_index_in_range),
                .rd_addr(read_address), .rd_data(bank1_read_data),
                .wr_en(storage_write_fire && !active_bank),
                .wr_addr(write_address),
                .wr_data(layer_command_descriptor)
            );

            always_ff @(posedge clk) begin
                if (rst) begin
                    read_valid_q <= 1'b0;
                    read_bank_q <= 1'b0;
                    read_generation_q <= '0;
                end else begin
                    read_valid_q <= engine_read_enable &&
                                    engine_index_in_range;
                    read_bank_q <= active_bank;
                    read_generation_q <= generation;
                end
            end

            always_comb begin
                narrow_write_active_q = 1'b0;
                narrow_write_prepared_q = 1'b0;
                narrow_read_busy_q = 1'b0;
            end

        end else begin : g_synchronous_narrow
            logic [31:0] bank0_read_word;
            logic [31:0] bank1_read_word;
            logic [511:0] write_descriptor_q;
            logic [INDEX_BITS-1:0] write_index_q;
            logic write_bank_q;
            logic [3:0] write_word_q;
            logic narrow_ram_write_enable;
            logic [NARROW_ADDR_BITS-1:0] narrow_ram_write_address;
            logic [31:0] narrow_ram_write_data;

            logic [NARROW_ADDR_BITS-1:0] read_base_address_q;
            logic [4:0] read_issue_word_q;
            logic read_capture_pending_q;
            logic [3:0] read_capture_word_q;
            logic read_bank_q;
            logic [GENERATION_BITS-1:0] read_generation_q;
            logic [511:0] read_assembly_q;
            logic read_request_fire;
            logic narrow_ram_read_enable;
            logic [NARROW_ADDR_BITS-1:0] narrow_ram_read_address;
            logic [31:0] selected_read_word;

            always_comb begin
                // Invalid commands are acknowledged immediately so the common
                // state machine can report their error.  Valid descriptors are
                // acknowledged only after all sixteen shadow words are stored.
                layer_command_ready = !rst && !load_abort &&
                    (!layer_command_valid || !input_protocol_valid ||
                     narrow_write_prepared_q);

                narrow_ram_write_enable = narrow_write_active_q;
                narrow_ram_write_address =
                    (write_index_q * 16) + write_word_q;
                narrow_ram_write_data =
                    write_descriptor_q[write_word_q*32 +: 32];

                engine_read_ready = !rst && !narrow_read_busy_q;
                engine_read_busy = narrow_read_busy_q;
                read_request_fire = engine_read_enable &&
                                    engine_read_ready &&
                                    engine_index_in_range;
                narrow_ram_read_enable = read_request_fire ||
                    (narrow_read_busy_q && (read_issue_word_q < 16));
                if (read_request_fire)
                    narrow_ram_read_address = engine_read_index * 16;
                else
                    narrow_ram_read_address =
                        read_base_address_q + read_issue_word_q;
                if (read_bank_q)
                    selected_read_word = bank1_read_word;
                else
                    selected_read_word = bank0_read_word;
            end

            c1_ram_sdp_read_first #(
                .DATA_WIDTH(32), .DEPTH(NARROW_DEPTH),
                .ADDR_WIDTH(NARROW_ADDR_BITS)
            ) u_bank0_ram (
                .clk(clk),
                .rd_en(narrow_ram_read_enable),
                .rd_addr(narrow_ram_read_address),
                .rd_data(bank0_read_word),
                .wr_en(narrow_ram_write_enable && !write_bank_q),
                .wr_addr(narrow_ram_write_address),
                .wr_data(narrow_ram_write_data)
            );

            c1_ram_sdp_read_first #(
                .DATA_WIDTH(32), .DEPTH(NARROW_DEPTH),
                .ADDR_WIDTH(NARROW_ADDR_BITS)
            ) u_bank1_ram (
                .clk(clk),
                .rd_en(narrow_ram_read_enable),
                .rd_addr(narrow_ram_read_address),
                .rd_data(bank1_read_word),
                .wr_en(narrow_ram_write_enable && write_bank_q),
                .wr_addr(narrow_ram_write_address),
                .wr_data(narrow_ram_write_data)
            );

            // Shadow descriptor serializer.  write_bank_q is the destination
            // bank number (the inverse of active_bank when capture begins).
            always_ff @(posedge clk) begin
                if (rst || load_abort) begin
                    narrow_write_active_q <= 1'b0;
                    narrow_write_prepared_q <= 1'b0;
                    write_descriptor_q <= '0;
                    write_index_q <= '0;
                    write_bank_q <= 1'b0;
                    write_word_q <= 4'd0;
                end else begin
                    if (!narrow_write_active_q &&
                        !narrow_write_prepared_q &&
                        !narrow_read_busy_q && layer_command_valid &&
                        input_protocol_valid) begin
                        write_descriptor_q <= layer_command_descriptor;
                        write_index_q <= layer_command_index;
                        write_bank_q <= ~active_bank;
                        write_word_q <= 4'd0;
                        narrow_write_active_q <= 1'b1;
                    end else if (narrow_write_active_q) begin
                        if (write_word_q == 4'd15) begin
                            narrow_write_active_q <= 1'b0;
                            narrow_write_prepared_q <= 1'b1;
                        end else begin
                            write_word_q <= write_word_q + 1'b1;
                        end
                    end

                    if (command_fire)
                        narrow_write_prepared_q <= 1'b0;
                end
            end

            // Sixteen-word engine read assembler.  Both banks are read in
            // parallel; read_bank_q selects the generation active at request.
            always_ff @(posedge clk) begin
                if (rst) begin
                    narrow_read_busy_q <= 1'b0;
                    read_base_address_q <= '0;
                    read_issue_word_q <= 5'd0;
                    read_capture_pending_q <= 1'b0;
                    read_capture_word_q <= 4'd0;
                    read_bank_q <= 1'b0;
                    read_generation_q <= '0;
                    read_assembly_q <= '0;
                    engine_read_valid <= 1'b0;
                    engine_read_descriptor <= '0;
                    engine_read_generation <= '0;
                end else begin
                    engine_read_valid <= 1'b0;
                    engine_read_descriptor <= '0;

                    if (read_request_fire) begin
                        narrow_read_busy_q <= 1'b1;
                        read_base_address_q <= engine_read_index * 16;
                        read_issue_word_q <= 5'd1;
                        read_capture_pending_q <= 1'b1;
                        read_capture_word_q <= 4'd0;
                        read_bank_q <= active_bank;
                        read_generation_q <= generation;
                        read_assembly_q <= '0;
                    end else if (read_capture_pending_q) begin
                        if (read_capture_word_q == 4'd15) begin
                            engine_read_descriptor <=
                                {selected_read_word, read_assembly_q[479:0]};
                            engine_read_generation <= read_generation_q;
                            engine_read_valid <= 1'b1;
                            narrow_read_busy_q <= 1'b0;
                            read_capture_pending_q <= 1'b0;
                        end else begin
                            read_assembly_q[read_capture_word_q*32 +: 32] <=
                                selected_read_word;
                            read_capture_word_q <=
                                read_issue_word_q[3:0];
                            if (read_issue_word_q < 16)
                                read_issue_word_q <=
                                    read_issue_word_q + 1'b1;
                        end
                    end
                end
            end
        end
    endgenerate

    // Transaction metadata changes only on a ready/valid command handshake.
    // In default narrow mode that handshake occurs after all sixteen RAM words
    // are safely written, preserving the original atomic commit contract.
    always_ff @(posedge clk) begin
        if (rst) begin
            loading <= 1'b0;
            shadow_count <= '0;
            expected_index_q <= '0;
            load_count_q <= '0;
            load_complete_pulse <= 1'b0;
            error_pulse <= 1'b0;
            error_code <= ERROR_NONE;
            active_bank <= 1'b0;
            active_count <= '0;
            generation <= '0;
        end else begin
            load_complete_pulse <= 1'b0;
            error_pulse <= 1'b0;
            error_code <= ERROR_NONE;

            if (load_abort) begin
                loading <= 1'b0;
                shadow_count <= '0;
                expected_index_q <= '0;
                load_count_q <= '0;
            end else if (command_fire) begin
                if (!input_protocol_valid) begin
                    loading <= 1'b0;
                    shadow_count <= '0;
                    expected_index_q <= '0;
                    load_count_q <= '0;
                    error_pulse <= 1'b1;
                    error_code <= input_error_code;
                end else if (!loading) begin
                    shadow_count <= {{(INDEX_BITS-1){1'b0}}, 1'b1};
                    load_count_q <= load_count;
                    if (load_count ==
                        {{(INDEX_BITS-1){1'b0}}, 1'b1}) begin
                        active_bank <= ~active_bank;
                        active_count <= load_count;
                        generation <= generation +
                            {{(GENERATION_BITS-1){1'b0}}, 1'b1};
                        loading <= 1'b0;
                        shadow_count <= '0;
                        expected_index_q <= '0;
                        load_count_q <= '0;
                        load_complete_pulse <= 1'b1;
                    end else begin
                        loading <= 1'b1;
                        expected_index_q <=
                            {{(INDEX_BITS-1){1'b0}}, 1'b1};
                    end
                end else begin
                    shadow_count <= shadow_count +
                        {{(INDEX_BITS-1){1'b0}}, 1'b1};
                    if (layer_command_index == (load_count_q -
                        {{(INDEX_BITS-1){1'b0}}, 1'b1})) begin
                        active_bank <= ~active_bank;
                        active_count <= load_count_q;
                        generation <= generation +
                            {{(GENERATION_BITS-1){1'b0}}, 1'b1};
                        loading <= 1'b0;
                        shadow_count <= '0;
                        expected_index_q <= '0;
                        load_count_q <= '0;
                        load_complete_pulse <= 1'b1;
                    end else begin
                        expected_index_q <= expected_index_q +
                            {{(INDEX_BITS-1){1'b0}}, 1'b1};
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (MAX_STAGES < 1)
            $fatal(1, "c1_r1_stage_config_bank MAX_STAGES must be >= 1");
        if (INDEX_BITS < $clog2(MAX_STAGES + 1))
            $fatal(1, "c1_r1_stage_config_bank INDEX_BITS cannot represent MAX_STAGES");
        if (GENERATION_BITS < 1)
            $fatal(1, "c1_r1_stage_config_bank GENERATION_BITS must be >= 1");
    end

    always_ff @(posedge clk) begin
        if (!rst) begin
            if (load_complete_pulse && error_pulse)
                $fatal(1, "stage bank completed and errored the same load");
            if (active_count > MAX_STAGES)
                $fatal(1, "stage bank active_count exceeded MAX_STAGES");
            if (shadow_count > MAX_STAGES)
                $fatal(1, "stage bank shadow_count exceeded MAX_STAGES");
        end
    end
`endif

endmodule
