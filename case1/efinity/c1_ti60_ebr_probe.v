// Minimal Efinix RAM inference probe.  It follows the generated FIFO memory
// template (separate write clocked block and two-stage synchronous read) so a
// comparison against c1_ti60_resource_proxy can distinguish an EBR-friendly
// local cache from an accidentally bit-blasted asynchronous implementation.
module c1_ti60_ebr_probe (
    input  wire         wclk,
    input  wire         rclk,
    input  wire         we,
    input  wire         re,
    input  wire [7:0]   waddr,
    input  wire [7:0]   raddr,
    input  wire [127:0] wdata,
    output reg  [127:0] rdata
);
    (* syn_ramstyle = "block_ram", keep = "true" *) reg [127:0] ram [255:0];
    reg [127:0] rdata_1p;

    always @(posedge wclk) begin
        if (we)
            ram[waddr] <= wdata;
    end

    always @(posedge rclk) begin
        if (re)
            rdata_1p <= ram[raddr];
        rdata <= rdata_1p;
    end
endmodule
