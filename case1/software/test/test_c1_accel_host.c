#include "c1_accel.h"
#include "c1_descriptor.h"
#include "c1_frame_buffer.h"
#include "c1_isp_config_regs.h"

#include <stdio.h>
#include <string.h>

#define WORD(offset) registers[(offset) / 4u]

static uint32_t registers[C1_REG_QOS_PROTOCOL / 4u + 1u];

static int require(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        return 0;
    }
    return 1;
}

int main(void)
{
    c1_accel_t device;
    c1_accel_config_t config;

    memset(registers, 0, sizeof(registers));
    memset(&config, 0, sizeof(config));
    device.base = (uintptr_t)&registers[0];
    device.steady_control = 0u;
    WORD(C1_REG_ID) = 0x43315254u;

    if (!require(c1_accel_probe(&device), "probe rejected the C1RT ID")) return 1;
    if (!require(!c1_accel_probe(NULL), "NULL probe was accepted")) return 1;

    /* A zero-initialized handle cannot launch: RTL ignores START while
     * system_enable is low. Reject without clearing retained IRQ evidence. */
    for (unsigned mode = 0u; mode < 4u; ++mode) {
        device.steady_control = ((mode & 1u) ? C1_CONTROL_CONTINUOUS : 0u) |
                               ((mode & 2u) ? C1_CONTROL_DROP_OLDEST : 0u);
        WORD(C1_REG_CONTROL) = 0x12340000u;
        WORD(C1_REG_IRQ_STATUS) = C1_IRQ_ALL;
        if (!require(!c1_accel_start(&device), "disabled start was reported successful")) return 1;
        if (!require(WORD(C1_REG_CONTROL) == 0x12340000u &&
                     WORD(C1_REG_IRQ_STATUS) == C1_IRQ_ALL,
                     "disabled start changed command or IRQ state")) return 1;
    }
    device.steady_control = 0u;
    if (!require(!c1_accel_start(NULL), "NULL start was accepted")) return 1;
    WORD(C1_REG_CONTROL) = 0u;
    WORD(C1_REG_IRQ_STATUS) = 0u;

    config.input_buffer_table = 0x00100000u;
    config.output_buffer_table = 0x00100100u;
    config.descriptor_base = 0x00110000u;
    config.weight_base = 0x00120000u;
    config.tensor_base = 0x02000000u;
    config.input_stride_bytes = 2560u;
    config.output_stride_bytes = 2560u;
    config.width = 640u;
    config.height = 480u;
    config.descriptor_count = 22u;
    config.input_format = C1_PIXEL_XRGB8888_DDR;
    config.output_format = C1_PIXEL_XRGB8888_DDR;
    config.style_id = 3u;
    config.display_mode = C1_DISPLAY_SPLIT;
    config.continuous = true;
    config.drop_oldest = true;

    if (!require(c1_accel_configure(&device, &config), "valid configuration rejected")) return 1;
    if (!require(WORD(C1_REG_IN_TABLE_LO) == 0x00100000u,
                 "input table low word mismatch")) return 1;
    if (!require(WORD(C1_REG_IN_TABLE_HI) == 0u,
                 "input table high word mismatch")) return 1;
    if (!require(WORD(C1_REG_FRAME_SIZE) == 0x01e00280u,
                 "frame size packing mismatch")) return 1;
    if (!require(WORD(C1_REG_IN_STRIDE) == 2560u &&
                 WORD(C1_REG_OUT_STRIDE) == 2560u,
                 "XRGB stride mismatch")) return 1;
    if (!require(WORD(C1_REG_PIXEL_FORMAT) == 0x22u,
                 "DDR pixel format mismatch")) return 1;
    if (!require(WORD(C1_REG_DESC_COUNT) == 22u,
                 "descriptor count mismatch")) return 1;
    if (!require(WORD(C1_REG_TENSOR_BASE) == 0x02000000u,
                 "tensor arena base mismatch")) return 1;
    if (!require(device.steady_control ==
                 (C1_CONTROL_ENABLE | C1_CONTROL_CONTINUOUS |
                  C1_CONTROL_DROP_OLDEST),
                 "steady control mismatch")) return 1;

    if (!require(c1_accel_start(&device), "idle start was rejected")) return 1;
    if (!require(WORD(C1_REG_CONTROL) ==
                 (device.steady_control | C1_CONTROL_START),
                 "start W1P write mismatch")) return 1;
    WORD(C1_REG_STATUS) = C1_STATUS_BUSY;
    if (!require(!c1_accel_start(&device), "busy start was accepted")) return 1;
    if (!require(!c1_accel_wait_idle(&device, 3u),
                 "wait-idle accepted a permanently busy device")) return 1;
    WORD(C1_REG_STATUS) = 0u;
    if (!require(c1_accel_wait_idle(&device, 1u),
                 "wait-idle rejected an idle device")) return 1;
    if (!require(!c1_accel_wait_idle(NULL, 1u) &&
                 !c1_accel_wait_idle(&device, 0u),
                 "wait-idle accepted an invalid call")) return 1;
    c1_accel_abort(&device);
    if (!require(WORD(C1_REG_CONTROL) ==
                 (device.steady_control | C1_CONTROL_ABORT),
                 "abort W1P write mismatch")) return 1;

    /* Exercise the aggregate QoS snapshot ABI added above the legacy
     * 0x104 register.  A disabled/legacy instance returns false with zeros;
     * this emulated instance advertises the generate-time presence bit. */
    WORD(C1_REG_QOS_STATUS) = C1_QOS_STATUS_ENABLED |
                              C1_QOS_STATUS_DEADLINE |
                              C1_QOS_STATUS_UNDERFLOW;
    WORD(C1_REG_QOS_FRAME_COUNT) = 2u;
    WORD(C1_REG_QOS_LAST_FRAME) = 123456u;
    WORD(C1_REG_QOS_DEADLINE) = 1u;
    WORD(C1_REG_QOS_UNDERFLOW) = 3u;
    WORD(C1_REG_QOS_READ_BUSY) = 400u;
    WORD(C1_REG_QOS_WRITE_BUSY) = 80u;
    WORD(C1_REG_QOS_R_OWNER_MAX) = 17u;
    WORD(C1_REG_QOS_W_OWNER_MAX) = 9u;
    WORD(C1_REG_QOS_PROTOCOL) = 0u;
    {
        c1_accel_qos_snapshot_t qos;
        if (!require(c1_accel_read_qos(&device, &qos),
                     "QoS presence bit was not reported")) return 1;
        if (!require(qos.status == (C1_QOS_STATUS_ENABLED |
                                    C1_QOS_STATUS_DEADLINE |
                                    C1_QOS_STATUS_UNDERFLOW) &&
                     qos.frame_count == 2u &&
                     qos.last_frame_cycles == 123456u &&
                     qos.deadline_miss_count == 1u &&
                     qos.underflow_count == 3u &&
                     qos.read_busy_cycles == 400u &&
                     qos.write_busy_cycles == 80u &&
                     qos.read_owner_hold_max == 17u &&
                     qos.write_owner_hold_max == 9u &&
                     qos.protocol_error_count == 0u,
                     "QoS aggregate snapshot mismatch")) return 1;
        if (!require(!c1_accel_read_qos(NULL, &qos) &&
                     !c1_accel_read_qos(&device, NULL),
                     "invalid QoS snapshot call was accepted")) return 1;
    }

    c1_accel_enable_irqs(&device, 0xffffffffu);
    if (!require(WORD(C1_REG_IRQ_ENABLE) == C1_IRQ_ALL,
                 "IRQ mask was not limited")) return 1;
    WORD(C1_REG_IRQ_STATUS) = C1_IRQ_ERROR | C1_IRQ_DISPLAY_SWAP;
    if (!require(c1_accel_irq_status(&device) ==
                 (C1_IRQ_ERROR | C1_IRQ_DISPLAY_SWAP),
                 "IRQ status read mismatch")) return 1;
    c1_accel_ack_irqs(&device, C1_IRQ_ERROR);
    if (!require(WORD(C1_REG_IRQ_STATUS) == C1_IRQ_ERROR,
                 "IRQ acknowledge write mismatch")) return 1;

    config.input_format = C1_PIXEL_RGB888_STREAM;
    if (!require(!c1_accel_configure(&device, &config),
                 "stream RGB888 was accepted as a DDR format")) return 1;
    config.input_format = C1_PIXEL_XRGB8888_DDR;
    config.width = 320u;
    if (!require(!c1_accel_configure(&device, &config),
                 "non-640 frame width was accepted")) return 1;
    config.width = 640u;
    config.descriptor_count = 21u;
    if (!require(!c1_accel_configure(&device, &config),
                 "non-22 descriptor graph was accepted")) return 1;
    config.descriptor_count = 22u;
    config.input_stride_bytes = 1920u;
    if (!require(!c1_accel_configure(&device, &config),
                 "short framebuffer stride was accepted")) return 1;
    config.input_stride_bytes = 2560u;
    config.tensor_base = 0x02000008u;
    if (!require(!c1_accel_configure(&device, &config),
                 "misaligned tensor arena was accepted")) return 1;
    config.tensor_base = 0x02000000u;
    config.descriptor_base = 0x0000000100110000ull;
    if (!require(!c1_accel_configure(&device, &config),
                 "nonzero AXI address high word was accepted")) return 1;

    if (!require(sizeof(c1_layer_descriptor_t) == C1_DESC_BYTES,
                 "descriptor C ABI size mismatch")) return 1;
    if (!require(sizeof(c1_frame_buffer_entry_t) == C1_FRAME_BUFFER_ENTRY_BYTES,
                 "framebuffer C ABI size mismatch")) return 1;
    if (!require(C1_ISP_REG_CONTROL == 0x200u &&
                 C1_ISP_REG_GAMMA_COMMAND == 0x268u,
                 "ISP APB register map mismatch")) return 1;
    if (!require(C1_ISP_AWB_Q2_14_ONE == 16384u &&
                 C1_ISP_CCM_Q3_13_ONE == 8192,
                 "ISP unity fixed-point constants mismatch")) return 1;
    if (!require(C1_ISP_BAYER_RGGB == 0u && C1_ISP_BAYER_BGGR == 1u &&
                 C1_ISP_BAYER_GRBG == 2u && C1_ISP_BAYER_GBRG == 3u,
                 "ISP Bayer encoding mismatch")) return 1;

    puts("C1_SOFTWARE_HOST_TEST_PASS registers=76 descriptor=64 framebuffer=16 isp=0x200..0x268 qos=0x108..0x12c");
    return 0;
}
