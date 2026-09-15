#ifndef C1_R2_RGB2_CAMERA_H
#define C1_R2_RGB2_CAMERA_H
#include <stdint.h>

/* C31 R2C2 extension in the SAME local APB window as R2V2/R2H1.
 * Static capability only: these reads are NOT an atomic live frame snapshot.
 * MMIO must be uncached/device mapped. BSP base decoding remains platform work.
 * R2C1 (C26/C29) is deliberately rejected: its FIFO counters count pixels. */
enum {
    C1_R2C2_ID=0x80, C1_R2C2_SOURCE=0xa8, C1_R2C2_ROI_SIZE=0xac,
    C1_R2C2_ROI_ORIGIN=0xb0, C1_R2C2_FIFO_DEPTH=0xb4,
    C1_R2C2_CAPABILITY=0xb8, C1_R2C2_FRAME_DIVISOR=0xbc
};
#define C1_R2C2_ID_VALUE UINT32_C(0x52324332)
#define C1_R2C2_CAP_VALUE UINT32_C(0x01310201)
typedef struct {
    uint32_t source_width,source_height,roi_x,roi_y,roi_width,roi_height;
    uint32_t fifo_records,record_bits,pixels_per_record_max,frame_divisor;
} c1_r2c2_info;

/* Returns 0, -1 invalid pointer/alignment/range, -2 incompatible ID,
 * -3 unsupported capability/configuration. Output is unchanged on error.
 * FIFO peak at 0x90 and depth at 0xb4 both count 49-bit records; a tail record
 * may contain ONE pixel, so depth*2 is a maximum capacity, not occupancy.
 * Divisor is a build-time configuration (1..256), NOT a writable control.
 * Admission still skips busy/disabled frames; divisor does not guarantee FPS. */
int c1_r2c2_info_read(uintptr_t registers,c1_r2c2_info *info);
#endif
