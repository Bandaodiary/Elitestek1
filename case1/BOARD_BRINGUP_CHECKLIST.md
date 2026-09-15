# Case-1 Ti60 / Efinity 板卡前置清单

> 版本：2026-08-28。竞赛指南已指定 Ti60F225I3 的 Ti60F225 开发板，用户截图还给出了 DDR3 颗粒；本文仍只冻结**接口和验证顺序**，不填写未经官方工程核验的板卡 revision、DDR 控制器拓扑/时序、引脚、封装细节、I/O 电气标准或 Efinity 原语名称。拿到随板参考工程后，再把本文件中的占位项转换为可执行的 Pin/Clock 约束。

Efinity 2026.1、Soft Sapphire RV32、RISC-V IDE 和命令行 flow 的本地路径/操作见 [EFINITY_RISCV_TOOLCHAIN_GUIDE.md](EFINITY_RISCV_TOOLCHAIN_GUIDE.md)。赛题文件与用户截图中的板卡事实、DDR/时钟推导集中记录在 [efinity/TI60F225_BOARD_PROFILE.md](efinity/TI60F225_BOARD_PROFILE.md)；本清单不重复猜测 pin。

## 1. 当前可作为板级集成边界的 RTL

推荐把 `rtl/top/c1_r1_portable_soc.sv` 作为最终板无关数据通路顶层。它不例化 Efinix IP，已经把 APB、采集、22-stage CNN/tensor、显示和七客户端 AXI4-128 组合起来。`rtl/top/c1_portable_top.sv` 是较早的骨架/兼容包装层，不应与 R1 portable SoC 混用。

### 1.1 必须由板级 wrapper 提供的时钟/复位

| 端口 | 当前语义 | 板级动作/待确认 |
|---|---|---|
| `core_clk` | 所有 APB、控制、CNN、tensor、共享 AXI fabric 的主时钟；Vivado proxy 以 100 MHz（10 ns）约束 | 由板载振荡器/PLL 或 DDR UI 时钟提供；拿到 DDR IP 后确认 AXI UI 是否同频，若不同频必须插入合法 clock bridge |
| `pixel_clk` | 显示 pixel 域；`c1_video_timing_720p` 的注释目标为 74.25 MHz 720p60 | 由视频 PLL/时钟 IP 提供。当前 proxy 用 14 ns（约 71.43 MHz），只是结构代理，不能当成 74.25 MHz 板级约束；若实际采用 74.25 MHz，应约束 13.468 ns 并以 PLL 生成时钟为准 |
| `camera_clk` | 传感器/CSI 解包后的 camera 域时钟；通过 async FIFO 进入 core 域 | 由相机接收 IP 输出或传感器恢复时钟提供，频率和占空比依传感器模式而定；不得假定与 `core_clk` 同步 |
| `arst_n` | 异步拉低、各时钟域同步释放 | 板级复位监控/按键/电源良好信号接入；`c1_reset_sync` 每域默认 2 级释放。验证复位脉冲宽度、上电时序和 PLL lock 后再释放系统 |

当前 RTL 的 reset 生成位于 `c1_r1_portable_soc.sv:537-545`：同一个 `arst_n` 分别同步到三域。多位配置/事件已经通过握手、异步 FIFO 或 toggle CDC 传输；不要用“把三时钟绑在一起”绕过 CDC。

### 1.2 APB/CPU 控制边界

板级 wrapper 或 Sapphire/RISC-V 子系统需要驱动：

`psel`, `penable`, `pwrite`, `paddr[11:0]`, `pwdata[31:0]`, `pstrb[3:0]`，并接收 `prdata`, `pready`, `pslverr`, `irq`。APB 从设备时钟是 `core_clk`。如果 CPU/Sapphire 使用另一时钟，需在 wrapper 中放 APB clock bridge；不能把异步 CPU 总线直接接到这些端口。

