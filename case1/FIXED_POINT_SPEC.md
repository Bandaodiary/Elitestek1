# 赛题一 Bit-Exact 定点与边界规范

状态：`R1 目标合同`

目标：保证 Python 整数 Golden、SystemVerilog RTL 和后续 RISC-V 配置对同一输入产生逐位一致结果。

本文件使用以下规范词：

- **必须**：Golden 与 RTL 不允许不同；
- **应当**：默认实现，修改时必须同时修改本规范和全部测试向量；
- **可选**：允许旁路或后续实现，但启用后的算术仍须遵守本文。

## 1. R0 Diagnostic 与 R1 Target 必须分离

### 1.1 R0 当前合同

当前 `c1_style_cnn3` 和 `tiny_style_infer()` 使用：

- RGB 通道均为 `uint8`，计算前零扩展；
- 权重为 `int8`，bias 为 `int32`；
- 每层仅使用整数右移，不含独立 BN multiplier；
- 舍入为“最近值，正负中点均远离 0”；
- 每层输出饱和到 `uint8 [0,255]`，这同时充当 ReLU；
- 两个 3x3 都是 valid 卷积，所以输入 `W x H` 最终输出 `(W-4) x (H-4)`；
- 输入/中间/输出排列为 HWC RGB，流信号为 `rgb[23:16]=R`、`[15:8]=G`、`[7:0]=B`。

R0 是现有回归的冻结合同。它不能被解释为 R1 的 s8 网络算术。

### 1.2 R1 目标合同

R1 使用对称 INT8 网络、SAME padding、folded BN affine 和与输入同尺寸的输出。R1 新模块使用独立命名或显式 `ARITH_PROFILE=R1`，不得悄悄复用 R0 的 u8 clamp 语义。

## 2. 通用数据类型

| 数据 | 类型 | 范围/格式 |
|---|---|---|
| CSI-2 payload | `uint8` | 0..255 |
| RAW sensor pixel | `uint10` | 0..1023 |
| BLC/Debayer pixel | `uint10` 或更宽中间值 | 输出钳位 0..1023 |
| AWB gain | `uint16 Q2.14` | 0..3.99994 |
| CCM coefficient | `int16 Q3.13` | -4..3.99988 |
| CCM offset | `int32` | 与 CCM 乘积同一 Q 域 |
| Gamma address/data | `uint10 -> uint8` | 1024 x 8 LUT |
| RGB stream | `uint8` 每通道 | 0..255 |
| CNN activation | `int8` | -128..127；ReLU 后 0..127 |
| CNN weight | `int8` | -127..127，训练导出禁止使用 -128 |
| CNN bias/accumulator | `int32` | 必须证明不溢出 |
| Requant multiplier | `int18` | 每输出通道一个 |
| Requant shift | `uint6` | 0..47 |
| Requant product | `int51` 或更宽 | 含符号扩展和舍入保护位 |
| Residual sum | `int9` | -256..254 |

实现可以使用更宽中间值，但在规范规定的量化边界必须产生相同结果。

## 3. 字节序、通道序和张量布局

### 3.1 流接口

RGB24 固定为：

```text
rgb[23:16] = R
rgb[15:8]  = G
rgb[7:0]   = B
```

### 3.2 DDR XRGB8888

每像素逻辑 32 位字固定为 `0x00RRGGBB`。在 little-endian DDR 地址空间中：

```text
address + 0: B
address + 1: G
address + 2: R
address + 3: 0x00
```

行首地址为 `base + y*stride_bytes`，像素地址为 `row + 4*x`。`stride_bytes` 必须是 16 字节整数倍。

### 3.3 CNN 布局

- 激活逻辑布局：HWC，channel 最内层；
- 普通卷积权重：OIHW，扁平顺序 `oc, ic, ky, kx`；
- depthwise 权重：CHW，扁平顺序 `c, ky, kx`；
- pointwise 权重：OI，扁平顺序 `oc, ic`；
- bias、multiplier、shift：按输出通道递增。

