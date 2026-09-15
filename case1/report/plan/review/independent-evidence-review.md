# 独立工程证据复核

- 审核日期：2026-08-31。
- 审核状态：**DONE_WITH_CONCERNS**。关键结构与已记录数字可支持架构报告；必须保留下列层次、模型和观测边界。
- 范围：按 `task-packets/02-independent-evidence-review.md`，核查 `evidence-map.md`、`source-metrics.json`、报告 blueprint，以及 E02/E03/E05/E07/E12/E13/E15/E17/E18 的定向源码和紧凑简报；只读对照 `chapters/赛题一_RTL架构设计与验证报告.md`。
- 方法：源代码阅读、已有结果口径比对、由 manifest 在内存中独立加总请求/MAC 数。未运行仿真、综合、布局布线；未读取大型运行日志；未修改 RTL。此复核不是新硬件测试记录。
- 路径基准：下文 `case1/...` 均相对 `D:/contest/2026FPGA/yilingsi`。

## 1. 结论摘要

1. 当前实际链路是 **camera RAW10 → capture FIFO/ISP → 输入帧 DDR → input DMA → Resize/C8 → tensor/engine → 输出帧 DDR → display**。不能将 Resize 画在当前 capture writer 之前。
2. portable SoC 的默认输入为 642×482，经有效窗口 Debayer 得到 640×480；这只是便携配置。当前顶层 Resize 步进固定 1.0、相位为 0，且 `MAX_WIDTH` 被顶层覆写为 `FRAME_WIDTH=640`。leaf 默认 2048 不等于当前系统支持 2048 宽输入。
3. 当前是固定 22 阶段 MicroStyle-24 的调度器，三块 8 MiB tensor bank 的路由及残差来源由 stage index 决定。不能描述为加载任意描述符即可运行任意 CNN。
4. 真实参数 8×8 scaled stage-0…21 handoff 与 native 640×480 CNN echo 是两类独立证据，不能拼接为原生真实网络 PASS。
5. `342,220,800 B/frame` 和 `47,547,744 B/frame` 的算术可复现，但后者是全局复用/打包的理想敏感性模型；它不是当前 cache 命中率、整系统 DDR 流量或实测吞吐。
6. DW 窄壳存在明确的输出可观测性损失和重复激励约束，**28 物理 DSP 不可当作完整 C8 DW 的资源需求**。也不能把它与 dot、Sapphire 等数字相加后称为整设计资源上界或余量证明。
7. 现有 OSD 显示状态与告警，不显示测量的处理 FPS。有限三输入缓冲也不能在 30 fps 输入、15 fps 处理时长期保存并处理每一帧。

## 2. 分项证据与可写结论

### 2.1 capture 与 Resize 的实际位置、配置边界

支持源：

- `case1/rtl/top/c1_r1_capture_subsystem.sv:1`：模块说明为 RAW10 经完整 ISP 后写 XRGB8888 DDR；`:170` 实例化 capture frontend，`:313` 直接把其 RGB 流连接到 XRGB writer。
- `case1/rtl/top/c1_r1_portable_soc.sv:18`：`FRAME_WIDTH=640`、`FRAME_HEIGHT=480`，sensor 参数为 frame 尺寸加 2。
- `case1/rtl/top/c1_r1_boardless_frame_system.sv:423`：input DMA 读取 XRGB；`:490` 调用 compute shell，source 选择 DMA，ISP 入口绑零。
- `case1/rtl/top/c1_r1_compute_shell.sv:480` 与 `case1/rtl/cnn/c1_r1_compute_ingress.sv:153`：Resize 在 compute ingress 内，然后接中心化 C8 codec。
- `case1/rtl/top/c1_r1_portable_soc.sv:911`：把 `MAX_WIDTH(FRAME_WIDTH)` 传到 boardless；`:934`—`:937` 固定 x/y step 为 Q16.16 的 1.0、phase 为 0。boardless→shell→ingress 继续传递同一 MAX_WIDTH。

可写：当前支持 RAW10/ISP/DDR/Resize 的便携功能链；Resize 算术模块可以接受配置参数，但当前 portable 顶层接线使用等尺寸、identity 几何。真实相机模式、裁剪和输入宽度须另行适配。

禁止过度声称：

- “当前 capture 已先缩放再写 DDR”；
- “SC431HAI 已配置成 642×482 模式”；
- “当前 SoC 已支持任意高分辨率输入并自动缩成 VGA”；
- 不加层次限定地称“当前系统最大输入宽度为 2048”。2048 是相关 leaf 的默认参数，不是 portable 默认实例值。

