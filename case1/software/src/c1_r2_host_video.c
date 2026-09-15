#include "c1_r2_host_video.h"

static uint32_t rd(uintptr_t base,unsigned offset) {
    return *(volatile uint32_t *)(base+offset);
}
static void barrier(void) {
#if defined(__riscv)
    __asm__ volatile("fence iorw, iorw" ::: "memory");
#elif defined(__GNUC__)
    __asm__ volatile("" ::: "memory");
#endif
}
int c1_r2h_status_read(uintptr_t base,uint32_t *status) {
    if((base&3u)||!status)return -1;
    if(rd(base,C1_R2H_ID)!=0x52324831u||rd(base,C1_R2H_VERSION)!=0x00010000u)return -2;
    barrier();
    *status=rd(base,C1_R2H_STATUS);
    barrier();
    return 0;
}
int c1_r2h_control(uintptr_t base,uint32_t control) {
    uint32_t status;
    int error;
    if(control&~15u)return -1;
    error=c1_r2h_status_read(base,&status);
    if(error)return error;
    if((control&C1_R2X_ENABLE)&&(status&C1_R2H_CPU_PROTOCOL_FAULT))return -4;
    return c1_r2x_control(base,control);
}
