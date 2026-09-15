#ifndef C1_R2_HOST_VIDEO_H
#define C1_R2_HOST_VIDEO_H
#include "c1_r2_rgbx_video.h"

/* C15 host-shell extension. All offsets are relative to the same LOCAL
 * APB window as R2V2, not physical addresses or a second peripheral base.
 * Use aligned 32-bit MMIO only. The platform must reserve the arena and
 * provide uncached/device MMIO plus the required cache maintenance/CDC. */
enum {
    C1_R2H_ID=0x100, C1_R2H_VERSION=0x104, C1_R2H_STATUS=0x108,
    C1_R2H_CPU_BUSY=1u, C1_R2H_CPU_PROTOCOL_FAULT=2u, C1_R2H_CORE_IRQ=4u
};
/* 0 success, -1 invalid argument/alignment, -2 wrong host-shell ABI.
 * Returns one live status word, not an atomic snapshot of the video system. */
int c1_r2h_status_read(uintptr_t registers,uint32_t *status);
/* R2V2 control with the additional C15 host-ABI and CPU-fault check.
 * Same errors as c1_r2x_control; -4 also means CPU reset-required fault.
 * Disabling remains allowed during a fault. A fault can still arrive after
 * this check: the scalar IRQ remains asserted until coordinated reset. */
int c1_r2h_control(uintptr_t registers,uint32_t control);
/* Core IRQ mask/W1C remains c1_r2x_interrupts(). It cannot clear/mask the
 * CPU protocol-fault level. Do NOT write the read-only 0x108 diagnostic.
 * This API does not install a PLIC handler or guarantee CPU progress after
 * a fatal DDR-path fault, and is not cache-maintenance implementation. */
#endif
