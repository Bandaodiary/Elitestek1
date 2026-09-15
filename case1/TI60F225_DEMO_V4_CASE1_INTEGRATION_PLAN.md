# Ti60F225 DemoBoard v4 例程对赛题一的复用与集成分析

> 2026-09-10 复审更正：本文是历史规划，部分接口判断已被源码复核推翻。实施前请先阅读 [RTL 与例程独立复审](D:/contest/2026FPGA/yilingsi/case1/review/RTL_AND_DEMO_REVIEW_20260910.md)。尤其是 CSI 输出已解码且不可回压、08 的 userInterruptA 为标量、CPU 断开 DDR 需重新安排软件与数据加载、v6 无活动 DSI 控制器实例，以及不能要求所有随板控制器都重新 IP 生成。本文复用百分比不构成量化评估；v1 资源也不是新顶层的上界。当前 AXI 仲裁器另有两处已复现问题，应先修复再进入正式联合集成。

状态：工程分析稿（可作为后续 Efinity GUI 集成的接口合同）  
更新时间：2026-09-01  
适用器件：Ti60F225I3 开发套件

## 1. 结论先行

企业资料不是赛题一的 CNN/风格迁移加速器，而是一组板级视频、DDR、Sapphire 和接口烟测工程。它对赛题一最有价值的部分是“器件外壳”和“上板 bring-up 路径”，不是现有算法、帧所有权或共享内存架构的替代品。

推荐的集成边界是：

1. 以当前 `c1_r1_portable_soc` 作为唯一的赛题一功能主系统，保留它的 ISP、Resize、MicroStyle-24、帧表/帧所有权、七客户端 AXI 仲裁和显示预取。
2. 从企业 v6 例程提取 MIPI CSI 物理端口、SC431 摄像头 I2C 起始表、DDR3 PHY/控制器连接方式、时钟/复位状态和 HDMI 物理发送边界。
3. 从 08 SoC 例程提取 Sapphire RV32、APB、UART/JTAG、用户中断和“单 AXI 主机连接 DDR”的 Efinity 工程组织方式。
4. 从 03 HDMI TX 例程提取可在 Icarus/xsim 中验证的普通 TMDS/视频时序模型；加密的 v6 DVI 文件只留给 Efinity/板卡阶段。
5. 在上述板级 IP 与当前便携 RTL 之间新增薄适配层，禁止把 v6 的 `frame_buffer_V3`、Debayer、DSI 和旧的帧轮换控制器整体叠加进来。

因此，企业平台外壳对赛题一的相关度约为 80%～90%，可直接复用的核心代码约为 40%～50%；剩余工作集中在 RAW10 保真适配、AXI ID/时钟转换、CPU 访问策略和 AI/Resize 的带宽闭合。

## 2. 资料与判定口径

本次只读取了压缩包目录、工程 XML、顶层/接口相关源文件和少量参数文件，没有读取 v1 `outflow` 下的大体积仿真或布局布线日志，也没有启动 Vivado、xsim 或 Efinity。压缩包及工程入口如下：

