`timescale 1ns/1ps

package c1_frame_buffer_pkg;
    localparam int C1_FRAME_BUFFER_ENTRY_BITS = 128;
    localparam int C1_INPUT_BUFFER_COUNT = 3;
    localparam int C1_OUTPUT_BUFFER_COUNT = 2;

    typedef logic [C1_FRAME_BUFFER_ENTRY_BITS-1:0] c1_frame_buffer_entry_t;

    function automatic logic [63:0] c1_fb_base(
        input c1_frame_buffer_entry_t entry
    );
        c1_fb_base = entry[63:0];
    endfunction

    function automatic logic [31:0] c1_fb_stride(
        input c1_frame_buffer_entry_t entry
    );
        c1_fb_stride = entry[95:64];
    endfunction

    function automatic logic [15:0] c1_fb_width(
        input c1_frame_buffer_entry_t entry
    );
        c1_fb_width = entry[111:96];
    endfunction

    function automatic logic [15:0] c1_fb_height(
        input c1_frame_buffer_entry_t entry
    );
        c1_fb_height = entry[127:112];
    endfunction
endpackage

