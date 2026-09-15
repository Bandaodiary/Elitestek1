# 赛题一 RTL 与企业例程独立复审

> 后续状态：本报告记录修复前的发现。同日已实施协议与探针修复，并增加可选显示并发，见 [修复与验证记录](D:/contest/2026FPGA/yilingsi/case1/review/RTL_FIXES_20260910.md)。R1/R2 已有修复回归；R3/R4/R6 的持续性能与物理签核仍未闭合。

日期：2026-09-10。范围：当前便携主顶层、共享 AXI/显示/CDC 关键路径、Efinity 探针与验证记录，以及 DemoBoard v4 中 v6 视频例程和 08 Sapphire 工程。此次是风险导向审查，不是全部源文件的形式验证。未修改生产 RTL、未重跑综合/P&R、未下载板卡。

## 1. 总体判断

已有 RTL 值得保留：算术与厂商 IP 分离、帧所有权、参数提交、软件 ABI、取消后排空以及 Python 整数参考模型形成了可继续开发的基础。小尺寸真实参数/算术验证有实际价值，不能因下面的问题否定全部工作。

但它目前属于功能原型，尚不足以作为完成实时视频要求、可直接接任意 AXI IP 的协处理器交付。此次在共享仲裁器复现两处问题；默认计算/访存结构和显示互斥也限制持续运行。之前大量 PASS 覆盖了特定 BFM 与配置，并没有证明通用 AXI 兼容性、目标板资源或 15 fps。

企业例程分析的方向基本成立，但不是完全正确。特别是“全部 IP 重新生成”“Sapphire 先断开 DDR”“CSI 包流重新解包”“单根中断当八位向量”等建议需要更正。最稳妥的开发方法是先复现企业原始基线，再逐项替换接口内侧功能。

## 2. RTL 审查发现（按优先级）

### R1 / P1：写地址握手成为 WVALID 的前提，可与合法 AXI 从机死锁

位置：[共享仲裁器](D:/contest/2026FPGA/yilingsi/case1/rtl/dma/c1_axi_n_serial_arbiter_128.sv:179)。`WR_ADDRESS` 只送 AW；AW 完成后进入 `WR_DATA`，才送 W。上游即使同时保持 AWVALID/WVALID，下游仍观察不到 WVALID，直到 AWREADY 先到。

合法从机可以等待写数据出现再接受地址。如果它注册地执行 `AWREADY <= WVALID`，当前仲裁器与它互相等待。此次用真实 DUT 的单客户端参数配置复现：30 个周期内 AW/W 握手均为零，AWVALID=1、WVALID=0；开关 read skid 均如此。

这不是指企业 DDR 必然使用该 READY 策略，而是当前“通用 AXI 兼容”说法不成立，换控制器/插入桥后可能暴露。Arm 的握手依赖规则要求主端不能等待 AWREADY 才发 WVALID，见 [AMBA AXI specification，A3.3](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)。

建议修复：选定同一 write owner 后独立推进 AW 与 W，分别记 `aw_done`、`w_done`；B 完成才释放 owner。可先做单 outstanding 正确版。还需检查内部主机是否同样 AW-first，不能只修最外层。

扩展静态检查：[双路旧仲裁器](D:/contest/2026FPGA/yilingsi/case1/rtl/dma/c1_axi2_serial_arbiter_128.sv:279) 有类似顺序结构；[多 outstanding 写候选](D:/contest/2026FPGA/yilingsi/case1/rtl/dma/c1_axi_n_write_burst_arbiter_128.sv:212) 以 `issued_count_q != 0` 放行 W，而该计数来自下游 AW 握手，也需要同类定向验证。后两者此次未作动态复现，不计入已复现数量。

已有 [七客户端压力 TB](D:/contest/2026FPGA/yilingsi/case1/sim/tb_c1_axi7_serial_arbiter_128.sv:116) 用伪随机数产生 AWREADY，最终会主动给地址通道机会，因此不会发现这种合法的跨通道依赖。应增加依赖型从机、W-first、同拍完成、任一通道长停顿的验证，而非只增加随机种子。

