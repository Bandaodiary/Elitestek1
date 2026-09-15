// One-entry registered response boundary for the frame-buffer table reader.
//
// The FIFO deliberately uses occupancy-only input admission (`!full_q`) so
// the reader never sees a combinational path from soc_control's response_ready
// back through the table/abort logic.  It carries the complete table payload;
// abort clears the buffered response, while c1_axi_read_abort_fence continues
// to drain any AXI R beat that was already committed.
module c1_table_response_elastic_fifo (
    input  logic        clk,
    input  logic        rst,
    input  logic        abort,

    input  logic        in_valid,
    output logic        in_ready,
    input  logic        in_error,
    input  logic [63:0] in_base,
    input  logic [31:0] in_stride,
    input  logic [15:0] in_width,
    input  logic [15:0] in_height,

    output logic        out_valid,
    input  logic        out_ready,
    output logic        out_error,
    output logic [63:0] out_base,
    output logic [31:0] out_stride,
    output logic [15:0] out_width,
    output logic [15:0] out_height
);

    logic full_q;
    logic error_q;
    logic [63:0] base_q;
    logic [31:0] stride_q;
    logic [15:0] width_q;
    logic [15:0] height_q;

    // No fall-through/replacement path: a full entry is held until the
    // consumer accepts it, which is the timing cut this experiment measures.
    always_comb begin
        in_ready  = !full_q;
        out_valid = full_q;
        out_error = error_q;
        out_base  = base_q;
        out_stride = stride_q;
        out_width = width_q;
        out_height = height_q;
    end

    always_ff @(posedge clk) begin
        if (rst || abort) begin
            full_q   <= 1'b0;
            error_q  <= 1'b0;
            base_q   <= 64'd0;
            stride_q <= 32'd0;
            width_q  <= 16'd0;
            height_q <= 16'd0;
        end else begin
            if (out_valid && out_ready)
                full_q <= 1'b0;
            if (in_valid && in_ready) begin
                full_q   <= 1'b1;
                error_q  <= in_error;
                base_q   <= in_base;
                stride_q <= in_stride;
                width_q  <= in_width;
                height_q <= in_height;
            end
        end
    end

`ifndef SYNTHESIS
    // A stalled response must remain bit-stable until it is consumed or
    // explicitly aborted.  This catches accidental fall-through rewiring in
    // the optional top-level experiment.
    logic hold_valid_q;
    logic hold_error_q;
    logic [63:0] hold_base_q;
    logic [31:0] hold_stride_q;
    logic [15:0] hold_width_q, hold_height_q;
    always_ff @(posedge clk) begin
        if (rst || abort) begin
            hold_valid_q <= 1'b0;
        end else begin
            if (out_valid && !out_ready) begin
                if (hold_valid_q &&
                    ((hold_error_q != out_error) ||
                     (hold_base_q != out_base) ||
                     (hold_stride_q != out_stride) ||
                     (hold_width_q != out_width) ||
                     (hold_height_q != out_height)))
                    $fatal(1, "table response FIFO payload changed while stalled");
                hold_valid_q  <= 1'b1;
                hold_error_q  <= out_error;
                hold_base_q   <= out_base;
                hold_stride_q <= out_stride;
                hold_width_q  <= out_width;
                hold_height_q <= out_height;
            end else begin
                hold_valid_q <= 1'b0;
            end
        end
    end
`endif

endmodule
