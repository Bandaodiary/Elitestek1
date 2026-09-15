`timescale 1ns/1ps
// One ordered 128-bit transfer descriptor. It is NOT an AXI burst: a DMA
// bridge must fragment at its beat limit/4KiB boundary. Parameters are two
// {16'b0,kind[1:0],address[13:0],data[31:0]} commands per memory word.
// Feature words use P2C8. Four SRAM writes unpack each accepted word.
module c1_r2_tensor_row_loader (
    input wire clk,rst,start_valid,
    output wire start_ready,
    input wire [2:0] start_mode,
    input wire start_parameters,start_residual_b,start_input_rgb,
    input wire [1:0] start_row,
    input wire [2:0] start_groups,
    input wire [31:0] start_address,
    input wire [15:0] start_beats,
    output wire cmd_valid,
    input wire cmd_ready,
    output wire [31:0] cmd_address,
    output wire [15:0] cmd_beats,
    input wire data_valid,
    output wire data_ready,
    input wire [127:0] data,
    input wire data_last,data_error,
    output wire load_valid,
    input wire load_ready,
    output wire [1:0] load_kind,
    output wire [13:0] load_addr,
    output wire [31:0] load_data,
    output logic done,error
);
    localparam IDLE=0,COMMAND=1,RECEIVE=2,UNPACK=3,DRAIN=4;
    logic [2:0] state,mode_q,groups_q,group_q;
    logic parameters_q,residual_b_q,rgb_q,last_q;
    logic [1:0] row_q,part_q;
    logic [10:0] pair_q;
    logic [15:0] beats_q,remaining_q;
    logic [31:0] address_q;
    logic [127:0] data_q;
    wire [63:0] parameter_command=part_q[0] ? data_q[127:64] : data_q[63:0];
    wire malformed_parameter=parameter_command[63:48]!=0 || parameter_command[47:46]==0;
    assign start_ready=!rst && state==IDLE;
    assign cmd_valid=!rst && state==COMMAND;
    assign cmd_address=address_q;assign cmd_beats=beats_q;
    assign data_ready=!rst && (state==RECEIVE || state==DRAIN);
    assign load_valid=!rst && state==UNPACK && (!parameters_q || !malformed_parameter);
    assign load_kind=parameters_q ? parameter_command[47:46] : 2'd0;
    wire [10:0] group_word=(groups_q==1 ? pair_q : groups_q==2 ? pair_q<<1 : groups_q==3 ? (pair_q<<1)+pair_q : (pair_q<<2)+(pair_q<<1))+group_q;
    wire [10:0] pixel=(pair_q<<1)+part_q[1];
    wire [10:0] linear_record=(groups_q==2 ? pixel<<1 : groups_q==3 ? (pixel<<1)+pixel : (pixel<<2)+(pixel<<1))+group_q;
    wire [1:0] chunks=groups_q==2 ? 2'd1 : groups_q==3 ? 2'd2 : 2'd3;
    wire [10:0] pw_word=(chunks==1 ? pair_q : chunks==2 ? pair_q<<1 : (pair_q<<1)+pair_q)+(group_q>>1);
    assign load_addr=parameters_q ? parameter_command[45:32] :
                     mode_q==0 ? {2'b00,part_q[1],pw_word[8:0],group_q[0],part_q[0]} :
                     mode_q==3 ? {2'b00,linear_record[0],linear_record[9:1],residual_b_q,part_q[0]} :
                     {row_q,part_q[1],group_word[9:0],part_q[0]};
    assign load_data=parameters_q ? parameter_command[31:0] : data_q[part_q*32+:32]^(rgb_q ? 32'h80808080 : 32'd0);
    wire unpack_last=parameters_q ? part_q==1 : part_q==3;
    // With the operator idle, load_ready==0 means malformed parameter ABI,
    // not a transient stall. Do not spin forever on an unaccepted command.
    wire bad_load=state==UNPACK && (malformed_parameter && parameters_q || !load_ready);
    always_ff @(posedge clk) begin
        if(rst) begin
            state<=IDLE;mode_q<=0;groups_q<=1;group_q<=0;parameters_q<=0;residual_b_q<=0;rgb_q<=0;last_q<=0;
            row_q<=0;part_q<=0;pair_q<=0;beats_q<=0;remaining_q<=0;address_q<=0;data_q<=0;done<=0;error<=0;
        end else begin
            done<=0;
            if(start_valid && start_ready) begin
                state<=COMMAND;mode_q<=start_mode;groups_q<=start_groups;group_q<=0;parameters_q<=start_parameters;
                residual_b_q<=start_residual_b;rgb_q<=start_input_rgb;row_q<=start_row;pair_q<=0;part_q<=0;
                beats_q<=start_beats;remaining_q<=start_beats;address_q<=start_address;error<=0;
            end
            if(cmd_valid && cmd_ready) state<=RECEIVE;
            if(data_valid && data_ready) begin
                if(state==DRAIN) begin if(data_last) begin state<=IDLE;done<=1;end end
                else if(data_error || data_last!=(remaining_q==1)) begin
                    error<=1;
                    if(data_last) begin state<=IDLE;done<=1;end else state<=DRAIN;
                end else begin data_q<=data;last_q<=data_last;part_q<=0;remaining_q<=remaining_q-1'b1;state<=UNPACK;end
            end
            if(state==UNPACK) begin
                if(bad_load) begin
                    error<=1;
                    if(last_q) begin state<=IDLE;done<=1;end else state<=DRAIN;
                end else if(load_valid && load_ready) begin
                    if(unpack_last) begin
                        if(last_q) begin state<=IDLE;done<=1;end else state<=RECEIVE;
                        if(group_q+1==groups_q) begin group_q<=0;pair_q<=pair_q+1'b1;end
                        else group_q<=group_q+1'b1;
                    end else part_q<=part_q+1'b1;
                end
            end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!rst && start_valid && start_ready && (start_beats==0 || start_address[3:0]!=0)) $fatal(1,"loader illegal transfer");
`endif
endmodule