### R2 / P1：read skid 把缺失 RLAST 改写成正常结束

位置：[共享仲裁器](D:/contest/2026FPGA/yilingsi/case1/rtl/dma/c1_axi_n_serial_arbiter_128.sv:310)。`rd_skid_last_q` 同时承担“内部应释放 owner”和“向上游输出 RLAST”两种含义，赋值为 `m_rlast || expected_last`，但 RRESP 原样透传。

此次注入单拍 ARLEN=0、RRESP=OKAY、RLAST=0：skid=0 时上游仍看到 RLAST=0；skid=1 时变为 RLAST=1、RRESP=OKAY，异常消失。这改变了开关前后的错误语义，叶级缺失 RLAST 检测会失效。

建议修复：分离 `actual_last` 与 `terminal_for_owner`；保留原始末拍信息并报告长度错误，或在明确的错误合同下向上游转换为错误响应。缺少/提前 RLAST 后不能假定链路自动恢复，应规定隔离、排空或受控重置，防止非法残余拍被后续 owner 接收。

### R3 / P1：显示补给与 CNN 活动互斥，不满足持续 scanout

位置：[系统控制器](D:/contest/2026FPGA/yilingsi/case1/rtl/top/c1_r1_soc_control.sv:846)。新显示 prefetch 必须等待 `!boardless_busy && !manager_nn_active && !nn_launch_pending_q && !manager_nn_request`。这有利于小尺寸任务消除等待环，却阻止 CNN 长任务期间持续启动显示补给。

显示器仍按像素时钟扫描。重复显示上一幅图也需要再次从 DDR 读取；仅保留帧地址/ownership 和少量行缓存不等于保存整幅画面。已有状态记录中 `deadline_miss=2/underflow=2` 与这个风险一致。

建议先启用可测量的显示响应缓冲与低水位优先服务，再逐步放开并发；确保占用 DDR 返回通道的客户端能够接收整段 burst。显示 QoS 要以可保证的最大服务空窗为指标，不能只看 round-robin 的平均公平性。

### R4 / P1：默认计算和 DDR 流量不具备 15 fps 余量

当前报告模型为 428,236,800 MAC/帧。即便统一按每拍 64 个有效 MAC、100 MHz、零停顿估计，也需要 6,691,200 周期，即约 66.912 ms；15 fps 只允许约 66.667 ms。这个理想模型已无余量，真实算子利用率、重定量和访存还会增加周期。

默认 tensor 访存估算为 342,220,800 B/帧，15 fps 为 5.133 GB/s；x16 DDR3 800 MT/s 原始峰值只有 1.6 GB/s。burst 降低事务开销，outstanding 隐藏等待，但它们本身不减少重复读取字节数。窗口/权重复用、C8 packing 和按层融合才是减少流量的手段。

优化顺序：先统计各层 MAC/字节/等待；做行或 tile 缓存和连续地址合并；再做可保证返回接收的 outstanding；最后据 Ti60 实际资源决定 MAC 共享、重定量共享、频率或模型计算量。不可直接复制多套完整 dot core；已有 Efinity 叶级记录显示一个 dot+requant 实例占到 80/160 DSP，但最终合并资源仍需重新测量。

### R5 / P2：综合探针的输入相关性、截断削弱了资源/频率证明

位置：[packed CNN 探针](D:/contest/2026FPGA/yilingsi/case1/efinity/c1_ti60_cnn_top_packed_wrapper.sv:56)。它固定 `stage_config_index=0`、重复同一 32 bit 形成 512 bit descriptor、重复同一字节形成参数数据、72 个窗口 lane 相同。这些约束允许综合器折叠数据通路/存储，不能当作真实网络的独立端口激励。

另有具体宽度问题：`observe_keep` 只有 40 bit，右侧拼接合计 47 bit，高 7 bit 被截掉，包含 busy/done/error/aborted 等状态；`keep` 不能恢复已被 HDL 截断的位。该问题位于评估壳，不是生产算术核心。