所有二进制模型文件必须带 manifest，记录维度、布局、scale、zero point、padding 和文件长度。装载器必须拒绝尺寸不符的数据。

## 4. RAW10 位序

对四个 10 位像素 `P0..P3`，五个 payload 字节定义为：

```text
B0 = P0[9:2]
B1 = P1[9:2]
B2 = P2[9:2]
B3 = P3[9:2]
B4[1:0] = P0[1:0]
B4[3:2] = P1[1:0]
B4[5:4] = P2[1:0]
B4[7:6] = P3[1:0]
```

解包公式为：

```text
P0 = (B0 << 2) | ((B4 >> 0) & 3)
P1 = (B1 << 2) | ((B4 >> 2) & 3)
P2 = (B2 << 2) | ((B4 >> 4) & 3)
P3 = (B3 << 2) | ((B4 >> 6) & 3)
```

每行独立开始 5-byte group 计数。行尾有剩余字节、payload 长度不匹配或超出配置宽度时，该帧置 `frame_bad`，不得把剩余字节带入下一行。

## 5. 坐标、帧标志和边界

- 坐标原点为左上角 `(0,0)`；x 向右，y 向下；
- `sof` 与 `(0,0)` 同拍，`eol` 与该行最后一个有效像素同拍，`eof` 与右下角同拍；
- 所有标志只在 `valid=1` 时有意义；
- stall 时像素、坐标和标志必须保持，或上游停止推进；
- reset 或坏帧丢弃后，行缓存、窗口移位寄存器、坐标和 RAW10 group 状态必须重新初始化；
- 不允许上一帧底行成为下一帧顶边界。

R1 CNN 的默认空间边界为 `clamp-to-edge`：

```text
sample(y,x) = image[clamp(y,0,H-1), clamp(x,0,W-1)]
```

训练模型、Python Golden 和 RTL 必须全部使用同一 replicate padding。R0 diagnostic 继续保持 valid 卷积，不受此条改变。

RAW Bayer 不能直接复制相邻边缘 sample，因为这会复制错误的 CFA 颜色相位。R1 ISP 首版采用与现有 RTL 一致的 **valid crop**：Debayer 只输出绝对坐标 `x=1..W-2, y=1..H-2`，Resize 的输入 ROI 从该矩形开始。若后续必须保持 Debayer 同尺寸，只允许采用保持 Bayer 奇偶相位的 reflect 取样（例如 `-1 -> 1`），不得使用普通 edge replication。

## 6. 通用舍入和饱和

### 6.1 有符号右移

函数 `round_shift_away(v, s)` 定义为最近整数，中点远离 0：

```text
s == 0:  v
v >= 0:  (v + 2^(s-1)) >> s
v <  0: -(((-v) + 2^(s-1)) >> s)
```

求负数绝对值前必须先扩展一位，避免最小负数溢出。`>>` 在上述公式中对非负 magnitude 使用逻辑意义的整数除法；最终负号单独恢复。

例子：

| v | s | 结果 |
|---:|---:|---:|
| 3 | 1 | 2 |
| 1 | 1 | 1 |
| -1 | 1 | -1 |
| -3 | 1 | -2 |
| 7 | 2 | 2 |
| -7 | 2 | -2 |

### 6.2 无符号平均

两个或四个非负整数的平均采用 half-up：

```text
avg2(a,b)       = (a+b+1) >> 1
avg4(a,b,c,d)   = (a+b+c+d+2) >> 2
```

### 6.3 饱和

```text
sat_u8(v)  = 0, if v<0; 255, if v>255; otherwise v
sat_u10(v) = 0, if v<0; 1023, if v>1023; otherwise v
sat_s8(v)  = -128, if v<-128; 127, if v>127; otherwise v
relu_s8(v) = max(v,0), after sat_s8
```

