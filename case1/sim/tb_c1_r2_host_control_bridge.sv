`timescale 1ns/1ps
module tb_c1_r2_host_control_bridge;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,psel=0,penable=0,pwrite=0;
    reg [15:0] paddr=0;reg [31:0] pwdata=0;
    wire [31:0] prdata;wire pready,pslverr,irq;
    reg cpu_adapter_busy=0,cpu_adapter_fault=0;
    wire core_psel,core_penable,core_pwrite,core_pready,core_pslverr,core_irq;
    wire [7:0] core_paddr;wire [31:0] core_pwdata,core_prdata;wire [3:0] core_pstrb;
    wire enabled;wire [2:0] request_enable;
    reg platform_ready=0,fabric_error=0,lease_error=0,cap_active=0,nn_active=0,display_active=0,front_valid=0;
    reg cap_event=0,cap_bad=0,nn_event=0,nn_bad=0,display_event=0,display_bad=0,overflow_event=0,underflow_event=0;
    reg [31:0] nn_cycles=0,nn_tag=0,dropped_captures=0,retired_pairs=0;
    reg [7:0] read_outstanding=0,write_outstanding=0;
    wire [31:0] capture_count,nn_count,display_count,underflow_count,last_nn_cycles,last_nn_tag;
    c1_r2_host_control_bridge bridge(.*);
    c1_r2_video_rgbx_csr csr (
        .psel(core_psel),.penable(core_penable),.pwrite(core_pwrite),.paddr(core_paddr),
        .pwdata(core_pwdata),.pstrb(core_pstrb),.prdata(core_prdata),.pready(core_pready),.pslverr(core_pslverr),.irq(core_irq),.*
    );
    integer checks=0,accesses=0,rejects=0;
    task check(input bit ok,input string why);
        begin if(!ok)$fatal(1,"host control: %s",why);checks=checks+1;end
    endtask
    task apb(input bit wr,input [15:0] addr,input [31:0] data,input bit error_expected,input [31:0] expected);
        begin
            @(negedge clk);psel=1;penable=0;pwrite=wr;paddr=addr;pwdata=data;#1;
            check(pready&&!pslverr,"setup has no access error");
            check(core_psel===(addr[15:8]==0),"upper address cannot alias core");
            if(core_psel)check(core_paddr==addr[7:0]&&core_pwdata==data&&core_pstrb==(wr?15:0),"exact APB3 full-word conversion");
            @(negedge clk);penable=1;#1;
            check(pready&&pslverr===error_expected,"access response");
            if(!wr&&!error_expected)check(prdata===expected,"read data");
            @(negedge clk);psel=0;penable=0;#1;
            check(!pslverr&&!core_psel,"idle no side effects/error");
            accesses=accesses+1;if(error_expected)rejects=rejects+1;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);check(!pready&&!irq&&!core_psel,"reset gates host");rst=0;
        apb(0,'h0000,0,0,'h52325632);apb(0,'h0004,0,0,'h10000);
        apb(0,'h0100,0,0,'h52324831);apb(0,'h0104,0,0,'h10000);apb(0,'h0108,0,0,0);
        apb(1,'h0100,15,1,0);apb(1,'h0104,15,1,0);apb(1,'h0108,15,1,0);
        apb(0,'h0101,0,1,0);apb(0,'h010c,0,1,0);apb(0,'hffff,0,1,0);
        apb(0,'h0009,0,1,0);apb(1,'h0000,0,1,0);apb(1,'h0008,16,1,0);
        check(!enabled,"invalid accesses never enabled core");
        // Holding SETUP is not a transfer, even with the full-word strobe.
        @(negedge clk);psel=1;penable=0;pwrite=1;paddr=8;pwdata=15;
        repeat(4)begin @(negedge clk);#1;check(!enabled&&!pslverr,"held setup does not write");end
        penable=1;@(negedge clk);psel=0;penable=0;#1;check(enabled&&request_enable==7,"one accepted control write");
        accesses=accesses+1;
        for(integer page=2;page<256;page=page+1)begin
            apb(1,(page<<8)|8,0,1,0);check(enabled&&request_enable==7,"high-page write cannot disable core");
            apb(0,(page<<8)|'h34,0,1,0);
        end
        apb(1,'h0108,0,1,0);check(enabled&&request_enable==7,"status-page write cannot alias control");
        apb(1,'h0134,15,1,0);apb(0,'h0034,0,0,0);
        apb(1,'h0008,0,0,0);
        @(negedge clk);nn_event=1;nn_tag=19;nn_cycles=12345;
        @(negedge clk);nn_event=0;#1;check(!enabled&&!core_irq&&!irq,"masked completion while disabled");
        apb(0,'h0010,0,0,1);apb(0,'h0018,0,0,19);apb(0,'h0014,0,0,12345);
        apb(0,'h0030,0,0,1);apb(1,'h0034,1,0,0);#1;check(core_irq&&irq,"late unmask reaches scalar IRQ");
        cpu_adapter_busy=1;cpu_adapter_fault=1;#1;apb(0,'h0108,0,0,7);
        apb(1,'h0030,15,0,0);#1;check(!core_irq&&irq,"core W1C cannot clear CPU reset-required fault");
        apb(1,'h0034,0,0,0);apb(1,'h0108,0,1,0);check(irq,"CPU fault is not maskable through core IRQ registers");
        apb(0,'h0108,0,0,3);
        cpu_adapter_fault=0;#1;check(!irq,"fault level removed");apb(0,'h0108,0,0,1);
        cpu_adapter_busy=0;
        // Back-to-back APB transfers retain PSEL, with a new SETUP cycle.
        @(negedge clk);psel=1;penable=0;pwrite=1;paddr='h34;pwdata=1;
        @(negedge clk);penable=1;@(negedge clk);penable=0;paddr='h30;pwdata=1;
        @(negedge clk);penable=1;nn_event=1;
        @(negedge clk);penable=0;psel=0;nn_event=0;#1;accesses=accesses+2;
        check(irq,"event set wins over simultaneous W1C through bridge");
        apb(1,'h0030,1,0,0);check(!irq,"clear deasserted event");
        @(negedge clk);psel=1;penable=0;pwrite=1;paddr=8;pwdata=15;rst=1;cpu_adapter_fault=1;#1;
        check(!pready&&!irq&&!core_psel&&!pslverr,"reset aborts setup and gates fatal IRQ");
        repeat(2)@(negedge clk);psel=0;rst=0;cpu_adapter_fault=0;#1;
        check(!enabled&&!irq&&nn_count==0,"coordinated reset clears core state");
        $display("C1_R2_HOST_CONTROL_PASS checks=%0d accesses=%0d rejects=%0d upper_pages=254 actual_csr=1 full_word_apb3=1 irq_union=1 cpu_fault_level_input=1 set_wins=1 reset=1",checks,accesses,rejects);
        $finish;
    end
    initial begin repeat(10000)@(posedge clk);$fatal(1,"host control watchdog");end
endmodule
