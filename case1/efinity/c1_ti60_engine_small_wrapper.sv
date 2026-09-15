`timescale 1ns/1ps

// Boardless Efinity front-end probe.  This wrapper intentionally exposes only
// a clock/reset and ties off the engine protocol.  It is not a functional
// board wrapper; its purpose is to distinguish a dimension/array elaboration
// issue from a basic unsupported construct in c1_r1_microstyle_engine.
module c1_ti60_engine_small_wrapper #(
    parameter integer P_REQUIRED_STAGES = 1,
    parameter integer P_PARAM_ADDR_W = 6,
    parameter integer P_PARAM_ARENA_BYTES = 256,
    parameter integer P_MAX_CHANNELS = 8,
    parameter integer P_MAX_WEIGHT_BYTES = 144,
    parameter integer P_MAX_PACKED_WEIGHT_TILES = 4,
    parameter integer P_MAX_GROUPS_OVERRIDE = 0,
    parameter integer P_AFFINE_CACHE_DEPTH_OVERRIDE = 0,
    parameter integer P_PACKED_AFFINE_CACHE = 0
) (
    input  logic clk,
    input  logic rst,
    input  logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    logic [7:0] error_code;
    logic [4:0] stage_index;
    logic [7:0] stage_opcode;
    logic [63:0] out_data_s8;
    logic [2:0] out_group_index;
    logic [15:0] out_x, out_y;
    logic [4:0] stage_config_error;
    logic [511:0] stage_config_descriptor;
    logic [575:0] in_window_s8;
    logic [63:0] in_residual_s8;
    logic [5:0] param_rd_addr;
    logic [127:0] param_rd_data;
    logic [7:0] stage_config_generation;
    logic [31:0] parameter_generation;
    logic [15:0] job_stage_count;
    logic [7:0] config_generation;
    logic [2:0] in_group_index;
    logic [15:0] in_x, in_y;

    logic job_start_ready, stage_config_ready, busy, aborted, error;
    logic param_rd_en, in_ready, out_valid;
    logic out_group_last, out_sof, out_eol, out_eof;
    logic param_rd_valid, param_rd_error;
    logic stage_config_valid, job_start_valid, parameter_active_valid;
    logic in_valid, in_group_last, in_sof, in_eol, in_eof, out_ready;
    logic abort;
    logic stage_done;
    logic adapter_required, stage_active, overflow_seen;

    // The stimulus bus is intentionally an unconstrained top-level input. It
    // prevents synthesis from proving the reduced engine permanently idle,
    // while keeping the probe small enough for quick Efinity front-end tests.
    // This is not a functional testbench or a board wrapper.
    assign job_start_valid = stimulus[0];
    assign job_stage_count = stimulus[16:1];
    assign config_generation = stimulus[24:17];
    assign parameter_active_valid = stimulus[25];
    assign parameter_generation = {stimulus[63:32], stimulus[31:0]};
    assign stage_config_valid = stimulus[26];
    assign stage_config_descriptor = {16{stimulus[31:0]}};
    assign stage_config_error = stimulus[31:27];
    assign stage_config_generation = stimulus[39:32];
    assign param_rd_valid = stimulus[40];
    assign param_rd_error = stimulus[41];
    assign param_rd_data = {16{stimulus[7:0]}};
    assign in_valid = stimulus[42];
    assign in_window_s8 = {72{stimulus[15:8]}};
    assign in_residual_s8 = {8{stimulus[23:16]}};
    assign in_group_index = stimulus[45:43];
    assign in_group_last = stimulus[46];
    assign in_x = stimulus[62:47];
    assign in_y = stimulus[31:16];
    assign in_sof = stimulus[47];
    assign in_eol = stimulus[48];
    assign in_eof = stimulus[49];
    assign out_ready = stimulus[50];
    assign abort = stimulus[51];

    (* keep_hierarchy = "yes", keep = "true" *) c1_r1_microstyle_engine #(
        .REQUIRED_STAGES(P_REQUIRED_STAGES),
        .PARAM_ADDR_W(P_PARAM_ADDR_W),
        .PARAM_ARENA_BYTES(P_PARAM_ARENA_BYTES),
        .MAX_CHANNELS(P_MAX_CHANNELS),
        .MAX_WEIGHT_BYTES(P_MAX_WEIGHT_BYTES),
        .MAX_PACKED_WEIGHT_TILES(P_MAX_PACKED_WEIGHT_TILES),
        .MAX_GROUPS_OVERRIDE(P_MAX_GROUPS_OVERRIDE),
        .AFFINE_CACHE_DEPTH_OVERRIDE(P_AFFINE_CACHE_DEPTH_OVERRIDE),
        .PACKED_AFFINE_CACHE(P_PACKED_AFFINE_CACHE),
        .ENFORCE_MICROSTYLE_TOPOLOGY(0),
        .PIPELINED_DOT_TREE(0),
        .PIPELINED_DOT_TREE_FULL(0),
        .PREVALIDATE_DESCRIPTOR_REPLAY(0),
        .PIPELINED_DECODER_VALIDATION(0),
        .CACHE_DW_WEIGHT_TILES(0),
        .MAC_PREFETCH_OVERLAP(0)
    ) u_engine (
        .clk(clk), .rst(rst), .abort(abort),
        .job_start_valid(job_start_valid), .job_start_ready(job_start_ready),
        .job_stage_count(job_stage_count), .config_generation(config_generation),
        .parameter_active_valid(parameter_active_valid),
        .parameter_generation(parameter_generation), .busy(busy), .done(done),
        .aborted(aborted), .error(error), .error_code(error_code),
        .stage_config_valid(stage_config_valid), .stage_config_ready(stage_config_ready),
        .stage_config_descriptor(stage_config_descriptor), .stage_config_error(stage_config_error),
        .stage_config_generation(stage_config_generation), .param_rd_en(param_rd_en),
        .param_rd_addr(param_rd_addr), .param_rd_valid(param_rd_valid),
        .param_rd_error(param_rd_error), .param_rd_data(param_rd_data),
        .in_valid(in_valid), .in_ready(in_ready), .in_window_s8(in_window_s8),
        .in_residual_s8(in_residual_s8), .in_group_index(in_group_index),
        .in_group_last(in_group_last), .in_x(in_x), .in_y(in_y), .in_sof(in_sof),
        .in_eol(in_eol), .in_eof(in_eof), .out_valid(out_valid), .out_ready(out_ready),
        .out_data_s8(out_data_s8), .out_group_index(out_group_index),
        .out_group_last(out_group_last), .out_x(out_x), .out_y(out_y),
        .out_sof(out_sof), .out_eol(out_eol), .out_eof(out_eof),
        .stage_index(stage_index), .stage_opcode(stage_opcode), .stage_active(stage_active),
        .adapter_required(adapter_required), .stage_done(stage_done),
        .overflow_seen(overflow_seen)
    );

    assign observe = {busy, done, error, aborted, stage_active, adapter_required,
                      overflow_seen, stage_done, stage_index, stage_opcode,
                      out_group_index, out_x[7:0], out_y[7:0],
                      ^out_data_s8, ^error_code, ^param_rd_addr,
                      stage_config_ready, in_ready, out_valid, job_start_ready};
endmodule

// Same stimulus/observation shell, but with production-scale storage and
// stage dimensions.  Keeping this alias in the same source lets Efinity map
// the small and full-shape probes without duplicating the protocol wiring.
module c1_ti60_engine_fullshape_wrapper (
    input  logic clk,
    input  logic rst,
    input  logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    c1_ti60_engine_small_wrapper #(
        .P_REQUIRED_STAGES(22), .P_PARAM_ADDR_W(11),
        .P_PARAM_ARENA_BYTES(16896), .P_MAX_CHANNELS(48),
        .P_MAX_WEIGHT_BYTES(2592), .P_MAX_PACKED_WEIGHT_TILES(72)
    ) u_probe (
        .clk(clk), .rst(rst), .stimulus(stimulus), .done(done), .observe(observe)
    );
endmodule

// One-stage control/cache scale-up.  This isolates array depth from the
// 22-stage topology dimension.
module c1_ti60_engine_fullcache_wrapper (
    input  logic clk,
    input  logic rst,
    input  logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    c1_ti60_engine_small_wrapper #(
        .P_REQUIRED_STAGES(1), .P_PARAM_ADDR_W(11),
        .P_PARAM_ARENA_BYTES(16896), .P_MAX_CHANNELS(48),
        .P_MAX_WEIGHT_BYTES(2592), .P_MAX_PACKED_WEIGHT_TILES(72)
    ) u_probe (
        .clk(clk), .rst(rst), .stimulus(stimulus), .done(done), .observe(observe)
    );
endmodule

// Weight-depth probe: keep channel arrays small, but use the production
// 16,896-byte arena and 2,592-byte convolution weight capacity.
module c1_ti60_engine_fullweight_wrapper (
    input  logic clk,
    input  logic rst,
    input  logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    c1_ti60_engine_small_wrapper #(
        .P_REQUIRED_STAGES(1), .P_PARAM_ADDR_W(11),
        .P_PARAM_ARENA_BYTES(16896), .P_MAX_CHANNELS(8),
        .P_MAX_WEIGHT_BYTES(2592), .P_MAX_PACKED_WEIGHT_TILES(72)
    ) u_probe (
        .clk(clk), .rst(rst), .stimulus(stimulus), .done(done), .observe(observe)
    );
endmodule

// Channel-depth probe: use production channel/cache dimensions, but keep the
// weight payload at the smallest legal C8 3x3 tile.
module c1_ti60_engine_fullchannel_wrapper (
    input  logic clk,
    input  logic rst,
    input  logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    c1_ti60_engine_small_wrapper #(
        .P_REQUIRED_STAGES(1), .P_PARAM_ADDR_W(11),
        .P_PARAM_ARENA_BYTES(16896), .P_MAX_CHANNELS(48),
        .P_MAX_WEIGHT_BYTES(144), .P_MAX_PACKED_WEIGHT_TILES(4)
    ) u_probe (
        .clk(clk), .rst(rst), .stimulus(stimulus), .done(done), .observe(observe)
    );
endmodule

// Intermediate channel-depth probe used to find the Efinity front-end
// failure threshold without touching production RTL.
module c1_ti60_engine_channel24_wrapper (
    input  logic clk,
    input  logic rst,
    input  logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    c1_ti60_engine_small_wrapper #(
        .P_REQUIRED_STAGES(1), .P_PARAM_ADDR_W(11),
        .P_PARAM_ARENA_BYTES(16896), .P_MAX_CHANNELS(24),
        .P_MAX_WEIGHT_BYTES(144), .P_MAX_PACKED_WEIGHT_TILES(4)
    ) u_probe (
        .clk(clk), .rst(rst), .stimulus(stimulus), .done(done), .observe(observe)
    );
endmodule

module c1_ti60_engine_channel16_wrapper (
    input  logic clk,
    input  logic rst,
    input  logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    c1_ti60_engine_small_wrapper #(
        .P_REQUIRED_STAGES(1), .P_PARAM_ADDR_W(11),
        .P_PARAM_ARENA_BYTES(16896), .P_MAX_CHANNELS(16),
        .P_MAX_WEIGHT_BYTES(144), .P_MAX_PACKED_WEIGHT_TILES(4)
    ) u_probe (
        .clk(clk), .rst(rst), .stimulus(stimulus), .done(done), .observe(observe)
    );
endmodule

// Group-depth bisection probes.  These deliberately keep all protocol and
// arithmetic wiring identical to the channel wrappers; only the diagnostic
// MAX_GROUPS override changes the extent of group-indexed memories.
module c1_ti60_engine_groups2_wrapper (
    input logic clk,
    input logic rst,
    input logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    c1_ti60_engine_small_wrapper #(
        .P_REQUIRED_STAGES(1), .P_PARAM_ADDR_W(11),
        .P_PARAM_ARENA_BYTES(16896), .P_MAX_CHANNELS(8),
        .P_MAX_WEIGHT_BYTES(144), .P_MAX_PACKED_WEIGHT_TILES(4),
        .P_MAX_GROUPS_OVERRIDE(2)
    ) u_probe (
        .clk(clk), .rst(rst), .stimulus(stimulus), .done(done), .observe(observe)
    );
endmodule

module c1_ti60_engine_channel16_groups1_wrapper (
    input logic clk,
    input logic rst,
    input logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    c1_ti60_engine_small_wrapper #(
        .P_REQUIRED_STAGES(1), .P_PARAM_ADDR_W(11),
        .P_PARAM_ARENA_BYTES(16896), .P_MAX_CHANNELS(16),
        .P_MAX_WEIGHT_BYTES(144), .P_MAX_PACKED_WEIGHT_TILES(4),
        .P_MAX_GROUPS_OVERRIDE(1)
    ) u_probe (
        .clk(clk), .rst(rst), .stimulus(stimulus), .done(done), .observe(observe)
    );
endmodule

module c1_ti60_engine_affine16_wrapper (
    input logic clk,
    input logic rst,
    input logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    // Keep channel/group geometry at the passing C8 case and only enlarge
    // the affine cache arrays to 16 entries.
    c1_ti60_engine_small_wrapper #(
        .P_REQUIRED_STAGES(1), .P_PARAM_ADDR_W(11),
        .P_PARAM_ARENA_BYTES(16896), .P_MAX_CHANNELS(8),
        .P_MAX_WEIGHT_BYTES(144), .P_MAX_PACKED_WEIGHT_TILES(4),
        .P_AFFINE_CACHE_DEPTH_OVERRIDE(16)
    ) u_probe (
        .clk(clk), .rst(rst), .stimulus(stimulus), .done(done), .observe(observe)
    );
endmodule

module c1_ti60_engine_channel16_affine8_groups1_wrapper (
    input logic clk,
    input logic rst,
    input logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    // Keep the scheduler's MAX_CHANNELS=16 geometry but constrain the three
    // affine storage arrays to the passing eight-entry extent.  The engine's
    // diagnostic guard prevents an out-of-range access if a probe stimulus is
    // later extended beyond the first group.
    c1_ti60_engine_small_wrapper #(
        .P_REQUIRED_STAGES(1), .P_PARAM_ADDR_W(11),
        .P_PARAM_ARENA_BYTES(16896), .P_MAX_CHANNELS(16),
        .P_MAX_WEIGHT_BYTES(144), .P_MAX_PACKED_WEIGHT_TILES(4),
        .P_MAX_GROUPS_OVERRIDE(1), .P_AFFINE_CACHE_DEPTH_OVERRIDE(8)
    ) u_probe (
        .clk(clk), .rst(rst), .stimulus(stimulus), .done(done), .observe(observe)
    );
endmodule

module c1_ti60_engine_channel16_packed_affine_wrapper (
    input logic clk,
    input logic rst,
    input logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    c1_ti60_engine_small_wrapper #(
        .P_REQUIRED_STAGES(1), .P_PARAM_ADDR_W(11),
        .P_PARAM_ARENA_BYTES(16896), .P_MAX_CHANNELS(16),
        .P_MAX_WEIGHT_BYTES(144), .P_MAX_PACKED_WEIGHT_TILES(4),
        .P_MAX_GROUPS_OVERRIDE(1), .P_PACKED_AFFINE_CACHE(1)
    ) u_probe (
        .clk(clk), .rst(rst), .stimulus(stimulus), .done(done), .observe(observe)
    );
endmodule

module c1_ti60_engine_fullchannel_packed_affine_wrapper (
    input logic clk,
    input logic rst,
    input logic [63:0] stimulus,
    output logic done,
    output logic [39:0] observe
);
    c1_ti60_engine_small_wrapper #(
        .P_REQUIRED_STAGES(1), .P_PARAM_ADDR_W(11),
        .P_PARAM_ARENA_BYTES(16896), .P_MAX_CHANNELS(48),
        .P_MAX_WEIGHT_BYTES(144), .P_MAX_PACKED_WEIGHT_TILES(4),
        .P_PACKED_AFFINE_CACHE(1)
    ) u_probe (
        .clk(clk), .rst(rst), .stimulus(stimulus), .done(done), .observe(observe)
    );
endmodule
