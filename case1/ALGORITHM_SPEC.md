# 赛题一图像算法与板卡无关系统规范

状态：`R1 目标架构`

适用范围：Python Golden、便携 SystemVerilog、AXI 行为模型、后续 Efinity 集成

目标基线：摄像头侧 `640x480 @ 30 fps`，风格网络 `640x480 >= 15 fps`，显示侧 `1280x720 @ 60 Hz`

本文规定从 CSI-2 RAW10 数据到 HDMI 对比画面的完整算法链、目标网络、数据流和板卡到手前的验收门槛。涉及逐位算术的规则以 [FIXED_POINT_SPEC.md](./FIXED_POINT_SPEC.md) 为准。

## 1. 当前实现状态与目标边界

### 1.1 当前三层 RGB RTL 的定位

当前仓库中的 `rtl/cnn/c1_style_cnn3.sv` 及其三个计算模块实现的是：

```text
RGB888
  -> 3x3 RGB Conv，3 -> 3
  -> 3x3 Depthwise Conv，3 -> 3
  -> 1x1 Pointwise Conv，3 -> 3
```

配套 `golden/style_pipeline.py` 中的 `vivid_paint` 权重是手工构造的平滑、锐化和颜色扩展系数。该实现的用途是打通以下硬件闭环：

- 权重、偏置和移位参数的装载；
- 3x3 行窗口和逐像素流控；
- 有符号乘加、舍入和饱和；
- Python 整数模型、测试向量和 xsim RTL 的逐像素比较；
- 无具体 FPGA 板卡时的端到端回归环境。

它不是训练得到的艺术风格迁移网络，也不满足最终的网络容量、同尺寸输出、BN 近似、AXI 帧调度或 15 fps 证明要求。任何报告都必须称其为“3 层 RGB diagnostic RTL”或“硬件闭环基线”，不得称为赛题一完整风格网络。

### 1.2 两个实现版本

| 版本 | 用途 | 算术/边界 | 是否作为最终网络 |
|---|---|---|---|
| R0 Diagnostic | 维持现有 Python/RTL 回归 | u8 激活、valid 卷积、两次 3x3 后宽高各缩小 4 | 否 |
| R1 MicroStyle-24 | 赛题一板卡无关目标 | s8 量化、SAME 卷积、两次下采样和上采样、folded BN | 是 |

R0 测试必须继续通过，但新增 R1 时不能为了兼容 R0 而改变 R1 的算术合同。

截至 2026-08-24，R0 已完成 640x480 自然图整帧 xsim；R1 已实现四 Bayer ISP 整链、双线性 Resize 两行采样缓存、XRGB 帧读写 DMA、descriptor/frame-table 读取与调度、参数 AXI loader、AXI 仲裁、job frontend、active-config dispatcher，以及 INT8 C8 窗口/dot/depthwise/requant/residual/upsample 构件。compute shell 已真实连接 ISP/DMA 源选择→Resize/C8 ingress→外部 CNN seam→C8 egress。`c1_r1_boardless_frame_system` 进一步把 frontend、输入 XRGB DMA、config dispatcher、compute shell、输出 XRGB DMA 和内存仲裁收进同一帧任务生命周期，并以严格 xsim 验证；最后一条 stage descriptor 完成握手前，config barrier 禁止 CNN 像素握手。R1 仍缺训练权重、多通道 group/权重供数、完整 22-stage 专用数据链，以及 APB/frame manager、capture ISP、参数供数和显示预取的最终 SoC 装配，因此不能称为完整 MicroStyle-24 layer engine 或参赛成品。实现证据与未完成边界见 `TEST_RESULTS.md`、`IMPLEMENTATION_STATUS.md`。

## 2. 端到端系统链

