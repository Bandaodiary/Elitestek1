#include "c1_r2_rgb2_camera.h"

static uint32_t rd(uintptr_t base,unsigned offset) {
    return *(volatile const uint32_t *)(base+offset);
}
static void barrier(void) {
#if defined(__riscv)
    __asm__ volatile("fence iorw, iorw" ::: "memory");
#elif defined(__GNUC__)
    __asm__ volatile("" ::: "memory");
#endif
}
int c1_r2c2_info_read(uintptr_t base,c1_r2c2_info *out) {
    c1_r2c2_info t;
    uint32_t source,size,origin;
    if(!out || (base&3u) || base>UINTPTR_MAX-C1_R2C2_FRAME_DIVISOR)return -1;
    barrier();
    if(rd(base,C1_R2C2_ID)!=C1_R2C2_ID_VALUE)return -2;
    if(rd(base,C1_R2C2_CAPABILITY)!=C1_R2C2_CAP_VALUE)return -3;
    source=rd(base,C1_R2C2_SOURCE);size=rd(base,C1_R2C2_ROI_SIZE);
    origin=rd(base,C1_R2C2_ROI_ORIGIN);
    t.source_width=source&65535u;t.source_height=source>>16;
    t.roi_x=origin&65535u;t.roi_y=origin>>16;
    t.roi_width=size&65535u;t.roi_height=size>>16;
    t.fifo_records=rd(base,C1_R2C2_FIFO_DEPTH);
    t.frame_divisor=rd(base,C1_R2C2_FRAME_DIVISOR);
    t.record_bits=49;t.pixels_per_record_max=2;
    barrier();
    if(t.source_width<2 || (t.source_width&1u) || !t.source_height ||
       !t.roi_width || !t.roi_height || t.roi_x+t.roi_width>t.source_width ||
       t.roi_y+t.roi_height>t.source_height || t.fifo_records<2 ||
       (t.fifo_records&(t.fifo_records-1u)) || !t.frame_divisor || t.frame_divisor>256)return -3;
    *out=t;
    return 0;
}
