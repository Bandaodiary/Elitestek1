# Case-1 Ti60F225I3 板卡配置档（板前冻结版）

> 版本：2026-08-28。本文把“用户提供的开发板规格”“赛题文件中的目标器件”和“由规格推导的带宽/容量数字”分开记录。截图本身是硬件资料，不是要求 RTL 必须采用某个实现方式的附加指令；本次实际工作请求是建立 Icarus/GTKWave 与 Efinity 的板前互操作入口。

## 1. 已确认的事实

### 1.1 目标器件和板卡

| 项目 | 已知值 | 来源/可信度 |
|---|---|---|
| FPGA | 易灵思 Titanium `Ti60F225I3`，Ti60F225 开发套件 | 赛题选题指南与用户截图；目标器件已确认 |
| 工艺/规模 | 16 nm FinFET；宣传值约 60K LE | 用户截图；器件级资源仍以 Efinity 2026.1 map 报告为准 |
| PLL | 4 个独立 PLL（PLL_BL/TL/TR/BR） | 用户截图 |
| 板载时钟 | 25 MHz、27 MHz、50 MHz 有源差分晶振 | 用户截图；具体连接到哪个 bank/PLL 尚未核验 |
| 电源 | VCC/VCCA 0.95 V，VCCAUX 1.8 V；HSIO 1.2/1.5/1.8 V，HVIO 最高 3.3 V | 用户截图；不能替代 pin 的 I/O standard 约束 |

