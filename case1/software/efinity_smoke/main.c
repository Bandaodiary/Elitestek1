#include <stdint.h>

#include "../include/c1_accel.h"

/* The generated Sapphire APB window can be injected with Makefile's
 * SOC_HEADER/SOC_INCLUDE options.  The fallback is only a compile/link probe
 * and must not be used as a board address. */
#if !defined(C1_ACCEL_MMIO_BASE) && defined(IO_APB_SLAVE_0_INPUT)
#define C1_ACCEL_MMIO_BASE IO_APB_SLAVE_0_INPUT
#endif
#if !defined(C1_ACCEL_MMIO_BASE) && defined(IO_APB_SLAVE_0_CTRL)
#define C1_ACCEL_MMIO_BASE IO_APB_SLAVE_0_CTRL
#endif
#ifndef C1_ACCEL_MMIO_BASE
#define C1_ACCEL_MMIO_BASE 0xf8100000u
#endif

volatile uint32_t c1_smoke_last_status;
volatile uint32_t c1_smoke_probe_result;

int main(void)
{
    c1_accel_t device = {
        (uintptr_t)C1_ACCEL_MMIO_BASE,
        C1_CONTROL_ENABLE
    };

    c1_smoke_probe_result = c1_accel_probe(&device) ? 1u : 0u;
    for (;;) {
        /* Keep this a harmless status poll: no START or write is issued by
         * the smoke image, so it can be used with an APB loopback. */
        c1_smoke_last_status = c1_accel_status(&device);
    }
}