因此，既有 435.540 MHz 的 C4 探针结果只证明该受限壳完成实现；不能证明完整 CNN 达到该频率，更不能替代 Ti60F225I3 的全系统结果。改用可加载独立参数/descriptor 的片上寄存器或存储接口，核对可达算术路径与综合后层级资源，再评估优化。

### R6 / P2：CDC 的逻辑结构有基础，物理签核尚未形成

[异步 FIFO](D:/contest/2026FPGA/yilingsi/case1/rtl/common/c1_async_stream_fifo.sv) 使用 Gray 指针与两级同步，且不复位数据存储，这些方向合理。但源码未标注同步器属性，所查 Efinity 约束未见针对这些 Gray 跨域总线的具体偏斜/最大延迟约束；当前完整 SoC 窄壳 SDC 只有单时钟。仿真无亚稳态，无法证明真实跨域实现。

此外 capture 默认深度 2048 的异步读 FIFO 可能映射大量逻辑，应该在 Ti60 上比较厂商双时钟 FIFO/同步读 EBR 适配方案，保持 ready/valid 和 reset 合同。此条属于实现风险，不能从静态 RTL 直接断言存在 CDC 功能故障。

## 3. 本轮实际复现记录

[定向 TB](D:/contest/2026FPGA/yilingsi/case1/review/tb_axi_audit_20260910.sv) 用本地 Icarus 编译运行，同一 DUT 分别配置 SKID=0/1，无波形文件。

```text
AUDIT_READ skid=0 injected_rlast=0 observed_rlast=0 observed_resp=0
AUDIT_WRITE skid=0 aw_handshakes=0 w_handshakes=0 downstream_awvalid=1 downstream_wvalid=0
REPRODUCED_AW_W_DEADLOCK
AUDIT_READ skid=1 injected_rlast=0 observed_rlast=1 observed_resp=0
REPRODUCED_RLAST_ERROR_MASKING
AUDIT_WRITE skid=1 aw_handshakes=0 w_handshakes=0 downstream_awvalid=1 downstream_wvalid=0
REPRODUCED_AW_W_DEADLOCK
```

这些是缺陷复现标记，不是修复 PASS。编译产物 VVP 已删除，仅保留小型测试源与本文。复现命令：工作目录为项目根，`iverilog -g2012 -s tb_axi_audit_20260910 -Ptb_axi_audit_20260910.SKID=1 -o <临时文件> case1/rtl/dma/c1_axi_n_serial_arbiter_128.sv case1/review/tb_axi_audit_20260910.sv`，再执行 `vvp <临时文件>`；SKID=0 为对照。

## 4. 对原例程分析的复核与更正