| 资料 | 用途 | 判定注意事项 |
|---|---|---|
| [SC431 v6 压缩包](D:/contest/Ti60F225_DemoBoard_v4/10_Ti60f225_sc431hai2hdmi_demo/Ti60f225_sc431hai2hdmi_v6.rar) | 最新视频链路、CSI、DDR3、frame buffer、HDMI/DSI 顶层参考 | 归档内仍有旧注释、加密文件和多个生成目录，必须以 XML 的活动源列表和顶层实例化关系为准 |
| [08 SoC 工程 XML](D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_hardjtag_demo/par/ddr_demo_ti60/ddr_demo_ti60.xml) | Sapphire+DDR+UART/JTAG 工程组织和版本信息 | 资料主要是 2025.2 生成的旧工程，不能直接当作 2026.1 生成物 |
| [08 DDR/Sapphire 顶层](D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_hardjtag_demo/rtl/ddr3_example_top.v) | 生成 IP 的端口连接范例 | 只适合作为连接模板，不能与赛题一视频顶层直接拼接 |
| [08 Axi_Mux.v](D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_hardjtag_demo/par/ddr_demo_ti60/src/Axi_Mux.v) | 多路 AXI 参考实现 | 文件头默认 ``X2``；未证明是赛题一所需的七路活动路径 |
| [03 HDMI TX 顶层](D:/contest/Ti60F225_DemoBoard_v4/03_hdmi_tx_demo/hdmi_tx_demo_v2/rtl/hdmi_src/top.v) | 普通 TMDS/视频时序仿真参考 | Efinity 原语、PLL 和高速串行器仍需板级工程生成 |
| [当前便携主顶层](D:/contest/2026FPGA/yilingsi/case1/rtl/top/c1_r1_portable_soc.sv) | 赛题一功能基线 | 不实例化厂商 IP，板级边界是有意保留的可移植接口 |

v6 归档的工程版本为 `2026.1.132.1.2`，而 08/v1 资料中仍可见 `2025.2.288.3.8`。用户当前安装的是 Efinity 2026.1.132 并已打补丁，后续应在 GUI 中重新生成 IP，并把实际生成版本、端口宽度和时钟频率记录到本文件的“待确认项”表中。

## 3. 当前赛题一 RTL 的真实接口合同

当前主顶层 [c1_r1_portable_soc.sv](D:/contest/2026FPGA/yilingsi/case1/rtl/top/c1_r1_portable_soc.sv) 的接口不是一块“空壳”，而是已经完成了功能数据面的组合：

| 边界 | 当前合同 | 对板级集成的含义 |
|---|---|---|
| 控制 | `core_clk` 域 APB，地址默认 12 bit，数据 32 bit，带 `PSTRB/PSLVERR` | Sapphire 只需通过 APB 适配器访问 CSR；地址窗口必须以生成 BSP 头文件为准 |
| 摄像头 | `camera_clk` 域已解码的单像素 `camera_raw10[9:0]`，附带 `x/y/SOF/EOL/EOF/valid` 和 ready | MIPI/CSI 不能直接接线，必须先把包流变成此无损 RAW10 流 |
| 视频 | `pixel_clk` 域 `video_rgb[23:0]`、`DE/HS/VS` | HDMI 发送器应位于外层；当前 RTL 不负责 TMDS 物理编码 |
| 存储 | 一个 board-facing AXI4-128 主接口，地址 32 bit、数据 128 bit、无 AXI ID/QoS 端口 | 现有七个内部客户端已在主顶层内仲裁；外层只能连接一个 DDR 从接口，或显式增加 CPU 主机仲裁 |
| 时钟/复位 | `camera_clk`、`core_clk`、`pixel_clk` 分离，域间已有 FIFO/握手边界 | 不要用“把所有时钟绑在一起”代替 CDC；板级 reset 还要等待 PLL lock 与 DDR calibration |
| 帧格式 | 外部 DDR 的帧槽为 little-endian XRGB8888，最小 stride 16 B 对齐 | v6 的 16 bit frame buffer 输出不能直接代替当前显示/输入格式 |
| 内部存储客户端 | 七路：捕获、表/参数、输入/输出 DMA、原图/风格图显示、tensor cache/bridge 等 | 企业例程的单一三帧泵不能再作为第二套所有权控制器并行存在 |

当前设计已有 3 个输入、2 个输出的帧所有权模型、五个帧槽和三组各 8 MiB 的 tensor bank。板卡无关仿真已经覆盖许多局部 AXI/帧/缓存合同，但这不等于已经通过 Ti60 的 DDR、CSI 和 HDMI 物理签核。

## 4. 企业工程逐项利用建议

