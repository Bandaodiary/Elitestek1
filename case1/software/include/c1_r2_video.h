#ifndef C1_R2_VIDEO_H
#define C1_R2_VIDEO_H
#include <stdint.h>
#include <stddef.h>

/* C11 R2V1, NOT the C10 R2C1 per-job ABI. One software control owner.
 * All accesses are 32-bit words, suitable for an APB3 wrapper tying PSTRB=15.
 * MMIO must be uncached/device memory. FENCE is ordering, NOT cache maintenance.
 * Before enabling: initialize trained parameters, clean relevant CPU caches,
 * release coordinated system reset, and wait for platform_ready.
 * Do not write hardware-owned frame/feature memory while running. */
enum {
    C1_R2V_ID=0x00, C1_R2V_VERSION=0x04, C1_R2V_CONTROL=0x08, C1_R2V_STATUS=0x0c,
    C1_R2V_NN_COUNT=0x10, C1_R2V_NN_CYCLES=0x14, C1_R2V_NN_TAG=0x18,
    C1_R2V_DROPPED=0x1c, C1_R2V_CAPTURE_COUNT=0x20, C1_R2V_DISPLAY_COUNT=0x24,
    C1_R2V_UNDERFLOW_COUNT=0x28, C1_R2V_PHYSICAL_DEBT=0x2c,
    C1_R2V_IRQ_STATUS=0x30, C1_R2V_IRQ_ENABLE=0x34,
    C1_R2V_SHAPE=0x38, C1_R2V_ARENA=0x3c, C1_R2V_RETIRED=0x40
};
enum {
    C1_R2V_ENABLE=1u, C1_R2V_CAPTURE=2u, C1_R2V_NN=4u, C1_R2V_DISPLAY=8u,
    C1_R2V_RUN_ALL=15u, C1_R2V_PAUSE_NN=11u
};
enum {
    C1_R2V_CAPTURE_ACTIVE=1u, C1_R2V_NN_ACTIVE=2u, C1_R2V_DISPLAY_ACTIVE=4u,
    C1_R2V_FRONT_VALID=8u, C1_R2V_PLATFORM_READY=16u,
    C1_R2V_FABRIC_ERROR=32u, C1_R2V_LEASE_ERROR=64u
};
typedef struct { uint32_t count,tag,cycles; } c1_r2v_result;
/* 0 success; -1 invalid argument/alignment; -2 wrong peripheral ABI;
 * -3 platform not ready; -4 fatal fabric/lease error (coordinated reset).
 * Enabling bits only controls NEW requests, never withdraws an owned command.
 * CONTROL=0 drains work, but does not free the retained FRONT buffer pair. */
int c1_r2v_control(uintptr_t registers,uint32_t control);
/* 1 stable completed record, 0 no successful CNN result; -1 bad pointer,
 * -2 wrong ABI, -3 raced three times. Success is not a whole-system snapshot. */
int c1_r2v_result_read(uintptr_t registers,c1_r2v_result *result);
/* IRQ bit0 NN completion (success or failure), bit1 failed completion,
 * bit2 overflow/underflow, bit3 reset-required fabric/lease error.
 * W1C does not mask a still-asserted fatal event; set wins over clear. */
int c1_r2v_interrupts(uintptr_t registers,uint32_t enable,uint32_t clear);
#endif
