# C1 R1 层描述符 ABI v1

当前 `model/microstyle_layout.py` 生成的是 `dedicated_multirate_streaming_graph` 配置：22 条记录在帧前装载到专用 stage，`INPUT/OUTPUT/RESIDUAL_OFFSET=0` 表示片上直连。它不是让一个共享引擎按 22 层顺序把中间 tensor 写回 DDR 的 schedule；若采用共享引擎，必须重新分配非零 tensor offset、row stride 和 cycle budget，并重算外存带宽。

便携 RTL 已提供 `c1_r1_stage_config_bank`：只有从 index 0 开始、连续接收恰好 `load_count` 条记录后才原子切换 active bank/generation；abort、错序或数量错误不会污染当前 active 配置。语义字段必须先通过 `c1_layer_command_decoder`，不能仅因 512-bit 数据已写入 shadow RAM 就视为有效模型。默认资源模式把每条记录拆成 16 个 32-bit word 存入两个 `352×32` 同步 RAM，读回时用 16 拍组装；descriptor 只在帧前读取，因此这比单拍 512-bit 宽 RAM 更符合 Ti60 的 M10K 端口形状。

每个 descriptor 固定为 64 byte、16 个 little-endian 32-bit word，首地址必须 64-byte 对齐。`descriptor_base` 指向连续数组；第 `i` 项地址为 `base + 64*i`。本格式是 RISC-V、Python packer、descriptor DMA 和 layer engine 的板卡无关合同。

## Word 布局

| Word | 名称 | 位域/含义 |
|---:|---|---|
| 0 | CONTROL | `[7:0] opcode`、`[9:8] activation`、`[15:10] flags`、`[23:16] version=1`、`[31:24] words=16` |
| 1 | INPUT_SIZE | `{input_height[15:0], input_width[15:0]}` |
| 2 | OUTPUT_SIZE | `{output_height[15:0], output_width[15:0]}` |
| 3 | CHANNELS | `{output_channels[15:0], input_channels[15:0]}` |
| 4 | INPUT_OFFSET | 相对 tensor arena base 的 byte offset |
| 5 | OUTPUT_OFFSET | 相对 tensor arena base 的 byte offset |
| 6 | RESIDUAL_OFFSET | residual tensor byte offset；无 residual 时为 0 |
| 7 | WEIGHT_OFFSET | 相对 `weight_base` 的 byte offset |
| 8 | BIAS_OFFSET | 相对 `weight_base` 的 int32 bias byte offset |
| 9 | MULTIPLIER_OFFSET | 相对 `weight_base` 的 int18/packed multiplier byte offset |
| 10 | SHIFT_OFFSET | 相对 `weight_base` 的 u6/packed shift byte offset |
| 11 | INPUT_ROW_STRIDE | 输入 tensor 每行 byte 数；片上流直连可为 0 |
| 12 | OUTPUT_ROW_STRIDE | 输出 tensor 每行 byte 数；片上流直连可为 0 |
| 13 | GEOMETRY | `{stride_y[7:0], stride_x[7:0], kernel_h[7:0], kernel_w[7:0]}` |
| 14 | SCHEDULE | `{tile_h[7:0], tile_w[7:0], mac_lanes[7:0], channel_block[7:0]}` |
| 15 | CYCLE_BUDGET | 本层允许周期预算；0 表示只统计、不触发超时 |

## Opcode

| 值 | 运算 |
|---:|---|
| 0 | NOP/非法占位，不进入已提交模型 |
| 1 | Conv 3x3 |
| 2 | Conv 1x1 / pointwise |
| 3 | Depthwise Conv 3x3 |
| 4 | Nearest upsample x2 |
| 5 | Same-scale residual add |
| 6 | s8→RGB888 output convert |

Activation：0=`NONE/HARD_TANH saturation`，1=`RELU`。flags 从 CONTROL bit10 起：bit0=`SAME_REPLICATE`、bit1=`RESIDUAL_VALID`、bit2=`INPUT_FRAME`、bit3=`OUTPUT_FRAME`、bit4=`PARAM_BANK_1`，bit5 保留且必须为 0。

## 提交规则

软件必须先在 shadow descriptor/weight 区完整写入并验证以下条件，再在网络 idle 或帧边界 commit：

- `version==1` 且 `words==16`；
- 宽、高、通道、kernel、stride 非零且与 opcode 一致；
- 所有 offset、row stride 和数组长度落在已分配 DDR/片上区域；
- residual 的尺寸、scale 与 zero point 相同；
- `cycle_budget` 为 0 或不小于离线排程器计算值；
- descriptor 数量与 CSR `DESCRIPTOR_COUNT` 相同。

descriptor 本身不保存物理绝对地址。tensor 使用 job/arena base + offset，参数使用 `weight_base + offset`，这样 32-bit offset 足够且模型可以整体重定位。