### 4.1 `10_Ti60F225_sc431hai2hdmi_demo`：平台外壳参考（优先级最高）

v6 活动顶层 `ti60f225_oob_top` 包含四路 CSI 数据物理端口、摄像头 I2C、DDR3 物理引脚、多个时钟和 HDMI/DSI 输出。它还实例化了 `csi_rx_controller`、DDR3 控制器、`frame_buffer` 和 Debayer。

可以复用或照着重建：

- Ti60F225 板卡上的 CSI lane/LP-HS/终端/FIFO 端口命名及约束组织；
- CSI IP 的 reset、FIFO 状态、CRC/ECC/包错误信号的引出方式；
- 摄像头 I2C 控制器的时钟和复位连接，及活动寄存器表的组织形式；
- DDR3 controller/PHY 的物理引脚、校准时钟、`cal_done` 观察点；
- HDMI 外层的时钟、TMDS 发送和复位释放边界。

不能直接复用：

- v6 整个 `ti60f225_oob_top`；它会带入自己的三帧 bank switch、Debayer、DSI、旧视频时序和专用复位树；
- v6 `frame_buffer_V3` 作为当前系统的总帧管理器；它是一个单视频泵，不理解赛题一的三输入/双输出所有权、CNN 中间 tensor 和显示 pair；
- v6 的默认 RAW 提取方式；它把 10 bit 样本截成 8 bit，具体拼接为 `w_mipi_rx_data[39:32]`、`[29:22]`、`[19:12]`、`[9:2]`，会丢失每个样本的两个低位；
- v6 的 Debayer 输出；当前赛题一已有可配置黑电平、AWB、CCM、Gamma 和自己的输入格式合同。

一个容易忽略的事实是：v6 顶层整体时序写成 1920×1080，但其 frame buffer 实例参数又是 `MAX_VID_WIDTH=960`、`I_VID_WIDTH=32`、`O_VID_WIDTH=16`。这只能说明例程某一条视频路径的参数取值，不能直接证明 640×480、720p 或 RAW10 无损路径已经适配。

### 4.2 `08_ti60f225_soc_demo`：CPU、APB、DDR 烟测基线（优先级最高）

08 工程的核心价值是展示 Efinity 生成的 Sapphire RV32 如何通过 APB、UART/JTAG、用户中断和一条 AXI 主机路径接入板级 DDR。其 [soc.v](D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_hardjtag_demo/par/ddr_demo_ti60/ip/soc/soc.v) 显示了 `io_apbSlave_0_*` 和带 ID 的 `io_ddrA_*` 端口；[ddr3_example_top.v](D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_hardjtag_demo/rtl/ddr3_example_top.v) 则给出生成 IP 到 DDR controller 的连接范例。

推荐用法：

1. 第一版板级工程只启用 Sapphire APB、UART/JTAG、一个用户 IRQ 和 LED；用它读写赛题一版本号、状态和错误寄存器。
2. 第二版单独验证 DDR `cal_done`、单主机读写和地址范围；先不要接 CSI、HDMI 或 CNN。
3. Sapphire 的 APB 主口经过现有 [c1_sapphire_apb_master_adapter.sv](D:/contest/2026FPGA/yilingsi/case1/rtl/vendor/c1_sapphire_apb_master_adapter.sv) 接到赛题一 CSR。该适配器已经处理“16 bit/无 PSTRB → 12 bit/全字写”的差异。
4. Sapphire 的用户中断经过 [c1_sapphire_irq_adapter.sv](D:/contest/2026FPGA/yilingsi/case1/rtl/vendor/c1_sapphire_irq_adapter.sv) 接 `userInterruptA[0]`，保持 level IRQ 和软件 W1C 语义。

初版建议把 Sapphire 的外部 DDR 主口隔离掉，让当前 `c1_r1_portable_soc` 的单一 AXI 主口负责加速器/视频内存。若以后需要 CPU 直接读写 DDR，再把 CPU 作为第八个逻辑客户端或在板级外层新增“两主机到 DDR”的仲裁器；不能把两套 AXI 输出直接并联。

