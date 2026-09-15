`timescale 1ns/1ps

// Three-input/two-output frame ownership manager.
//
// The module contains real synthesizable allocation and ownership logic, but
// it does not know physical frame-buffer addresses.  Software/DMA logic maps
// the returned indices through the buffer tables programmed in c1_apb_csr.
// Integration contract: distinct live slots must map to non-overlapping
// physical storage. Preserving IN/OUT_DISPLAY does not detect table aliases.
// abort releases non-display bookkeeping immediately, not external AXI work;
// the parent must fence new capture/NN admission until canceled DMAs drain.
module c1_frame_manager (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        abort,
    input  wire        drop_oldest_mode,

    // Capture side. cap_frame_start is a one-cycle allocation request that must
    // precede the first stored pixel by one core cycle.  An ingress FIFO must
    // hold SOF/data until cap_accept_pulse.  If accepted, the returned input
    // index remains owned by capture until cap_frame_done.
    input  wire        cap_frame_start,
    input  wire        cap_frame_done,
    output reg         cap_accept_pulse,
    output reg         cap_drop_pulse,
    output reg  [1:0]  cap_input_index,
    output reg  [31:0] cap_frame_id,

    // CNN side. nn_job_request may be held high until nn_job_grant pulses.
    input  wire        nn_job_request,
    input  wire        nn_done,
    output reg         nn_job_grant,
    output reg  [1:0]  nn_input_index,
    output reg         nn_output_index,
    output reg  [31:0] nn_frame_id,

    // Display changes buffers only on display_vsync.  The swap outputs identify
    // a complete, frame-ID-matched original/processed pair.
    input  wire        display_vsync,
    output reg         display_swap_pulse,
    output reg  [1:0]  display_input_index,
    output reg         display_output_index,
    output reg  [31:0] display_frame_id,
    output reg         display_active,

    output reg  [2:0]  input_ready_count,
    output reg  [1:0]  output_ready_count,
    output wire        capture_active_out,
    output wire        nn_active_out,
    output reg  [31:0] dropped_frame_count,
    // Logical ownership only; abort may release this before DMA drain.
    output wire [2:0] input_owned_mask,
    output wire [1:0] output_owned_mask
);

    localparam [2:0] IN_FREE          = 3'd0;
    localparam [2:0] IN_CAPTURING     = 3'd1;
    localparam [2:0] IN_READY_NN      = 3'd2;
    localparam [2:0] IN_PROCESSING    = 3'd3;
    localparam [2:0] IN_READY_DISPLAY = 3'd4;
    localparam [2:0] IN_DISPLAY       = 3'd5;

    localparam [1:0] OUT_FREE          = 2'd0;
    localparam [1:0] OUT_PROCESSING    = 2'd1;
    localparam [1:0] OUT_READY_DISPLAY = 2'd2;
    localparam [1:0] OUT_DISPLAY       = 2'd3;

    reg [2:0]  input_state [0:2];
    assign input_owned_mask = {input_state[2]!=IN_FREE,
                               input_state[1]!=IN_FREE,input_state[0]!=IN_FREE};
    reg [31:0] input_frame_id [0:2];
    reg [1:0]  output_state [0:1];
    assign output_owned_mask={output_state[1]!=OUT_FREE,output_state[0]!=OUT_FREE};
    reg [31:0] output_frame_id [0:1];
    reg [1:0]  output_source_index [0:1];

    reg capture_active;
    reg nn_active;
    reg [31:0] next_frame_id;

    reg in_free_found;
    reg [1:0] in_free_index;
    reg in_ready_found;
    reg [1:0] in_ready_index;
    reg out_free_found;
    reg out_free_index;
    reg out_ready_found;
    reg out_ready_index;

    // READY slots are produced and consumed in frame order because capture and
    // CNN execution are both single-owner pipelines.  Keeping that order in
    // tiny FIFOs avoids re-discovering it every cycle with cascaded 32-bit
    // frame-ID comparisons.
    reg [1:0] input_ready_q0;
    reg [1:0] input_ready_q1;
    reg [1:0] input_ready_q2;
    reg [1:0] input_ready_q_count;
    reg       output_ready_q0;
    reg       output_ready_q1;
    reg [1:0] output_ready_q_count;

    wire nn_grant_possible = nn_job_request && !nn_active &&
                             in_ready_found && out_free_found;

    wire input_ready_recycle = cap_frame_start && !capture_active &&
                               !in_free_found && drop_oldest_mode &&
                               in_ready_found && !nn_grant_possible;
    wire input_ready_push = cap_frame_done && capture_active;
    wire input_ready_pop  = nn_grant_possible || input_ready_recycle;
    wire output_ready_push = nn_done && nn_active;
    wire output_ready_pop  = display_vsync && out_ready_found;

    integer reset_index;

    assign capture_active_out = capture_active;
    assign nn_active_out      = nn_active;

    // Free-slot selection remains a small fixed-priority search.  READY-slot
    // selection comes directly from the queue head, so state changes no longer
    // feed two cascaded 32-bit oldest-frame comparisons.
    always @* begin
        in_free_found = 1'b1;
        in_free_index = 2'd0;
        if (input_state[0] == IN_FREE) begin
            in_free_index = 2'd0;
        end else if (input_state[1] == IN_FREE) begin
            in_free_index = 2'd1;
        end else if (input_state[2] == IN_FREE) begin
            in_free_index = 2'd2;
        end else begin
            in_free_found = 1'b0;
        end

        in_ready_found    = (input_ready_q_count != 2'd0);
        in_ready_index    = input_ready_q0;
        input_ready_count = {1'b0, input_ready_q_count};

        out_free_found = 1'b1;
        out_free_index = 1'b0;
        if (output_state[0] == OUT_FREE) begin
            out_free_index = 1'b0;
        end else if (output_state[1] == OUT_FREE) begin
            out_free_index = 1'b1;
        end else begin
            out_free_found = 1'b0;
        end

        out_ready_found    = (output_ready_q_count != 2'd0);
        out_ready_index    = output_ready_q0;
        output_ready_count = output_ready_q_count;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (reset_index = 0; reset_index < 3; reset_index = reset_index + 1) begin
                input_state[reset_index]    <= IN_FREE;
                input_frame_id[reset_index] <= 32'd0;
            end
            for (reset_index = 0; reset_index < 2; reset_index = reset_index + 1) begin
                output_state[reset_index]        <= OUT_FREE;
                output_frame_id[reset_index]     <= 32'd0;
                output_source_index[reset_index] <= 2'd0;
            end
            capture_active      <= 1'b0;
            nn_active           <= 1'b0;
            next_frame_id       <= 32'd0;
            input_ready_q0      <= 2'd0;
            input_ready_q1      <= 2'd0;
            input_ready_q2      <= 2'd0;
            input_ready_q_count <= 2'd0;
            output_ready_q0      <= 1'b0;
            output_ready_q1      <= 1'b0;
            output_ready_q_count <= 2'd0;
            cap_accept_pulse    <= 1'b0;
            cap_drop_pulse      <= 1'b0;
            cap_input_index     <= 2'd0;
            cap_frame_id        <= 32'd0;
            nn_job_grant        <= 1'b0;
            nn_input_index      <= 2'd0;
            nn_output_index     <= 1'b0;
            nn_frame_id         <= 32'd0;
            display_swap_pulse  <= 1'b0;
            display_input_index <= 2'd0;
            display_output_index<= 1'b0;
            display_frame_id    <= 32'd0;
            display_active      <= 1'b0;
            dropped_frame_count <= 32'd0;
        end else begin
            cap_accept_pulse   <= 1'b0;
            cap_drop_pulse     <= 1'b0;
            nn_job_grant       <= 1'b0;
            display_swap_pulse <= 1'b0;

            if (abort) begin
                for (reset_index = 0; reset_index < 3; reset_index = reset_index + 1) begin
                    if (input_state[reset_index] != IN_DISPLAY)
                        input_state[reset_index] <= IN_FREE;
                end
                for (reset_index = 0; reset_index < 2; reset_index = reset_index + 1) begin
                    if (output_state[reset_index] != OUT_DISPLAY)
                        output_state[reset_index] <= OUT_FREE;
                end
                capture_active <= 1'b0;
                nn_active      <= 1'b0;
                input_ready_q_count  <= 2'd0;
                output_ready_q_count <= 2'd0;
            end else begin
                // Input READY queue: cap_frame_done appends the completed
                // capture; an NN grant or drop-oldest replacement removes the
                // current head.  Simultaneous pop/push preserves queue depth.
                case ({input_ready_push, input_ready_pop})
                    2'b10: begin
                        case (input_ready_q_count)
                            2'd0: input_ready_q0 <= cap_input_index;
                            2'd1: input_ready_q1 <= cap_input_index;
                            2'd2: input_ready_q2 <= cap_input_index;
                            default: begin end
                        endcase
                        if (input_ready_q_count != 2'd3)
                            input_ready_q_count <= input_ready_q_count + 2'd1;
                    end
                    2'b01: begin
                        input_ready_q0 <= input_ready_q1;
                        input_ready_q1 <= input_ready_q2;
                        if (input_ready_q_count != 2'd0)
                            input_ready_q_count <= input_ready_q_count - 2'd1;
                    end
                    2'b11: begin
                        case (input_ready_q_count)
                            2'd1: input_ready_q0 <= cap_input_index;
                            2'd2: begin
                                input_ready_q0 <= input_ready_q1;
                                input_ready_q1 <= cap_input_index;
                            end
                            2'd3: begin
                                input_ready_q0 <= input_ready_q1;
                                input_ready_q1 <= input_ready_q2;
                                input_ready_q2 <= cap_input_index;
                            end
                            default: begin
                                input_ready_q0      <= cap_input_index;
                                input_ready_q_count <= 2'd1;
                            end
                        endcase
                    end
                    default: begin end
                endcase

                // Output READY queue has the same ownership ordering, with a
                // maximum depth of two.
                case ({output_ready_push, output_ready_pop})
                    2'b10: begin
                        if (output_ready_q_count == 2'd0)
                            output_ready_q0 <= nn_output_index;
                        else if (output_ready_q_count == 2'd1)
                            output_ready_q1 <= nn_output_index;
                        if (output_ready_q_count != 2'd2)
                            output_ready_q_count <= output_ready_q_count + 2'd1;
                    end
                    2'b01: begin
                        output_ready_q0 <= output_ready_q1;
                        if (output_ready_q_count != 2'd0)
                            output_ready_q_count <= output_ready_q_count - 2'd1;
                    end
                    2'b11: begin
                        if (output_ready_q_count == 2'd1) begin
                            output_ready_q0 <= nn_output_index;
                        end else if (output_ready_q_count == 2'd2) begin
                            output_ready_q0 <= output_ready_q1;
                            output_ready_q1 <= nn_output_index;
                        end else begin
                            output_ready_q0      <= nn_output_index;
                            output_ready_q_count <= 2'd1;
                        end
                    end
                    default: begin end
                endcase

                if (cap_frame_start) begin
                    next_frame_id <= next_frame_id + 32'd1;
                    if (capture_active) begin
                        // A second SOF before completion is treated as a whole
                        // frame drop; ownership of the current capture remains.
                        cap_drop_pulse      <= 1'b1;
                        dropped_frame_count <= dropped_frame_count + 32'd1;
                    end else if (in_free_found) begin
                        input_state[in_free_index]    <= IN_CAPTURING;
                        input_frame_id[in_free_index] <= next_frame_id;
                        capture_active               <= 1'b1;
                        cap_accept_pulse              <= 1'b1;
                        cap_input_index               <= in_free_index;
                        cap_frame_id                  <= next_frame_id;
                    end else if (input_ready_recycle) begin
                        // Only READY_NN is recyclable.  Processing and display
                        // buffers are never overwritten.
                        input_state[in_ready_index]    <= IN_CAPTURING;
                        input_frame_id[in_ready_index] <= next_frame_id;
                        capture_active                <= 1'b1;
                        cap_accept_pulse               <= 1'b1;
                        cap_drop_pulse                 <= 1'b1;
                        cap_input_index                <= in_ready_index;
                        cap_frame_id                   <= next_frame_id;
                        dropped_frame_count            <= dropped_frame_count + 32'd1;
                    end else begin
                        cap_drop_pulse      <= 1'b1;
                        dropped_frame_count <= dropped_frame_count + 32'd1;
                    end
                end

                if (cap_frame_done && capture_active) begin
                    input_state[cap_input_index] <= IN_READY_NN;
                    capture_active              <= 1'b0;
                end

                if (nn_grant_possible) begin
                    input_state[in_ready_index]          <= IN_PROCESSING;
                    output_state[out_free_index]         <= OUT_PROCESSING;
                    output_frame_id[out_free_index]      <= input_frame_id[in_ready_index];
                    output_source_index[out_free_index]  <= in_ready_index;
                    nn_active                            <= 1'b1;
                    nn_job_grant                         <= 1'b1;
                    nn_input_index                       <= in_ready_index;
                    nn_output_index                      <= out_free_index;
                    nn_frame_id                          <= input_frame_id[in_ready_index];
                end

                if (nn_done && nn_active) begin
                    input_state[nn_input_index]   <= IN_READY_DISPLAY;
                    output_state[nn_output_index] <= OUT_READY_DISPLAY;
                    nn_active                    <= 1'b0;
                end

                if (display_vsync && out_ready_found) begin
                    if (display_active) begin
                        input_state[display_input_index]   <= IN_FREE;
                        output_state[display_output_index] <= OUT_FREE;
                    end

                    input_state[output_source_index[out_ready_index]] <= IN_DISPLAY;
                    output_state[out_ready_index]                     <= OUT_DISPLAY;
                    display_input_index  <= output_source_index[out_ready_index];
                    display_output_index <= out_ready_index;
                    display_frame_id     <= output_frame_id[out_ready_index];
                    display_active       <= 1'b1;
                    display_swap_pulse   <= 1'b1;
                end
            end
        end
    end

endmodule
