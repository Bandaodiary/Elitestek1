#ifndef C1_FRAME_BUFFER_H
#define C1_FRAME_BUFFER_H

#include <stdint.h>

enum {
    C1_FRAME_BUFFER_ENTRY_BYTES = 16u,
    C1_INPUT_BUFFER_COUNT = 3u,
    C1_OUTPUT_BUFFER_COUNT = 2u
};

typedef struct {
    uint64_t base_address;
    uint32_t stride_bytes;
    uint16_t width_pixels;
    uint16_t height_lines;
} c1_frame_buffer_entry_t;

#if defined(__STDC_VERSION__) && (__STDC_VERSION__ >= 201112L)
_Static_assert(sizeof(c1_frame_buffer_entry_t) == C1_FRAME_BUFFER_ENTRY_BYTES,
               "c1_frame_buffer_entry_t must be exactly 16 bytes");
#endif

#endif

