`timescale 1ns/1ps
// Exhaustive five-bit interrupt-event/W1C collision matrix, no forced state.
module tb_c1_apb_irq_events;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    logic psel=0,penable=0,pwrite=0;
    logic [11:0] paddr=0;
    logic [31:0] pwdata=0;
    logic [3:0] pstrb=0;
    logic [4:0] events=0;
    logic [7:0] error_code=0;
    logic [31:0] error_address=0;
    wire [31:0] prdata;
    wire pready,pslverr,irq;
    wire clear_stats;
    logic [31:0] sequence_before;
    logic [31:0] seq_a,seq_b,snapshot_code,snapshot_address;
    c1_apb_csr dut (
        .clk(clk),.rst_n(rst_n),.psel(psel),.penable(penable),.pwrite(pwrite),
        .paddr(paddr),.pwdata(pwdata),.pstrb(pstrb),
        .prdata(prdata),.pready(pready),.pslverr(pslverr),.irq(irq),
        .clear_stats_pulse(clear_stats),
        .busy(1'b0),.done_event(events[0]),.error_event(events[1]),
        .capture_drop_event(events[2]),.display_swap_event(events[3]),
        .display_underflow_event(events[4]),
        .error_code_in(error_code),.error_address_in(error_address)
    );
    task automatic write_event(input logic[11:0] addr,input logic[31:0] value,
                               input logic[4:0] ev,input logic[3:0] strobe=15,input bit expect_error=0);
        @(negedge clk);psel=1;penable=0;pwrite=1;paddr=addr;pwdata=value;pstrb=strobe;
        @(negedge clk);penable=1;events=ev;
        @(posedge clk);if(!pready || pslverr!==expect_error) $fatal(1,"IRQ test APB transfer failed");
        @(negedge clk);psel=0;penable=0;pwrite=0;events=0;
    endtask
    task automatic check_status(input logic[4:0] expected,input logic[4:0] enabled);
        paddr=12'h01c;
        #1;if(prdata!=={27'd0,expected} || irq!==|(expected & enabled))
            $fatal(1,"IRQ collision mismatch expected=%h actual=%h irq=%b",expected,prdata,irq);
    endtask
    task automatic read_event(input logic[11:0] addr,output logic[31:0] value,input bit new_error=0);
        @(negedge clk);psel=1;penable=0;pwrite=0;paddr=addr;pstrb=0;
        @(negedge clk);penable=1;events=new_error ? 5'b00010 : 0;
        @(posedge clk);
        if(!pready || pslverr) $fatal(1,"snapshot APB read failed");
        value=prdata; // sample before the same-edge error register updates
        @(negedge clk);psel=0;penable=0;events=0;
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(integer mask=0;mask<32;mask++) begin
            write_event(12'h018,mask,0);
            for(integer ev=0;ev<32;ev++) begin
                error_code=8'h46;error_address=32'h12345670;
                write_event(12'h01c,0,31); // set every pending bit
                write_event(12'h01c,mask,ev);
                check_status((5'h1f & ~mask[4:0]) | ev[4:0],mask[4:0]);
            end
        end
        write_event(12'h018,31,0);
        write_event(12'h01c,0,31);
        write_event(12'h01c,31,0,4'he); // byte 0 disabled: no clear
        check_status(31,31);
        write_event(12'h01c,31,0);
        check_status(0,31);
        paddr=12'h020;#1;if(prdata!==32'h46) $fatal(1,"W1C erased error code");
        paddr=12'h024;#1;if(prdata!==32'h12345670) $fatal(1,"W1C erased error address");
        // Statistics clear defines a new counter interval; coincident done
        // does not count in it, but its interrupt must remain observable.
        write_event(12'h010,32'h20,1);
        if(!clear_stats) $fatal(1,"clear-stats command pulse missing");
        paddr=12'h100;#1;if(prdata!==0) $fatal(1,"statistics reset priority changed");
        check_status(1,31);
        paddr=12'h028;#1;sequence_before=prdata;
        // Two errors share a code but have different addresses; the sequence
        // must reveal a torn software read even when code comparison cannot.
        error_code=8'h46;error_address=32'h1110;
        write_event(12'h01c,2,2);
        paddr=12'h028;#1;if(prdata!==sequence_before+1) $fatal(1,"error sequence did not advance");
        error_address=32'h2220;
        write_event(12'h01c,2,2);
        paddr=12'h028;#1;if(prdata!==sequence_before+2) $fatal(1,"same-code error lost sequence update");
        write_event(12'h010,32'h20,0);
        write_event(12'h01c,31,0);
        paddr=12'h028;#1;if(prdata!==sequence_before+2) $fatal(1,"software clear erased error sequence");
        write_event(12'h028,32'hdeadbeef,0,15,1);
        paddr=12'h028;#1;if(prdata!==sequence_before+2) $fatal(1,"read-only sequence was modified");
        for(integer same_code=0;same_code<2;same_code++) begin
            for(integer phase=0;phase<4;phase++) begin
                error_code=8'h11;error_address=32'h1110;
                write_event(12'h01c,0,2);
                error_code=same_code ? 8'h11 : 8'h22;error_address=32'h2220;
                read_event(12'h028,seq_a,phase==0);
                read_event(12'h020,snapshot_code,phase==1);
                read_event(12'h024,snapshot_address,phase==2);
                read_event(12'h028,seq_b,phase==3);
                if(phase<3) begin
                    if(seq_a==seq_b) $fatal(1,"snapshot failed to detect interleaved error phase=%0d",phase);
                end else if(seq_a!=seq_b || snapshot_code!=32'h11 || snapshot_address!=32'h1110)
                    $fatal(1,"final-read collision did not preserve coherent pre-edge snapshot");
                read_event(12'h028,seq_a);
                read_event(12'h020,snapshot_code);
                read_event(12'h024,snapshot_address);
                read_event(12'h028,seq_b);
                if(seq_a!=seq_b || snapshot_code!=(same_code ? 32'h11 : 32'h22) || snapshot_address!=32'h2220)
                    $fatal(1,"stable snapshot retry failed");
            end
        end
        $display("C1_APB_ERROR_SNAPSHOT_PASS phases=4 same_code_modes=2 retry_coherent=1 final_read_linearized=1");
        @(negedge clk);rst_n=0;
        @(negedge clk);check_status(0,0);
        paddr=12'h028;#1;if(prdata!==0) $fatal(1,"reset did not clear error sequence");
        $display("C1_APB_IRQ_EVENTS_PASS combinations=1024 event_wins=1 byte_mask=1 diagnostics_retained=1 stats_clear_keeps_irq=1 error_sequence=1");
        $finish;
    end
    initial begin #200000;$fatal(1,"IRQ event matrix timeout");end
endmodule
