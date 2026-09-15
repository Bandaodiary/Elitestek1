#ifndef C1_R2_RGBX_VIDEO_H
#define C1_R2_RGBX_VIDEO_H
#include <stdint.h>
#include <stddef.h>

/* C12 R2V2, RGBX32 frame memory, four raw/three styled slots.
 * NOT the C11 R2V1 or C10 R2C1 ABI. One software control owner.
 * All accesses are 32-bit words, suitable for an APB3 wrapper tying PSTRB=15.
 * MMIO must be uncached/device memory. FENCE is ordering, NOT cache maintenance.
 * Before enabling: initialize trained parameters, clean relevant CPU caches,
 * release coordinated system reset, and wait for platform_ready.
 * Do not write hardware-owned frame/feature memory while running. */
#define C1_R2X_PIXEL_BYTES 4u
#define C1_R2X_RAW_SLOTS 4u
#define C1_R2X_OUTPUT_SLOTS 3u
enum {
    C1_R2X_ID=0x00, C1_R2X_VERSION=0x04, C1_R2X_CONTROL=0x08, C1_R2X_STATUS=0x0c,
    C1_R2X_NN_COUNT=0x10, C1_R2X_NN_CYCLES=0x14, C1_R2X_NN_TAG=0x18,
    C1_R2X_DROPPED=0x1c, C1_R2X_CAPTURE_COUNT=0x20, C1_R2X_DISPLAY_COUNT=0x24,
    C1_R2X_UNDERFLOW_COUNT=0x28, C1_R2X_PHYSICAL_DEBT=0x2c,
    C1_R2X_IRQ_STATUS=0x30, C1_R2X_IRQ_ENABLE=0x34,
    C1_R2X_SHAPE=0x38, C1_R2X_ARENA=0x3c, C1_R2X_RETIRED=0x40
};
enum {
    C1_R2X_ENABLE=1u, C1_R2X_CAPTURE=2u, C1_R2X_NN=4u, C1_R2X_DISPLAY=8u,
    C1_R2X_RUN_ALL=15u, C1_R2X_PAUSE_NN=11u
};
enum {
    C1_R2X_CAPTURE_ACTIVE=1u, C1_R2X_NN_ACTIVE=2u, C1_R2X_DISPLAY_ACTIVE=4u,
    C1_R2X_FRONT_VALID=8u, C1_R2X_PLATFORM_READY=16u,
    C1_R2X_FABRIC_ERROR=32u, C1_R2X_LEASE_ERROR=64u
};
typedef struct { uint32_t count,tag,cycles; } c1_r2x_result;
/* 0 success; -1 invalid argument/alignment; -2 wrong peripheral ABI;
 * -3 platform not ready; -4 fatal fabric/lease error (coordinated reset).
 * Enabling bits only controls NEW requests, never withdraws an owned command.
 * CONTROL=0 drains work, but does not free the retained FRONT buffer pair. */
int c1_r2x_control(uintptr_t registers,uint32_t control);
/* 1 stable completed record, 0 no successful CNN result; -1 bad pointer,
 * -2 wrong ABI, -3 raced three times. Success is not a whole-system snapshot. */
int c1_r2x_result_read(uintptr_t registers,c1_r2x_result *result);
/* IRQ bit0 NN completion (success or failure), bit1 failed completion,
 * bit2 overflow/underflow, bit3 reset-required fabric/lease error.
 * W1C does not mask a still-asserted fatal event; set wins over clear. */
int c1_r2x_interrupts(uintptr_t registers,uint32_t enable,uint32_t clear);
#endif