软件 ABI 已在 `software/include/c1_accel.h` 和 `software/README.md` 固定。首个板上读回应检查 `ID/VERSION/CAPABILITY`，再执行 DDR 测试、参数/描述符/framebuffer 分配和 START。QoS 窗口见第 3 节。

### 1.3 相机输入边界

`camera_valid`, `camera_raw10[9:0]`, `camera_x[CAMERA_X_BITS-1:0]`, `camera_y[CAMERA_Y_BITS-1:0]`, `camera_sof`, `camera_eol`, `camera_eof`, `camera_ready`, `camera_overflow` 属于**已完成接收/解包后的并行语义**。默认 640×480 时 `SENSOR_WIDTH=642`、`SENSOR_HEIGHT=482`，因此 x/y 位宽由参数计算（x=10 bit，y=9 bit）。

`rtl/vendor/c1_camera_vendor_adapter_stub.sv` 目前只是透明 ready/valid 直通，明确没有 MIPI D-PHY、CSI-2 包解析、RAW10 lane 对齐或传感器 I2C。板上必须替换/包裹它，并先用 color-bar/固定 RAW10 pattern 验证 SOF/EOL/EOF 与坐标一致性。

### 1.4 视频输出边界

顶层输出 `video_rgb[23:0]`, `video_de`, `video_hsync`, `video_vsync`；输入 `pixel_clk`。`c1_video_timing_720p.sv` 产生 1280×720 总时序（1650×750），active-high sync。`rtl/vendor/c1_video_vendor_adapter_stub.sv` 只做并行直通，未实现 PLL、TMDS/差分串行、I/O delay 或 HDMI PHY。板上应先让 wrapper 输出内部 color-bar，再接实际视频 IP；不要把 stub 的像素时钟直连到未经约束的外部引脚。

### 1.5 DDR/AXI 数据边界

`m_axi_*` 是 core 域、32-bit 地址、128-bit 数据的无 ID AXI4 子集：

- 写：`AWADDR/AWLEN/AWSIZE/AWBURST/AWVALID/AWREADY`、`WDATA/WSTRB/WLAST/WVALID/WREADY`、`BRESP/BVALID/BREADY`；
- 读：`ARADDR/ARLEN/ARSIZE/ARBURST/ARVALID/ARREADY`、`RDATA/RRESP/RLAST/RVALID/RREADY`。

当前七客户端 fabric 是 ID-less、事务锁定、AXI 读写方向独立。Efinix DDR controller/PHY 应接在此 seam 后，并确认：AXI 数据宽度、burst 最大长度、4-KiB 边界、读响应顺序、刷新造成的停顿、UI 时钟和 reset/initialization done。若 DDR IP 的 AXI 时钟不同于 `core_clk`，必须显式加入 clock conversion/async bridge；不要在约束中把两个实际异步时钟误声明为同步。

三组 tensor bank（3×8 MiB=24 MiB）以及 framebuffers 位于外部 DDR，不是 Ti60 片上 RAM。地址宽度目前只有 32 bit，软件会拒绝高 32 bit 非零地址。

## 2. 约束缺口和拿到板卡后的最小输入

当前 `case1` 没有可提交的 `.lpf/.cst/.sdc`、Ti60F225I3 板卡 pin map 或本次生成的 Efinity project；赛题 PDF 与截图给出的器件/DDR 颗粒已记录，但具体 revision、DDR 控制器/IP 拓扑、地址映射和官方时钟约束仍待确认。现有 Vivado Tcl 的 `create_clock` 仅用于 `xc7a200tsbg484-1` 结构 proxy，且把三时钟设为异步组；它不是 Ti60 约束，不能直接复制到板卡。

拿到官方板卡资料后，按下表补齐（先写清来源，再落成工具语法）：

