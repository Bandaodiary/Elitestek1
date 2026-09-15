#ifndef C1_DESCRIPTOR_H
#define C1_DESCRIPTOR_H

#include <stdint.h>

enum {
    C1_DESC_VERSION = 1u,
    C1_DESC_WORDS = 16u,
    C1_DESC_BYTES = 64u
};

enum {
    C1_OP_NOP = 0u,
    C1_OP_CONV3X3 = 1u,
    C1_OP_CONV1X1 = 2u,
    C1_OP_DWCONV3X3 = 3u,
    C1_OP_UPSAMPLE2 = 4u,
    C1_OP_RESIDUAL_ADD = 5u,
    C1_OP_OUTPUT_RGB = 6u
};

enum {
    C1_ACT_NONE = 0u,
    C1_ACT_RELU = 1u
};

enum {
    C1_DESC_FLAG_SAME_REPLICATE = 1u << 0,
    C1_DESC_FLAG_RESIDUAL_VALID = 1u << 1,
    C1_DESC_FLAG_INPUT_FRAME = 1u << 2,
    C1_DESC_FLAG_OUTPUT_FRAME = 1u << 3,
    C1_DESC_FLAG_PARAM_BANK_1 = 1u << 4
};

#define C1_DESC_CONTROL(opcode, activation, flags) \
    (((uint32_t)(opcode) & 0xffu) | \
     (((uint32_t)(activation) & 0x3u) << 8) | \
     (((uint32_t)(flags) & 0x3fu) << 10) | \
     (C1_DESC_VERSION << 16) | (C1_DESC_WORDS << 24))

#define C1_DESC_PAIR16(low, high) \
    (((uint32_t)(low) & 0xffffu) | (((uint32_t)(high) & 0xffffu) << 16))

#define C1_DESC_GEOMETRY(kw, kh, sx, sy) \
    (((uint32_t)(kw) & 0xffu) | (((uint32_t)(kh) & 0xffu) << 8) | \
     (((uint32_t)(sx) & 0xffu) << 16) | (((uint32_t)(sy) & 0xffu) << 24))

#define C1_DESC_SCHEDULE(channel_block, mac_lanes, tile_w, tile_h) \
    (((uint32_t)(channel_block) & 0xffu) | \
     (((uint32_t)(mac_lanes) & 0xffu) << 8) | \
     (((uint32_t)(tile_w) & 0xffu) << 16) | \
     (((uint32_t)(tile_h) & 0xffu) << 24))

typedef struct {
    uint32_t control;
    uint32_t input_size;
    uint32_t output_size;
    uint32_t channels;
    uint32_t input_offset;
    uint32_t output_offset;
    uint32_t residual_offset;
    uint32_t weight_offset;
    uint32_t bias_offset;
    uint32_t multiplier_offset;
    uint32_t shift_offset;
    uint32_t input_row_stride;
    uint32_t output_row_stride;
    uint32_t geometry;
    uint32_t schedule;
    uint32_t cycle_budget;
} c1_layer_descriptor_t;

#if defined(__STDC_VERSION__) && (__STDC_VERSION__ >= 201112L)
_Static_assert(sizeof(c1_layer_descriptor_t) == C1_DESC_BYTES,
               "c1_layer_descriptor_t must be exactly 64 bytes");
#endif

#endif
