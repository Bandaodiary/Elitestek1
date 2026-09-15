`timescale 1ns/1ps

// Independent APB3 shadow/configuration block for the R1 ISP.
//
// 12-bit byte address map (word accesses):
//   0x200 CONTROL       bit0 COMMIT W1P, bit1 ABORT_PENDING W1P
//   0x204 STATUS        [0] cfg_busy, [1] gamma_busy, [2] any_busy,
//                       [3] cfg_ready input, [4] gamma_ready input,
//                       [11:8] sticky error summary
//   0x208 ERROR_STATUS  W1C: [0] commit while busy, [1] gamma write
//                       while busy, [2] conflicting command, [3] bad address
//   0x210 BAYER_CFG     [1:0] pattern, [2] ROI x parity, [3] ROI y parity
//   0x214..0x220        BLACK_R, BLACK_GR, BLACK_GB, BLACK_B (u10)
//   0x224..0x22c        AWB_R, AWB_G, AWB_B (u16 Q2.14)
//   0x230..0x250        CCM RR,RG,RB,GR,GG,GB,BR,BG,BB (s16 Q3.13)
//   0x254..0x25c        OFFSET_R, OFFSET_G, OFFSET_B (s32 Q13 domain)
//   0x260 GAMMA_ADDR    [9:0]
//   0x264 GAMMA_DATA    [7:0]
//   0x268 GAMMA_COMMAND bit0 WRITE W1P
//
// COMMIT copies every scalar shadow register into a dedicated pending
// snapshot, then holds cfg_valid and the snapshot stable until cfg_ready.
// Shadow writes remain legal while waiting and affect only the next COMMIT.
// GAMMA_COMMAND similarly snapshots GAMMA_ADDR/DATA until gamma_cfg_ready.
// A new W1P command while its channel is busy is ignored, returns PSLVERR, and
// sets a sticky error bit.  ABORT_PENDING cancels both not-yet-accepted
// transactions and emits abort_pulse; it cannot undo a handshake already
// accepted by the ISP on an earlier edge.
module c1_apb_isp_config #(
    parameter integer APB_ADDR_W = 12
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    psel,
    input  logic                    penable,
    input  logic                    pwrite,
    input  logic [APB_ADDR_W-1:0]   paddr,
    input  logic [31:0]             pwdata,
    input  logic [3:0]              pstrb,
    output logic [31:0]             prdata,
    output logic                    pready,
    output logic                    pslverr,

    output logic                    cfg_valid,
    input  logic                    cfg_ready,
    output logic [1:0]              cfg_bayer_pattern,
    output logic                    cfg_roi_x_parity,
    output logic                    cfg_roi_y_parity,
    output logic [9:0]              cfg_black_r,
    output logic [9:0]              cfg_black_gr,
    output logic [9:0]              cfg_black_gb,
    output logic [9:0]              cfg_black_b,
    output logic [15:0]             cfg_awb_gain_r,
    output logic [15:0]             cfg_awb_gain_g,
    output logic [15:0]             cfg_awb_gain_b,
    output logic signed [15:0]      cfg_ccm_rr,
    output logic signed [15:0]      cfg_ccm_rg,
    output logic signed [15:0]      cfg_ccm_rb,
    output logic signed [15:0]      cfg_ccm_gr,
    output logic signed [15:0]      cfg_ccm_gg,
    output logic signed [15:0]      cfg_ccm_gb,
    output logic signed [15:0]      cfg_ccm_br,
    output logic signed [15:0]      cfg_ccm_bg,
    output logic signed [15:0]      cfg_ccm_bb,
    output logic signed [31:0]      cfg_ccm_offset_r,
    output logic signed [31:0]      cfg_ccm_offset_g,
    output logic signed [31:0]      cfg_ccm_offset_b,

    output logic                    gamma_valid,
    input  logic                    gamma_cfg_ready,
    output logic [9:0]              gamma_cfg_addr,
    output logic [7:0]              gamma_cfg_data,
    output logic                    abort_pulse
);

    localparam logic [APB_ADDR_W-1:0] ADDR_CONTROL       = 12'h200;
    localparam logic [APB_ADDR_W-1:0] ADDR_STATUS        = 12'h204;
    localparam logic [APB_ADDR_W-1:0] ADDR_ERROR_STATUS  = 12'h208;
    localparam logic [APB_ADDR_W-1:0] ADDR_BAYER_CFG     = 12'h210;
    localparam logic [APB_ADDR_W-1:0] ADDR_BLACK_R       = 12'h214;
    localparam logic [APB_ADDR_W-1:0] ADDR_BLACK_GR      = 12'h218;
    localparam logic [APB_ADDR_W-1:0] ADDR_BLACK_GB      = 12'h21c;
    localparam logic [APB_ADDR_W-1:0] ADDR_BLACK_B       = 12'h220;
    localparam logic [APB_ADDR_W-1:0] ADDR_AWB_R         = 12'h224;
    localparam logic [APB_ADDR_W-1:0] ADDR_AWB_G         = 12'h228;
    localparam logic [APB_ADDR_W-1:0] ADDR_AWB_B         = 12'h22c;
    localparam logic [APB_ADDR_W-1:0] ADDR_CCM_RR        = 12'h230;
    localparam logic [APB_ADDR_W-1:0] ADDR_CCM_RG        = 12'h234;
    localparam logic [APB_ADDR_W-1:0] ADDR_CCM_RB        = 12'h238;
    localparam logic [APB_ADDR_W-1:0] ADDR_CCM_GR        = 12'h23c;
    localparam logic [APB_ADDR_W-1:0] ADDR_CCM_GG        = 12'h240;
    localparam logic [APB_ADDR_W-1:0] ADDR_CCM_GB        = 12'h244;
    localparam logic [APB_ADDR_W-1:0] ADDR_CCM_BR        = 12'h248;
    localparam logic [APB_ADDR_W-1:0] ADDR_CCM_BG        = 12'h24c;
    localparam logic [APB_ADDR_W-1:0] ADDR_CCM_BB        = 12'h250;
    localparam logic [APB_ADDR_W-1:0] ADDR_OFFSET_R      = 12'h254;
    localparam logic [APB_ADDR_W-1:0] ADDR_OFFSET_G      = 12'h258;
    localparam logic [APB_ADDR_W-1:0] ADDR_OFFSET_B      = 12'h25c;
    localparam logic [APB_ADDR_W-1:0] ADDR_GAMMA_ADDR    = 12'h260;
    localparam logic [APB_ADDR_W-1:0] ADDR_GAMMA_DATA    = 12'h264;
    localparam logic [APB_ADDR_W-1:0] ADDR_GAMMA_COMMAND = 12'h268;

    logic [1:0] sh_bayer_pattern;
    logic sh_roi_x_parity;
    logic sh_roi_y_parity;
    logic [9:0] sh_black_r, sh_black_gr, sh_black_gb, sh_black_b;
    logic [15:0] sh_awb_r, sh_awb_g, sh_awb_b;
    logic signed [15:0] sh_ccm_rr, sh_ccm_rg, sh_ccm_rb;
    logic signed [15:0] sh_ccm_gr, sh_ccm_gg, sh_ccm_gb;
    logic signed [15:0] sh_ccm_br, sh_ccm_bg, sh_ccm_bb;
    logic signed [31:0] sh_offset_r, sh_offset_g, sh_offset_b;
    logic [9:0] sh_gamma_addr;
    logic [7:0] sh_gamma_data;

    logic cfg_pending;
    logic gamma_pending;
    logic [3:0] sticky_error;

    logic apb_access;
    logic apb_write;
    logic address_valid;
    logic cfg_command;
    logic abort_command;
    logic gamma_command;
    logic command_conflict;
    logic cfg_busy_error;
    logic gamma_busy_error;

    function automatic logic [31:0] merge_wstrb(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  byte_strobe
    );
        integer byte_index;
        begin
            merge_wstrb = old_value;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (byte_strobe[byte_index])
                    merge_wstrb[byte_index*8 +: 8] =
                        new_value[byte_index*8 +: 8];
        end
    endfunction

    function automatic logic [3:0] merge_u4(
        input logic [3:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0] byte_strobe
    );
        logic [31:0] merged;
        begin
            merged = merge_wstrb({28'd0, old_value}, new_value, byte_strobe);
            merge_u4 = merged[3:0];
        end
    endfunction

    function automatic logic [7:0] merge_u8(
        input logic [7:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0] byte_strobe
    );
        logic [31:0] merged;
        begin
            merged = merge_wstrb({24'd0, old_value}, new_value, byte_strobe);
            merge_u8 = merged[7:0];
        end
    endfunction

    function automatic logic [9:0] merge_u10(
        input logic [9:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0] byte_strobe
    );
        logic [31:0] merged;
        begin
            merged = merge_wstrb({22'd0, old_value}, new_value, byte_strobe);
            merge_u10 = merged[9:0];
        end
    endfunction

    function automatic logic [15:0] merge_u16(
        input logic [15:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0] byte_strobe
    );
        logic [31:0] merged;
        begin
            // Upper sign-extension bits are readback-only; byte strobes 2/3
            // therefore cannot alter the stored signed16 value.
            merged = merge_wstrb({16'd0, old_value}, new_value, byte_strobe);
            merge_u16 = merged[15:0];
        end
    endfunction

    always_comb begin
        case (paddr)
            ADDR_CONTROL, ADDR_STATUS, ADDR_ERROR_STATUS,
            ADDR_BAYER_CFG,
            ADDR_BLACK_R, ADDR_BLACK_GR, ADDR_BLACK_GB, ADDR_BLACK_B,
            ADDR_AWB_R, ADDR_AWB_G, ADDR_AWB_B,
            ADDR_CCM_RR, ADDR_CCM_RG, ADDR_CCM_RB,
            ADDR_CCM_GR, ADDR_CCM_GG, ADDR_CCM_GB,
            ADDR_CCM_BR, ADDR_CCM_BG, ADDR_CCM_BB,
            ADDR_OFFSET_R, ADDR_OFFSET_G, ADDR_OFFSET_B,
            ADDR_GAMMA_ADDR, ADDR_GAMMA_DATA,
            ADDR_GAMMA_COMMAND: address_valid = 1'b1;
            default: address_valid = 1'b0;
        endcase

        apb_access = psel && penable;
        apb_write = apb_access && pwrite;
        cfg_command = apb_write && (paddr == ADDR_CONTROL) &&
                      pstrb[0] && pwdata[0];
        abort_command = apb_write && (paddr == ADDR_CONTROL) &&
                        pstrb[0] && pwdata[1];
        gamma_command = apb_write && (paddr == ADDR_GAMMA_COMMAND) &&
                        pstrb[0] && pwdata[0];
        command_conflict = cfg_command && abort_command;
        cfg_busy_error = cfg_command && cfg_pending && !abort_command;
        gamma_busy_error = gamma_command && gamma_pending;

        pready = 1'b1;
        pslverr = apb_access &&
                  (!address_valid || command_conflict ||
                   cfg_busy_error || gamma_busy_error);

        cfg_valid = cfg_pending;
        gamma_valid = gamma_pending;
    end

    always_comb begin
        prdata = 32'd0;
        case (paddr)
            ADDR_CONTROL:      prdata = 32'd0;
            ADDR_STATUS:       prdata = {20'd0, sticky_error,
                                         3'd0, gamma_cfg_ready, cfg_ready,
                                         (cfg_pending || gamma_pending),
                                         gamma_pending, cfg_pending};
            ADDR_ERROR_STATUS: prdata = {28'd0, sticky_error};
            ADDR_BAYER_CFG:    prdata = {28'd0, sh_roi_y_parity,
                                         sh_roi_x_parity, sh_bayer_pattern};
            ADDR_BLACK_R:      prdata = {22'd0, sh_black_r};
            ADDR_BLACK_GR:     prdata = {22'd0, sh_black_gr};
            ADDR_BLACK_GB:     prdata = {22'd0, sh_black_gb};
            ADDR_BLACK_B:      prdata = {22'd0, sh_black_b};
            ADDR_AWB_R:        prdata = {16'd0, sh_awb_r};
            ADDR_AWB_G:        prdata = {16'd0, sh_awb_g};
            ADDR_AWB_B:        prdata = {16'd0, sh_awb_b};
            ADDR_CCM_RR:       prdata = {{16{sh_ccm_rr[15]}}, sh_ccm_rr};
            ADDR_CCM_RG:       prdata = {{16{sh_ccm_rg[15]}}, sh_ccm_rg};
            ADDR_CCM_RB:       prdata = {{16{sh_ccm_rb[15]}}, sh_ccm_rb};
            ADDR_CCM_GR:       prdata = {{16{sh_ccm_gr[15]}}, sh_ccm_gr};
            ADDR_CCM_GG:       prdata = {{16{sh_ccm_gg[15]}}, sh_ccm_gg};
            ADDR_CCM_GB:       prdata = {{16{sh_ccm_gb[15]}}, sh_ccm_gb};
            ADDR_CCM_BR:       prdata = {{16{sh_ccm_br[15]}}, sh_ccm_br};
            ADDR_CCM_BG:       prdata = {{16{sh_ccm_bg[15]}}, sh_ccm_bg};
            ADDR_CCM_BB:       prdata = {{16{sh_ccm_bb[15]}}, sh_ccm_bb};
            ADDR_OFFSET_R:     prdata = sh_offset_r;
            ADDR_OFFSET_G:     prdata = sh_offset_g;
            ADDR_OFFSET_B:     prdata = sh_offset_b;
            ADDR_GAMMA_ADDR:   prdata = {22'd0, sh_gamma_addr};
            ADDR_GAMMA_DATA:   prdata = {24'd0, sh_gamma_data};
            ADDR_GAMMA_COMMAND:prdata = 32'd0;
            default:           prdata = 32'd0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sh_bayer_pattern <= 2'b00;
            sh_roi_x_parity <= 1'b0;
            sh_roi_y_parity <= 1'b0;
            sh_black_r <= 10'd0;
            sh_black_gr <= 10'd0;
            sh_black_gb <= 10'd0;
            sh_black_b <= 10'd0;
            sh_awb_r <= 16'd16384;
            sh_awb_g <= 16'd16384;
            sh_awb_b <= 16'd16384;
            sh_ccm_rr <= 16'sd8192;
            sh_ccm_rg <= 16'sd0;
            sh_ccm_rb <= 16'sd0;
            sh_ccm_gr <= 16'sd0;
            sh_ccm_gg <= 16'sd8192;
            sh_ccm_gb <= 16'sd0;
            sh_ccm_br <= 16'sd0;
            sh_ccm_bg <= 16'sd0;
            sh_ccm_bb <= 16'sd8192;
            sh_offset_r <= 32'sd0;
            sh_offset_g <= 32'sd0;
            sh_offset_b <= 32'sd0;
            sh_gamma_addr <= 10'd0;
            sh_gamma_data <= 8'd0;

            cfg_pending <= 1'b0;
            gamma_pending <= 1'b0;
            sticky_error <= 4'd0;
            abort_pulse <= 1'b0;

            cfg_bayer_pattern <= 2'b00;
            cfg_roi_x_parity <= 1'b0;
            cfg_roi_y_parity <= 1'b0;
            cfg_black_r <= 10'd0;
            cfg_black_gr <= 10'd0;
            cfg_black_gb <= 10'd0;
            cfg_black_b <= 10'd0;
            cfg_awb_gain_r <= 16'd16384;
            cfg_awb_gain_g <= 16'd16384;
            cfg_awb_gain_b <= 16'd16384;
            cfg_ccm_rr <= 16'sd8192;
            cfg_ccm_rg <= 16'sd0;
            cfg_ccm_rb <= 16'sd0;
            cfg_ccm_gr <= 16'sd0;
            cfg_ccm_gg <= 16'sd8192;
            cfg_ccm_gb <= 16'sd0;
            cfg_ccm_br <= 16'sd0;
            cfg_ccm_bg <= 16'sd0;
            cfg_ccm_bb <= 16'sd8192;
            cfg_ccm_offset_r <= 32'sd0;
            cfg_ccm_offset_g <= 32'sd0;
            cfg_ccm_offset_b <= 32'sd0;
            gamma_cfg_addr <= 10'd0;
            gamma_cfg_data <= 8'd0;
        end else begin
            abort_pulse <= 1'b0;

            if (cfg_pending && cfg_ready)
                cfg_pending <= 1'b0;
            if (gamma_pending && gamma_cfg_ready)
                gamma_pending <= 1'b0;

            if (apb_access && !address_valid)
                sticky_error[3] <= 1'b1;
            if (cfg_busy_error)
                sticky_error[0] <= 1'b1;
            if (gamma_busy_error)
                sticky_error[1] <= 1'b1;
            if (command_conflict)
                sticky_error[2] <= 1'b1;

            if (apb_write) begin
                case (paddr)
                    ADDR_CONTROL: begin
                        if (command_conflict) begin
                            // Both commands are ignored.
                        end else if (abort_command) begin
                            cfg_pending <= 1'b0;
                            gamma_pending <= 1'b0;
                            abort_pulse <= 1'b1;
                        end else if (cfg_command && !cfg_pending) begin
                            cfg_pending <= 1'b1;
                            cfg_bayer_pattern <= sh_bayer_pattern;
                            cfg_roi_x_parity <= sh_roi_x_parity;
                            cfg_roi_y_parity <= sh_roi_y_parity;
                            cfg_black_r <= sh_black_r;
                            cfg_black_gr <= sh_black_gr;
                            cfg_black_gb <= sh_black_gb;
                            cfg_black_b <= sh_black_b;
                            cfg_awb_gain_r <= sh_awb_r;
                            cfg_awb_gain_g <= sh_awb_g;
                            cfg_awb_gain_b <= sh_awb_b;
                            cfg_ccm_rr <= sh_ccm_rr;
                            cfg_ccm_rg <= sh_ccm_rg;
                            cfg_ccm_rb <= sh_ccm_rb;
                            cfg_ccm_gr <= sh_ccm_gr;
                            cfg_ccm_gg <= sh_ccm_gg;
                            cfg_ccm_gb <= sh_ccm_gb;
                            cfg_ccm_br <= sh_ccm_br;
                            cfg_ccm_bg <= sh_ccm_bg;
                            cfg_ccm_bb <= sh_ccm_bb;
                            cfg_ccm_offset_r <= sh_offset_r;
                            cfg_ccm_offset_g <= sh_offset_g;
                            cfg_ccm_offset_b <= sh_offset_b;
                        end
                    end
                    ADDR_ERROR_STATUS: begin
                        if (pstrb[0])
                            sticky_error <= sticky_error & ~pwdata[3:0];
                    end
                    ADDR_BAYER_CFG: begin
                        {sh_roi_y_parity, sh_roi_x_parity, sh_bayer_pattern} <=
                            merge_u4(
                                {sh_roi_y_parity, sh_roi_x_parity,
                                 sh_bayer_pattern}, pwdata, pstrb);
                    end
                    ADDR_BLACK_R:
                        sh_black_r <= merge_u10(sh_black_r, pwdata, pstrb);
                    ADDR_BLACK_GR:
                        sh_black_gr <= merge_u10(sh_black_gr, pwdata, pstrb);
                    ADDR_BLACK_GB:
                        sh_black_gb <= merge_u10(sh_black_gb, pwdata, pstrb);
                    ADDR_BLACK_B:
                        sh_black_b <= merge_u10(sh_black_b, pwdata, pstrb);
                    ADDR_AWB_R:
                        sh_awb_r <= merge_u16(sh_awb_r, pwdata, pstrb);
                    ADDR_AWB_G:
                        sh_awb_g <= merge_u16(sh_awb_g, pwdata, pstrb);
                    ADDR_AWB_B:
                        sh_awb_b <= merge_u16(sh_awb_b, pwdata, pstrb);
                    ADDR_CCM_RR:
                        sh_ccm_rr <= merge_u16(sh_ccm_rr, pwdata, pstrb);
                    ADDR_CCM_RG:
                        sh_ccm_rg <= merge_u16(sh_ccm_rg, pwdata, pstrb);
                    ADDR_CCM_RB:
                        sh_ccm_rb <= merge_u16(sh_ccm_rb, pwdata, pstrb);
                    ADDR_CCM_GR:
                        sh_ccm_gr <= merge_u16(sh_ccm_gr, pwdata, pstrb);
                    ADDR_CCM_GG:
                        sh_ccm_gg <= merge_u16(sh_ccm_gg, pwdata, pstrb);
                    ADDR_CCM_GB:
                        sh_ccm_gb <= merge_u16(sh_ccm_gb, pwdata, pstrb);
                    ADDR_CCM_BR:
                        sh_ccm_br <= merge_u16(sh_ccm_br, pwdata, pstrb);
                    ADDR_CCM_BG:
                        sh_ccm_bg <= merge_u16(sh_ccm_bg, pwdata, pstrb);
                    ADDR_CCM_BB:
                        sh_ccm_bb <= merge_u16(sh_ccm_bb, pwdata, pstrb);
                    ADDR_OFFSET_R:
                        sh_offset_r <= merge_wstrb(sh_offset_r, pwdata, pstrb);
                    ADDR_OFFSET_G:
                        sh_offset_g <= merge_wstrb(sh_offset_g, pwdata, pstrb);
                    ADDR_OFFSET_B:
                        sh_offset_b <= merge_wstrb(sh_offset_b, pwdata, pstrb);
                    ADDR_GAMMA_ADDR:
                        sh_gamma_addr <= merge_u10(sh_gamma_addr, pwdata, pstrb);
                    ADDR_GAMMA_DATA:
                        sh_gamma_data <= merge_u8(sh_gamma_data, pwdata, pstrb);
                    ADDR_GAMMA_COMMAND: begin
                        if (gamma_command && !gamma_pending) begin
                            gamma_pending <= 1'b1;
                            gamma_cfg_addr <= sh_gamma_addr;
                            gamma_cfg_data <= sh_gamma_data;
                        end
                    end
                    default: begin
                        // Read-only/unmapped writes have no register effect.
                    end
                endcase
            end
        end
    end

endmodule