| 类别 | 必填信息 | 验收 |
|---|---|---|
| device | Ti60 具体型号、封装、speed grade、温度等级 | Efinity 能打开目标 part，资源报告可复现 |
| board clocks | 板载 oscillator 频率、相位、PLL lock、DDR UI 频率 | 生成时钟约束与实际频率测量一致；core/pixel/camera CDC 分组只依据真实拓扑 |
| reset | 电源良好、外部复位极性、PLL/DDR ready 依赖 | 上电、热复位、PLL 未锁定期间无 APB/AXI 假事务 |
| camera I/O | MIPI/并行接口 lane、差分对、I/O standard、sensor mode、I2C 地址 | 接收 IP 输出 RAW10/sideband；固定 pattern 无丢帧/坐标错位 |
| video I/O | HDMI/LVDS/并行接口、电气标准、极性、实际 pixel clock | 720p color-bar 在显示端锁定；DE/HS/VS 极性正确 |
| DDR I/O/IP | 已知 `MT41J128M16JT-125` x16/800 Mbps；仍需核验控制器/IP、颗粒拓扑、校准完成信号、AXI ports、地址映射 | memory test + AXI BFM/硬件回读；确认 24 MiB tensor arena 与五个 framebuffer 区不重叠 |
| CPU/APB | Sapphire/RISC-V 时钟、APB base、PLIC IRQ 号、UART | 读 ID、写 CSR、START/IRQ/WAIT_IDLE 全流程可重复 |

约束文件中至少应包含：外部时钟输入周期/波形、PLL/DDR 生成时钟、输入时钟 I/O 约束、相应 false-path/CDC 例外、DDR IP 官方时序约束和所有实际使用 I/O 的位置/电气属性。AXI/APB 内部信号不是板级 pins，不应人为分配 I/O。

## 3. 已有 QoS/15-fps 观测点及板上接法

将 `ENABLE_SHARED_QOS_MONITOR=1` 作为**板级诊断 build**（默认兼容 build 仍为 0）。monitor 的 aggregate snapshot 已接入 APB：

| 地址 | 含义 |
|---:|---|
| `0x108` | bit0 enabled，bit1 frame_active，bit2 counter overflow，bit3 display underflow，bit4 deadline miss，bit5 AXI protocol error |
| `0x10c` | QoS 观测窗口完成帧数 |
| `0x110` | 最近一帧 core cycles |
| `0x114` | deadline miss 累计 |
| `0x118` | display underflow 累计 |
| `0x11c/0x120` | 读/写 busy cycles |
| `0x124/0x128` | 读/写 owner hold 最大 cycles |
| `0x12c` | AXI protocol error 累计 |

窗口边界是 `boardless_start_valid && boardless_start_ready` 到**带新帧标签的 display prefetch 完成**；`display_swap_event`/VSYNC 是独立的可见性事件。因此软件要同时记录 QoS window、IRQ/DONE、VSYNC/swap，不能只把 `0x110` 当作端到端显示延迟。

`SHARED_QOS_COUNTER_W=24` 在 100 MHz 下可覆盖约 167 ms；板上第一次应读取并清零，再连续采集至少 30 帧，记录：`last_frame_cycles`、deadline/underflow/protocol、读写 busy、owner hold，以及 IRQ 到 `STATUS.BUSY=0` 的时间。deadline 应按实际 `core_clk` 设置为 `floor(f_core/15)`，并额外留出 DDR refresh、CDC 和显示余量；BFM 中的 1,000,000-cycle deadline 只是故意触发告警的测试值。

当前 per-client 明细（client 0..6 的 AW/AR wait、W/R/B stall）仍主要作为层次化诊断，尚未全部映射到 APB。若板上需要定位 starvation，使用 Efinity 的片上逻辑分析/调试核或增加一个诊断 CSR bank，至少采样 client-4/5 display、client-6 tensor 的 AR wait/R stall 和 FIFO occupancy。诊断核只放在 bring-up build，最终资源评估应关闭或单独计入。

## 4. 资源与实时性闸门（不可用 proxy 代替）

当前最新 full-top Vivado proxy 仅用于趋势：

| build | LUT | FF | BRAM tile | DSP | core WNS @ proxy 100 MHz |
|---|---:|---:|---:|---:|---:|
| fixed descriptor-size control | 47,512 | 34,821 | 32 | 85 | -1.079 ns |
| iterative W×H shift-add experiment | 47,611 | 34,917 | 32 | 82 | -1.206 ns |