### 2.2 固定 22 阶段、三 bank 与描述符语义

支持源：

- `case1/model/microstyle_layout.py:100` 附近生成固定网络拓扑；`case1/model/microstyle24_starry_functional/manifest.json` 明示 22 descriptors、12,212 卷积权重、16,896 B arena、428,236,800 MAC/frame，tensor offsets 为零。
- `case1/rtl/cnn/c1_r1_microstyle_tensor_adapter.sv:3`—`:33`：单个 64-bit C8 请求在途、三 bank、每 bank 8 MiB；零 offset 不解释为 DDR 地址。
- 同文件 `:432`—`:485`：expected opcode/Cin/Cout 按 index 固定；`:491`—`:571`：input/output/residual bank 为固定 stage 映射，残差 stage 5/9/13 分别用 bank 0/2/1。

可写：descriptor 提供当前固定图的配置、形状与参数信息；adapter 依据 stage index 和 H/W/C 生成真实地址，保留 residual 生命周期，算术模块跨阶段复用。

禁止过度声称：任意图执行器；任意层数 CNN；descriptor 的 tensor offset 已形成通用外存调度；22 个阶段等于 22 个卷积层；将旧逐层 mac_lanes 加总当成当前共享引擎总并行 MAC 数。

### 2.3 native echo 与真实 8×8 handoff 必须分开

支持源：

- `case1/STAGE8_21_HANDOFF_PREFLIGHT.md`：8×8 缩放 trained artifact、真实 1,056×128-bit 参数 arena、production bank 地址合同；stage21 为 `operands=896/results=836/final=64/stage_done=22/abort=0`。
- `case1/sim/tb_c1_r1_microstyle_artifact_tensor_engine_8x8.sv:139`—`:150`：FRAME_W/H=8，PARAM_BYTES=16896，BANK_BYTES=8 MiB，但 BFM 只保存足够用于小帧的稀疏窗口；`:548` 起为 production parameter bank；高 stage 开关自动启用前置阶段。
- `case1/sim/tb_c1_r1_native_boardless_job.sv:3`—`:10`、`:279`—`:325`：native 640×480 boardless frame system 的外部 CNN 明确为一槽 C8 echo，`cnn_out_data_s8` 由输入暂存直接返回。
- `case1/IMPLEMENTATION_STATUS.md:75`—`:86`：native 两向各 307,200 像素、4,800 AXI burst；另有 native portable SoC xvlog/xelab 证据。

可写：真实参数 handoff 已覆盖缩放链的 22 阶段、bank 来源/精确地址/窗口读序/写回/最终 64 RGB beat；native echo 覆盖原生 DMA、回压、配置派发与排空；elaboration 仅覆盖层次展开。

禁止过度声称：native 22-stage 真实算术已通过；640×480 trained network end-to-end PASS；8×8 sparse BFM 等同 24 MiB DDR 数据平面实测；小帧 `drops=0` 等同长时间无丢帧。

文档细节提醒：旧 handoff 简报把“每个 N 的完整 2×2”泛用于所有终点并不精确，decoder/output 已扩展至 4×4/8×8。正文应采用“8×8 缩放链、有界阶段终点、最终64像素”，不要沿用“stage21 完整2×2”的旧措辞。

### 2.4 带宽模型：数字正确，不是性能实现

支持源：`case1/model/tensor_perf_model.py:43`—`:191`、`case1/efinity/TI60F225_BOARD_PROFILE.md` §2；独立按 manifest 层表加总得到：

| 核查项 | 数值 | 含义 |
|---|---:|---|
| 初始 tensor 写请求 | 307,200 | 每像素一个 C8 写入 |
| 各阶段读请求 | 17,376,000 | 包括 tap、1×1、residual、upsample、最终流读取 |
| 各阶段 tensor 写请求 | 3,705,600 | 最终 RGB 输出阶段不再写 tensor bank |
| 逻辑 64-bit 请求合计 | 21,388,800 | 不是连续有效 128-bit payload 拍数 |
| 默认 AXI 数据拍流量 | 342,220,800 B/frame | 一个 64-bit 请求占用一个 128-bit beat |
| 全局复用9、打包2的场景 | 47,547,744 B/frame | 按模型 ceil 规则分别处理读写 |
| 默认15fps需求 | 5,133,312,000 B/s | tensor 路径数据拍口径 |
| 理想场景15fps需求 | 713,216,160 B/s | tensor 路径理想场景口径 |

重要限制：

