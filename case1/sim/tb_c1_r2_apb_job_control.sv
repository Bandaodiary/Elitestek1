`timescale 1ns/1ps
module tb_c1_r2_apb_job_control;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,psel=0,penable=0,pwrite=0;
    reg [7:0] paddr=0;reg [31:0] pwdata=0;reg [3:0] pstrb=0;
    wire [31:0] prdata;wire pready,pslverr,irq,busy,graph_start_valid,graph_done_ready;
    reg fabric_error=0,capture_busy=0,display_busy=0;
    reg [31:0] capture_base=0,display_base=0;
    reg graph_start_ready=1,graph_done_valid=0,graph_done_error=0;
    reg [31:0] graph_cycles=32'd12345;reg [4:0] active_stage=0;
    reg [7:0] read_outstanding=0,write_outstanding=0;
    wire [10:0] frame_width,publish_width;wire [9:0] frame_height,publish_height;
    wire [31:0] input_base,workspace_base,output_base,parameter_base,publish_base,publish_tag;
    wire publish_valid;reg publish_ready=0;
    c1_r2_apb_job_control dut(.*);
    integer checks=0,starts=0;
    always @(posedge clk) if(!rst && graph_start_valid && graph_start_ready) starts<=starts+1;
    task bus(input bit wr,input [7:0] addr,input [31:0] value,input [3:0] mask,input bit err);
        begin
            @(negedge clk);psel=1;penable=0;pwrite=wr;paddr=addr;pwdata=value;pstrb=mask;
            repeat(2) begin @(negedge clk);if(pslverr) $fatal(1,"PSLVERR outside access");end
            penable=1;#1;if(!pready || pslverr!==err) $fatal(1,"APB error response addr=%h got=%b expected=%b",addr,pslverr,err);
            @(negedge clk);psel=0;penable=0;checks=checks+1;
        end
    endtask
    task rd(input [7:0] addr,input [31:0] want);
        begin
            bus(0,addr,0,0,0);#1;if(prdata!==want) $fatal(1,"APB read addr=%h got=%h expected=%h",addr,prdata,want);
        end
    endtask
    task setup_job;
        begin
            bus(1,'h20,0,15,0);bus(1,'h24,'h00800000,15,0);bus(1,'h28,'h02000000,15,0);
            bus(1,'h2c,'h02800000,15,0);bus(1,'h30,'h01e00280,15,0);bus(1,'h34,'h12345678,15,0);
        end
    endtask
    task complete_job(input bit err);
        begin
            @(negedge clk);graph_done_error=err;graph_done_valid=1;
            #1;if(!graph_done_ready) $fatal(1,"owned completion not accepted");
            @(negedge clk);graph_done_valid=0;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        rd(0,'h52324331);bus(1,0,0,15,1);bus(0,1,0,0,1);bus(1,'h10,3,15,1);bus(1,'h10,4,15,1);
        bus(1,'h10,2,1,0);if(busy || irq) $fatal(1,"idle discard had an effect");
        setup_job();bus(1,'h34,'hab000000,8,0);rd('h34,'hab345678);bus(1,'h18,7,1,0);
        capture_busy=1;capture_base=0;bus(1,'h10,1,1,1);capture_base='h03000000;
        display_busy=1;display_base='h02000000;bus(1,'h10,1,1,1);display_base='h03800000;
        bus(1,'h30,'h81e00280,15,0);bus(1,'h10,1,1,1);bus(1,'h30,'h01e00280,15,0);
        bus(1,'h10,1,0,0);if(busy || starts!=0) $fatal(1,"zero-strobe command had effect");
        bus(1,'h10,1,1,0);graph_start_ready=0;
        bus(1,'h20,'h03000000,15,0);bus(1,'h34,0,15,0);
        if(!graph_start_valid || !busy || input_base!=0 || frame_width!=640 || frame_height!=480) $fatal(1,"pending snapshot changed");
        graph_start_ready=1;@(negedge clk);
        bus(1,'h10,1,1,1);if(starts!=1) $fatal(1,"duplicate start");
        complete_job(0);
        if(!irq || busy || !publish_valid || publish_base!='h02000000 || publish_tag!='hab345678) $fatal(1,"success publication");
        rd('h38,12345);rd('h3c,'hab345678);
        bus(1,'h10,4,1,0);bus(1,'h10,1,1,1); // consumer still owns the pending publication
        repeat(11) begin @(negedge clk);if(!publish_valid || publish_tag!='hab345678) $fatal(1,"publication not held");end
        publish_ready=1;@(negedge clk);publish_ready=0;
        bus(1,'h1c,7,1,0);if(irq) $fatal(1,"W1C IRQ");
        setup_job();bus(1,'h10,1,1,0);bus(1,'h10,2,1,0);complete_job(0);
        if(publish_valid || !dut.result_discard || dut.result_error || !irq) $fatal(1,"discard published / misreported");
        bus(1,'h10,4,1,0);bus(1,'h1c,7,1,0);
        bus(1,'h10,1,1,0);complete_job(1);if(publish_valid || !dut.result_error) $fatal(1,"error published");
        bus(1,'h10,4,1,0);bus(1,'h1c,7,1,0);
        // W1C coincident with completion: completion event wins.
        bus(1,'h10,1,1,0);
        @(negedge clk);psel=1;penable=0;pwrite=1;paddr='h1c;pwdata=7;pstrb=1;
        @(negedge clk);penable=1;graph_done_valid=1;graph_done_error=0;
        @(negedge clk);psel=0;penable=0;graph_done_valid=0;
        if(!irq || dut.irq_status!=1) $fatal(1,"completion lost to W1C");
        publish_ready=1;@(negedge clk);publish_ready=0;bus(1,'h10,4,1,0);
        fabric_error=1;@(negedge clk);bus(1,'h1c,7,1,0);
        if(!irq || !dut.irq_status[1]) $fatal(1,"fatal fabric fault cleared without reset");
        bus(1,'h10,1,1,1);
        $display("C1_R2_SHARED_APB_PASS checks=%0d starts=%0d snapshot=1 lease_reject=1 publication_hold=1 deferred_discard=1 irq_set_wins=1",checks,starts);
        $finish;
    end
endmodule