| 旧结论或建议 | 本轮判断 | 应采用的解释 |
|---|---|---|
| 例程没有风格迁移/通用 Resize，不能覆盖现有 CNN | 成立 | 保留现有算法、参数 ABI、帧调度；例程提供外围和联调基线 |
| v6 RAW10 被截成 RAW8 | 成立 | 顶层四个 `[9:2]` 式切片确实丢弃低两位 |
| v6 实际使用复制的 CSI 5.15 | 成立 | XML 活动文件为 `rtl/csi_rx_controller.sv`，文件头 IP Version 5.15；与工程 2026.1 版本不同 |
| v6 必须带入活动 DSI 才能复用 | 不成立 | 查到遗留 DSI 端口/reset/时钟名，但顶层无活动 DSI 控制器实例、活动 XML 无 DSI 源列表。残留 periphery 是否占 PLL/HSIO 需继续核对，不能由端口名推断 |
| `MAX_VID_WIDTH=960` 表示图像宽度异常/半幅 | 证据不足 | 同一路还有 `H_VALID=MAX_HRES/2`、16 bit 双 RAW8 像素与后续双像素 Debayer，应按像素并行度理解，不能孤立看 960 |
| 64 bit CSI 输出应重新做 CSI 包头/RAW10 字节解码 | 接口层级不准确 | 这里已是 CSI IP 解码后的 `pixel_data`。新模块应按 datatype/pixel_per_clk 做像素拆分、marker 和有效 lane 处理；只有连接更低字节层时才需 CSI 包解析 |
| 给 CSI 像素流加随机 ready 即可验证输入 | 遗漏不可回压条件 | 活动 CSI 像素接口没有 ready；有限 FIFO 无法解决持续平均输入高于消费速率 |
| Sapphire `userInterruptA[0]` 为八位向量第一位 | 对该例程不成立 | `soc.v:152` 是标量 `input userInterruptA`；BSP 的 PLIC 中断编号是 16。当前八位适配器可明确取 bit0 接标量，不能隐式截断或选非零位 |
| 08 外部 DDR 是 16 MiB 窗口 | 混淆两个接口 | BSP 中 AXI-A 是 `0xe1000000/0x01000000`，DDR 是 `0x1000/0xe0000000` 的地址窗口；后者不代表物理 DDR 有 3.5 GiB |
| 第一版直接隔离 Sapphire DDR master | 只能用于专门重配的微型 smoke | 例程 linker `default.ld` 将程序放在 `0x1000`、124 KiB；BSP OCR 仅 4 KiB。不能照搬软件后切断 DDR，还必须提供参数/描述符加载路径 |
| 所有 IP 必须重新生成 2026.1 版本 | 过于激进且部分无依据 | v6 DDR 是随板源码 `rtl/ddr3_controller/...`；没有证据证明存在可等价替换的一键 IP generator。先复现原始受支持配置，再逐 IP 升级 |
| v1 资源是 v6/合并系统的保守上限 | 不成立 | 只能作历史参考；删减与新增、packing 和时序变化使它不构成数学上界 |
| 平台复用 80%～90%、核心复用 40%～50% | 不可作为工程量证据 | 无分母、代码统计或任务权重，降级为定性判断：外围参考价值高，核心 AI 不提供 |

补充：此前“2048 B burst 小于 4 KiB，因此安全”不充分。跨界与起始地址有关，必须满足 `addr[11:0] + beats*bytes_per_beat <= 4096`。例程中存在边界处理逻辑，但本轮没有对所有起始地址和尾 burst 做穷尽验证，不应标成已验证的通用 burst 引擎。

证据入口：企业 v6 归档的 `rtl/ti60f225_oob_top.v`、`ti60f225_oob.xml`、`rtl/csi_rx_controller.sv`；08 的 `par/ddr_demo_ti60/ip/soc/soc.v`、`embedded_sw/soc/bsp/efinix/EfxSapphireSoc/include/soc.h` 与 `linker/default.ld`。

## 5. 应如何联合开发

### 5.1 先锁定三套可复现配置

1. 企业视频基线：保留 v6 原始 CSI、I2C、DDR、frame buffer、Debayer、HDMI，先在安装版本尝试实现并独立上板验证。原始配置和生成源码留档，不同时升级 IP 与替换算法。
2. 企业 SoC 基线：08 原始 Sapphire+DDR+UART+链接脚本，确认启动、DDR 测试、APB 和标量 IRQ。以真实 BSP 为准，核对大窗口中超出物理 DDR 范围的访问会否别名。
3. Case-1 便携基线：固定参数配置和 golden，先解决 R1/R2，再通过真实参数小图逐像素、错误与 abort 回归。使用不同 BFM 服务策略，避免只验证单一存储模型。

已有 Efinity 工具链可用于上述工作；Icarus/xsim 验证纯 RTL 与可用的非加密模型。换成 Icarus 并不会自动使 Efinix 加密 IP 可仿真；仍须依据具体 IP 提供的模型/仿真器支持。

### 5.2 联合拓扑与内存所有权

建议最终组合：Sapphire 的 APB 接现有 CSR；Sapphire DDR master 与 Case-1 单 AXI128 master 接外层两主机互连；该互连连接同一套随板 DDR 控制器。CPU 的 ID 必须无冲突地转换并可逆路由，不能直接把 8 bit 截成 4 bit。第一版可以按 owner 串行化，后续再增加带 ID 的在途能力。

