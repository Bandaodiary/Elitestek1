#ifndef C1_ISP_CONFIG_REGS_H
#define C1_ISP_CONFIG_REGS_H

/*
 * R1 ISP configuration APB register offsets.
 *
 * These are byte offsets in the 12-bit APB address space implemented by
 * c1_apb_isp_config.sv.  Add the containing peripheral's CPU-visible base
 * address when accessing the block from software.
 *
 * Scalar ISP parameters are shadow registers.  Software may update them in
 * any order, then write C1_ISP_CONTROL_COMMIT.  A COMMIT takes one atomic
 * snapshot.  STATUS_CFG_BUSY remains set until the ISP accepts that snapshot.
 * A second COMMIT while busy is ignored, returns APB PSLVERR, and latches
 * C1_ISP_ERROR_CFG_BUSY.
 *
 * Gamma address/data follow the same one-entry command rule.  Program both
 * shadow registers, then write C1_ISP_GAMMA_COMMAND_WRITE.  Do not issue the
 * next command until STATUS_GAMMA_BUSY clears.
 * The Gamma RAM has no reset default: initialize all 1024 entries before
 * capture. An identity u10-to-u8 table uses value = address >> 2. A scalar
 * COMMIT alone does not initialize this RAM; control reset retains its data.
 */

#define C1_ISP_REG_CONTROL              0x200u
#define C1_ISP_REG_STATUS               0x204u
#define C1_ISP_REG_ERROR_STATUS         0x208u

#define C1_ISP_REG_BAYER_CFG            0x210u
#define C1_ISP_REG_BLACK_R              0x214u
#define C1_ISP_REG_BLACK_GR             0x218u
#define C1_ISP_REG_BLACK_GB             0x21cu
#define C1_ISP_REG_BLACK_B              0x220u
#define C1_ISP_REG_AWB_R                0x224u
#define C1_ISP_REG_AWB_G                0x228u
#define C1_ISP_REG_AWB_B                0x22cu

#define C1_ISP_REG_CCM_RR               0x230u
#define C1_ISP_REG_CCM_RG               0x234u
#define C1_ISP_REG_CCM_RB               0x238u
#define C1_ISP_REG_CCM_GR               0x23cu
#define C1_ISP_REG_CCM_GG               0x240u
#define C1_ISP_REG_CCM_GB               0x244u
#define C1_ISP_REG_CCM_BR               0x248u
#define C1_ISP_REG_CCM_BG               0x24cu
#define C1_ISP_REG_CCM_BB               0x250u
#define C1_ISP_REG_OFFSET_R             0x254u
#define C1_ISP_REG_OFFSET_G             0x258u
#define C1_ISP_REG_OFFSET_B             0x25cu

#define C1_ISP_REG_GAMMA_ADDR           0x260u
#define C1_ISP_REG_GAMMA_DATA           0x264u
#define C1_ISP_REG_GAMMA_COMMAND        0x268u

#define C1_ISP_CONTROL_COMMIT           (1u << 0)
#define C1_ISP_CONTROL_ABORT_PENDING    (1u << 1)

#define C1_ISP_STATUS_CFG_BUSY          (1u << 0)
#define C1_ISP_STATUS_GAMMA_BUSY        (1u << 1)
#define C1_ISP_STATUS_ANY_BUSY          (1u << 2)
#define C1_ISP_STATUS_CFG_READY         (1u << 3)
#define C1_ISP_STATUS_GAMMA_READY       (1u << 4)
#define C1_ISP_STATUS_ERROR_SHIFT       8u
#define C1_ISP_STATUS_ERROR_MASK        (0x0fu << C1_ISP_STATUS_ERROR_SHIFT)

/* ERROR_STATUS bits are sticky and write-one-to-clear in byte lane zero. */
#define C1_ISP_ERROR_CFG_BUSY           (1u << 0)
#define C1_ISP_ERROR_GAMMA_BUSY         (1u << 1)
#define C1_ISP_ERROR_CONTROL_CONFLICT   (1u << 2)
#define C1_ISP_ERROR_BAD_ADDRESS        (1u << 3)
#define C1_ISP_ERROR_ALL                0x0fu

/* Bayer encoding shared with c1_r1_isp_pipeline. */
#define C1_ISP_BAYER_RGGB               0u
#define C1_ISP_BAYER_BGGR               1u
#define C1_ISP_BAYER_GRBG               2u
#define C1_ISP_BAYER_GBRG               3u
#define C1_ISP_BAYER_PATTERN_MASK       0x03u
#define C1_ISP_BAYER_ROI_X_PARITY       (1u << 2)
#define C1_ISP_BAYER_ROI_Y_PARITY       (1u << 3)

#define C1_ISP_BLACK_U10_MASK           0x03ffu
#define C1_ISP_AWB_Q2_14_MASK           0xffffu
#define C1_ISP_CCM_Q3_13_MASK           0xffffu
#define C1_ISP_GAMMA_ADDR_MASK          0x03ffu
#define C1_ISP_GAMMA_DATA_MASK          0x00ffu
#define C1_ISP_GAMMA_COMMAND_WRITE      (1u << 0)

#define C1_ISP_AWB_Q2_14_ONE            16384u
#define C1_ISP_CCM_Q3_13_ONE            8192

#endif /* C1_ISP_CONFIG_REGS_H */
