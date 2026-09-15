`timescale 1ns/1ps
module tb_c1_r2_plan_decode;
    reg clk=0;always #5 clk=~clk;
    reg [4:0] index=0;reg [10:0] frame_width=4;reg [9:0] frame_height=4;
    wire valid,last,input_rgb,output_rgb,virtual_up2,view;
    wire [2:0] mode;wire [5:0] cin,cout;
    wire [10:0] src_width,dst_width;wire [9:0] src_height,dst_height;
    wire [1:0] src_slot,dst_slot,skip_slot;wire [15:0] parameter_beats;wire [4:0] parameter_block;
    c1_r2_microstyle_plan plan(.*);
    // Observe the actual retained RTL decoder, not a retyped expected table.
    // Only its internal registered index/geometry are forced; the engine
    // stays in reset. This is decode equivalence, NOT graph execution.
    c1_r2_microstyle_pingpong_graph old (
        .clk(clk),.rst(1'b1),.start_valid(1'b0),.frame_width(frame_width),.frame_height(frame_height),
        .input_base(32'd0),.workspace_base(32'h00800000),.output_base(32'h02000000),.parameter_base(32'h02800000),
        .done_ready(1'b0),.rd_cmd_ready(1'b0),.rd_valid(1'b0),.rd_data(128'd0),.rd_last(1'b0),.rd_error(1'b0),
        .wr_cmd_ready(1'b0),.wr_ready(1'b0),.wr_response_valid(1'b0),.wr_response_error(1'b0)
    );
    integer checks=0,executable=0,views=0,invalid=0;
    task check(input bit ok,input string why);
        begin if(!ok)$fatal(1,"plan decode: %s index=%0d width=%0d height=%0d",why,index,frame_width,frame_height);checks=checks+1;end
    endtask
    initial begin
        for(integer shape=0;shape<9;shape=shape+1)begin
            case(shape)
                0:begin frame_width=4;frame_height=4;end
                1:begin frame_width=8;frame_height=12;end
                2:begin frame_width=12;frame_height=8;end
                3:begin frame_width=32;frame_height=32;end
                4:begin frame_width=640;frame_height=4;end
                5:begin frame_width=4;frame_height=480;end
                6:begin frame_width=636;frame_height=476;end
                7:begin frame_width=640;frame_height=480;end
                8:begin frame_width=320;frame_height=240;end
            endcase
            for(integer instruction=0;instruction<32;instruction=instruction+1)begin
                index=instruction;
                // Reapply for each vector; do not rely on simulators tracking
                // a procedural force expression when its RHS subsequently moves.
                force old.stage_q=index;force old.width_q=frame_width;force old.height_q=frame_height;
                #2;
                check(valid===(instruction<22),"valid range");
                if(valid)begin
                    check(last===(instruction==21)&&input_rgb===(instruction==0)&&output_rgb===(instruction==20)&&
                          virtual_up2===(instruction==15||instruction==18)&&view===(instruction==14||instruction==17||instruction==21)&&
                          parameter_block===index,"plan routing/fusion flags");
                    if(!view)begin
                        check({mode,cin,cout,src_width,src_height,dst_width,dst_height,parameter_beats,virtual_up2}===
                              {old.mode_c_decoded,old.cin_c_decoded,old.cout_c_decoded,old.src_width_decoded,old.src_height_decoded,
                               old.dst_width_decoded,old.dst_height_decoded,old.parameter_beats_decoded,old.virtual_c_decoded},"actual old decoder executable fields");
                        check(dst_slot===old.dst_slot_decoded,"destination coloring");
                        if(!input_rgb)check(src_slot===old.src_slot_decoded,"source lifetime/coloring");
                        if(mode==3)check(skip_slot===old.skip_slot_decoded,"skip lifetime/coloring");
                        executable=executable+1;
                    end else views=views+1;
                end else begin
                    check(!last&&!input_rgb&&!output_rgb&&!virtual_up2&&view&&parameter_beats==0,"invalid instruction cannot launch work");
                    invalid=invalid+1;
                end
            end
        end
        release old.stage_q;release old.width_q;release old.height_q;
        $display("C1_R2_PLAN_DECODE_PASS checks=%0d geometries=9 executable=%0d views=%0d invalid=%0d actual_retained_decoder=1 execution_claim=0",checks,executable,views,invalid);
        $finish;
    end
endmodule
