`timescale 1ns/1ps

module tb_c1_apb_r1_mux;

    localparam integer TARGET_CSR     = 0;
    localparam integer TARGET_ISP     = 1;
    localparam integer TARGET_INVALID = 2;

    logic clk = 1'b0;

    logic psel = 1'b0;
    logic penable = 1'b0;
    logic pwrite = 1'b0;
    logic [11:0] paddr = 12'd0;
    logic [31:0] pwdata = 32'd0;
    logic [3:0] pstrb = 4'd0;
    logic [31:0] prdata;
    logic pready;
    logic pslverr;

    logic csr_psel;
    logic csr_penable;
    logic csr_pwrite;
    logic [11:0] csr_paddr;
    logic [31:0] csr_pwdata;
    logic [3:0] csr_pstrb;
    logic [31:0] csr_prdata = 32'd0;
    logic csr_pready = 1'b1;
    logic csr_pslverr = 1'b0;

    logic isp_psel;
    logic isp_penable;
    logic isp_pwrite;
    logic [11:0] isp_paddr;
    logic [31:0] isp_pwdata;
    logic [3:0] isp_pstrb;
    logic [31:0] isp_prdata = 32'd0;
    logic isp_pready = 1'b1;
    logic isp_pslverr = 1'b0;

    integer setup_count = 0;
    integer completion_count = 0;
    integer csr_completion_count = 0;
    integer isp_completion_count = 0;
    integer invalid_completion_count = 0;
    integer downstream_error_count = 0;
    integer wait_cycle_count = 0;
    integer read_count = 0;
    integer write_count = 0;
    integer back_to_back_count = 0;
    integer randomized_count = 0;
    integer random_index;
    integer random_target;
    logic [11:0] random_address;
    logic random_error;
    integer random_wait;

    always #5 clk = ~clk;

    c1_apb_r1_mux dut (.*);

    function automatic integer decode_target(input logic [11:0] address);
        begin
            if (address <= 12'h1ff)
                decode_target = TARGET_CSR;
            else if (address <= 12'h2ff)
                decode_target = TARGET_ISP;
            else
                decode_target = TARGET_INVALID;
        end
    endfunction

    function automatic logic [31:0] response_data(
        input integer target,
        input logic [11:0] address
    );
        begin
            case (target)
                TARGET_CSR: response_data = 32'hc500_0000 |
                                            {20'd0, address};
                TARGET_ISP: response_data = 32'h1a50_0000 |
                                            {20'd0, address};
                default:    response_data = 32'd0;
            endcase
        end
    endfunction

    task automatic set_selected_response(
        input integer target,
        input logic [31:0] data_value,
        input logic ready_value,
        input logic error_value,
        input logic [31:0] poison_value
    );
        begin
            case (target)
                TARGET_CSR: begin
                    csr_prdata = data_value;
                    csr_pready = ready_value;
                    csr_pslverr = error_value;
                    isp_prdata = poison_value;
                    isp_pready = !ready_value;
                    isp_pslverr = !error_value;
                end
                TARGET_ISP: begin
                    isp_prdata = data_value;
                    isp_pready = ready_value;
                    isp_pslverr = error_value;
                    csr_prdata = poison_value;
                    csr_pready = !ready_value;
                    csr_pslverr = !error_value;
                end
                default: begin
                    csr_prdata = poison_value;
                    csr_pready = 1'b0;
                    csr_pslverr = 1'b1;
                    isp_prdata = ~poison_value;
                    isp_pready = 1'b0;
                    isp_pslverr = 1'b1;
                end
            endcase
        end
    endtask

    task automatic apb_transfer(
        input logic [11:0] address,
        input logic write_value,
        input logic [31:0] write_data,
        input logic [3:0] write_strobes,
        input integer wait_cycles,
        input logic child_error
    );
        integer target;
        integer wait_index;
        logic [31:0] expected_data;
        logic expected_error;
        begin
            target = decode_target(address);
            expected_data = response_data(target, address);
            expected_error = (target == TARGET_INVALID) || child_error;

            @(negedge clk);
            psel = 1'b1;
            penable = 1'b0;
            pwrite = write_value;
            paddr = address;
            pwdata = write_data;
            pstrb = write_strobes;
            set_selected_response(target, expected_data,
                                  (wait_cycles == 0), child_error,
                                  32'hdead_0000 ^ {20'd0, address});
            #1;
            if (pslverr ||
                ((target == TARGET_CSR) && (!csr_psel || isp_psel)) ||
                ((target == TARGET_ISP) && (!isp_psel || csr_psel)) ||
                ((target == TARGET_INVALID) && (csr_psel || isp_psel))) begin
                $fatal(1, "setup decode/error mismatch addr=%03x", address);
            end

            @(negedge clk);
            penable = 1'b1;

            for (wait_index = 0; wait_index < wait_cycles;
                 wait_index = wait_index + 1) begin
                set_selected_response(target, expected_data, 1'b0, 1'b1,
                                      32'hbad0_0000 ^ wait_index);
                @(posedge clk);
                #1;
                if (target == TARGET_INVALID) begin
                    $fatal(1, "locally-invalid transfer unexpectedly waited");
                end
                if (pready || pslverr || (prdata !== expected_data)) begin
                    $fatal(1, "wait-state routing mismatch addr=%03x cycle=%0d",
                           address, wait_index);
                end
                @(negedge clk);
            end

            set_selected_response(target, expected_data, 1'b1, child_error,
                                  32'hfeed_0000 ^ {20'd0, address});
            @(posedge clk);
            #1;
            if (!pready || (pslverr !== expected_error) ||
                (prdata !== expected_data)) begin
                $fatal(1, "completion response mismatch addr=%03x data=%08x/%08x err=%0b/%0b",
                       address, prdata, expected_data,
                       pslverr, expected_error);
            end

            @(negedge clk);
            psel = 1'b0;
            penable = 1'b0;
            pwrite = 1'b0;
            paddr = 12'd0;
            pwdata = 32'd0;
            pstrb = 4'd0;
            csr_pready = 1'b1;
            csr_pslverr = 1'b0;
            isp_pready = 1'b1;
            isp_pslverr = 1'b0;
        end
    endtask

    task automatic back_to_back_cross_window;
        logic [31:0] first_data;
        logic [31:0] second_data;
        begin
            first_data = response_data(TARGET_CSR, 12'h004);
            second_data = response_data(TARGET_ISP, 12'h204);

            @(negedge clk);
            psel = 1'b1;
            penable = 1'b0;
            pwrite = 1'b0;
            paddr = 12'h004;
            pwdata = 32'd0;
            pstrb = 4'd0;
            set_selected_response(TARGET_CSR, first_data, 1'b1, 1'b0,
                                  32'h1111_1111);
            @(negedge clk);
            penable = 1'b1;
            @(posedge clk);
            #1;
            if (!pready || pslverr || prdata !== first_data ||
                !csr_psel || isp_psel)
                $fatal(1, "first back-to-back response mismatch");

            // APB returns to setup without dropping PSEL.  The new address
            // must select only ISP immediately and must not leak CSR response.
            @(negedge clk);
            penable = 1'b0;
            paddr = 12'h204;
            set_selected_response(TARGET_ISP, second_data, 1'b1, 1'b0,
                                  32'h2222_2222);
            #1;
            if (!isp_psel || csr_psel || pslverr || prdata !== second_data)
                $fatal(1, "cross-window back-to-back setup mismatch");
            @(negedge clk);
            penable = 1'b1;
            @(posedge clk);
            #1;
            if (!pready || pslverr || prdata !== second_data ||
                !isp_psel || csr_psel)
                $fatal(1, "second back-to-back response mismatch");

            @(negedge clk);
            psel = 1'b0;
            penable = 1'b0;
            paddr = 12'd0;
            back_to_back_count = back_to_back_count + 1;
        end
    endtask

    // Structural/protocol monitor.  The full payload is required to fan out
    // unchanged even though only one PSEL may ever be active.
    always @(posedge clk) begin
        if (csr_psel && isp_psel)
            $fatal(1, "APB mux selected both slaves");
        if ((csr_penable !== penable) || (isp_penable !== penable) ||
            (csr_pwrite !== pwrite) || (isp_pwrite !== pwrite) ||
            (csr_paddr !== paddr) || (isp_paddr !== paddr) ||
            (csr_pwdata !== pwdata) || (isp_pwdata !== pwdata) ||
            (csr_pstrb !== pstrb) || (isp_pstrb !== pstrb)) begin
            $fatal(1, "APB request payload fan-out mismatch");
        end
        if (psel) begin
            case (decode_target(paddr))
                TARGET_CSR:
                    if (!csr_psel || isp_psel)
                        $fatal(1, "CSR window selected incorrectly");
                TARGET_ISP:
                    if (!isp_psel || csr_psel)
                        $fatal(1, "ISP window selected incorrectly");
                default:
                    if (csr_psel || isp_psel)
                        $fatal(1, "unmapped address selected a slave");
            endcase
        end else if (csr_psel || isp_psel) begin
            $fatal(1, "slave selected while upstream PSEL was low");
        end

        if (pslverr && !(psel && penable && pready))
            $fatal(1, "PSLVERR escaped outside a completing access");

        if (psel && !penable)
            setup_count = setup_count + 1;
        if (psel && penable && !pready)
            wait_cycle_count = wait_cycle_count + 1;
        if (psel && penable && pready) begin
            completion_count = completion_count + 1;
            if (pwrite)
                write_count = write_count + 1;
            else
                read_count = read_count + 1;
            case (decode_target(paddr))
                TARGET_CSR: begin
                    csr_completion_count = csr_completion_count + 1;
                    if (pslverr)
                        downstream_error_count = downstream_error_count + 1;
                end
                TARGET_ISP: begin
                    isp_completion_count = isp_completion_count + 1;
                    if (pslverr)
                        downstream_error_count = downstream_error_count + 1;
                end
                default:
                    invalid_completion_count = invalid_completion_count + 1;
            endcase
        end
    end

    initial begin
        // Idle response is independent of arbitrary downstream values.
        repeat (3) @(posedge clk);
        @(negedge clk);
        csr_prdata = 32'hffff_ffff;
        csr_pready = 1'b0;
        csr_pslverr = 1'b1;
        isp_prdata = 32'haaaa_5555;
        isp_pready = 1'b0;
        isp_pslverr = 1'b1;
        #1;
        if (prdata !== 32'd0 || !pready || pslverr || csr_psel || isp_psel)
            $fatal(1, "idle response was not deterministic");

        // Exact window boundaries.
        apb_transfer(12'h000, 1'b0, 32'd0, 4'd0, 0, 1'b0);
        apb_transfer(12'h1ff, 1'b1, 32'h0123_4567, 4'b0101, 0, 1'b0);
        apb_transfer(12'h200, 1'b0, 32'd0, 4'd0, 0, 1'b0);
        apb_transfer(12'h2ff, 1'b1, 32'h89ab_cdef, 4'b1010, 0, 1'b0);

        // Register holes and unaligned words remain within their owner window;
        // selected-slave PSLVERR must be preserved precisely.
        apb_transfer(12'h180, 1'b0, 32'd0, 4'd0, 0, 1'b1);
        apb_transfer(12'h20c, 1'b1, 32'h55aa_aa55, 4'hf, 0, 1'b1);
        apb_transfer(12'h011, 1'b0, 32'd0, 4'd0, 0, 1'b1);
        apb_transfer(12'h211, 1'b1, 32'hf0f0_0f0f, 4'hf, 0, 1'b1);

        // Wait-state propagation and PSLVERR suppression until PREADY.
        apb_transfer(12'h104, 1'b0, 32'd0, 4'd0, 7, 1'b0);
        apb_transfer(12'h264, 1'b1, 32'h0000_00a6, 4'b0001, 5, 1'b0);
        apb_transfer(12'h108, 1'b0, 32'd0, 4'd0, 3, 1'b1);
        apb_transfer(12'h26c, 1'b0, 32'd0, 4'd0, 4, 1'b1);

        // Locally-unmapped addresses complete in one access irrespective of
        // poisoned downstream PREADY/PSLVERR/data.
        apb_transfer(12'h300, 1'b0, 32'd0, 4'd0, 0, 1'b0);
        apb_transfer(12'h7a5, 1'b1, 32'h1357_9bdf, 4'hf, 0, 1'b0);
        apb_transfer(12'hfff, 1'b0, 32'd0, 4'd0, 0, 1'b0);

        back_to_back_cross_window();

        // Deterministic pseudo-random sweep of both windows and the unmapped
        // region with mixed reads/writes, child errors and wait lengths.
        for (random_index = 0; random_index < 96;
             random_index = random_index + 1) begin
            case (random_index % 5)
                0, 3: begin
                    random_target = TARGET_CSR;
                    random_address = ((random_index * 37) & 12'h1fc);
                end
                1, 4: begin
                    random_target = TARGET_ISP;
                    random_address = 12'h200 |
                                     ((random_index * 53) & 12'h0fc);
                end
                default: begin
                    random_target = TARGET_INVALID;
                    random_address = 12'h300 |
                                     ((random_index * 71) & 12'hcff);
                end
            endcase
            random_error = (random_target != TARGET_INVALID) &&
                           ((random_index % 13) == 0);
            random_wait = (random_target == TARGET_INVALID) ? 0 :
                          (random_index % 4);
            apb_transfer(random_address, random_index[0],
                         32'h9e37_79b9 ^ random_index,
                         4'b0001 << (random_index & 3),
                         random_wait, random_error);
            randomized_count = randomized_count + 1;
        end

        repeat (6) @(posedge clk);
        if (psel || penable || csr_psel || isp_psel || pslverr)
            $fatal(1, "APB mux regression ended with active bus state");
        if ((completion_count != 113) || (setup_count != 113) ||
            (csr_completion_count == 0) || (isp_completion_count == 0) ||
            (invalid_completion_count == 0) ||
            (downstream_error_count < 8) || (wait_cycle_count < 100) ||
            (read_count == 0) || (write_count == 0) ||
            (back_to_back_count != 1) || (randomized_count != 96)) begin
            $fatal(1, "APB mux coverage mismatch setup=%0d complete=%0d csr=%0d isp=%0d invalid=%0d errors=%0d waits=%0d reads=%0d writes=%0d",
                   setup_count, completion_count, csr_completion_count,
                   isp_completion_count, invalid_completion_count,
                   downstream_error_count, wait_cycle_count,
                   read_count, write_count);
        end

        $display("C1_APB_R1_MUX_PASS transfers=%0d csr=%0d isp=%0d invalid=%0d downstream_errors=%0d waits=%0d randomized=%0d",
                 completion_count, csr_completion_count,
                 isp_completion_count, invalid_completion_count,
                 downstream_error_count, wait_cycle_count,
                 randomized_count);
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "global APB mux testbench timeout");
    end

endmodule
