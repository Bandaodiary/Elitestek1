`timescale 1ns/1ps

// Boardless full-top candidate probe.  It keeps the CNN dispatcher and the
// 22-stage descriptor cache in the elaborated design while selecting the
// Efinity-friendly packed affine-cache representation.  The narrow stimulus
// shell is deliberately not a board interface; it only prevents the mapper
// from proving every protocol input constant.
module c1_ti60_cnn_top_packed_wrapper (
    input  logic        clk,
    input  logic        rst,
    input  logic [63:0] stimulus,
    output logic [46:0] observe
);
    localparam integer STAGES = 22;
    localparam integer PARAM_ADDR_W = 11;

    logic abort;
    logic start_valid, start_ready;
    logic [15:0] stage_count;
    logic [7:0] config_generation;
    logic parameter_active_valid;
    logic [31:0] parameter_generation;
    logic busy, done, aborted, error;
    logic [7:0] error_code;
    logic stage_config_valid, stage_config_ready;
    logic [15:0] stage_config_index;
    logic [511:0] stage_config_descriptor;
    logic [7:0] stage_config_generation;
    logic param_rd_en, param_rd_valid, param_rd_error;
    logic [PARAM_ADDR_W-1:0] param_rd_addr;
    logic [127:0] param_rd_data;
    logic in_valid, in_ready;
    logic [575:0] in_window_s8;
    logic [63:0] in_residual_s8;
    logic [2:0] in_group_index;
    logic in_group_last;
    logic [15:0] in_x, in_y;
    logic in_sof, in_eol, in_eof;
    logic out_valid, out_ready;
    logic [63:0] out_data_s8;
    logic [2:0] out_group_index;
    logic out_group_last;
    logic [15:0] out_x, out_y;
    logic out_sof, out_eol, out_eof;
    logic [4:0] stage_index;
    logic [7:0] stage_opcode;
    logic stage_active, adapter_required, stage_done, overflow_seen;
    logic config_capture_complete;

    assign start_valid = !stimulus[63] && stimulus[0];
    assign stage_count = (stimulus[16:1] == 0) ? 16'd22 : stimulus[16:1];
    assign config_generation = stimulus[24:17];
    assign parameter_active_valid = stimulus[25];
    assign stage_config_valid = !stimulus[63] && stimulus[26];
    assign parameter_generation = stimulus[31:0];
    assign stage_config_index = stimulus[15:0];
    assign stage_config_generation = config_generation;
    assign param_rd_valid = !stimulus[63] && stimulus[40];
    assign param_rd_error = stimulus[41];
    assign in_valid = !stimulus[63] && stimulus[42];
    assign in_residual_s8 = stimulus;
    // Serial loading permits independent lane/descriptor values. Repeated
    // combinational bytes used by the old probe enabled constant folding.
    always_ff @(posedge clk) begin
        if (rst) begin
            stage_config_descriptor <= '0;
            param_rd_data <= '0;
            in_window_s8 <= '0;
        end else if (stimulus[63]) begin
            case (stimulus[62:61])
                2'd0: stage_config_descriptor <= {stage_config_descriptor[479:0], stimulus[31:0]};
                2'd1: param_rd_data <= {param_rd_data[95:0], stimulus[31:0]};
                2'd2: in_window_s8 <= {in_window_s8[543:0], stimulus[31:0]};
                default: begin end
            endcase
        end
    end
    assign in_group_index = stimulus[45:43];
    assign in_group_last = stimulus[46];
    assign in_sof = stimulus[47];
    assign in_eol = stimulus[48];
    assign in_eof = stimulus[49];
    assign out_ready = stimulus[50];
    assign abort = stimulus[51];
    assign in_x = stimulus[62:47];
    assign in_y = stimulus[31:16];

    // Keep the observation vector connected so the candidate is not reduced
    // to a pure control shell during synthesis.
    (* keep = "true" *) logic [46:0] observe_keep;
    assign observe_keep = {busy, done, error, aborted, stage_active,
                           adapter_required, overflow_seen, stage_done,
                           stage_index, stage_opcode, out_group_index,
                           out_x[7:0], out_y[7:0], ^out_data_s8,
                           ^error_code, ^param_rd_addr, stage_config_ready,
                           in_ready, out_valid, start_ready};
    assign observe = observe_keep;

    c1_r1_microstyle_cnn_top #(
        .REQUIRED_STAGES(STAGES),
        .PARAM_ADDR_W(PARAM_ADDR_W),
        .PARAM_ARENA_BYTES(16896),
        .MAX_CHANNELS(48),
        .MAX_WEIGHT_BYTES(2592),
        .PACKED_AFFINE_CACHE(1)
    ) u_top (
        .clk(clk), .rst(rst), .abort(abort),
        .start_valid(start_valid), .start_ready(start_ready),
        .stage_count(stage_count),
        .config_generation(config_generation),
        .parameter_active_valid(parameter_active_valid),
        .parameter_generation(parameter_generation),
        .busy(busy), .done(done), .aborted(aborted), .error(error),
        .error_code(error_code),
        .stage_config_valid(stage_config_valid),
        .stage_config_ready(stage_config_ready),
        .stage_config_index(stage_config_index),
        .stage_config_descriptor(stage_config_descriptor),
        .stage_config_generation(stage_config_generation),
        .param_rd_en(param_rd_en), .param_rd_addr(param_rd_addr),
        .param_rd_valid(param_rd_valid), .param_rd_error(param_rd_error),
        .param_rd_data(param_rd_data),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_window_s8(in_window_s8), .in_residual_s8(in_residual_s8),
        .in_group_index(in_group_index), .in_group_last(in_group_last),
        .in_x(in_x), .in_y(in_y), .in_sof(in_sof), .in_eol(in_eol),
        .in_eof(in_eof),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_data_s8(out_data_s8), .out_group_index(out_group_index),
        .out_group_last(out_group_last), .out_x(out_x), .out_y(out_y),
        .out_sof(out_sof), .out_eol(out_eol), .out_eof(out_eof),
        .stage_index(stage_index), .stage_opcode(stage_opcode),
        .stage_active(stage_active), .adapter_required(adapter_required),
        .stage_done(stage_done), .overflow_seen(overflow_seen),
        .config_capture_complete(config_capture_complete)
    );
endmodule