```text
SC431HAI
  -> MIPI D-PHY RX / CSI-2 Controller               [厂商 IP]
  -> VC/DT/帧行检查、RAW10 解包                     [便携 RTL]
  -> BLC -> Bayer Debayer -> AWB -> CCM -> Gamma    [便携 RTL]
  -> ROI/Crop -> Resize 640x480                     [便携 RTL]
  -> Capture Frame Manager -> 外部 DDR              [AXI + DDR wrapper]
  -> Input DMA -> MicroStyle-24 -> Output DMA        [便携 RTL]
  -> Style Ping-Pong Buffer                          [外部 DDR]
  -> 原图/风格图 720p 合成 + OSD/FPS                 [便携 RTL]
  -> HDMI Timing / PHY                              [便携时序 + 板级 wrapper]
```

RISC-V 只负责控制面：传感器寄存器初始化、帧缓存地址、权重装载、任务启动、完成中断、风格切换、FPS 和 OSD 参数。RISC-V 不参与逐像素卷积、Debayer 或显示像素搬运。

## 3. 算法清单与 MVP 取舍

| 阶段 | 算法 | R1 MVP | 原因 |
|---|---|---:|---|
| CSI-2 | D-PHY、包解析、ECC/CRC | wrapper/BFM | 真实实现依赖 Efinix IP |
| RAW | RAW10 5-byte/4-pixel 解包 | 必须 | 可独立验证，且决定全部后续位序 |
| RAW ISP | 黑电平校正 BLC | 必须 | 去除传感器固定偏置 |
| RAW ISP | 坏点校正 DPC | 可选 | 真实传感器出现坏点后再启用 |
| RAW ISP | 镜头阴影校正 LSC | 可选 | 依赖镜头标定，非板前阻塞项 |
| RAW ISP | RAW 域降噪 | 可选 | 第一版先保留旁路寄存器 |
| RGB ISP | 双线性 Debayer | 必须 | 题目明确要求 RAW 转 RGB |
| RGB ISP | AWB 通道增益 | 必须且可旁路 | 保证网络输入颜色分布接近训练数据 |
| RGB ISP | 3x3 Color Correction Matrix | 必须且可旁路 | 将传感器色域映射到显示/训练 RGB |
| RGB ISP | Gamma LUT | 必须且可旁路 | 风格网络训练图通常是 gamma 编码的 sRGB |
| 几何 | ROI/Crop、宽高比处理 | 必须 | 避免任意拉伸，处理 Bayer 相位 |
| 几何 | 中心对齐双线性 Resize | R1 必须 | 输出固定为 640x480 |
| 网络 | 输入中心化、INT8 Conv/DW/PW | 必须 | 风格迁移主体 |
| 网络 | folded BN affine、ReLU | 必须 | 满足题目并适合硬件 |
| 网络 | 残差、nearest 上采样 | 必须 | 保持内容结构并避免反卷积棋盘格 |
| 输出 | hard-tanh/饱和、RGB888 | 必须 | 固定输出范围 |
| 显示 | 原图/风格图合成、FPS OSD | 必须 | 题目明确要求 |
| 时域 | 光流/时序损失 | 训练可选 | 不增加推理硬件即可减轻闪烁 |
| 时域 | 帧间 EMA | 不进入 MVP | 增加 DDR 读带宽且会产生拖影 |

### 3.1 当前板前算法覆盖矩阵

