#ifndef C1_R2_CONTROL_H
#define C1_R2_CONTROL_H
#include <stdint.h>
#include <stddef.h>

/* C10 new R2 ABI. Not compatible with the R1 descriptor/CSR driver.
 * Single software owner; MMIO region must be uncached/device memory.
 * Callers own buffer leases and DMA cache maintenance. A RISC-V FENCE here
 * orders accesses; it does NOT clean/invalidate a cached tensor arena. */
enum {
    C1_R2_ID=0x00, C1_R2_COMMAND=0x10, C1_R2_STATUS=0x14,
    C1_R2_IRQ_ENABLE=0x18, C1_R2_IRQ_STATUS=0x1c,
    C1_R2_INPUT=0x20, C1_R2_WORKSPACE=0x24, C1_R2_OUTPUT=0x28,
    C1_R2_PARAMETERS=0x2c, C1_R2_SHAPE=0x30, C1_R2_TAG=0x34,
    C1_R2_CYCLES=0x38, C1_R2_RESULT_TAG=0x3c
};
enum {
    C1_R2_BUSY=1u, C1_R2_PENDING=2u, C1_R2_RESULT=4u,
    C1_R2_ERROR=8u, C1_R2_DISCARDED=16u, C1_R2_PUBLICATION=32u,
    C1_R2_CAN_START=64u, C1_R2_FABRIC_ERROR=128u
};
typedef struct {
    uint32_t input,workspace,output,parameters,tag;
    uint16_t width,height;
} c1_r2_job;
typedef struct { uint32_t tag,cycles,status; } c1_r2_result;

/* Return 0 success; -1 owner/result/publication busy; -2 bad configuration;
 * -3 hardware preflight/lease not ready; -4 reset-required fabric error;
 * -5 wrong peripheral ID or ABI version (no configuration writes).
 * Submission is serialized with lease acquisition by the system owner. */
int c1_r2_submit(uintptr_t registers,const c1_r2_job *job);
/* 1 = stable result copied, 0 = pending/not completed. */
int c1_r2_poll(uintptr_t registers,c1_r2_result *result);
/* Does not stop AXI traffic. Suppresses the active frame's publication when
 * sampled before completion; idle/too-late requests are harmless no-ops. */
void c1_r2_discard(uintptr_t registers);
/* CPU result ACK only. A display consumer must separately accept publication.
 * IRQ W1C is separate, with hardware event-set winning concurrent clears. */
int c1_r2_ack_result(uintptr_t registers);
void c1_r2_irq_enable(uintptr_t registers,uint32_t mask);
void c1_r2_irq_clear(uintptr_t registers,uint32_t mask);
#endif
