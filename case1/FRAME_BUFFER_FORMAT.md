# C1 framebuffer 表 ABI v1

输入表固定包含 3 项，输出表固定包含 2 项；CSR 中的 `INPUT_TABLE_BASE`、`OUTPUT_TABLE_BASE` 指向各自连续数组。每项恰好 16 byte，可由一次 AXI128 beat 读取，表首地址和每项地址均须 16-byte 对齐。

| Byte | 字段 | 含义 |
|---:|---|---|
| 0..7 | `base_address` | framebuffer 首字节地址，little-endian u64；当前 32-bit AXI 实现要求高 32 位为 0 |
| 8..11 | `stride_bytes` | 行跨度；至少 `width*4` 且为 16 的整数倍 |
| 12..13 | `width_pixels` | 非零 u16 |
| 14..15 | `height_lines` | 非零 u16 |

## 硬件读取与配对

`rtl/dma/c1_axi_frame_buffer_table_reader.sv` 使用 AXI128 单 beat 读取一项，地址为 `table_base + index*16`；当前 32-bit AXI 实现拒绝 table/entry framebuffer 地址高 32 位非零、未对齐、地址加法溢出和非 OKAY/RLAST 响应。已经发出的读在 abort 后仍会 drain，不会把旧响应泄漏给下一任务。

`rtl/control/c1_frame_pair_resolver.sv` 复用一个 reader，按输入项、输出项顺序解析，并检查：输入 index 0..2、输出 index 0..1、尺寸与任务完全一致、stride 至少 `width*4` 且 16-byte 对齐、最后活动字节不越 32-bit 地址空间。它还逐行比较两组活动像素区间，禁止输入/输出 framebuffer 真正重叠；padding 相交不误报。

软件仍应在提交前检查三输入/双输出表中全部五个区域互不重叠。硬件 resolver 只保护当前被领取的一对，不能替代软件的整表布局审计。

像素格式由 CSR `PIXEL_FORMAT` 统一指定，当前只允许值 2（XRGB8888）。逻辑像素字为 `0x00RRGGBB`，little-endian DDR 字节为 `BB GG RR 00`。表项不保存所有权；`c1_frame_manager` 返回的 index 只用于选择对应项。

软件提交表前必须检查：base/stride 对齐、尺寸非零、stride 足够、最后一行末地址不溢出当前 AXI 地址宽度，以及五个 framebuffer 物理区间互不重叠。表项写完并完成必要的 cache clean / memory barrier 后，才能启动 capture 或 CNN。