禁止以截断低位或二进制回绕代替饱和。

## 7. BLC、Debayer、AWB、CCM 和 Gamma

### 7.1 Bayer 相位

Bayer pattern 由 `(row_parity,column_parity)` 查表，不用硬编码 RGGB。ROI 后的新相位为：

寄存器、描述符、Python 和 RTL 统一使用以下 2 位编码；禁止用“R 所在位置”直接充当公开编码：

| 编码 | Pattern | 2x2 tile |
|---:|---|---|
| `00` | RGGB | `R Gr / Gb B` |
| `01` | BGGR | `B Gb / Gr R` |
| `10` | GRBG | `Gr R / B Gb` |
| `11` | GBRG | `Gb B / R Gr` |

四路黑电平寄存器顺序固定为 `(R, Gr, Gb, B)`，对应 phase ID `0,1,2,3`；其中 Gr 是 R 同行的绿色点，Gb 是 B 同行的绿色点。它不是简单的绝对奇偶位置顺序。

```text
new_row_phase = original_row_phase XOR (crop_y & 1)
new_col_phase = original_col_phase XOR (crop_x & 1)
```

四种 pattern 和四种 `(crop_x&1,crop_y&1)` 组合必须进入回归。

### 7.2 BLC

```text
blc_s11 = int(raw_u10) - int(black_level_u10[phase])
blc_u10 = sat_u10(blc_s11)
```

### 7.3 Debayer

Debayer 先按第 6.2 节在 10 位域插值，结果逐通道为 u10。首版边界使用第 5 节定义的 valid crop。禁止先转 8 位再插值。

### 7.4 AWB

`gain` 为 Q2.14：

```text
awb_wide = pixel_u10 * gain_q14
awb_u12  = clamp(round_shift_away(awb_wide,14), 0, 4095)
```

尽管输入是非负，仍调用统一舍入定义。恒等增益为 `16384`。

### 7.5 CCM

CCM 系数为 signed Q3.13，offset 已在同一乘积 Q 域：

```text
sum_q13[c] = offset_q13[c]
           + awb[R]*m[c][R]
           + awb[G]*m[c][G]
           + awb[B]*m[c][B]
linear_u10[c] = sat_u10(round_shift_away(sum_q13[c],13))
```

乘积和累加使用 signed32 或更宽。恒等矩阵的对角系数为 `8192`，其余为 0，offset 为 0。

### 7.6 Gamma

Gamma LUT 为 1024 个 u8 项，地址是 `linear_u10`。恒等/线性表定义为：

```text
lut[i] = min(255, (i + 2) >> 2)
```

R、G、B 可共享同一个组合表，但每拍需要满足三个读取端口；资源不足时允许三 bank 复制，不能时分复用到破坏像素吞吐。

## 8. R1 双线性 Resize

### 8.1 相位寄存器

RTL 不做运行时除法。RISC-V/Python 使用整数有理数计算 signed Q16.16：

```text
x_step_q16   = round_div_away(Win << 16, Wout)
y_step_q16   = round_div_away(Hin << 16, Hout)
x_phase0_q16 = round_div_away((Win-Wout) << 15, Wout)
y_phase0_q16 = round_div_away((Hin-Hout) << 15, Hout)
phase_x(x)   = x_phase0_q16 + x*x_step_q16
phase_y(y)   = y_phase0_q16 + y*y_step_q16
```

其中 `round_div_away(n,d)` 对有符号分子、正分母执行最近整数除法，中点远离 0。配置软件与 Golden 使用同一整数寄存器值；寄存器值而非浮点近似是最终事实来源。

### 8.2 采样和权重

对 signed Q16.16 phase：

```text
x0 = floor(phase_x / 65536)        // 算术右移 16
fx16 = phase_x - x0*65536          // 0..65535
wx1 = min(4096, (fx16 + 8) >> 4)   // Q0.12
wx0 = 4096 - wx1
x1 = x0 + 1
```

