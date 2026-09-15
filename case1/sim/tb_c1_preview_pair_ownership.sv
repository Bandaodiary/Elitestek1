`timescale 1ns/1ps
// Preview sidecar binding: preview slot == processed output slot.
// Real ownership manager and join; child activity and display drain are models.
module tb_c1_preview_pair_ownership;
    logic clk=0,rst_n=0; always #5 clk=~clk;
    logic abort=0,drop_oldest_mode=0,cap_frame_start=0,cap_frame_done=0;
    wire cap_accept_pulse,cap_drop_pulse;wire [1:0] cap_input_index;
    wire [31:0] cap_frame_id;
    logic request=0;wire nn_job_request,nn_done,nn_job_grant;
    wire [1:0] nn_input_index;wire nn_output_index;wire [31:0] nn_frame_id;
    logic display_vsync=0;wire display_swap_pulse;
    wire [1:0] display_input_index;wire display_output_index;
    wire [31:0] display_frame_id;wire display_active;
    wire [2:0] input_ready_count;wire [1:0] output_ready_count;
    wire capture_active_out,nn_active_out;wire [31:0] dropped_frame_count;
    wire [2:0] input_owned_mask;
    wire [1:0] output_owned_mask;
    wire join_ready,join_busy,child_start;
    logic left_busy=0,right_busy=0,left_done=0,right_done=0;
    integer grants=0,swaps=0;
    logic first_slot,second_slot;
    logic [1:0] held_input;
    assign nn_job_request=request&&join_ready&&!abort;
    c1_frame_manager manager(.*);
    c1_r1_runtime_join joiner(
        .clk(clk),.rst(!rst_n),.start_valid(nn_job_grant),.start_ready(join_ready),
        .cancel(abort),.child_start(child_start),.left_ready(1'b1),.right_ready(1'b1),
        .left_busy(left_busy),.left_done(left_done),.left_error(1'b0),
        .left_error_code(8'd0),.left_error_address(32'd0),
        .right_busy(right_busy),.right_done(right_done),.right_error(1'b0),
        .right_error_code(8'd0),.right_error_address(32'd0),
        .busy(join_busy),.done(nn_done),.error(),.error_code(),.error_address()
    );
    always @(posedge clk) if(rst_n) begin
        if(nn_job_grant) grants<=grants+1;
        if(display_swap_pulse) swaps<=swaps+1;
        if(child_start) begin left_busy<=1;right_busy<=1;end
        if(nn_job_grant&&display_active&&nn_output_index==display_output_index)
            $fatal(1,"allocated output/preview slot still owned by display");
        if(cap_accept_pulse&&display_active&&cap_input_index==display_input_index)
            $fatal(1,"capture allocated input still owned by display");
        if(nn_done&&(left_busy||right_busy||abort)) $fatal(1,"published unfinished pair");
    end
    task automatic capture;
        @(negedge clk);cap_frame_start=1;@(negedge clk);cap_frame_start=0;
        if(!cap_accept_pulse) $fatal(1,"capture unexpectedly rejected");
        cap_frame_done=1;@(negedge clk);cap_frame_done=0;
    endtask
    task automatic launch;
        request=1;wait(nn_job_grant);@(negedge clk);request=0;
        wait(join_busy);@(negedge clk);
    endtask
    task automatic finish_left;
        left_busy=0;left_done=1;@(negedge clk);left_done=0;
    endtask
    task automatic finish_right;
        right_busy=0;right_done=1;@(negedge clk);right_done=0;
        wait(!join_busy);@(negedge clk);
    endtask
    task automatic vsync;
        display_vsync=1;@(negedge clk);display_vsync=0;
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        capture();launch();first_slot=nn_output_index;
        finish_left();
        repeat(8) begin
            vsync();
            if(output_ready_count!=0||display_active||!nn_active_out)
                $fatal(1,"compute completion published unfinished preview");
        end
        finish_right();vsync();@(negedge clk);
        if(!display_active||display_output_index!==first_slot||display_frame_id!==0)
            $fatal(1,"first pair publication mismatch");
        capture();launch();second_slot=nn_output_index;
        if(second_slot==first_slot) $fatal(1,"display sidecar reused early");
        finish_left();finish_right();
        capture();request=1;
        repeat(8) begin
            @(negedge clk);
            if(grants!=2||nn_job_grant) $fatal(1,"ready/display slots reused before swap");
        end
        // This event represents a VSYNC permitted only after old display reads drain.
        vsync();wait(nn_job_grant);@(negedge clk);request=0;
        if(nn_output_index!==first_slot||display_output_index!==second_slot||display_frame_id!==1)
            $fatal(1,"paired preview lease not released with processed output");
        wait(join_busy);@(negedge clk);finish_left();finish_right();
        if(grants!=3||swaps!=2||output_ready_count!=1) $fatal(1,"ownership coverage counts");
        held_input=display_input_index;
        // The third pair is ready but not displayed. Abort must dominate
        // same-edge VSYNC and preserve the second pair's display ownership.
        abort=1;display_vsync=1;
        @(negedge clk);abort=0;display_vsync=0;
        repeat(3) begin
            @(negedge clk);
            if(!display_active || display_input_index!==held_input ||
               display_output_index!==second_slot || display_frame_id!==1 ||
               output_ready_count!=0 || display_swap_pulse || swaps!=2)
                $fatal(1,"abort/VSYNC published canceled pending pair or lost current pair");
        end
        capture();launch();
        if(nn_output_index!==first_slot) $fatal(1,"recovery did not use free preview slot");
        finish_left();
        // A cancel pulse must not fabricate retirement for outstanding preview
        // writes. The join gates admission until right_busy really clears.
        abort=1;display_vsync=1;
        @(negedge clk);abort=0;display_vsync=0;request=1;
        repeat(10) begin
            @(negedge clk);
            if(!join_busy || join_ready || nn_job_grant || nn_done ||
               !display_active || display_input_index!==held_input ||
               display_output_index!==second_slot || display_frame_id!==1 || swaps!=2)
                $fatal(1,"canceled preview drain released admission or display lease early");
        end
        request=0;right_busy=0;
        wait(!join_busy);@(negedge clk);
        if(grants!=4 || output_ready_count!=0) $fatal(1,"cancel published a success");
        // No reset: reuse only the non-displayed slot after physical retirement.
        capture();launch();
        if(nn_output_index!==first_slot || nn_frame_id!==4)
            $fatal(1,"post-drain recovery lease/id mismatch");
        finish_left();finish_right();vsync();@(negedge clk);
        if(grants!=5 || swaps!=3 || !display_active ||
           display_output_index!==first_slot || display_frame_id!==4 || output_ready_count!=0)
            $fatal(1,"post-cancel successful pair failed publication");
        $display("C1_PREVIEW_PAIR_CANCEL_PASS pending_vsync=1 active_cancel=1 drain_hold=10 jobs=5 swaps=3 no_reset=1");
        $display("C1_PREVIEW_PAIR_OWNERSHIP_PASS jobs=5 swaps=3 held_preview=8 held_slots=8 paired_index=1 reuse_after_swap=1");
        $finish;
    end
    initial begin #20000;$fatal(1,"preview ownership timeout grants=%0d",grants);end
endmodule