| 算法/功能 | Python Golden | 便携 RTL | 2026-08-24 结论 |
|---|---|---|---|
| CSI-2 D-PHY/包/ECC/CRC | BFM 合同 | vendor seam | 必须用 Efinix IP 和真实链路验证 |
| RAW10 解包 | bit-exact | 已完成 | 随机与端到端 R0 回归通过 |
| BLC（R/Gr/Gb/B） | 四 pattern/ROI | 已完成 | 随机/边界 exact |
| 双线性 Debayer | 四 pattern/ROI | 已完成 | valid crop；边界不做错误的 Bayer replication |
| AWB/CCM/Gamma | Q2.14/Q3.13/1024 LUT | 已完成 | 已接成 R1 ISP，配置按帧原子提交 |
| ROI/中心对齐双线性 Resize | 已完成 | 坐标、插值、两行四点采样缓存完成 | 端到端小帧 exact；当前 system adapter 仍 one-outstanding，需优化吞吐 |
| active-config 分发 | descriptor/layout 可导出 | active bank 逐 stage ready/valid dispatcher 完成 | 启动时锁存 count/generation；同步/零延迟读、backpressure、generation 改变、timeout、abort/restart 已验证 |
| DPC/LSC/RAW 降噪 | 未冻结标定 | 旁路/未实现 | 可选；等真实镜头和坏点数据后决定 |
| RGB888→s8 输入映射 | 规范完成 | C8 elastic center codec 完成 | 当前固定 `u8 XOR 0x80`；最终激活 scale 仍需 QAT 复核 |
| Conv/DW/PW | 拓扑与 MAC 统计完成 | C8 SAME窗口、dot8、8×8 core、逐 lane 3×3 depthwise+requant 完成 | 多通道 group 调度、PW/Conv 权重供数和 22-stage 连线尚缺；当前窗口 stride1 body II=3 |
| folded BN/requant/ReLU | 整数规则完成 | requant 原语/8 路 bank 完成 | 训练后每通道参数尚未产生 |
| Residual | 整数规则完成 | C8 双流 elastic add 完成 | 坐标/marker、饱和/ReLU、abort/restart 已验证；整网分支缓存仍需连接 |
| nearest upsample ×2 | 拓扑/描述符完成 | C8 单行缓存复制引擎完成 | bit-exact；单 C8 平均约 0.8 output beat/clk，C16/C24 需 group wrapper/并行化 |
| hard-tanh/s8→RGB888 | 规范完成 | C8 codec 的 RGB 三通道反向映射完成 | 固定 scale exact；最终 hard-tanh/scale 由训练参数冻结 |
| 720p 原图/风格分屏 | 几何模型 | timing/compositor 完成 | DDR line prefetch、模式控制、FPS/OSD 尚缺 |
| 帧任务 DMA/abort | 帧表与 XRGB8888 ABI | boardless frontend→input DMA→compute→output DMA 已接通 | 已提交 AR 按期望 beat drain；已呈现/提交的写 burst 完成 W/B drain；取消期间隔离像素并可安全重启 |

这张表区分“算术已验证”“系统缓存已实现”和“只能等板卡/IP”三类工作。尤其是 Resize 与 CNN：已有算术/握手核心并不等于已有持续像素率的数据供给系统。

boardless frame-job 的严格运行号为 `ae0e704e95424efca51334059063d8cb`：`jobs=9 launches=7 done=2 errors=5 aborted=2 stages=110 dispatches=5 generations=7 cnn_in=73 cnn_out=73 ar=197 aw=9 w=18 b=9 drains=5 reverse=2139 midread=1 rwoverlap=0`。该证据覆盖任务生命周期、配置屏障和安全 drain；读写通道在结构上独立，但该短帧回归未形成 outstanding 读写同时活跃，真实并发仍需长帧/DDR 验证。外部 22-stage CNN seam 由 testbench 模型驱动，不代表真实网络已完成。

## 4. CSI-2 与 RAW10 输入

### 4.1 厂商 IP 边界

板卡无关设计不重新实现模拟 D-PHY。`mipi_rx_wrapper` 的规范化输出至少包含：

- `pixel_byte_valid`、`pixel_byte[7:0]`；
- `sof`、`eof`、`sol`、`eol`；
- CSI-2 `virtual_channel` 和 `data_type`；
- `ecc_error`、`crc_error`、`line_length_error`；
- 可回压 FIFO 或明确的不可回压溢出标志。

Python 和 xsim 使用 BFM 产生相同接口。只有校验正确、行长正确且帧完整的数据帧可以被 Frame Manager 发布为 `READY`。

### 4.2 RAW10

CSI-2 RAW10 每 4 个像素使用 5 字节。前 4 字节保存各像素 `[9:2]`，第 5 字节依次保存四个像素的两位 LSB。完整位序见定点规范。

需要独立验证：

- 随机 RAW10 pack/unpack 往返完全一致；
- 行尾不是错误地跨行拼接；
- 非 5 字节整数倍 payload 被标错而不是静默截断；
- CRC、短行或帧中断后不发布半帧。

## 5. ISP 算法

### 5.1 黑电平校正

