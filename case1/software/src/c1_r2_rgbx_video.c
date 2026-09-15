#include "c1_r2_rgbx_video.h"
static uint32_t rd(uintptr_t b,unsigned o) {return *(volatile uint32_t *)(b+o);}
static void wr(uintptr_t b,unsigned o,uint32_t v) {*(volatile uint32_t *)(b+o)=v;}
static void barrier(void) {
#if defined(__riscv)
    __asm__ volatile("fence iorw, iorw" ::: "memory");
#elif defined(__GNUC__)
    __asm__ volatile("" ::: "memory");
#endif
}
static int probe(uintptr_t b) {
    if(b&3u)return -1;
    return rd(b,C1_R2X_ID)==0x52325632u&&rd(b,C1_R2X_VERSION)==0x00010000u ? 0 : -2;
}
int c1_r2x_control(uintptr_t b,uint32_t control) {
    int error;uint32_t status;
    if(control&~15u)return -1;
    error=probe(b);if(error)return error;
    if(control&C1_R2X_ENABLE) {
        status=rd(b,C1_R2X_STATUS);
        if(status&(C1_R2X_FABRIC_ERROR|C1_R2X_LEASE_ERROR))return -4;
        if(!(status&C1_R2X_PLATFORM_READY))return -3;
    }
    barrier();wr(b,C1_R2X_CONTROL,control);barrier();return 0;
}
int c1_r2x_result_read(uintptr_t b,c1_r2x_result *r) {
    int error;uint32_t before,after,tag,cycles;
    if(!r)return -1;
    error=probe(b);if(error)return error;
    for(unsigned retry=0;retry<3;retry++) {
        before=rd(b,C1_R2X_NN_COUNT);barrier();
        tag=rd(b,C1_R2X_NN_TAG);cycles=rd(b,C1_R2X_NN_CYCLES);barrier();after=rd(b,C1_R2X_NN_COUNT);
        if(before==after) {
            /* Count may wrap to zero during long operation; cycles remains
             * nonzero after a valid completion and resets with the count. */
            if(cycles==0)return 0;
            r->count=after;r->tag=tag;r->cycles=cycles;return 1;
        }
    }
    return -3;
}
int c1_r2x_interrupts(uintptr_t b,uint32_t enable,uint32_t clear) {
    int error;
    if((enable|clear)&~15u)return -1;
    error=probe(b);if(error)return error;
    wr(b,C1_R2X_IRQ_ENABLE,enable);wr(b,C1_R2X_IRQ_STATUS,clear);barrier();return 0;
}