### 4.3 `03_hdmi_tx_demo`：仿真友好的显示参考（优先级中）

该例程有普通的时序发生器、DVI/TMDS 编码和 10:1 串行发送器，适合在 Icarus/xsim 中做颜色条、DE/HS/VS 和 TMDS 符号检查。它不能证明 Ti60 高速 IO、PLL 或实际 HDMI 线缆稳定，因此板级阶段仍需用 Efinity 生成的器件原语和约束。

建议先用一个行为版 `c1_ti60_hdmi_video_adapter` 把当前 `video_rgb/DE/HS/VS` 接到 03 的普通编码器模型；通过后，再替换为 v6/官方 IP 的物理发送壳。不要在 Vivado 中强行展开 v6 的 `*.v_encrypted.v`。

### 4.4 `11_Ti60F225_MIPI_CSI_loop_demo`、`07_Ti60F225_MIPI_C2D_Demo`

这两类工程适合确认 CSI/D-PHY 的 lane、LP/HS 状态和物理复位顺序。它们没有赛题一的帧表、Resize、CNN 或共享 DDR QoS，不能作为功能系统基线。可复用的证据应限定为“物理 CSI 能够出包、错误计数器可读、像素时钟可观测”。

### 4.5 `01`、`17` 和 `02` 等工程

- `01` 的时钟、按键、LED 和复位小工程适合作为最小板级 smoke；
- `17` 的 UART 连接可用于早期 Sapphire/BSP 日志；
- `02` 的 HDMI RX/TX 示例主要是接口活动或直通，不提供赛题一所需的 DDR 帧缓存；
- v1 的完整视频工程可作为历史资源“红线”参考，但不能与 08 SoC 工程资源相加，也不能把旧 report 当作 v6/I3 的新 P&R 结果。

## 5. 必须新增的适配层

推荐新建一个板级文件组，而不是修改便携主顶层的端口合同：

| 建议文件 | 责任 | 不负责的内容 |
|---|---|---|
| `case1/rtl/vendor/c1_ti60_case1_board_adapter.sv` | 汇总时钟/复位、CSI、DDR、Sapphire、HDMI 端口；连接状态和 IRQ | 不实现 CNN、帧所有权或 AXI 仲裁 |
| `case1/rtl/vendor/c1_ti60_csi_raw10_adapter.sv` | CSI 64 bit 包流 → 单像素 RAW10，恢复 x/y/SOF/EOL/EOF，保留 CRC/ECC/overflow 状态 | 不做 Bayer、Gamma 或 Resize |
| `case1/rtl/vendor/c1_ti60_ddr_axi_adapter.sv` | 无 ID AXI128 ↔ 生成 DDR AXI；处理 ID、时钟、reset、4 KiB/响应合同 | 不新增第二套 frame buffer |
| `case1/rtl/vendor/c1_ti60_hdmi_video_adapter.sv` | RGB/DE/HS/VS ↔ 行为 TMDS 或 Efinity HDMI 外壳 | 不改变当前 compositor 的输出语义 |
| `case1/efinity/c1_ti60_case1_top.xml` | 新建的 2026.1 board project、IP manifest、约束和顶层 | 不把生成目录提交为便携 RTL |

### 5.1 CSI/RAW10 适配合同

v6 CSI 输出是 `pixel_data[63:0]`，而当前输入是一拍一个 10 bit 像素。适配器至少要完成：

- 根据 CSI 数据类型和 lane 顺序解包 RAW10；不能照搬 v6 的 RAW8 截位；
- 对齐帧起始、行结束和帧结束标记，处理包头/包尾造成的气泡；
- 将 CSI 的 pixel clock 与 `camera_clk` 明确分开，必要时使用异步 FIFO；
- 将 CRC/ECC、FIFO full/empty、packet-size/frame/line error 转成当前 `camera_overflow` 或额外状态寄存器；
- 由活动 I2C 表和板上实际传感器确认是 SC431HAI。目录名、旧注释或 `IMX219` 字样不能单独作为传感器配置依据。