赛题文件的目标型号记录在 [`../../doc/全国大学生嵌入式芯片与系统设计竞赛'2026FPGA赛道选题指南-易灵思.pdf`](../../doc/全国大学生嵌入式芯片与系统设计竞赛'2026FPGA赛道选题指南-易灵思.pdf)。板卡 revision、完整 pin map、speed/温度等级和官方 Efinity 工程仍需从随板工程确认，不能由截图反推。

### 1.2 外部存储和高速接口

| 接口 | 板卡资料 | 对 Case-1 的直接含义 |
|---|---|---|
| DDR3 | `MT41J128M16JT-125`，256 MB（2 Gb），物理数据宽度 x16，最高 800 Mbps | 可放 3×8 MiB tensor bank、framebuffer、软件堆；必须使用官方 DDR3 控制器/PHY 和校准流程 |
| QSPI Flash | `GD25LQ64`，8 MB | 适合 bitstream、启动代码、压缩权重/descriptor；不能独占存放当前 24 MiB tensor arena |
| MIPI D-PHY | 1.5 Gbps，最高 4 lane/group | 板级 CSI-2 RX/PHY 必须由 Efinity IP/参考设计提供；当前 stub 只代表解包后的并行语义 |
| HDMI | RX + TX，最高 1080p@60 Hz | 先用内部 color-bar 验证视频时序，再接 HDMI PHY；当前 RTL 输出是并行 RGB/DE/HS/VS |
| LVDS | 最高 1.5 Gbps | 可作为扩展/调试链路，当前 Case-1 不直接依赖 |
| Ethernet | YT8531SC RGMII，10/100/1000M 自适应 | 可用于远程加载/诊断的后续扩展，不能替代 DDR 主数据通路 |
| 下载/调试 | FT4232HL Type-C（供电、下载、UART）及板载 USB-UART | 可用于 JTAG/OpenOCD、串口日志和板上寄存器回归 |

## 2. 可直接使用的容量和带宽推导

下面是十进制单位的**理论上限或结构估算**，不是 DDR 控制器实测值。DDR 刷新、读写 turnaround、命令开销、PHY 校准和共享仲裁都会降低有效带宽。

### 2.1 DDR3 峰值

物理 x16、800 MT/s 的数据面峰值为：

```text
800,000,000 transfers/s × 16 bit ÷ 8 = 1,600,000,000 B/s
```

即约 **1.6 GB/s（12.8 Gb/s）**。板级控制器若向用户逻辑暴露 128-bit AXI、100 MHz UI，AXI 数据面同样是 `100 MHz × 16 B = 1.6 GB/s` 的理论数；这只是在控制器恰好采用该 UI 配置时成立，必须以生成的 DDR IP 端口和时钟为准。`DDRWidth=128` 在 Sapphire IPXACT 中表示 AXI 侧数据宽度，不表示板上 DDR 颗粒变成 x128。

### 2.2 当前 tensor 路径与 15 fps

当前 correctness-first 顺序 adapter 的结构计数为 `342,220,800 B/frame`，因此：

```text
342,220,800 × 15 = 5,133,312,000 B/s ≈ 5.133 GB/s
```

这约为 DDR3 理论峰值的 **3.21 倍**，所以该版本只能作为功能基线，不能通过增加时钟约束“硬跑”到 15 fps。

性能模型中的理想候选 `47,547,744 B/frame` 对应：

```text
47,547,744 × 15 = 713,216,160 B/s ≈ 713.216 MB/s
```

约占 1.6 GB/s 峰值的 **44.6%**。这仍是假设 cache 命中、AXI burst、多个 outstanding 且无刷新/仲裁损失的下界；与视频和 CPU 流量相加后余量会明显变小，不能当作已达到 15 fps。

### 2.3 Framebuffer 和 Flash 预算

XRGB8888 的一个 `640×480` frame 是：

```text
640 × 480 × 4 = 1,228,800 B
```

三输入、双输出五个 slot 合计 `6,144,000 B`（约 5.86 MiB），建议全部放 DDR，不要尝试放入 Ti60 片上 RAM。当前 tensor arena 的三 bank 为 `3×8 MiB=24 MiB`；与五个 framebuffer 合计约 **31.31 MB（十进制，29.86 MiB）**，256 MB DDR 在容量上足够，但仍要为 Sapphire 外部内存、堆栈、日志、对齐和 DDR 控制器保留区留余量。

8 MB QSPI Flash 不足以原样容纳 24 MiB tensor arena。建议 Flash 只保存 bitstream、RV32 启动镜像、压缩/定点权重和 descriptor；启动后由 CPU/JTAG/以太网加载到 DDR，再由软件把实际基址写入 Case-1 descriptor。最终地址必须来自生成的 `soc.h`/linker，不在文档中硬编码一个假地址。

### 2.4 片上 RAM/DSP 的方向性预算

器件宣传值为约 60K LE、160 DSP、2.6 Mbit embedded memory（精确可用资源以 Ti60F225I3 的 Efinity report 为准）。当前板前结构中：

| 结构 | 原始容量/代理观察 | 解释 |
|---|---:|---|
| 三行 C8 window cache | `3×1280×64 = 245,760 bit`（约 30 KiB） | 仅 payload 容量下界；端口形状和同步读会改变实际 EBR/M10K 数量 |
| 双参数 bank | 约 33,792 B payload | 外部/片上 staging 取决于最终实现；不能把 Vivado BRAM tile 直接换算成 Ti60 block |
| descriptor 双 bank | `2×22×512 = 22,528 bit` | 适合窄 RAM 组装，避免 512-bit 宽单块造成碎片 |
| 当前 full-top proxy | 约 47.5K LUT、34.8K FF、32 BRAM tile、81–85 DSP | `xc7a200t` 结构代理，不是 Ti60 LE/EBR/DSP 结果；Soft Sapphire、DDR、PLL、视频 IP 尚未合并 |

因此板上首轮应先做 Soft Sapphire 单核 + 最小 APB + LED/UART 的 `map`，再逐步加入 DDR、视频 IP、CNN/cache；每一步保留资源余量和可启动 bitstream。不要把“60K LE”与 Xilinx LUT 一一相加，也不要把独立 proxy 的 DSP 数直接与 Sapphire 厂商表相加。

## 3. 时钟、复位和接口边界计划

1. 将 25/27/50 MHz 只视为**候选输入源**，由 Efinity PLL/IP 生成 `core_clk`、DDR UI、pixel_clk 和必要的 camera/CSI 时钟；不要假定 50 MHz 一定是 core 或 27 MHz 一定是 MIPI。
2. 720p60 常用像素时钟约 74.25 MHz，1080p60 约 148.5 MHz；当前 `c1_video_timing_720p` 的并行输出先在板前 color-bar 验证，实际 HDMI 时钟/PHY 由官方 IP 和约束决定。
3. `core_clk`、`pixel_clk`、`camera_clk` 三域的 reset 必须在各自 PLL/DDR ready 后同步释放；APB、camera FIFO、display FIFO 和 AXI bridge 的 CDC 不能用“绑同一时钟”规避。
4. DDR UI 若不是 `core_clk`，在 `c1_r1_portable_soc` 与 DDR controller 之间放明确的 AXI clock converter/async bridge，并验证 AW/W/B、AR/R 顺序和 4-KiB burst 边界。
5. FT4232HL 的 UART/JTAG 先只承载 ID、版本、DDR memory test 和 QoS 计数；逐像素数据不要通过 UART 传输。

## 4. 推荐的板级 bring-up 分层

| 层级 | 最小工程 | 通过条件 |
|---|---|---|
| L0 | Ti60 + PLL + reset + LED | map/P&R 成功，按键/LED 稳定 |
| L1 | Soft Sapphire RV32 + UART/APB loopback | CPU 启动，读写 Case-1 `ID/VERSION/CAPABILITY`，IRQ 可清除 |
| L2 | DDR3 controller + 固定地址短 burst | 校准完成、memory test 通过、刷新期间无协议错误 |
| L3 | HDMI color-bar、MIPI/RAW10 固定 pattern | DE/HS/VS、SOF/EOL/EOF、CDC FIFO 无 under/overflow |
| L4 | Case-1 小帧 `8×8/64×48` + 真实 descriptor | 软件 START→IRQ→IDLE，frame ownership 不丢失 |
| L5 | 640×480 长帧 + QoS monitor | 30 帧无 protocol/underflow/deadline 错误，再评估 15 fps |

每一层的 Efinity `work/`、`outflow/`、波形和 bitstream 放在可删除的 staging 目录；仓库只保留 project 参数、约束来源、紧凑报告和复现命令。详见 [`../BOARD_BRINGUP_CHECKLIST.md`](../BOARD_BRINGUP_CHECKLIST.md) 与 [`../RESOURCE_BUDGET.md`](../RESOURCE_BUDGET.md)。

## 5. 当前未确认项

- 板卡 revision、Ti60F225I3 的完整 package/speed 约束及官方 `.xml/.sdc/.pin`；
- DDR3 控制器是 Efinity 原生 IP 还是随板参考工程封装、AXI UI 的实际宽度/频率和地址映射；
- 25/27/50 MHz 各自连接、MIPI lane 映射、HDMI 电气/PHY 配置、RGMII 时钟相位；
- 生成 Soft Sapphire 的 APB base、PLIC IRQ 号、cache 属性和 CPU 可见 DDR 窗口。

在这些输入确认前，可以完成 RTL、Python golden、软件 ABI、APB/IRQ seam、Icarus 小型互操作测试和 Efinity IP Manager 的 boardless 生成演练；不能生成可信的最终 pin constraint、bitstream 或 Ti60 时序签核。