```text
Sapphire -- APB --> Case-1 CSR / ISP config
    |                      |
    | DDR master           | Case-1 七客户端 --> 单 AXI128 master
    +----------------------+------> 外层双主机互连 --> 随板 DDR3

CSI IP --> 已解码 RAW10 多像素 FIFO/拆分 --> Case-1 ISP/采集
Case-1 display RGB/DE/HS/VS --> 企业 HDMI 像素侧发送边界
Case-1 IRQ --> 明确宽度适配 --> Sapphire 标量 userInterruptA
```

单主机 smoke 也可采用“CPU 初始化 DDR → CPU 转入片上代码并排空事务 → 交接给加速器 → 完成后交回”的方式，但必须有可执行的片上软件、cache 维护与 owner 交接合同；不能运行 DDR 程序时切走 CPU 总线。

统一地址表应包含 CPU 程序/栈、参数 arena、descriptor、frame table、五个 framebuffer 和三 tensor bank。旧软件的 CPU 虚拟/总线地址到 DDR 物理偏移必须实测或沿 controller 地址解码确认。CPU 缓存需要 clean/invalidate；普通 RISC-V `fence` 不等价于把非一致性数据 cache 自动刷到 DDR。

### 5.3 相机分辨率与速率必须先决策

当前默认输入为 642×482，输出目标 640×480；企业相机链路是 1920×1080。后级 Resize 并不会自动让前级 capture/ISP 接受不同宽度。必须选定一种明确路径：传感器支持的较小模式、保留 Bayer 相位的 ROI，或增加可接受完整传感器尺寸的 ISP/缩放入口。ROI 是裁剪，不保留全视场；不能把它写成全幅缩放。

v6 有四像素打包。若连续有效拍按 50 MHz 输出四像素，则瞬时到达率为 200 Mpixel/s，100 MHz 的单像素消费者最多 100 Mpixel/s；只有实际 valid 间隔、FIFO 容量与平均速率满足条件才可串行化。应采集 `pixel_per_clk/datatype/word_count`，按真实有效占空比算最大积压；满时标记整帧丢弃并在下一个 SOF 恢复，不能随机丢几个像素继续当好帧。

### 5.4 分步替换顺序与验收

| 步骤 | 实际变化 | 验收门 |
|---|---|---|
| A | 修复共享 AXI 协议；整理唯一 correctness/Ti60/performance 配置 | R1/R2 复现改为正常通过；7 客户端、reset/abort/错误路径通过 |
| B | 复现原始 v6 与 08 的实现/启动 | 确认原始源码版本、I3 periphery、DDR calibration、UART；硬件验证按持板情况推进 |
| C | 加外层 CPU/Case-1 互连，暂用 DMA 图案 | CPU 可加载并读回参数/图案；两主机争用无错路由/别名 |
| D | 企业 CSI 接 Case-1 RAW/ISP，暂时算法旁路 | 不可回压输入测试、Bayer 相位/尺寸/低位保真、完整帧读回 |
| E | Case-1 scanout 接企业 HDMI 像素发送边界 | 时钟域和像素并行度匹配；持续显示、零 underflow，之后再更换帧 |
| F | 加真实网络、保持显示服务；逐层启用 cache/burst | golden 逐像素、逐帧 deadline、DDR 等待/FIFO 水位与目标 I3 P&R |

板级复位分域设计：DDR calibration 本身必须先能运行；CPU 调试/状态读取应在 DDR 未 ready 时仍有可用路径。只限制新的 DDR 任务准入，不能把所有模块 reset 都直接与 `cal_done` 相与形成启动依赖环。

## 6. 下一阶段最值得执行的工作

先修复 R1/R2 并扩展协议回归，然后选择一个 Ti60 候选配置（包含经功能验证的 packed affine），改造综合探针以避免输入相关性折叠。与此同步建立 08 的软件启动/DDR 地址/参数加载合同，冻结 v6 已解码 CSI 像素接口。完成这些门以后再写正式板级 adapter，能减少“接口能连上、系统不能运行”的返工。

本次交付的是审查结果和缺陷复现，生产 RTL 中 R1/R2 尚未修复。此前文档中被本报告否定的条目不应继续作为 GUI 集成依据；旧报告的历史仿真记录仍保留其原有范围。
