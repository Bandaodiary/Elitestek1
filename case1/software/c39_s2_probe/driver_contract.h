#ifndef C39_S2_DRIVER_CONTRACT_H
#define C39_S2_DRIVER_CONTRACT_H
#include <stdint.h>
#include "soc.h"
#include "c1_r2_host_video.h"
#include "c1_r2_rgb2_camera.h"

/* Compile-time binding to the generated Lite S2 platform, not CPU execution. */
#if !defined(__riscv) || __riscv_xlen != 32
#error "S2 driver contract requires RV32"
#endif
#if defined(__riscv_compressed) || defined(__riscv_flen)
#error "S2 generated core has neither compressed instructions nor floating point"
#endif
_Static_assert(sizeof(uintptr_t) == 4, "RV32 MMIO pointers required");
_Static_assert(SYSTEM_RISCV_ISA_EXT_M == 1, "S2 M extension required");
_Static_assert(SYSTEM_RISCV_ISA_EXT_C == 0 && SYSTEM_RISCV_ISA_EXT_F == 0,
               "S2 generated ISA differs");
_Static_assert(SYSTEM_CLINT_HZ == 100000000, "S2 clock differs");
_Static_assert(IO_APB_SLAVE_0_INPUT == 0xf8100000u && IO_APB_SLAVE_0_INPUT_SIZE == 65536u,
               "S2 current host MMIO aperture differs");
_Static_assert(SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT == 16, "S2 host IRQ differs");
_Static_assert(C1_R2X_ID == 0 && C1_R2H_ID == 0x100 && C1_R2C2_ID == 0x80,
               "current R2V2/R2H1/R2C2 local register pages required");
#endif