`x0` 和 `x1` 在取样时分别 clamp 到 `0..Win-1`；y 同理。先水平、后垂直，每一级独立 half-up：

```text
h0 = ((wx0*p[y0,x0] + wx1*p[y0,x1]) + 2048) >> 12
h1 = ((wx0*p[y1,x0] + wx1*p[y1,x1]) + 2048) >> 12
out = ((wy0*h0 + wy1*h1) + 2048) >> 12
```

三通道完全相同。旁路模式必须逐像素不变，不允许经过插值后产生 1 LSB 差异。

由于每一级都满足 `w0+w1=4096` 且输入为 `0..255`，加上2048后的分子范围为 `2048..1046528`，严格小于 `2^20`；右移12位的结果天然位于 `0..255`，不得在合法数据通路中另加输出饱和。RTL在输入事务接受边界检查权重和合同，违反合同属于上游协议错误。

R0 的 nearest resize 使用单独合同，不得拿 R0 输出作为 R1 bilinear 的期望值。

## 9. R1 CNN 算术

### 9.1 输入映射

RGB888 到 CNN s8：

```text
a_s8 = int16(rgb_u8) - 128
```

因此 0 映射为 -128，128 映射为 0，255 映射为 127。网络训练和 QAT 必须使用此 zero point。

在 packed two's-complement byte 上，该变换与反变换都等价于 `byte ^ 8'h80`。`c1_rgb_s8_center_codec.sv` 以一槽弹性 ready/valid 实现此双向映射，并原样传递坐标和 SOF/EOL/EOF；不得依赖 Verilog 的隐式 signed cast 代替 zero-point 运算。

### 9.2 普通、Depthwise 和 Pointwise 卷积

所有卷积遵守：

```text
acc_s32[oc] = bias_s32[oc]
for each kernel input:
    acc_s32[oc] += int8(activation) * int8(weight)
