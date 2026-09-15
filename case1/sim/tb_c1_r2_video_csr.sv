`timescale 1ns/1ps
module tb_c1_r2_video_csr;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,psel=0,penable=0,pwrite=0;reg [7:0] paddr=0;
    reg [31:0] pwdata=0;reg [3:0] pstrb=15;
    wire [31:0] prdata;wire pready,pslverr,enabled,irq;wire [2:0] request_enable;
    reg platform_ready=0,fabric_error=0,lease_error=0,cap_active=0,nn_active=0,display_active=0,front_valid=0;
    reg cap_event=0,cap_bad=0,nn_event=0,nn_bad=0,display_event=0,display_bad=0,overflow_event=0,underflow_event=0;
    reg [31:0] nn_cycles=0,nn_tag=0,dropped_captures=0,retired_pairs=0;
    reg [7:0] read_outstanding=0,write_outstanding=0;
    wire [31:0] capture_count,nn_count,display_count,underflow_count,last_nn_cycles,last_nn_tag;
    c1_r2_video_csr dut(.*);
    integer checks=0;
    task check(input bit ok,input string why);begin if(!ok)$fatal(1,"video CSR: %s",why);checks=checks+1;end endtask
    task apb(input bit wr,input [7:0] addr,input [31:0] data,input [3:0] strobes,input bit error_expected,input [31:0] expected);
        begin
            @(negedge clk);psel=1;penable=0;pwrite=wr;paddr=addr;pwdata=data;pstrb=strobes;#1;
            check(pready&&!pslverr,"setup has no access error");
            @(negedge clk);penable=1;#1;check(pready&&pslverr===error_expected,"access response");
            if(!wr&&!error_expected)check(prdata===expected,"read data");
            @(negedge clk);psel=0;penable=0;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);check(!pready&&!enabled&&!irq,"reset");rst=0;
        apb(0,'h00,0,0,0,'h52325631);apb(0,'h04,0,0,0,'h10000);
        apb(0,'h38,0,0,0,'h01e00280);apb(0,'h3c,0,0,0,'h08000000);
        apb(1,'h00,1,15,1,0);apb(1,'h10,1,15,1,0);apb(0,'h09,0,0,1,0);apb(0,'h44,0,0,1,0);
        apb(1,'h08,'hffffff0f,1,0,0);check(enabled&&request_enable==7,"low-byte enable");
        apb(1,'h08,0,2,0,0);check(enabled&&request_enable==7,"unselected byte preserved");
        apb(1,'h08,16,1,1,0);check(enabled&&request_enable==7,"reserved write no side effect");
        apb(1,'h08,'hffffffff,0,0,0);check(enabled&&request_enable==7,"zero strobe no side effect");
        apb(1,'h08,11,15,0,0);check(enabled&&request_enable==5,"pause NN admission only");
        cap_active=1;nn_active=1;display_active=1;front_valid=1;platform_ready=1;
        apb(0,'h0c,0,0,0,31);apb(1,'h08,0,15,0,0);check(!enabled&&request_enable==0,"disable new admissions");
        @(negedge clk);cap_event=1;nn_event=1;display_event=1;nn_cycles=1234;nn_tag=9;
        @(negedge clk);cap_event=0;nn_event=0;display_event=0;
        check(capture_count==1&&nn_count==1&&display_count==1&&last_nn_cycles==1234&&last_nn_tag==9,"completion still counted while disabled");
        check(!irq,"masked pending event");apb(0,'h30,0,0,0,1);apb(1,'h34,15,15,0,0);check(irq,"late unmask pending IRQ");
        apb(1,'h30,1,2,0,0);check(irq,"W1C byte mask");apb(1,'h30,1,1,0,0);check(!irq,"W1C");
        @(negedge clk);cap_event=1;nn_event=1;display_event=1;cap_bad=1;nn_bad=1;display_bad=1;nn_cycles=999;nn_tag=99;
        @(negedge clk);cap_event=0;nn_event=0;display_event=0;cap_bad=0;nn_bad=0;display_bad=0;
        check(capture_count==1&&nn_count==1&&display_count==1&&last_nn_cycles==1234&&last_nn_tag==9,"bad completions not counted as successful");
        apb(0,'h30,0,0,0,3);apb(1,'h30,15,15,0,0);
        @(negedge clk);underflow_event=1;
        @(negedge clk);underflow_event=0;check(underflow_count==1,"underflow pulse counter");apb(0,'h30,0,0,0,4);
        // Same clock event-set wins over software clear. No implicit reset.
        @(negedge clk);psel=1;penable=0;pwrite=1;paddr='h30;pwdata=4;pstrb=1;
        @(negedge clk);penable=1;overflow_event=1;
        @(negedge clk);psel=0;penable=0;overflow_event=0;
        apb(0,'h30,0,0,0,4);apb(1,'h30,4,1,0,0);check(!irq,"set-wins then clear");
        fabric_error=1;apb(1,'h30,8,1,0,0);check(irq,"level fatal event cannot be cleared while asserted");
        fabric_error=0;apb(1,'h30,8,1,0,0);check(!irq,"fatal deassert then clear");
        lease_error=1;apb(0,'h0c,0,0,0,95);lease_error=0;apb(1,'h30,15,1,0,0);
        read_outstanding=6;write_outstanding=4;dropped_captures=7;retired_pairs=3;
        apb(0,'h2c,0,0,0,'h0604);apb(0,'h1c,0,0,0,7);apb(0,'h40,0,0,0,3);
        apb(0,'h10,0,0,0,1);apb(0,'h14,0,0,0,1234);apb(0,'h18,0,0,0,9);
        @(negedge clk);rst=1;repeat(2)@(negedge clk);rst=0;#1;
        check(!enabled&&!irq&&capture_count==0&&nn_count==0&&display_count==0&&underflow_count==0,"reset all software state");
        $display("C1_R2_VIDEO_CSR_PASS checks=%0d masked_writes=1 reserved_reject=1 irq_set_wins=1 disabled_completion=1 reset=1",checks);$finish;
    end
    initial begin repeat(2000)@(posedge clk);$fatal(1,"video CSR watchdog");end
endmodule
