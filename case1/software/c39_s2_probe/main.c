#include <stdint.h>
#include "soc.h"
#include "c1_r2_host_video.h"

/* Official S2 BSP, current R2 host ABI. This image NEVER starts the accelerator. */
_Static_assert(__riscv_xlen == 32, "RV32 target required");
_Static_assert(SYSTEM_RISCV_ISA_EXT_M == 1, "S2 multiply/divide extension required");
_Static_assert(SYSTEM_RISCV_ISA_EXT_C == 0, "do not assume compressed ISA in S2");
_Static_assert(SYSTEM_RISCV_ISA_EXT_F == 0, "S2 has no FPU");
_Static_assert(SYSTEM_CLINT_HZ == 100000000, "BSP clock must match joint S2 project");
_Static_assert(IO_APB_SLAVE_0_INPUT == 0xf8100000u, "unexpected accelerator APB window");
_Static_assert(SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT == 16, "unexpected host IRQ ID");

volatile int32_t c39_probe_error;
volatile uint32_t c39_host_status;
volatile uint32_t c39_probe_iterations;

int main(void)
{
    for (;;) {
        uint32_t status = 0;
        c39_probe_error = c1_r2h_status_read((uintptr_t)IO_APB_SLAVE_0_INPUT, &status);
        c39_host_status = status;
        c39_probe_iterations++;
    }
}
