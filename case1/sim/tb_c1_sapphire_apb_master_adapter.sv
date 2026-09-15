`timescale 1ns/1ps

module tb_c1_sapphire_apb_master_adapter #(parameter integer SOURCE_WIDTH=16);
    logic clk;
    logic sapphire_psel;
    logic sapphire_penable;
    logic sapphire_pwrite;
    logic [SOURCE_WIDTH-1:0] sapphire_paddr;
    logic slave_ready=1,slave_error=0;
    logic [31:0] sapphire_pwdata;
    wire [31:0] sapphire_prdata;
    wire sapphire_pready;
    wire sapphire_pslverr;

    wire c1_psel;
    wire c1_penable;
    wire c1_pwrite;
    wire [11:0] c1_paddr;
    wire [31:0] c1_pwdata;
    wire [3:0] c1_pstrb;
    logic [31:0] c1_prdata;
    logic c1_pready;
    logic c1_pslverr;

    logic [31:0] last_write_data;
    logic [11:0] last_write_addr;
    logic [3:0] last_write_strb;
    integer write_count;

    wire c1_irq = 1'b0;
    wire [7:0] sapphire_user_interrupt;
    logic irq_test;

    c1_sapphire_apb_master_adapter #(
        .SAPPHIRE_ADDR_W(SOURCE_WIDTH),
        .C1_ADDR_W(12),
        .WRITE_PSTRB(4'hf),
        .REJECT_UPPER_ADDR(1)
    ) dut (
        .sapphire_psel(sapphire_psel),
        .sapphire_penable(sapphire_penable),
        .sapphire_pwrite(sapphire_pwrite),
        .sapphire_paddr(sapphire_paddr),
        .sapphire_pwdata(sapphire_pwdata),
        .sapphire_prdata(sapphire_prdata),
        .sapphire_pready(sapphire_pready),
        .sapphire_pslverr(sapphire_pslverr),
        .c1_psel(c1_psel),
        .c1_penable(c1_penable),
        .c1_pwrite(c1_pwrite),
        .c1_paddr(c1_paddr),
        .c1_pwdata(c1_pwdata),
        .c1_pstrb(c1_pstrb),
        .c1_prdata(c1_prdata),
        .c1_pready(c1_pready),
        .c1_pslverr(c1_pslverr)
    );

    assign c1_prdata = (c1_paddr == 12'h014) ? 32'hC1A0_0001 : 32'h0;
    assign c1_pready = slave_ready;
    assign c1_pslverr = slave_error;

    c1_sapphire_irq_adapter #(
        .USER_INTERRUPT_INDEX(3)
    ) irq_dut (
        .c1_irq(irq_test),
        .sapphire_user_interrupt(sapphire_user_interrupt)
    );

    always #5 clk = ~clk;

    // Plain always is intentional: the compact testbench initializes these
    // scoreboarding variables in the initial block before the clocked checks.
    always @(posedge clk) begin
        if (c1_psel && c1_penable && c1_pwrite && c1_pready) begin
            write_count <= write_count + 1;
            last_write_data <= c1_pwdata;
            last_write_addr <= c1_paddr;
            last_write_strb <= c1_pstrb;
        end
    end

    task automatic apb_transfer(
        input logic [15:0] addr,
        input logic write,
        input logic [31:0] data,
        output logic [31:0] read_data,
        output logic error,
        input integer waits=0,
        input logic inject_error=0
    );
        begin
            @(negedge clk);
            sapphire_psel = 1'b1;
            sapphire_penable = 1'b0;
            sapphire_pwrite = write;
            sapphire_paddr = addr;
            sapphire_pwdata = data;
            slave_ready=(waits==0);
            slave_error=inject_error;
            #1;
            if(sapphire_pslverr) $fatal(1,"adapter exposed error in setup phase");
            if(c1_pstrb !== (write ? 4'hf : 4'h0))
                $fatal(1,"adapter mapped byte strobes incorrectly during transfer");
            @(negedge clk);
            sapphire_penable = 1'b1;
            repeat(waits) begin
                #1;
                if(sapphire_pready || sapphire_pslverr || !c1_psel ||
                   c1_paddr!==12'(addr) || c1_pwdata!==data)
                    $fatal(1,"adapter lost wait-state request or exposed early error");
                @(negedge clk);
            end
            slave_ready=1;
            #1;
            if (!sapphire_pready)
                $fatal(1, "adapter did not complete APB access");
            read_data = sapphire_prdata;
            error = sapphire_pslverr;
            @(negedge clk);
            sapphire_psel = 1'b0;
            sapphire_penable = 1'b0;
            sapphire_pwrite = 1'b0;
            sapphire_paddr = 16'd0;
            sapphire_pwdata = 32'd0;
            slave_error=0;
        end
    endtask

    logic [31:0] read_data;
    logic [31:0] readback_data;
    logic transfer_error;

    initial begin
        clk = 1'b0;
        sapphire_psel = 1'b0;
        sapphire_penable = 1'b0;
        sapphire_pwrite = 1'b0;
        sapphire_paddr = 16'd0;
        sapphire_pwdata = 32'd0;
        last_write_data = 32'd0;
        last_write_addr = 12'd0;
        last_write_strb = 4'd0;
        write_count = 0;
        irq_test = 1'b0;

        #1;
        if (sapphire_user_interrupt !== 8'h00)
            $fatal(1, "IRQ adapter asserted while source was low");
        irq_test = 1'b1;
        #1;
        if (sapphire_user_interrupt !== 8'h08)
            $fatal(1, "IRQ adapter selected wrong Sapphire user input: %h",
                   sapphire_user_interrupt);
        irq_test = 1'b0;

        apb_transfer(16'h0010, 1'b1, 32'hA5A5_5A5A, read_data, transfer_error);
        if (transfer_error || (write_count != 1) ||
            (last_write_addr != 12'h010) ||
            (last_write_data != 32'hA5A5_5A5A) ||
            (last_write_strb != 4'hf))
            $fatal(1, "full-word APB write mapping failed");

        apb_transfer(16'h0014, 1'b0, 32'd0, read_data, transfer_error);
        if (transfer_error || (read_data != 32'hC1A0_0001) ||
            (c1_pstrb != 4'h0))
            $fatal(1, "APB read mapping or read strobe failed");
        readback_data = read_data;

        if(SOURCE_WIDTH>12) begin
            apb_transfer(16'h1010, 1'b1, 32'hDEAD_BEEF, read_data, transfer_error);
            if (!transfer_error || (write_count != 1) || c1_psel)
                $fatal(1, "upper-address rejection failed");
        end

        apb_transfer(16'h0020, 1'b1, 32'h1234_5678, read_data, transfer_error);
        if (transfer_error || (write_count != 2) ||
            (last_write_addr != 12'h020))
            $fatal(1, "adapter did not recover after rejected transfer");

        apb_transfer(16'h0010,1'b1,32'h55667788,read_data,transfer_error,9,0);
        if(transfer_error || write_count!=3 || last_write_data!=32'h55667788)
            $fatal(1,"waited write did not complete exactly once");
        apb_transfer(16'h0014,1'b0,0,read_data,transfer_error,7,1);
        if(!transfer_error || read_data!=32'hC1A0_0001 || write_count!=3)
            $fatal(1,"downstream error response was not propagated");
        apb_transfer(16'h0020,1'b1,32'h10203040,read_data,transfer_error);
        if(transfer_error || write_count!=4) $fatal(1,"downstream error recovery failed");
        $display("C1_SAPPHIRE_APB_ADAPTER_PASS source_width=%0d writes=%0d read=%08h waits=16 upper_error=%0d",
                 SOURCE_WIDTH,write_count,readback_data,SOURCE_WIDTH>12);
        $finish;
    end
endmodule
