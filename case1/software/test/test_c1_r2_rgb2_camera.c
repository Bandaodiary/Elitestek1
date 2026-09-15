#include "c1_r2_rgb2_camera.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    uint32_t mmio[64]={0};
    uintptr_t base=(uintptr_t)mmio;
    c1_r2c2_info out,saved;
    mmio[C1_R2C2_ID/4]=C1_R2C2_ID_VALUE;
    mmio[C1_R2C2_CAPABILITY/4]=C1_R2C2_CAP_VALUE;
    mmio[C1_R2C2_SOURCE/4]=(1080u<<16)|1920u;
    mmio[C1_R2C2_ROI_SIZE/4]=(1080u<<16)|1440u;
    mmio[C1_R2C2_ROI_ORIGIN/4]=240u;
    mmio[C1_R2C2_FIFO_DEPTH/4]=512;
    mmio[C1_R2C2_FRAME_DIVISOR/4]=2;
    memset(&out,0xa5,sizeof out);
    assert(c1_r2c2_info_read(base,&out)==0);
    assert(out.source_width==1920 && out.source_height==1080 && out.roi_x==240 && out.roi_y==0);
    assert(out.roi_width==1440 && out.roi_height==1080 && out.fifo_records==512);
    assert(out.record_bits==49 && out.pixels_per_record_max==2 && out.frame_divisor==2);
    saved=out;
    assert(c1_r2c2_info_read(base+1,&out)==-1);
    assert(c1_r2c2_info_read(base,0)==-1);
    assert(c1_r2c2_info_read(UINTPTR_MAX&~(uintptr_t)3,&out)==-1);
    mmio[C1_R2C2_ID/4]=0x52324331u;
    assert(c1_r2c2_info_read(base,&out)==-2);
    mmio[C1_R2C2_ID/4]=C1_R2C2_ID_VALUE;
    mmio[C1_R2C2_CAPABILITY/4]^=1;
    assert(c1_r2c2_info_read(base,&out)==-3);
    mmio[C1_R2C2_CAPABILITY/4]=C1_R2C2_CAP_VALUE;
    mmio[C1_R2C2_FRAME_DIVISOR/4]=0;
    assert(c1_r2c2_info_read(base,&out)==-3);
    mmio[C1_R2C2_FRAME_DIVISOR/4]=257;
    assert(c1_r2c2_info_read(base,&out)==-3);
    mmio[C1_R2C2_FRAME_DIVISOR/4]=2;
    mmio[C1_R2C2_FIFO_DEPTH/4]=511;
    assert(c1_r2c2_info_read(base,&out)==-3);
    mmio[C1_R2C2_FIFO_DEPTH/4]=512;
    mmio[C1_R2C2_ROI_ORIGIN/4]=600;
    assert(c1_r2c2_info_read(base,&out)==-3);
    mmio[C1_R2C2_ROI_ORIGIN/4]=240;
    assert(memcmp(&out,&saved,sizeof out)==0);
    for(unsigned divisor=1;divisor<=256;divisor++) {
        mmio[C1_R2C2_FRAME_DIVISOR/4]=divisor;
        assert(c1_r2c2_info_read(base,&out)==0 && out.frame_divisor==divisor);
    }
    puts("C31_RGB2_CAMERA_SOFTWARE_PASS divisors=256 failures=9 output_unchanged_on_error=1 legacy_abi_rejected=1 records_not_pixels=1");
    return 0;
}
