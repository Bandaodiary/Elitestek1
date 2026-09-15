// C23 standalone Resize probe: runtime input/Q16 phases, fixed 640x480 output.
// RGB888 ready/valid source; not a CSI frontend or a complete R2 host.
module c1_ti60_r2_resize_640 (
    input wire clk,rst,host_write,cfg_valid,abort,in_valid,out_ready,
    input wire [3:0] host_address,
    input wire [31:0] host_data,
    input wire in_sof,in_eol,in_eof,
    input wire [1:0] observe,
    output wire cfg_ready,cfg_error,in_ready,out_valid,done,error,busy,aborted,
    output logic [31:0] observed
);
    logic [15:0] win,hin,wout,hout,in_x,in_y;
    logic signed [31:0] xs,ys,xp,yp;
    wire [15:0] out_x,out_y;
    wire [23:0] out_rgb;
    wire out_sof,out_eol,out_eof;
    wire [3:0] error_code;
    always_ff @(posedge clk)if(host_write)begin
        case(host_address)
            0:begin win<=host_data[15:0];hin<=host_data[31:16];end
            1:begin wout<=host_data[15:0];hout<=host_data[31:16];end
            2:xs<=host_data;
            3:ys<=host_data;
            4:xp<=host_data;
            5:yp<=host_data;
            6:begin in_x<=host_data[15:0];in_y<=host_data[31:16];end
        endcase
    end
    c1_r2_resize_pipeline #(.MAX_WIDTH(2048),.REGISTER_ABORT_RESET(1)) u_resize (
        .clk(clk),.rst(rst),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_error(cfg_error),
        .cfg_win(win),.cfg_hin(hin),.cfg_wout(16'd640),.cfg_hout(16'd480),
        .cfg_x_step_q16(xs),.cfg_y_step_q16(ys),.cfg_x_phase0_q16(xp),.cfg_y_phase0_q16(yp),
        .abort(abort),.aborted(aborted),.busy(busy),.done(done),.error(error),.error_code(error_code),
        .in_valid(in_valid),.in_ready(in_ready),.in_x(in_x),.in_y(in_y),
        .in_sof(in_sof),.in_eol(in_eol),.in_eof(in_eof),.in_rgb888(host_data[23:0]),
        .out_valid(out_valid),.out_ready(out_ready),.out_sof(out_sof),.out_eol(out_eol),.out_eof(out_eof),
        .out_x(out_x),.out_y(out_y),.out_rgb888(out_rgb)
    );
    always_comb case(observe)
        0:observed={1'b0,error_code,out_eof,out_eol,out_sof,out_rgb};
        1:observed={out_y,out_x};
        2:observed={24'd0,cfg_ready,cfg_error,in_ready,out_valid,done,error,busy,aborted};
        default:observed={hin,win};
    endcase
endmodule