每个 Bayer 相位可配置独立黑电平，也允许使用统一值。四路寄存器固定按 `(R, Gr, Gb, B)` 排列，四种 Bayer pattern 的 2 位编码固定为 `00 RGGB / 01 BGGR / 10 GRBG / 11 GBRG`：

```text
raw_blc = max(raw10 - black_level[phase], 0)
```

MVP 使用静态寄存器。自动曝光和自动黑电平由后续 RISC-V 软件迭代，不进入第一版像素流水线。

### 5.2 双线性 Debayer

实现四种 Bayer 排列：`RGGB`、`BGGR`、`GRBG`、`GBRG`。以 RGGB 为例：

- R 点：`R=C`，`G=avg(N,S,W,E)`，`B=avg(NW,NE,SW,SE)`；
- B 点：`B=C`，`G=avg(N,S,W,E)`，`R=avg(NW,NE,SW,SE)`；
- R 行 G 点：`G=C`，`R=avg(W,E)`，`B=avg(N,S)`；
- B 行 G 点：`G=C`，`R=avg(N,S)`，`B=avg(W,E)`。

所有计算保持 10 位精度，最后进入 AWB/CCM。首版只输出具有完整 3x3 CFA 窗口的 `x=1..W-2, y=1..H-2`；普通 edge replication 会破坏 Bayer 颜色相位，禁止使用。ROI 左上角移动奇数个像素时，必须同步修改 Bayer 相位。

### 5.3 AWB、CCM 与 Gamma

数据顺序固定为：

```text
Debayer RGB10 -> AWB gain -> 3x3 CCM + offset -> clamp -> Gamma LUT -> RGB888
```

所有模块必须有独立 bypass 位。没有真实传感器标定值时使用恒等参数：AWB 增益为 1、CCM 为单位矩阵、Gamma LUT 为线性映射。

### 5.4 可选 ISP

坏点校正、镜头阴影、3x3 中值滤波和锐化均放在独立模块，不得混入 Debayer 或网络模块。这样可以用寄存器旁路，并能在出现真实传感器问题后局部加入。

## 6. Resize

R1 使用中心对齐、可回压、两行缓存的双线性缩放器。坐标与系数由定点规范固定。支持非零尺寸且 `win<=MAX_WIDTH` 的输入缩放到 `640x480`；当前默认 `MAX_WIDTH=2048`，2560 宽输入必须先裁剪到不超过 2048，或增大参数后重新综合。第一阶段至少覆盖：

- 640x480 原尺寸旁路；
- 1280x960 到 640x480；
- 1280x720 先居中裁剪为 960x720，再缩放到 640x480；
- 非整数缩放比，用于发现 phase accumulator 漂移。

当前 Golden 的 `resize_nearest_u8()` 仍用于 R0 diagnostic 向量；它不是 R1 Resize 的最终质量实现。

## 7. MicroStyle-24 网络

### 7.1 设计原则

- 只在 640x480 帧的边界访问 DDR，中间层使用多速率行流水；
- 第一、第二层 stride 2，在 160x120 瓶颈完成主要风格变换；
- 使用 depthwise separable 和 inverted residual 降低 MAC；
- 使用 nearest-neighbor 上采样加普通卷积，不使用转置卷积；
- 学生网络只使用可折叠的 BatchNorm/affine，不在 MVP 中计算整帧 InstanceNorm；
- 所有残差分支在 QAT 中共享同一个激活 scale。

### 7.2 逐层结构

每个 MAC 定义为一次乘法加一次累加。下表不把 bias、ReLU、加法和插值计入 MAC。