两者均为未 P&R/无真实 I/O/无 Efinity DDR IP 的 Xilinx proxy，不能换算 Ti60 LE/M10K，也都不是时序签核。Ti60 器件级上限（见 `RESOURCE_BUDGET.md`）为 62,016 LE、256 个 10-Kbit memory blocks、160 DSP、2.6 Mbit embedded memory；实际可用余量必须以 Efinity 映射、布局布线和 DDR/视频 IP 资源报告为准。3×8 MiB tensor arena 和 framebuffers 仍计入外部 DDR 带宽/容量。

实时闸门也尚未满足：当前正确性 baseline 的 tensor 结构流量约 5.133 GB/s（15 fps，未计仲裁/刷新），64-MAC 纯算术下界约 6,691,200 core cycles/frame，略高于 100 MHz/15 fps 的 6,666,667-cycle 预算。故拿到板卡后应先测真实 DDR service time 和 CNN issue/II，再决定是否启用 burst/cache/outstanding/MAC 版本；不能因小帧 xsim PASS 或 proxy WNS 改善而宣称 15 fps。

## 5. 建议的板前→上板顺序

1. **板前冻结**：保持 portable SoC 通用端口和软件 ABI；完成 lint/elaboration、Python golden、8×8/64×48 两帧 BFM；默认关闭所有实验开关，单独保留 `ENABLE_SHARED_QOS_MONITOR=1` 诊断配置。
2. **wrapper 骨架**：只新增 board wrapper，不改核心 RTL；先接时钟/复位、APB、IRQ、内部 color-bar 和 DDR IP placeholder。引脚先使用待填字段，禁止提交猜测 pin。
3. **时钟/复位冒烟**：板上读 ID/VERSION，观察三域同步释放；PLL/DDR 未 ready 时确认无 AXI valid。记录实际 core/pixel/camera 频率。
4. **DDR 最小闭环**：运行 DDR memory test，再用固定地址做 AXI 单拍/短 burst 读写；验证 4-KiB 边界、WSTRB、RLAST/WLAST、刷新停顿和 24 MiB tensor arena 分区。
5. **视频/相机分开 bring-up**：先视频 color-bar，再相机固定 RAW10 pattern；分别确认 720p timing、SOF/EOL/EOF、坐标、CDC FIFO overflow/underflow。
6. **软件控制闭环**：加载 `parameter_arena.bin`/`descriptors.bin`，配置三输入/双输出表和 ISP，START→IRQ→`c1_accel_wait_idle()`；不要在 DONE IRQ 后立即复用 DDR。
7. **QoS/帧率测量**：打开 monitor，至少 30 帧记录 APB QoS 与 VSYNC/swap；先建立不启用实验优化的基线，再一次只启用一个 burst/cache/outstanding/MAC 变体做 A/B。
8. **最终签核**：Efinity map/P&R、时序、功耗和资源报告齐全，且相机持续流、显示无 underflow、deadline/protocol=0、目标帧率达到题目要求后，才把相应参数写入 release build。

## 6. 明确的当前阻塞项

- 已知竞赛目标为 Ti60F225I3/Ti60F225 开发板，截图也给出 `MT41J128M16JT-125` DDR3 x16/800 Mbps，但尚未核验具体板卡 revision、pin map、DDR 控制器/IP 配置与地址映射、相机/视频物理连接和本次 Sapphire APB base/IRQ；因此现在仍不能生成可提交的 pin/LPF/clock constraint。
- vendor camera/video stubs 和 DDR seam 不是可直接上板的 IP；它们必须由官方 Efinity IP/参考设计替换。
- full-top proxy 仍有负 WNS，且 15 fps 尚无 native 长帧证据；后续优化应以真实 Ti60/Efinity P&R 与 QoS 计数为依据，而非继续堆叠无板卡约束的 Vivado A/B。
