#include "c1_r2_video.h"
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
    return rd(b,C1_R2V_ID)==0x52325631u&&rd(b,C1_R2V_VERSION)==0x00010000u ? 0 : -2;
}
int c1_r2v_control(uintptr_t b,uint32_t control) {
    int error;uint32_t status;
    if(control&~15u)return -1;
    error=probe(b);if(error)return error;
    if(control&C1_R2V_ENABLE) {
        status=rd(b,C1_R2V_STATUS);
        if(status&(C1_R2V_FABRIC_ERROR|C1_R2V_LEASE_ERROR))return -4;
        if(!(status&C1_R2V_PLATFORM_READY))return -3;
    }
    barrier();wr(b,C1_R2V_CONTROL,control);barrier();return 0;
}
int c1_r2v_result_read(uintptr_t b,c1_r2v_result *r) {
    int error;uint32_t before,after,tag,cycles;
    if(!r)return -1;
    error=probe(b);if(error)return error;
    for(unsigned retry=0;retry<3;retry++) {
        before=rd(b,C1_R2V_NN_COUNT);barrier();
        tag=rd(b,C1_R2V_NN_TAG);cycles=rd(b,C1_R2V_NN_CYCLES);barrier();after=rd(b,C1_R2V_NN_COUNT);
        if(before==after) {
            /* Count may wrap to zero during long operation; cycles remains
             * nonzero after a valid completion and resets with the count. */
            if(cycles==0)return 0;
            r->count=after;r->tag=tag;r->cycles=cycles;return 1;
        }
    }
    return -3;
}
int c1_r2v_interrupts(uintptr_t b,uint32_t enable,uint32_t clear) {
    int error;
    if((enable|clear)&~15u)return -1;
    error=probe(b);if(error)return error;
    wr(b,C1_R2V_IRQ_ENABLE,enable);wr(b,C1_R2V_IRQ_STATUS,clear);barrier();return 0;
}