```

普通卷积遍历 `ic,ky,kx`；depthwise 只使用相同 channel；pointwise 只遍历 `ic`。数学结果必须在 signed32 范围内。模型导出器必须计算每层理论界和校准集实际峰值；RTL 仿真需有溢出断言。

MicroStyle-24 最大 3x3 depthwise 输入通道数为 48，但每个输出只累加 9 项；最大普通 3x3 的每输出累加项为 E1 的 `3*3*12=108`。signed32 留有充分余量，仍不得允许 bias 无限制破坏该前提。

### 9.3 Folded BN / affine requant

每个输出通道保存 `bias_s32`、`mult_s18`、`shift_u6`：

```text
product_wide = int51(acc_s32) * int18(mult_s18)
q_swide = round_shift_away(product_wide, shift_u6)
```

随后按层描述符执行：

- `ACT_NONE`：`sat_s8(q)`；
- `ACT_RELU`：`max(sat_s8(q),0)`；
- `ACT_HARD_TANH`：等同 `sat_s8(q)`，用于末层命名表达。

BN 的 `gamma/sqrt(var+eps)` 和 beta 在导出期折叠进 weight/bias/mult/shift。R1 RTL 中保留明确的 affine requant 单元及每通道参数，作为 BN 近似硬件。不得在运行期计算浮点均值、方差或平方根。

若使用 power-of-two 量化，允许 `mult=1` 并仅通过 shift 实现；它仍必须产生与 Golden 相同结果。

### 9.4 SAME stride-2 卷积

E0 和 E1 输出尺寸固定为输入的一半。输出 `(yo,xo)` 的 3x3 窗口中心位于输入 `(2*yo,2*xo)`：

```text
input_y = 2*yo + ky - 1
input_x = 2*xo + kx - 1
```

越界使用 replicate。当前目标尺寸均为偶数；R1 首版拒绝奇数宽高配置，避免 `ceil/floor` 歧义。

### 9.5 Residual add

残差主支和旁路必须由 QAT/导出器保证相同 scale 和 zero point。两支先在 signed9 中相加：

```text
sum_s9 = int9(main_s8) + int9(skip_s8)
out_s8 = relu_s8(sat_s8(sum_s9))
```

禁止对 scale 不同的两支直接相加。若导出器发现不同 scale，必须拒绝模型或显式插入 requant，不能静默继续。

### 9.6 Nearest-neighbor 上采样

两倍上采样的唯一定义为：

```text
out[y,x,c] = in[y >> 1, x >> 1, c]
```

每个输入 feature vector 按左上、右上、左下、右下次序产生四个输出坐标。数值不做任何舍入。

### 9.7 网络输出

末层 s8 转回 RGB888：

```text
rgb_u8 = uint8(int16(out_s8) + 128)
```

末层输出已由 `sat_s8` 限制，所以无需再次饱和。通道顺序仍为 R、G、B。

## 10. 参数更新和帧原子性

- 权重、bias、multiplier 和 shift 使用 active/shadow bank；
- RISC-V 只写 shadow bank；
- `commit` 仅在网络 idle 或下一帧 SOF 前原子切换；
- 同一帧内禁止部分层使用旧参数、部分层使用新参数；
- manifest 的层数、尺寸和数据长度校验通过前不能 commit；
- 配置写入期间出现 reset 时 active bank 保持上一次完整模型或进入明确 invalid 状态。

## 11. Bit-Exact 验证门槛

### 11.1 算术单元

- `round_shift_away`：覆盖 0、正负 1、中点、最大正负数及 shift 0..47；
- `sat_u8/sat_u10/sat_s8`：覆盖边界前后至少两个值；
- 随机至少 10,000 组 acc/mult/shift 与 Python 比较；
- 任何 RTL/Golen 差异均为失败，不设置“允许 1 LSB”容差。

### 11.2 RAW 与 ISP

- RAW10 0、1023、2-bit LSB 全组合和随机 payload 往返 exact；
- 四 Bayer pattern、ROI 四种奇偶相位、四角和四边 exact；
- BLC、AWB、CCM、Gamma 分别测试恒等、最小、最大和饱和参数；
- Resize 覆盖 1:1、2:1、3:2、非整数比和负初始 phase，逐像素 exact；
- 对由 RGB 合成的 Bayer 图记录重建 PSNR/SSIM，但硬件验收仍以整数 Golden exact 为准。

### 11.3 CNN

- 每层至少测试全零、全最大、交替符号、冲激、随机权重和真实模型权重；
- 检查 E0/E1 四边 replicate、stride-2 坐标和输出尺寸；
- 每个 IRB 分别导出 expand、depthwise、project、residual tensor；
- 整数 Python、RTL 在每个量化边界逐元素 exact；
- QAT fake-quant 与导出的整数模型建议达到 `PSNR >= 35 dB` 且 `SSIM >= 0.98`，否则重新校准或 QAT；该质量门槛不能替代 bit-exact 门槛。

### 11.4 流与帧

- 随机 valid gap/backpressure 不改变像素值或次序；
- SOF/EOL/EOF 和坐标与目标像素同拍；
- 帧间 flush 后首像素不依赖上一帧；
- 参数 bank 只在帧边界切换；
- 64x48 小图必须逐层跑通，之后至少一次 640x480 整帧 xsim；
- 100 MHz 目标下每帧总周期不超过 6,666,667，并应保留至少 10% 余量。

## 12. 变更纪律

凡是改变以下任一内容，都必须在同一提交中更新本文件、Python Golden、manifest、RTL 和测试向量：

- rounding mode；
- padding/border mode；
- RGB/字节/权重布局；
- resize phase 或插值顺序；
- activation zero point/scale；
- residual scale；
- 层顺序、stride、channel 数；
- 参数 bank 的 commit 时刻。

不得通过放宽图像误差容限来掩盖 bit-exact 合同不一致。