1. `effective_read_requests = ceil(stage_reads/read_reuse)` 把因子 9 施加给全部读请求，不只 3×3 tap。独立加总可见其中 2,860,800 个读请求来自非 3×3/DW 阶段。故“9倍缓存命中收益”不能当成当前 cache 的真实属性。
2. pack_factor=2 假定可以理想合并两次 C8 传输；未证明地址连续性、边界、排空、读写转换均可达到该效率。
3. outstanding=4 只进入 latency/cycle 估算，不参与字节数公式；不能称“多 outstanding 把字节数减到47.548MB”。
4. 模型使用每拍发一个 beat、固定 response latency，并以 `max(memory_cycles,compute_cycles)` 组合下界，没有证明实际存算重叠或当前 FSM 可达到该周期数。
5. 两个字节数均不是整系统 DDR 流量：未计 capture XRGB 写、输入 XRGB 读、输出 XRGB 写、双路显示读、参数/descriptor/CPU 等其他客户端，也未计 DDR 命令/刷新/仲裁损失。
6. 1.6 GB/s 是 x16×800 MT/s 的物理数据面峰值；128-bit×100MHz 只是可能的用户接口配置。生成 DDR IP 后仍须核对宽度、频率和有效服务率。

可写：当前无复用的单拍 tensor 路径在15fps目标下的数据拍需求已经超过标称DDR峰值，必须优化流量/利用率；理想因子模型用于展示优化量级，不能证明15fps。

### 2.5 统一64-MAC模型的算术边界

`428,236,800/64 = 6,691,200 cycles/frame` 的算术正确；100MHz 下对应理想约14.945fps，15fps整数周期预算为6,666,666。这些数适用于“全网络统一按64有效MAC/拍”的假设模型。

但 `case1/rtl/cnn/c1_dwconv3x3_c8_requant_core.sv:19`—`:34`、`:145`—`:153` 显示 DW leaf 为8通道×9乘积位置，流水填充后可接受每拍一个C8窗口。真实 engine 含独立DW路径，因此总MAC除64不是针对该异构engine逐层证明的、不可突破的绝对物理下界。

可写：“在统一64有效MAC/拍的简化模型中，计算预算已十分紧张；实际实现还需逐层统计Conv/DW吞吐、配置/通道填充/回压并测量完整帧周期。”

不要写：“现有整个engine在100MHz下即使完美供数也绝不可能超过14.945fps”，除非另有逐层周期证明。当前默认访存路径不能达到15fps的结论已有独立流量证据，无需把这个简化MAC模型升级为绝对结论。

### 2.6 Efinity：C4隔离探针、DW裁剪与I3整板不同

支持源：`case1/efinity/RESOURCE_MAP_RESULTS_20260829.md`；两个相关 wrapper XML 的 `:2` 均明确 timing_model=C4；目标板 profile 为 Ti60F225I3。

可记录的历史观察：dot/requant独立核心80物理DSP、189.717MHz；DW窄壳28物理DSP、271.592MHz；scheduler1物理DSP、236.855MHz。均须保留对象、壳层与C4条件，不是I3整板时钟/资源。

DW关键风险的源码依据：

- `case1/efinity/c1_ti60_dw_leaf_wrapper.sv:8` 的观察寄存器只有32bit；`:23` 的core输出为64bit；`:72`—`:73` 将该输出参与按位运算后赋回32bit，core输出高32bit没有被这个数据观察路径保留。
- `:55`、`:56`、`:57`、`:58`、`:68` 的权重、窗口、bias为重复或固定模式，不能覆盖八个独立通道的任意输入和参数空间；未使用的输出/诊断还提供其他优化机会。
- 简报中原始宽IO DW为72×DSP24+16×DSP48，窄壳为36×DSP24+8×DSP48，随后物理打包成28块。逻辑原语先减半与输出截窄风险相符；未检查网表，故不宣称已精确定位每个被裁剪实例，但资源完整性显然未被该壳证明。

据此，28物理DSP只能写为受窄壳约束及可能裁剪影响的该次PNR观察。原简报“4+80+28=112，可作为上界并说明仍有余量”的推论不应进入报告：未知完整DW占用、共享/packing、CPU配置和其他IP，不能由此建立整设计上界。

packed top窄壳进一步限制：`case1/efinity/c1_ti60_cnn_top_packed_wrapper.sv` 把 `stage_config_index` 固定为0，descriptor、arena读数据和窗口均由窄stimulus重复扩展。其map/PNR PASS及435.540MHz只证明该特殊连接约束下的兼容性/时序门，不能代表22阶段真实视频推理的数据通路时钟。保留22-stage参数化不等于保留每条可达执行路径的完整物理资源。