### 5.2 AXI/DDR 适配合同

v6 `ddr3_parameter.vh` 的典型配置是 AXI 数据 128 bit、控制器 ID 4 bit、地址 32 bit；`frame_buffer_V3` 内部又使用 6 bit ID，08 生成的 Sapphire DDR 端口可见 8 bit ID。当前赛题一外层没有任何 ID 端口，七路内部客户端由事务锁定仲裁器串行化。

因此适配器必须显式规定：

1. 只有在“当前仲裁器保证单一在途事务、控制器接受固定 ID”得到仿真证据后，才能把 ID 置零或固定映射；收到的 `RID/BID` 必须检查是否符合该映射。
2. 如果生成的 DDR UI 不在 `core_clk`，必须使用完整 AXI clock converter/异步桥，不能分别同步地址和数据线。
3. `ARLEN/AWLEN`、`AxSIZE`、4 KiB 边界、`RLAST/WLAST` 和取消后的 drain 要在适配器边界重新断言。
4. v6 128 beat、16 B/beat 的示例 burst 是 2048 B，仍低于 4 KiB；当前 tensor 默认桥是单 beat（`ARLEN/AWLEN=0`）。两者不能凭“都是 AXI128”视为等效性能路径。

CPU 访问策略有两个可行版本：

- **推荐的第一版：** Sapphire 只负责 APB/控制和 UART，当前加速器独占 DDR AXI；参数和帧数据通过预置内存、后续 DMA 或专用加载流程进入 DDR。
- **后续版本：** 将 CPU DDR 主机作为第八个客户端加入一个有响应路由的仲裁层，或在当前单一 AXI 主口外增加二主机桥。需要定义 cache flush、软件 fence、优先级和 CPU 长 burst 对视频 deadline 的影响。

### 5.3 APB/IRQ 适配合同

生成的 Sapphire APB 端口是 `io_apbSlave_0_PADDR[15:0]`、`PSEL/PENABLE/PWRITE/PWDATA`，没有 `PSTRB`。当前适配器把写访问视为全字写，并拒绝超出本地窗口的高地址位。真正的基地址、窗口大小和 `soc.h` 宏必须来自新生成 BSP，不能手写假地址。

IRQ 采用电平保持直到软件清除的语义；建议把 `cal_done`、CSI error、DDR error 和 Case-1 terminal IRQ 分别放在状态寄存器中，避免把一次性脉冲直接接到 PLIC。

### 5.4 HDMI/复位适配合同

当前系统只输出并行视频，板级 HDMI 外壳负责像素 PLL、慢/快串行时钟、TMDS 编码和 IO 发送。v6 的 `w_arstn` 是多个 PLL lock 的与逻辑；赛题一还必须加入 DDR calibration ready 和 CSI/IP ready，但不能在 AXI 事务已握手后突然切断时钟或 reset。推荐每个时钟域异步拉低、同步释放，并由系统控制器在所有必需 ready 之后才放行 `START`。

## 6. 推荐目标架构

```text
Ti60F225 board top (Efinity 2026.1)
  PLL/clock/reset + MIPI CSI IP + camera I2C + DDR3 controller + HDMI PHY + Sapphire RV32
       |
       v
c1_ti60_case1_board_adapter (new thin wrapper)
  +-- CSI decoded RAW10/SOF/EOL/EOF --> c1_r1_portable_soc camera ports
  +-- Sapphire APB --> c1_sapphire_apb_master_adapter --> Case-1 CSR/ISP
  +-- Case-1 IRQ --> c1_sapphire_irq_adapter --> userInterruptA[0]
  +-- Case-1 AXI4-128 (single, ID-less) --> ID/clock/reset adapter --> DDR3 UI
  +-- Case-1 RGB/DE/HS/VS --> HDMI video/TMDS shell

c1_r1_portable_soc (portable RTL, unchanged functional owner)
  capture/ISP + frame table + Resize + MicroStyle-24 + display/compositor
  seven internal AXI clients --> c1_axi_n_serial_arbiter_128
```