| 层 | 运算 | 输出张量 | 逻辑张量大小 | 权重数 | MAC/帧 |
|---|---|---:|---:|---:|---:|
| Input | RGB888 转 s8 | 640x480x3 | 900 KiB | 0 | 0 |
| E0 | Conv 3x3, s2, 3->12 + affine + ReLU | 320x240x12 | 900 KiB | 324 | 24,883,200 |
| E1 | Conv 3x3, s2, 12->24 + affine + ReLU | 160x120x24 | 450 KiB | 2,592 | 49,766,400 |
| IRB1 | PW 24->48, DW 3x3, PW 48->24, residual | 160x120x24 | 450 KiB | 2,736 | 52,531,200 |
| IRB2 | 同 IRB1 | 160x120x24 | 450 KiB | 2,736 | 52,531,200 |
| IRB3 | 同 IRB1 | 160x120x24 | 450 KiB | 2,736 | 52,531,200 |
| D0 | NN x2, DW 3x3 C24, PW 24->16 + ReLU | 320x240x16 | 1,200 KiB | 600 | 46,080,000 |
| D1 | NN x2, DW 3x3 C16, PW 16->8 + ReLU | 640x480x8 | 2,400 KiB | 272 | 83,558,400 |
| OUT | Conv 3x3, 8->3 + affine + hard-tanh | 640x480x3 | 900 KiB | 216 | 66,355,200 |
| **合计** |  |  |  | **12,212** | **428,236,800** |

15 fps 对应 `6.424 GMAC/s`。INT8 权重约 11.9 KiB；采用便于硬件寻址的 int32 bias、int32 容器中的 int18 multiplier、u8 容器中的 shift，并做 16/64-byte 对齐后，当前生成器给出每种风格 16,896 B（16.5 KiB，预算按 17 KiB），远低于高阶挑战的 500 KB 参数限制。

IRB 内部顺序固定为：

```text
x
 -> PW 24->48 -> affine -> ReLU
 -> DW 3x3    -> affine -> ReLU
 -> PW 48->24 -> affine
 -> add(x) -> ReLU
```

若首次 Efinity 映射的 RAM 或时序不足，可以将 IRB 从 3 个减为 2 个。此降级版本为约 `375.706 M MAC/帧`、`9,476` 个权重，接口与量化合同不变。

### 7.3 训练和量化路线

推荐使用教师-学生方案：

1. PC 端训练或选用含 InstanceNorm 的标准 Fast Neural Style 教师；
2. 教师为内容数据集生成目标风格图；
3. MicroStyle-24 学生使用 Charbonnier/L1 蒸馏损失、VGG content/style loss 和 total-variation loss；
4. 可选加入相邻视频帧的时序一致性损失，但推理端不引入光流；
5. FP32 收敛后进行 QAT；权重采用 per-output-channel s8，激活采用 per-tensor s8；
6. 冻结 BN，将其折叠为每输出通道的 bias、multiplier 和 shift；
7. 导出整数权重、逐层描述符和 Python bit-exact 输出。

一个风格对应一组权重。多风格版本在 DDR 预置多组权重，在帧边界装入本地双 weight bank；切换过程中不能修改正在计算的 bank。

descriptor 的 64-byte/16-word 二进制布局固定在 `DESCRIPTOR_FORMAT.md`。当前生成的 22 条描述符用于**帧前配置专用多速率 stage 图**，其 tensor offset 为零，不是一份把 22 层依次写回 DDR 的执行表。descriptor reader/scheduler 只验证配置记录的 request/response/command/abort 传输；专用 stage 在装载配置后并发形成流水。如果将来改用单个共享 layer engine，必须生成非零 tensor arena 地址并重新计算中间张量 DDR 容量、带宽和总周期，不能直接复用当前“streaming layout”宣称可行。

## 8. 全流式缓存和计算资源

### 8.1 行缓存预算

下表是数据位容量，不包含具体 SRAM 宽度、端口和 banking 造成的碎片。

| 缓存 | 字节 |
|---|---:|
| E0 两行，640x3 | 3,840 |
| E1 两行，320x12 | 7,680 |
| 3 个 IRB 的 DW 两行，3x160x48 | 46,080 |
| 3 个 IRB 的 residual 对齐，3x2x160x24 | 23,040 |
| D0 两行，320x24 | 15,360 |
| D1 两行，640x16 | 20,480 |
| OUT 两行，640x8 | 10,240 |
| **逻辑通道 payload 合计** | **126,720 B（123.75 KiB）** |