默认unpacked map崩溃、packed窄壳PASS、portable限时map未完成都应作为工具/结构状态报告，不应解释成资源超限或已经全板实现。禁止简单相加独立leaf资源后给出整板占用率。

### 2.7 OSD不是实时FPS

支持源：

- `case1/rtl/top/c1_r1_portable_soc.sv:1354`：OSD word由error code、engine stage index、display frame id低19位组成。
- `case1/rtl/top/c1_r1_display_subsystem.sv:305`：实例化hex OSD；`:368`—`:371` 在帧边界锁存状态。
- `case1/rtl/display/c1_hex_osd_overlay.sv:3`：八个十六进制字符显示32-bit状态，并按alarm选择颜色。

可写：已有状态/告警OSD、显示帧事件及相关统计接口，可作为后续FPS实现的基础。

不可写：已满足当前处理FPS叠加；frame id就是FPS；720p60刷新证明算法60fps。处理FPS应计一定真实时间内新完成并成功发布的风格帧，而非重复scanout次数。

### 2.8 30fps采集、15fps处理与无丢帧限制

支持源：`case1/rtl/top/c1_r1_capture_frontend.sv:6`—`:13` 明示2048条FIFO只是约3.2条sensor行的弹性缓冲，并要求source遵从ready或在有限积压内完成接纳；`:184`—`:188` 标记source valid且不ready的溢出。`case1/rtl/control/c1_frame_manager.sv:95`—`:99`、`:269`—`:297` 定义无空槽时回收READY帧或丢弃当前帧，绝不覆盖processing/display持有帧。

可写：三输入双输出可解耦任务、保护ownership并吸收有界抖动；队满时具有明确的接纳/丢弃策略，显示可重复上一对完整结果。

不可写：仅靠三缓冲便保证30fps采集帧全部以15fps计算而永不丢帧；camera_ready可物理暂停真实CSI传感器；短小两帧drops=0证明持续链路零丢帧。

若要求所有30fps采集帧都经过风格化，长期计算服务率至少必须覆盖30fps，并留出抖动/停顿余量；否则必须明示主动取样/丢弃规则，区分主动采样、链路异常丢帧与重复显示。

## 3. 已生成正文的只读审阅意见

审阅对象：`case1/report/chapters/赛题一_RTL架构设计与验证报告.md` 的本轮已生成稿；主代理可在接收意见后继续修改，以下为审阅时快照。

| 位置 | 状态 | 主代理处理建议 |
|---|---|---|
| §3.2 Resize位置 | 已正确放在input DMA之后 | 增加portable step=1.0/phase=0；将leaf默认2048与当前实例640分开 |
| §4.4 固定bank | 已正确限制网络拓扑 | 保留，不需扩张描述符可编程性 |
| §6.2 表4与正文 | echo、真实8×8、native展开已正确分层 | portable SoC动态回归行宜再直接标“零参数生命周期”，避免只看表时混淆 |
| §6.3 DW和packed | 已标小IO/可能壳层优化 | 明确完整C8资源未被证明、存在32bit观察截窄；禁止引用112 DSP包络为上界 |
| §6.4 MAC预算 | 公式正确、已有64MAC假设 | 加“统一64MAC模型，非独立DW逐层周期模型”，避免成为绝对硬件上限 |
| §6.4 47.548MB | 已标全局粗粒度复用与理想场景 | 补“不含其他DDR客户端”；说明outstanding影响周期而非字节数 |
| §4.5/§6.5 FPS | 已正确区分状态OSD、处理FPS及刷新率 | 保留 |
| §7.3 30/15速率差 | 已明确有限缓存不能保证所有帧均处理 | 保留，并在验收表统计主动丢弃与异常丢帧 |

## 4. 交接与剩余核查

- 已将DW裁剪风险、portable Resize固定配置、2048/640参数层次、MAC模型条件、总线流量排除项发送主代理。
- 此文件不修改原始E15/E16历史简报或RTL；历史简报中DW资源包络、stage21“2×2”等陈述应由报告采用上述更严格口径覆盖。
- 主代理仍需在最终正文与图表中同步这些限制，尤其图1的Resize位置、表5的DW行以及§6.4模型标题/公式解释。
- 本审核不覆盖未读的完整运行数据库、原始波形、板级电气/IP配置，也不构成I3整板或原生真实CNN性能验收。