这里刻意没有画出企业 `frame_buffer_V3` 和 Debayer。它们可以作为独立视频烟测工程存在，但不能与当前 capture/display/NN 所有权同时控制同一块 DDR。

## 7. 分阶段实施顺序

### 阶段 0：拿到板卡前（当前即可完成）

- 建立 `c1_ti60_*_adapter.sv` 的行为模型和端口 manifest；顶层仍可用 Icarus 编译；
- 为 CSI 64 bit → RAW10 编写纯 RTL 解包器，并用 Python/行为 CSI 源产生包头、气泡、CRC 错误和随机 backpressure；
- 为 DDR adapter 编写带 ID 的 AXI BFM 场景，覆盖固定 ID、`AW/W` 先后、`AR/R` gap、4 KiB 边界、`RLAST/BRESP` 错误和 reset/calibration gate；
- 用 03 的普通 TMDS 编码器或自有行为 checker 验证颜色条和当前并行视频时序；
- 先保留当前 `FRAME_WIDTH=640`、默认单拍 tensor bridge 和现有七客户端回归，新增适配层不改变默认功能；
- 记录一份 IP manifest（IP 名称、生成版本、时钟、数据宽度、ID 宽度、reset 极性、待确认端口）。

阶段 0 的完成标志是“板级适配器在没有任何 Efinity 加密文件时可 elaboration，且 AXI/APB/RAW10/TMDS 边界都有可重复的行为回归”。

### 阶段 1：Efinity GUI 最小 SoC

从 08 工程重新生成一个 Sapphire RV32 + APB + UART/JTAG + 一个用户 IRQ，不加入 CSI、HDMI 和 CNN。验证 LED、UART、版本寄存器、IRQ 清除和 reset release。

### 阶段 2：单主机 DDR

从新版本 IP 生成 DDR3 controller/PHY，先使用单一 AXI master 做 walking-1/PRBS/地址别名测试，确认 `cal_done`、UI 时钟和 ID 行为；再连接 Case-1 AXI 适配器。此阶段不要把 Sapphire DDR master 和 Case-1 master 并联。

### 阶段 3：CSI + 单帧回路

加入 SC431 I2C 和 CSI IP，先绕过 CNN，只完成一帧 RAW10 → Case-1 capture → DDR → display。读取 CSI CRC/ECC/包错误计数，并比较 Python/行为模型中的像素、SOF/EOL/EOF 计数。

### 阶段 4：HDMI 外壳

先输出颜色条，再输出原图，再输出原图/风格图双路 compositor。xsim 使用普通 TMDS checker；Efinity/板卡才验证高速 IO、PLL 和显示器锁定。

### 阶段 5：启用 Resize/AI

先用 8×8、16×8 和 64×48 shape gate，再逐步恢复 640×480。每一步同时记录 display underflow、七客户端等待、tensor cache 命中、frame deadline 和错误 drain。

### 阶段 6：资源与 15 fps 优化

只有首个完整 P&R 结果出来后，才决定是否打开 tensor burst/refill、display response FIFO、更多 outstanding 或并行 MAC。优先删除 v6 中不需要的 DSI、旧 Debayer 和重复 framebuffer，再根据 Ti60 实际 RAM/PLL/GBUF/HSIO/时序报告做优化。

## 8. 验证矩阵