126,720 B 是未计 C8 padding 的逻辑通道 payload 下界，相当于约 99 个 10-Kbit RAM block。若 E0/E1 直接复用通用 NHWC-C8 缓存，3 通道按 8 lane、12 通道按 16 lane 存储，下界增加 8,960 B，变为 135,680 B、恰好 106 个 M10K；也可为 E0/E1 设计专用窄缓存避免该开销。考虑通道 banking、端口宽度和深度取整，网络行缓存规划仍先取 110-140 个 block，但不是已证明上界。双参数 arena 的纯容量下界为 27 个 M10K；当前 `2×1056×128` 结构按 Ti60 `512×20` SDP 端口几何约需 42 个，因此权重供数不能继续沿用只按 bit 数得到的 13-16 块旧估计。必须以 Efinity 报告为最终依据，Vivado BRAM 数不能直接替代 Ti60 的实际映射。

### 8.2 100 MHz、15 fps 的建议 MAC 配置

| Stage | 建议 MAC lane/DSP | 最忙子阶段周期/输出 | 可用平均周期/输出 |
|---|---:|---:|---:|
| E0 | 5 | 324/5 = 64.8 | 86.8 |
| E1 | 9 | 2,592/9 = 288 | 347.2 |
| 每个 IRB | 4 + 2 + 4 = 10 | 1,152/4 = 288 | 347.2 |
| D0 | 3 + 5 = 8 | 384/5 = 76.8 | 86.8 |
| D1 | 8 + 8 = 16 | 144/8 = 18 | 21.7 |
| OUT | 12 | 216/12 = 18 | 21.7 |
| **CNN 合计** | **80** |  |  |

CNN 80 个 MAC lane、CCM/AWB 12 个乘法器和 Resize 18 个乘法器先形成约 110 个乘法器等价项；若 requant 能与 MAC 时分复用或映射到 LE，完整路径应争取控制在 120–140 个 DSP，给 Ti60 留 20–40 个余量。若每个 stage 独立复制 requant DSP，则很可能突破 160。每个 stage 单独实例化，stage 内按通道折叠并以 FIFO 解耦；不能只用总 MAC 数推断一个共享阵列一定满足吞吐。

可执行的 `model/microstyle_schedule.py` 给出更严格的当前下界：80 个 CNN MAC lane 时，瓶颈 `decoder1.pointwise1x1` 为 5,898,240 cycle/frame；100 MHz、15 fps 且预留 10% 后的上限是 6,000,000 cycle，只剩 101,760 cycle。该数字未计 FIFO stall、流水填排、权重 banking、requant 和 CDC。颜色流水约 12 个乘法器，双线性插值源码同时需要 18 个乘法器，因此在不单独复制 requant 乘法器时已是约 110 个乘法器等价项。当前 8×8 验证核额外并列 8 个 requant 乘法器；最终必须通过时分复用或 LE 映射控制 DSP，而不能把验证核逐 stage 原样复制。

## 9. 外部 DDR、帧率与 AXI

### 9.1 帧格式

DDR 推荐使用 XRGB8888，每像素 4 字节，单帧大小为：

```text
640 * 480 * 4 = 1,228,800 B
```

使用 128-bit AXI 时每 beat 正好传输 4 个像素。输入和输出 DMA 优先使用 16-beat burst，且不得跨越 AXI 4 KiB 边界。

### 9.2 30 fps 采集与 15 fps 网络的冲突

如果网络处理一帧接近 66.7 ms，仅有两个输入 buffer 时，摄像头可能在网络尚未读完时复用同一个 buffer。R1 必须采用以下方案之一：

- 三输入帧缓存，状态为 `FREE/CAPTURING/READY/PROCESSING`；或
- 原图显示 Ping-Pong 与 15 fps 风格输入 Ping-Pong 分离，选中的帧额外写入风格输入区。

风格输出另用 Ping-Pong。禁止用时间上的“应该来得及”代替所有权状态机。

若采用三个输入加两个输出 XRGB8888 缓冲，容量约 6.14 MB。无中间特征图 DDR 回写时的粗略持续带宽为：

