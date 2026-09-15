#include "c1_accel.h"

#define C1_ID_VALUE 0x43315254u /* "C1RT" */

static inline volatile uint32_t *c1_register(const c1_accel_t *device, uint32_t offset)
{
    return (volatile uint32_t *)(device->base + (uintptr_t)offset);
}

static inline uint32_t c1_read(const c1_accel_t *device, uint32_t offset)
{
    return *c1_register(device, offset);
}

static inline void c1_write(const c1_accel_t *device, uint32_t offset, uint32_t value)
{
    *c1_register(device, offset) = value;
}

static void c1_write_u64(const c1_accel_t *device, uint32_t low_offset, uint64_t value)
{
    c1_write(device, low_offset, (uint32_t)value);
    c1_write(device, low_offset + 4u, (uint32_t)(value >> 32));
}

typedef struct {
    uint64_t base;
    uint64_t size;
} c1_memory_region_t;

static bool c1_regions_overlap(c1_memory_region_t a, c1_memory_region_t b)
{
    return (a.base < (b.base + b.size)) && (b.base < (a.base + a.size));
}

bool c1_accel_probe(const c1_accel_t *device)
{
    return (device != NULL) && (c1_read(device, C1_REG_ID) == C1_ID_VALUE);
}

bool c1_accel_configure(c1_accel_t *device, const c1_accel_config_t *config)
{
    uint32_t control;
    uint32_t minimum_stride;
    c1_memory_region_t regions[5];
    unsigned int i;
    unsigned int j;
    if ((device == NULL) || (config == NULL) || (config->width == 0u) ||
        (config->height == 0u) || (config->input_stride_bytes == 0u) ||
        (config->output_stride_bytes == 0u) ||
        (config->descriptor_count == 0u)) {
        return false;
    }

    if ((c1_read(device, C1_REG_STATUS) & C1_STATUS_BUSY) != 0u)
        return false;

    /* The current board-independent DMA contract is AXI128 XRGB8888. */
    minimum_stride = (uint32_t)config->width * 4u;
    if ((config->width != C1_REQUIRED_FRAME_WIDTH) ||
        (config->height != C1_REQUIRED_FRAME_HEIGHT) ||
        (config->descriptor_count != C1_REQUIRED_DESCRIPTOR_COUNT) ||
        ((config->display_mode & 0x7cu) != 0u) ||
        (config->input_format != C1_PIXEL_XRGB8888_DDR) ||
        (config->output_format != C1_PIXEL_XRGB8888_DDR) ||
        (config->input_stride_bytes < minimum_stride) ||
        (config->output_stride_bytes < minimum_stride) ||
        ((config->input_stride_bytes | config->output_stride_bytes) & 15u) ||
        ((config->input_buffer_table | config->output_buffer_table |
          config->descriptor_base) & 63u) ||
        (config->weight_base & 15u) ||
        (config->tensor_base & (C1_TENSOR_ARENA_ALIGNMENT - 1u)) ||
        (config->tensor_base >
         (uint64_t)UINT32_MAX - (C1_TENSOR_ARENA_BYTES - 1u)) ||
        (config->input_buffer_table >
         (uint64_t)UINT32_MAX - (C1_INPUT_TABLE_BYTES - 1u)) ||
        (config->output_buffer_table >
         (uint64_t)UINT32_MAX - (C1_OUTPUT_TABLE_BYTES - 1u)) ||
        (config->descriptor_base >
         (uint64_t)UINT32_MAX -
         (C1_REQUIRED_DESCRIPTOR_COUNT * C1_DESCRIPTOR_BYTES - 1u)) ||
        (config->weight_base >
         (uint64_t)UINT32_MAX - (C1_PARAMETER_ARENA_BYTES - 1u)) ||
        ((config->input_buffer_table | config->output_buffer_table |
          config->descriptor_base | config->weight_base |
          config->tensor_base) >> 32)) {
        return false;
    }


    /* Check software-owned metadata/parameter arenas.  Frame payload ranges
     * are stored inside the two tables and must be checked by the allocator
     * that creates those entries. */
    regions[0] = (c1_memory_region_t){config->input_buffer_table,
                                      C1_INPUT_TABLE_BYTES};
    regions[1] = (c1_memory_region_t){config->output_buffer_table,
                                      C1_OUTPUT_TABLE_BYTES};
    regions[2] = (c1_memory_region_t){config->descriptor_base,
                                      (uint64_t)config->descriptor_count *
                                      C1_DESCRIPTOR_BYTES};
    regions[3] = (c1_memory_region_t){config->weight_base,
                                      C1_PARAMETER_ARENA_BYTES};
    regions[4] = (c1_memory_region_t){config->tensor_base,
                                      C1_TENSOR_ARENA_BYTES};
    for (i = 0u; i < 5u; ++i) {
        for (j = i + 1u; j < 5u; ++j) {
            if (c1_regions_overlap(regions[i], regions[j]))
                return false;
        }
    }

    c1_write_u64(device, C1_REG_IN_TABLE_LO, config->input_buffer_table);
    c1_write_u64(device, C1_REG_OUT_TABLE_LO, config->output_buffer_table);
    c1_write(device, C1_REG_FRAME_SIZE,
             ((uint32_t)config->height << 16) | config->width);
    c1_write(device, C1_REG_IN_STRIDE, config->input_stride_bytes);
    c1_write(device, C1_REG_OUT_STRIDE, config->output_stride_bytes);
    c1_write(device, C1_REG_PIXEL_FORMAT,
             ((uint32_t)(config->output_format & 0x0fu) << 4) |
             (uint32_t)(config->input_format & 0x0fu));
    c1_write_u64(device, C1_REG_DESC_BASE_LO, config->descriptor_base);
    c1_write(device, C1_REG_DESC_COUNT, config->descriptor_count);
    c1_write(device, C1_REG_STYLE_ID, config->style_id);
    c1_write_u64(device, C1_REG_WEIGHT_BASE_LO, config->weight_base);
    c1_write(device, C1_REG_TENSOR_BASE, (uint32_t)config->tensor_base);
    c1_write(device, C1_REG_DISPLAY_MODE, config->display_mode);

    control = C1_CONTROL_ENABLE;
    if (config->continuous)
        control |= C1_CONTROL_CONTINUOUS;
    if (config->drop_oldest)
        control |= C1_CONTROL_DROP_OLDEST;
    device->steady_control = control;
    c1_write(device, C1_REG_CONTROL, control | C1_CONTROL_CLEAR_STATS);
    c1_write(device, C1_REG_IRQ_STATUS, C1_IRQ_ALL);
    return true;
}

