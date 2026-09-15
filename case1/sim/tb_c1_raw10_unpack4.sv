`timescale 1ns/1ps

module tb_c1_raw10_unpack4;
    logic [39:0] in_packed40;
    logic [9:0] pixel0, pixel1, pixel2, pixel3;

    c1_raw10_unpack4 dut (.*);

    initial begin
        in_packed40 = 40'h2700aa55ff;
        #1;
        if (pixel0 !== 10'h3ff || pixel1 !== 10'h155 ||
            pixel2 !== 10'h2aa || pixel3 !== 10'h000)
            $fatal(1, "RAW10 unpack mismatch %h %h %h %h",
                   pixel0, pixel1, pixel2, pixel3);
        $display("C1_RAW10_UNPACK_PASS");
        $finish;
    end
endmodule