| 功能 | Icarus/xsim（行为） | Efinity（实现） | 实体板 |
|---|---|---|---|
| APB CSR/IRQ | APB 读写、PSTRB、错误、W1C | 新生成 Sapphire 端口和 BSP 地址 | UART 读版本、启动/完成/错误 IRQ |
| CSI RAW10 | 随机包、气泡、标记和解包 golden | IP 端口合法性、时钟/复位、综合 | SC431 出包、CRC/ECC、长帧稳定性 |
| DDR AXI | 随机 AW/W/AR/R/B 背压、ID、4 KiB、reset gate | controller/PHY 时序、calibration | PRBS、长时间读写、温升/错误计数 |
| 帧所有权 | 无撕裂、drop/abort/drain、双显示 pair | RAM/时序和跨域实现 | HDMI 原图/风格图连续显示 |
| AI/Resize | Python golden、定点误差、shape gate | LUT/FF/RAM/DSP/Fmax | 图像质量、端到端延迟、FPS |
| HDMI | 普通 TMDS symbol checker | 高速 IO/PLL/约束 | 显示器锁定、长时间无闪烁 |

建议在日志和报告中统一使用 `SIM_PASS`、`PNR_PASS`、`BOARD_PASS` 三种状态，不能用“例程 bitstream 能下载”替代赛题一端到端通过。

## 9. 资源、带宽和时序红线

- 板卡是 Ti60F225I3，标称 60,800 XLR、256 个 Memory Block、160 个 DSP、32 个 GBUF、4 个 PLL；DDR3 为 `MT41J128M16JT-125`，x16、256 MB，理论数据面约 1.6 GB/s。
- v1 完整视频工程历史结果约为 RAM 83.2%、PLL 4/4，已经接近红线；v6 没有可直接替代的新 P&R 证明，必须重新实现和测量。不能把 v1 视频与 08 SoC 的资源百分比相加后推断新顶层结果。
- 08 SoC+DDR 的历史报告约为 XLR 25.5%、RAM 25.8%、DSP 4/160、GBUF 8/32、PLL 2/4，只能作为 Sapphire/DDR 外壳量级参考。
- 当前赛题一 full-top proxy 中出现过约 47.5K LUT、34.8K FF、32 BRAM tile、81～85 DSP，但这是另一器件结构的代理数字，不是 Ti60 LE/EBR/DSP 结果。
- 当前五个 640×480 XRGB8888 帧槽约 6.144 MB，三 tensor bank 为 24 MiB，合计约 31.31 MB（29.86 MiB），容量上低于 256 MB；真正风险是带宽、刷新、读写切换、仲裁和 CPU 争用。
- 现有 correctness-first tensor 路径的模型流量约 5.133 GB/s（15 fps 估算），显著超过板级理论峰值；即使采用窗口复用/packing 的理想估算约 713 MB/s，也还没有计入采集、显示、参数和控制流量。因此例程的长 burst 只能作为优化参考，不能自动解决赛题一 15 fps。
- v6 SDC 含 DSI、多个旧时钟和高速串行时钟；不要整份复制。应根据删减后的新顶层和 2026.1 生成 IP 重写时钟约束，并明确 false-path/CDC 边界。

## 10. 明确的“做/不做”清单

### 应做

- 重新生成 2026.1 的 Sapphire、DDR3、CSI、PLL 和 HDMI IP；
- 以活动 XML/实例化关系为准，逐个确认端口宽度、reset 极性、ID 宽度和时钟频率；
- 保留当前便携 RTL 的七客户端仲裁和帧所有权，把企业资源限制在外层；
- 先完成 LED/UART/APB，再 DDR，再 CSI 单帧，再 HDMI，最后 AI；
- 将 `cal_done`、CSI 错误、AXI response 错误、display underflow 和 CNN deadline 纳入同一组软件可读状态。

### 不应做