bool c1_accel_start(c1_accel_t *device)
{
    if ((device == NULL) ||
        ((device->steady_control & C1_CONTROL_ENABLE) == 0u) ||
        ((c1_read(device, C1_REG_STATUS) & C1_STATUS_BUSY) != 0u))
        return false;
    /* DONE/ERROR are sticky IRQ-derived status bits.  Remove stale terminal
     * state before launching a new foreground job. */
    c1_write(device, C1_REG_IRQ_STATUS, C1_IRQ_DONE | C1_IRQ_ERROR);
    c1_write(device, C1_REG_CONTROL, device->steady_control | C1_CONTROL_START);
    return true;
}

bool c1_accel_wait_idle(const c1_accel_t *device, uint32_t poll_limit)
{
    uint32_t poll;
    if (device == NULL)
        return false;

    /* DONE/ERROR can be reported before abort/display/tensor cleanup drains.
     * Memory owned by a job may only be reused after BUSY is observed low. */
    for (poll = 0u; poll < poll_limit; ++poll) {
        if ((c1_read(device, C1_REG_STATUS) & C1_STATUS_BUSY) == 0u)
            return true;
    }
    return false;
}

void c1_accel_abort(c1_accel_t *device)
{
    c1_write(device, C1_REG_CONTROL, device->steady_control | C1_CONTROL_ABORT);
}

void c1_accel_enable_irqs(const c1_accel_t *device, uint32_t mask)
{
    c1_write(device, C1_REG_IRQ_ENABLE, mask & C1_IRQ_ALL);
}

uint32_t c1_accel_irq_status(const c1_accel_t *device)
{
    return c1_read(device, C1_REG_IRQ_STATUS) & C1_IRQ_ALL;
}

void c1_accel_ack_irqs(const c1_accel_t *device, uint32_t mask)
{
    c1_write(device, C1_REG_IRQ_STATUS, mask & C1_IRQ_ALL);
}

uint32_t c1_accel_status(const c1_accel_t *device)
{
    return c1_read(device, C1_REG_STATUS);
}

uint32_t c1_accel_frame_count(const c1_accel_t *device)
{
    return c1_read(device, C1_REG_FRAME_COUNT);
}

uint32_t c1_accel_busy_cycles(const c1_accel_t *device)
{
    return c1_read(device, C1_REG_BUSY_CYCLES);
}

bool c1_accel_read_qos(const c1_accel_t *device,
                       c1_accel_qos_snapshot_t *snapshot)
{
    if ((device == NULL) || (snapshot == NULL))
        return false;

    /* These are independent live APB reads, not a hardware-frozen snapshot.
     * Callers that need a coherent frame result should wait for idle (and, if
     * necessary, retry until frame_count/last_frame are stable). */
    snapshot->status = c1_read(device, C1_REG_QOS_STATUS);
    snapshot->frame_count = c1_read(device, C1_REG_QOS_FRAME_COUNT);
    snapshot->last_frame_cycles = c1_read(device, C1_REG_QOS_LAST_FRAME);
    snapshot->deadline_miss_count = c1_read(device, C1_REG_QOS_DEADLINE);
    snapshot->underflow_count = c1_read(device, C1_REG_QOS_UNDERFLOW);
    snapshot->read_busy_cycles = c1_read(device, C1_REG_QOS_READ_BUSY);
    snapshot->write_busy_cycles = c1_read(device, C1_REG_QOS_WRITE_BUSY);
    snapshot->read_owner_hold_max = c1_read(device, C1_REG_QOS_R_OWNER_MAX);
    snapshot->write_owner_hold_max = c1_read(device, C1_REG_QOS_W_OWNER_MAX);
    snapshot->protocol_error_count = c1_read(device, C1_REG_QOS_PROTOCOL);
    /* The presence bit is a static generate-time capability, not a runtime
     * enable.  Returning it lets software distinguish a legacy tie-off from
     * a valid all-zero snapshot. */
    return (snapshot->status & C1_QOS_STATUS_ENABLED) != 0u;
}

uint8_t c1_accel_error_code(const c1_accel_t *device)
{
    return (uint8_t)c1_read(device, C1_REG_ERROR_CODE);
}

uint32_t c1_accel_error_address(const c1_accel_t *device)
{
    return c1_read(device, C1_REG_ERROR_ADDRESS);
}
