// Narrow host probe. All data/config bits remain runtime-observable; not a
// board pinout or DMA bridge. Host must hold response data until accepted.
module c1_ti60_r2_bound_plan96 (
    input wire clk,rst,host_write,
    input wire [3:0] host_address,observe,
    input wire [31:0] host_data,
    output logic [31:0] observed,
    input wire start_valid,done_ready,
    output wire start_ready,busy,done_valid,done_error,
    output wire rd_cmd_valid,rd_ready,wr_cmd_valid,wr_valid,wr_last,wr_response_ready,
    input wire rd_cmd_ready,rd_valid,rd_last,rd_error,wr_cmd_ready,wr_ready,wr_response_valid,wr_response_error
);
    logic [127:0] rd_data;
    logic [31:0] input_base,workspace_base,output_base,parameter_base;
    logic [10:0] frame_width;logic [9:0] frame_height;
    wire [31:0] rd_cmd_address,wr_cmd_address,frame_cycles;
    wire [15:0] rd_cmd_beats,wr_cmd_beats;
    wire [127:0] wr_data;
    wire stage_done;wire [4:0] stage_done_index,active_stage;
    always_ff @(posedge clk) if(host_write) begin
        case(host_address)
            0,1,2,3:rd_data[host_address[1:0]*32+:32]<=host_data;
            4:input_base<=host_data;5:workspace_base<=host_data;6:output_base<=host_data;7:parameter_base<=host_data;
            8:begin frame_width<=host_data[10:0];frame_height<=host_data[25:16];end
        endcase
    end
    c1_r2_planned_pingpong_graph u_graph(.*);
    always_comb begin
        case(observe)
            0:observed=rd_cmd_address;1:observed=wr_cmd_address;2:observed={rd_cmd_beats,wr_cmd_beats};
            3,4,5,6:observed=wr_data[(observe-3)*32+:32];7:observed=frame_cycles;
            8:observed={21'd0,stage_done,stage_done_index,active_stage};default:observed=0;
        endcase
    end
endmodule