- 摄像头写 30 fps：36.9 MB/s；
- 网络读加写 15 fps：36.9 MB/s；
- 720p 对比视图读取两张 640x480 图并以 60 Hz 重复：147.5 MB/s；
- 合计约 221 MB/s，尚未计 AXI 效率和刷新开销。

仲裁优先级为显示读最高、摄像头写次之、网络 DMA 再次、RISC-V 最低。显示 FIFO 即将欠载时必须抢占非实时主设备。

## 10. 720p 对比显示

不需要对 640x480 图像做二次缩放。推荐布局：

```text
1280x720 canvas
y = 0..119      黑边/标题
y = 120..599    左侧 x=0..639 原图；右侧 x=640..1279 风格图
y = 600..719    黑边/状态
```

原图可 30 fps 更新，风格图 15 fps 更新，显示扫描始终为 60 Hz。显示模块只在垂直消隐期锁存新的 buffer 地址，避免撕裂。OSD 使用字模 ROM 叠加 FPS、style ID、错误状态和处理延迟。

## 11. 板卡无关验证门槛

### 11.1 算法与 Golden

- RAW10 随机往返逐样本完全一致；
- 四种 Bayer pattern、四个 ROI 奇偶组合和边界像素全部覆盖；
- 恒定色块、渐变、棋盘格、单像素脉冲和自然图像均有中间结果；
- R1 float/QAT 与整数 Golden 完成逐层 tensor 导出；
- 整数量化模型与 fake-quant 导出模型在约定整数节点逐元素一致；
- 记录经典图像的 ISP PSNR/SSIM、量化前后 PSNR/SSIM 和饱和比例，但不得用观感替代 bit-exact 检查。

当前公开自然图回归为 6 张×4 Bayer，最低/平均 PSNR 为 29.3864/31.7270 dB；本地经典图成功解码 5 张、覆盖 20 个 Bayer case，跳过 2 张解码器不支持的 TIFF，最低/平均 PSNR 为 22.9877/31.7866 dB，其中 Lenna 四 Bayer 为 33.2582–33.2876 dB。这些数字只衡量 RGB 合成 RAW10 后的 ISP/Resize 重建；当前尚未输出 SSIM，也没有训练/QAT 网络的风格质量指标。

### 11.2 RTL

- 每个算术原语和每层输出与 Python 整数 Golden bit-exact；
- AXI BFM 随机插入 `ready` 拉低、读延迟和读写竞争后仍无丢像素、重复像素或死锁；
- SOF/EOL/EOF、坐标和数据延迟严格对齐；
- 帧中断、短行、CRC 错误和 reset 后不会把上一帧状态带入下一帧；
- 小图回归覆盖全部边界，至少完成一次 640x480 整帧 xsim；
- 从 cycle counter 证明 100 MHz 下不超过 6,666,667 周期/风格帧，并保留至少 10% 调度余量；
- 输入/输出 buffer 所有权断言在长时间随机仿真中零失败。

### 11.3 板前退出条件

达到以下条件后，才可称“无需具体板卡的 RTL 系统架构完成”：

1. R0 diagnostic 回归继续通过，并明确标注其非最终网络；
2. R1 的 RAW10、ISP、Resize、MicroStyle-24、DMA/AXI、帧管理、720p compositor 均有 RTL 或可替换 wrapper；
3. Python 整数 Golden 与 R1 RTL 完成逐层和端到端 bit-exact 回归；
4. 行缓存、权重带宽、MAC 排程和帧缓存冲突均有断言或报告；
5. 不含任何 Xilinx 专用原语，厂商相关模块全部位于 wrapper；
6. 明确保留以下板上验证项：真实 D-PHY/CSI-2、SC431HAI 寄存器、DDR PHY 校准、HDMI PLL/IO、Efinity 资源和时序、真实 15 fps 与功耗。

当前已达到 R0 持续回归、portable frame-job 组合和厂商边界隔离等架构条件，但第 3 项的训练后完整 R1 逐层/端到端 bit-exact，以及第 4 项的最终权重供数、完整网络周期与资源闭合仍未达到。因此可称“无需具体板卡的 RTL 帧任务架构基线完成”，不能称“全部板前退出条件完成”。