- 不要把 v6/v1 `ti60f225_oob_top` 整体复制为赛题一顶层；
- 不要同时实例化企业 `frame_buffer_V3` 和当前 capture/display frame manager 控制同一 DDR；
- 不要把 v6 RAW8 截位路径当作 RAW10 无损输入；
- 不要把 `Axi_Mux.v` 文件头的“2～8 路”当成已经验证的七客户端实现；
- 不要在 Vivado/xsim 中依赖 `*.v_encrypted.v` 的厂商保护内容；
- 不要把旧 readme、hex、bit 或 v1 P&R 数字当作赛题一功能/资源的最新证明。

## 11. 待确认项与预留空位

| 项目 | 当前状态 | 需要在 GUI/板卡阶段填写 |
|---|---|---|
| SC431HAI 活动 I2C 表 | 目录/注释存在冲突，未作最终传感器确认 | 传感器料号、RAW10 数据类型、行/帧时序、I2C 地址 |
| CSI 输出定义 | 观察到 64 bit `pixel_data` 和独立 pixel clock | 每拍有效像素数、lane 顺序、marker 语义、错误端口 |
| DDR AXI UI | 例程显示 128 bit，但时钟/ID 需以新 IP 为准 | UI 时钟、ID 宽度、最大 burst、地址映射、`cal_done` 时序 |
| Sapphire 地址窗口 | 适配器默认本地 12 bit | 新 BSP `soc.h` 中的 APB 基址、窗口大小、缓存属性 |
| CPU 是否直接访问 DDR | 第一版建议否 | 若需要，确定第八客户端/外层二主机仲裁和 cache fence |
| HDMI 时钟 | v6 有多级视频/串行时钟 | 目标分辨率、像素时钟、PLL 输出、HSIO 资源 |
| 新顶层资源 | 尚无合并后的 Ti60 P&R 结果 | XLR、Memory Block、DSP、GBUF、PLL、HSIO、WNS/TNS |
| 15 fps | 尚未完成 native 长帧板测 | 每阶段有效 FPS、DDR 利用率、underflow/deadline |

## 12. 下一步建议

当前最有收益、且不需要板卡的下一步是实现并验证两个纯 RTL 边界：

1. `c1_ti60_csi_raw10_adapter.sv`：用行为 CSI 64 bit 输入产生无损 RAW10 像素和帧标记；
2. `c1_ti60_ddr_axi_adapter.sv`：对 ID、4 KiB、时钟/复位和 `R/B` 响应建立可断言的 AXI 合同。

这两个适配器通过后，再在 Efinity GUI 中以 08 SoC 的 Sapphire/DDR 工程为控制基线生成新项目；v6 的 CSI/HDMI 物理外壳作为第二条输入，逐项接入，而不是复制整个视频 demo。这样可以在不增加大体积仿真生成目录的情况下，把“例程可用”逐步收敛为“赛题一端到端可验证”。

## 13. 相关现有文档

- [企业例程详细分析](D:/contest/2026FPGA/yilingsi/TI60F225_DEMOBOARD_V4_DETAILED_ANALYSIS.md)
- [企业例程交接摘要](D:/contest/2026FPGA/yilingsi/TI60F225_DEMOBOARD_V4_HANDOFF_SUMMARY.md)
- [当前 RTL 架构说明](D:/contest/2026FPGA/yilingsi/case1/ARCHITECTURE.md)
- [Ti60F225 板卡资源画像](D:/contest/2026FPGA/yilingsi/case1/efinity/TI60F225_BOARD_PROFILE.md)
- [板级 bring-up checklist](D:/contest/2026FPGA/yilingsi/case1/BOARD_BRINGUP_CHECKLIST.md)
- [Efinity/RISC-V 工具链指南](D:/contest/2026FPGA/yilingsi/case1/EFINITY_RISCV_TOOLCHAIN_GUIDE.md)
- [赛题一 RTL 架构与验证报告](D:/contest/2026FPGA/yilingsi/case1/report/chapters/赛题一_RTL架构设计与验证报告.md)
