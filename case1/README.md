# 赛题一：板卡前 Golden、RTL 与软件基线

## 文档入口（2026-09-15）

- [Efinity 本机自动化开发方法](EFINITY_AUTOMATION_PLAYBOOK.md)：可提供给其他赛题会话，涵盖 IP 生成、软件、仿真、MAP/PNR/STA、隔离运行及清理。
- [赛题一工程报告草稿](report/chapters/赛题一_RTL架构设计与验证报告.md)：按已确认八节框架描述当前 C39 工作，未完成的板级、软件运行及效果测试保留编号空位。
- 公开发布采用独立的赛题一源码快照，不包含本机其他赛题、原始工具输出或厂商 IP 载荷。历史文档中的日志链接需在本地完整开发树追溯。

## 当前工程入口（2026-09-15，C39三个优化目标已验收）

- [C37纯host资源工程](efinity/c1_ti60_c37_resource24.xml)保留为已验收回退版本。后续历史段落中的“当前C24/C35”不再表示本轮入口。
- 当前开发组合为[C39 one-hot纯host工程](efinity/c1_ti60_c39_host_onehot.xml)：实际40,476 XLR/117 RAM/121 DSP，同边界比C37少842 XLR；完整算子双回压、三个模型及640×480六帧系统回归通过，最差完成间隔6,433,652周期，与C37相同，标称150MHz下约23.315fps。量化及512/1024窗口原始短测证据也已补齐。见[最终验收与边界](review/C39_THREE_OBJECTIVES_FINAL_ACCEPTANCE_20260915.md)。
- 官方CPU/DDR联合入口为[Sapphire S2 + one-hot + 逐端点CDC工程](efinity/c1_ti60_c39_joint_s2_onehot_cdc.xml)：实际51,900 XLR/165 RAM/125 DSP，最终setup/hold为正；这是100MHz联合资源/指定host CDC探针，不是已完成引脚、PLL、摄像头和HDMI集成的可下载板级工程。不得沿用纯host@150MHz的帧率作为联合系统实测。
- [C39实际选源说明](rtl/c39/README.md)列出了当前组合使用的不同目录；**导入已有XML或明确源列表，不要把全部版本的同名SV一起导入**。[当前S2软件入口](software/c39_s2_probe/README.md)使用非压缩RV32IM构建，不是旧C1 smoke。

最新状态看[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md)，验收证据看[C39运行链](review/C39_ONEHOT_ACCEPTANCE_20260915.md)。以下各日期段落保留历史过程，其中“最新/当前/运行中”均以其记录时间为准。

## 历史进展

2026-09-15目标更新：模型/训练与RTL共同优化，原模型不再固定为最终方案。已复查赛题与原预览，新增14种保留当前算子的轻量候选及可训练浮点参考；静态计算/访存改善不等于已获画质或fps。优先方案、真实证据和后续训练/QAT工作见[算法重新评估](review/CNN_ALGORITHM_REASSESSMENT_20260915.md)。当前C35原图六帧xsim继续运行，未改其源码和参数。

2026-09-15 00:29补记：融合xsim小图原生时钟验证已通过并清理；原22项640×480六CNN同AW2压力对照已进入独立xsim worker35892，生产源码冻结，尚无新原生FPS。C35资源44,352 XLR/129 RAM/130 DSP及逻辑超预算问题见下段；[最新证据与运行边界](review/R2_ROW_FUSED_TAIL_20260914.md)。

2026-09-15 00:24最新：C35原图640×12行传输配对周期少约9.0%～9.1%；融合故障/复位及真实AXI主机矩阵已通过。[物理实现](logs/r2_c35_fused_pnr_gate_20260915_a.log)44,352 XLR/129 RAM/130 DSP，核心150MHz约束setup/hold +0.579/+0.026ns，但逻辑比C34多1,066，官方平台粗和仍超限，完整CDC签核未完成。融合xsim小图原生时钟验证进行中，尚无C35原生六帧FPS。详见[C35记录](review/R2_ROW_FUSED_TAIL_20260914.md)。下面较早“最新”均为历史快照。

2026-09-14 23:56最新：C35原22项640×4配对已实测85,240→80,782拍（约少5.23%，非640×480整机fps）；640×12融合正确、对照因运行器300秒时限停止，现只补测缺项，已验证的三个配置记录来源复用。融合故障/复位及真实AXI主机smoke随后串行执行。48源[Efinity主机候选](efinity/c1_ti60_r2_fused_rgb2_host96.xml)和独立系统测试台已准备，源/软件向量预检通过；尚无该候选主机RTL/PNR结果，不能继承C34资源。详见[当前实现状态](IMPLEMENTATION_STATUS.md)和[C35报告](review/R2_ROW_FUSED_TAIL_20260914.md)。

2026-09-14 23:36最新：C34资源实测已降至129 RAM（43,286 XLR / 130 DSP），完整短回归结束。C35的真实DW→PW行算术与整图小尺寸回归已通过；新的整图执行器和生存期分配消除了DW中间张量的DDR读写，且保留原模型/精度及普通逐层回退。12×12配对因参数重载而变慢，尚无新FPS收益；640宽配对在后台运行，融合阶段故障/复位随后串行执行。C35尚未接入AXI/video/host或重新PNR，不替代稳定入口。见[行融合报告](review/R2_ROW_FUSED_TAIL_20260914.md)和[实现状态](IMPLEMENTATION_STATUS.md)。以下旧时间点为历史记录。

2026-09-14 22:35：C33原生六CNN/整机门禁通过，AW2同压力配置名义150MHz最慢14.502105fps，仍差343,326拍达到15fps；临时工程已清理。C34写侧92配置和主机smoke/配对通过，小图配对间隔不变，完整回归/资源验证仍在串行执行。C35影子行RAM、接收器、PW feeder及共享MAC连接候选已新增，但尚无C35编译/仿真结果、未接入整网行调度器。见[实现状态](IMPLEMENTATION_STATUS.md)和[行融合报告](review/R2_ROW_FUSED_TAIL_20260914.md)。下方“原生在途/候选未验证”为历史快照。

2026-09-14 20:50新增 [C34 环形写回存储候选](review/R2_RING_WRITE_STORAGE_20260914.md)：保留原模型/精度/算子，把两个行描述符与共享物理空间分离，目标减少16 RAM。软件所有权模型及源码/驱动预检通过；92组写侧测试已条件式排队，独立主机与Efinity项目已准备但未执行，**未取得新RAM或FPS结果**。C33原生继续原进程，C31仍为稳定入口。

2026-09-14 20时新增 [C33 信用写回整机候选](review/R2_BURST_CREDIT_WRITER_20260914.md)：46生产源，58组写侧测试、8×8/32×32整机、12×12六帧xsim与Efinity定向实现通过；32×32同配置完成间隔−8.7732%。43,300 XLR/145 RAM/130 DSP，150MHz setup/hold +0.463/+0.026ns。原生帧率与官方联合容量尚未闭合；稳定主线仍为下述C31。

最新集成入口为 [C31 双像素完整主机](review/R2_RGB2_HOST_INTEGRATION_20260914.md)：`c1_r2_rgb2_host_system`，45生产源，C29/C30及R1全部保留。小图/故障/定向PNR及修复后的原生六次功能验证均通过，43,152 XLR/145 RAM/130 DSP；AW2压力模型下约14.10171fps，未达15fps、未完成板级集成。[C32提前写回](review/R2_CUTTHROUGH_WRITER_20260914.md)通过单元和写侧AXI数据检查，但实测共享W队首阻塞，暂不接入主线；下一步为逐突发就绪准入与已授权范围排空。以下各阶段“当前/未接入”按其历史时间理解，最新状态以[实现状态](IMPLEMENTATION_STATUS.md)为准。

2026-09-14 新增独立 **C30 前端**：[企业双像素接口与 Resize 调度优化](review/R2_DEMO_RGB2_INGRESS_20260914.md)。实际企业 Debayer、ROI/CDC、Resize、AXI 写回通过 Icarus/xsim；完整1080p VS/DE源连续两帧正确，FIFO峰404/512。旧Resize加到1024仍溢出，同拍采样交接解决该调度瓶颈。前端Ti60 MAP仅+180 LUT4/+130 FF/+1 RAM、DSP不变；[门禁](logs/r2_c30_gate_20260914_c.log)通过，临时目录已清除。**尚未合入完整主机；下一步为C31整机共享DDR/帧接纳与物理验证，不继承新路径的整网fps。**

2026-09-14 当前联合候选为 **C29**：[位精确量化与窗口RAM容量优化](review/R2_CAMERA_CAPACITY_20260914.md)，入口`c1_r2_camera_capacity_host_system`，44源。最终回归/xsim/PNR/统一门禁通过；Ti60为42,777 XLR/144 RAM/130 DSP，较C28减少972 XLR/4 RAM，核心150MHz级+0.650/+0.026ns，同配置数值和周期不变。粗加官方必要平台仅余662 XLR/7 RAM；下一步为官方双像素接口与联合工程，尚无完整板测、全量CDC签核或C29原生fps证明，默认板级top未替换。

保留的 **C28**：[同步链保护与源控制寄存器化](review/R2_CAMERA_CDC_HARDENING_20260913.md)，入口`c1_r2_camera_safe_host_system`，43,749 XLR/148 RAM/130 DSP。其3个guarded模块继续用于C29；C21命名冲突已修复并重新通过备用基线源审计与编译，过程见C29记录。

保留的 **C26** 联合基线：[相机→ROI/CDC→Resize→CNN完整主机](review/R2_CAMERA_HOST_INTEGRATION_20260913.md)。
入口 `c1_r2_camera_host_system`，44生产源；相机最终排空结果驱动帧池发布，新增只读相机APB页。
两套图各24次CNN、8故障配置48次正确CNN/40个故障后新任务、8项实际RAM负控及独立xsim小图通过；最终门禁为`r2_c26_gate_20260913_b.log`。联合MAP为148 RAM/130 DSP，物理CDC/PNR尚未签核。
完整1080p源的C26原生六帧xsim已完成：[独立门禁](logs/r2_c26_native_gate_20260914_a.log)核验13次采集、6正确CNN、最慢间隔9,793,756周期，150MHz/既定DDR模型下约15.31588fps；不是板测，也不能向C29/C30继承。
C21/C22各自原生六帧现已完成并分别核验约15.3145fps（150MHz、仿真DDR条件），不是板测或C26帧率。
已完成[C27物理CDC审计](review/R2_CAMERA_PHYSICAL_CDC_20260913.md)：43,577 XLR/148 RAM/130 DSP，核心150MHz级+0.365/+0.026ns；同步链重定时问题及组合控制跨域仍待整机修复，`syn_keep`原型已验证但未覆盖C26。工具CDC分类器内部断言，物理签核未完成。
**下方C25/C24段落按历史时点保留，其“尚未接完整主机”已由C26完成；R1及这些独立基线均不覆盖。**

2026-09-13 新增C25相机前端：[不可回压输入、ROI/CDC与容量边界](review/R2_CAMERA_INGRESS_20260913.md)。
`c1_r2_camera_ingress`＋双时钟同步读RAM FIFO已接真实Resize/Capture；连续1920×1080约30fps源经1440×1080 ROI
至640×480，两帧golden通过。256/512 FIFO最高水位193、均2 RAM；128实际溢出整帧丢弃，默认仍保留1024。
全源尾部校验、取消/B排空、帧跳过/恢复与xsim/MAP通过；物理CDC约束及与完整CNN帧池/主机的接入仍待完成。
**完整主机入口仍为下述C24**，C25不构成新的CNN整机15fps或板级时序证明。

2026-09-13 最新联合候选C24：[Resize→Capture→CNN主机接入](review/R2_RESIZE_HOST_INTEGRATION_20260913.md)。
入口`c1_r2_resize_host_system`，工程`efinity/c1_ti60_r2_resize_host96.xml`选取41个生产源；真实联合PNR为
43,665 XLR/146 RAM/130 DSP，150MHz setup/hold +0.387/+0.026ns。已验证实际Resize数值、失败采集隔离、
取消/B排空与无复位恢复、两套DAG全链路及独立xsim。仍无相机有限缓冲/ROI/CDC与实际CPU/PHY集成，
新源配置为RTL端口而非新增APB寄存器；不声称C24原生15fps。含官方平台粗预算仍为251 RAM/61026 XLR。
下方C23及更早内容保留各阶段时点；C24已完成其中Resize/Capture接入项。

2026-09-13 新增C23外围候选：[紧凑Resize与平台接入边界](review/R2_RESIZE_BANKED_20260913.md)。CNN/主机仍用C22，
Resize尚未接入完整系统。奇偶列银行使独立Resize实测20→12 RAM；完整1440×1080→640×480 golden/旧新周期对照、
取消恢复、xsim和150MHz PNR通过，`r2_c23_gate_20260913_b.log`。输入允许回压，不代表实际摄像头不会溢出。
固定640输出Resize再加官方平台的粗预算251/256 RAM、61026/60800 XLR，仍需真实联合工程和CDC/ROI检查。

2026-09-13 当前候选C22：[共享特征存储](review/R2_FEATURE_OVERLAY_20260913.md)。入口`c1_r2_overlay_host_system`，
工程`efinity/c1_ti60_r2_overlay_host96.xml`选择34源闭包。PW/残差复用空间缓存行0，Ti60 I3实测
41,252 XLR/134 RAM/112 DSP，150MHz setup/hold +0.349/+0.026ns；相对C21再省16 RAM，已完成测试周期保持。
374算子、两套图各24次CNN、RAM专项/负控、9种恢复及xsim/PNR通过，门禁`r2_c22_gate_20260913_b.log`。
C22自身原生六帧已独立启动、Job=false，C21原进程不动。官方平台粗加239/256 RAM仍不等于联合板级通过。
共享后的两套特征视图不能同时持久有效，切换消费前须重填被覆盖数据。下方C21及更早内容为保留阶段记录。

2026-09-13 当前主线候选C21：[六路权重接入完整CNN/主机](review/R2_COMPACT_HOST_INTEGRATION_20260913.md)。
入口`c1_r2_compact_host_system`，工程`efinity/c1_ti60_r2_compact_host96.xml`。最终Ti60 I3实测41,620 XLR/150 RAM/112 DSP，
相比C18少4,911 XLR/22 RAM；150MHz setup/hold +0.586/+0.027ns。修复残差8192标量末批加载/地址回绕边界；
374算子/185万标量、原22项与18项变体各24次CNN、8实际RAM负对照、9错误恢复场景与xsim通过，周期/访存与C18一致。
局部门禁`logs/r2_c21_gate_20260913_b.log`。不改R1/C18备用源；C21自身原生六帧已独立启动、Job=false，尚无该版本原生FPS。

原C18自身640×480六帧已于18:33收口：最坏15.3145fps@150MHz、最小周期余量2.0535%、13采集/21配对显示无欠载；
`logs/r2_c18_native_gate_20260913_a.log`通过，临时工程清理。下方早期“C18仍在途”属于历史状态。
实际CPU/DDR/CSI/Debayer加入后C21仍粗估255/256 RAM，Resize/CDC未计入，平台集成与模型质量尚未完成。

2026-09-13 新增C20：[平台容量审计与六路权重存储](review/R2_WEIGHT_MEMORY_BUDGET_20260913.md)。
独立候选`c1_r2_weight_store6`用六份完整表和5→20位混合位宽，将权重RAM实测64→42块（−34.4%）；
Icarus/xsim数值、逐字更新、复位保持、14负对照及Ti60 PNR通过，`logs/r2_c20_gate_20260913_a.log`。
尚未接入完整CNN，C18仍使用原权重存储，不新增系统FPS结论。即使保留22块节省，按官方现有CPU/DDR/CSI/Debayer
估算已用255/256 RAM，尚缺Resize/CDC，因此资源闭合仍须继续。配对TDP试验已被否定，不作为可用设计。

2026-09-13 新增C19：[完整主机错误排空与恢复](review/R2_HOST_ERROR_RECOVERY_20260913.md)。生产RTL保持C18不变；
13个实际SLVERR场景通过（含同一CNN两笔B债务），39成功/13预期失败、26次失败后完整恢复，失败结果不进入显示。
Vivado跨模拟器复核通过，`logs/r2_c19_gate_20260913_d.log`。另修正旧检查器的完成时刻少算1拍，原有15.3145fps结论不变；
最新C15原生/C18局部门禁为`r2_c15_native_gate_20260913_b.log`、`r2_c18_gate_20260913_c.log`。C18原生仍在原进程运行。

2026-09-13 当前新增C18：[生成式计划接入完整主机/视频/AXI](review/R2_PLANNED_HOST_INTEGRATION_20260913.md)。
独立入口`c1_r2_planned_host_system`保留旧生产RTL；原22项与18项结构试验各24次CNN、8次真实RAM负对照、
256窄访问任务及六帧小图xsim通过。原图周期/访存/调度与C15一致。Ti60 I3联合核心150MHz：
46,531 XLR/172 RAM/112 DSP，setup/hold +0.536/+0.028ns；`logs/r2_c18_gate_20260913_a.log`。
C18自身640×480六帧已于16:36独立启动，尚无C18原生FPS，未包含实际CPU/PHY/CDC/板卡接口。

2026-09-13 新增C17：[计划/参数配套与实际18项变体RTL](review/R2_BOUND_PLAN_PACKAGE_20260913.md)。
同一C16行执行器运行22项/18项生成包；原图参数与保留导出逐字节一致，10次原图回归周期/流量不变。
变体18次数值帧＋故障/复位/配套负对照及xsim通过；38,660 XLR/160 RAM/112 DSP，150MHz setup/hold +0.737/+0.026ns。
门禁`logs/r2_c17_gate_20260913_b.log`。变体未重训或验证风格质量，未替代比赛模型；完整系统接入现见上方C18。

2026-09-13 新增C16独立候选：[由算子/DAG生成执行计划](review/R2_GENERATED_EXECUTION_PLAN_20260913.md)。
自动生成算子、张量槽、残差/视图融合与终止配置，不覆盖C8～C15。12项规划测试、1,107项译码对照、
数值/故障/复位回归及xsim通过；C16时18项变体仅验证规划，实际执行已在后续C17补齐。门禁`logs/r2_c16_gate_20260913_c.log`。
Ti60 I3单CNN行核心150MHz：38,846 XLR/160 RAM/112 DSP，setup/hold +0.615/+0.065ns；尚未接入C15或验证C16原生fps。

2026-09-13 新增C15候选：[APB3/CPU/IRQ生产主机封装](review/R2_HOST_INTEGRATION_20260913.md)。
入口`c1_r2_host_video_system`组合保留C14核心和C13适配器，16位本地APB窗口、R2H1只读诊断及标量IRQ。
2,451项控制检查、24次多尺寸CNN、6帧xsim、4个实际RAM破坏通过；实际host/fabric窄访问256任务通过（视频关闭）。
Ti60 I3核心150MHz：45,817 XLR/172 RAM/112 DSP，setup/hold +0.263/+0.026ns。新驱动RV32链接通过，非CPU执行。
局部证据`logs/r2_c15_gate_20260913_b.log`；C15自身原生六帧现已收口，见`logs/r2_c15_native_gate_20260913_a.log`，未替换默认整机或覆盖旧RTL。

最新性能：C12/C13/C14/C15各自六帧原生已收口，四个完整负载间隔最慢均15.3145fps@150MHz，
最小周期余量2.0535%，13次采集/21次双图显示零欠载。C14六次均选中最新完成帧，第4次采集完成到CNN启动年龄57.81→24.48ms，
新证据`logs/r2_c15_native_gate_20260913_a.log`确认C15也全部选择最新完成帧。这是有限行为模型仿真，不是实际CPU执行、板测或C16/C17/C18性能；早期记录保留历史条件。

2026-09-13 新增C14调度候选：[最新待处理输入保护](review/R2_FRESH_INPUT_SCHEDULING_20260913.md)。
优先回收FREE/较旧READY，避免有替代槽时丢弃最新完成帧；CNN、CPU适配层及C12/C13保留。
594项调度检查、旧RTL负对照、实际RAM破坏、24次多尺寸CNN及小图六帧xsim通过。
Ti60 I3核心150MHz：45,937 XLR/172 RAM/112 DSP，setup/hold +0.210/+0.026ns；非板级签核。
局部证据`logs/r2_c14_gate_20260913_a.log`；独立C14原生六帧及新鲜度轨迹现已通过，见上方新证据。

2026-09-13 新增C13候选：[CPU普通DDR适配与C12联合验证](review/R2_CPU_AXI_ADAPTER_20260913.md)。
独立`c1_r2_cpu_axi_adapter.sv`保留完整8-bit CPU ID，读写各一笔在途，支持对齐窄INCR访问，
明确拒绝独占/非零REGION等未支持命令。882次适配层任务、24次联合CNN和六帧xsim通过。
联合核心150MHz实现：45,842 XLR、172 RAM、112 DSP（较C12增加325 XLR）；未实例化官方CPU/PHY/CDC。
C13原生六帧现已独立通过，最坏完整间隔15.3145fps，详见上方新证据；不能称已全面兼容Sapphire。
证据入口`logs/r2_c13_gate_20260913_b.log`；原C12及更早生产RTL保持不变。

2026-09-13 当前主线R2-C12：[RGBX32外存与四原图/三结果连续调度](review/R2_RGBX_BUFFER_PIPELINE_20260913.md)。
保留C11及更早RTL，CNN内部P2C8、22节点和96MAC不变；仅RGB边界压缩到4B/像素并增加帧所有权容量。
Icarus系统含连续六帧共44次CNN、三组xsim共10次CNN、行格式/视频DMA异常恢复及实际RAM负对照已通过。
Ti60 I3核心150MHz实现通过：45,517 XLR、172 RAM、112 DSP，setup/hold +0.556/+0.026ns。
新R2V2 ABI `0x52325632`与独立RV32驱动已验证到编译；未接实际CPU/PHY/ISP/HDMI/CDC。
原生640×480三次CNN联合运行已通过：30fps采集＋720p60双图＋CPU竞争，共享1.2GB/s服务模型；
最后完成间隔9,728,220拍，150MHz折算**15.42fps**，零欠载/显示失约，周期余量2.72%。
以上是早期三帧的一个完整负载间隔；后续六帧已通过四个连续全负载间隔，最慢15.3145fps，非长期板测保证。
独立检查器`golden/check_r2_rgbx_system_evidence.py`，最终六帧门禁`logs/r2_c12_sixframe_gate_20260913_a.log`。

此前R2-C11：[真实像素DMA、帧缓冲所有权与CNN联合系统](review/R2_VIDEO_DMA_DEVELOPMENT_20260913.md)。
已增加不可回压RGB采集、双图显示、三原图/两结果缓冲配对及新R2V1控制器，保留原CNN和C10基线。
小图联合回归、W先于AW、实际RAM破坏负对照、148项帧状态和102项CSR检查及两组xsim交叉验证已通过。
当前源Ti60 I3核心实现通过：44,742 XLR、170 RAM、112 DSP；150MHz setup/hold +0.644/+0.026ns。
这是固定640×480的核心探针，不含CPU/DDR PHY/ISP/HDMI/CDC；新R2V1驱动仅通过RV32编译，尚未在CPU执行。
640×480原生30fps采集＋720p60双图＋CPU竞争仿真已完成，三次CNN及配对显示功能通过；
最后完成间隔15,573,978拍，150MHz折算**9.63fps，未达15fps**（含缓冲启动等待；第三次CNN执行本身13.44fps）。
C10的15.28fps负载较轻（15fps采集、单图显示），不能作为完整视频系统15fps达标证据。
C11最终门禁：`logs/r2_c11_gate_20260913_d.log`；仿真不保存波形，运行结束自动删除大文件。

此前R2-C10：[APB＋共享 AXI 子系统](review/R2_SHARED_AXI_SYSTEM_20260913.md)。
新增 CPU 控制/IRQ/结果发布、四主机 fabric、RISC-V 最小驱动；保留 R1/C5～C9 执行 RTL。
最终原生 640×480 竞争流量 xsim 通过，9,814,854 拍，150 MHz 折算 **15.28 fps**；
这是 640×480 P2C8 采集/显示/CPU 负载模型下的 CNN 作业吞吐，非板测或视频期限保证。
普通/背压/无背景/W先于AW共38正常帧、20错误/丢弃帧，另有原生1帧、4个真实采集RAM污染负测试。
独立命名 C10 Efinity 工程150MHz通过：44,686 XLR、162 RAM、112 DSP，setup/hold +0.482/+0.089ns。
当时待办的视频DMA/缓冲协调器现由C11推进；官方CPU/DDR IP适配及完整板级资源/时序仍待完成。

此前R2-C9：C8计算核外新增128位AXI行DMA，16拍burst、读写各4笔在途，
自动4KiB切分、AW/W独立握手、所有B响应屏障及协议故障的本地页排空。
30组独立DMA配置/828次行用例已通过；最终Ti60核级150MHz map+PNR为40,015 XLR、
160 RAM、112 DSP，setup/hold为+0.732/+0.089ns。完整640×480实际AXI图核实测
9,297,258拍，150MHz折算**16.13fps**（共享1.2GB/s、每物理burst延迟20拍）。
22节点/21,043,200有效标量对应结果一致，AR/AW/B=94,950/89,400/89,400，真实读写峰值均4笔。
完整矩阵34正常/恢复帧、18错误帧通过；本阶段仍未接CPU/视频/真实DDR PHY，非板测帧率。
详见[R2-C9报告](review/R2_AXI_ROW_DMA_20260913.md)。R1与C8等全部保留，不替换默认SoC。
包含W先于AW压力用例在内，累计57正常帧（含原生）、36错误帧及4次实际RAM污染负测试通过；
最终门禁通过，仿真/EDA私有目录已清空，下一步是共享DDR/CPU/视频集成。

此前R2-C8：双缓冲writer＋RTL预取优先，计算与旧行写回实际重叠。
完整640×480的22节点已在detached xsim通过，21,043,200个有效标量对应写回与golden一致；
共享读写1.2GB/s、逻辑命令延迟20拍条件下实测9,289,054拍，按150MHz为**16.15fps**。
这是核级存储模型下跨过15fps门限，**非实际AXI/整机/板测帧率**；每帧尚余约71万拍预算。
Ti60图核150MHz map+PNR为38,819XLR、160RAM、112DSP，setup/hold为+0.540/+0.031ns。
小图/原生宽度矩阵18正常帧、24错误帧通过，另有长写背压与六种系统复位/完整重启验证。
R1/C5/C6/C7均保留，外部流量仍47.2MB/帧，未替换默认SoC。下一步真实AXI burst/4KiB
切分、有界多outstanding，再接CPU/DDR/视频并验证实际集成开销是否仍满足15fps。
本次仿真/EDA私有目录已清理，仅保留小日志和摘要。
入口：[R2-C8 报告](review/R2_PINGPONG_WRITE_OVERLAP_20260913.md)、
[当前实现状态](IMPLEMENTATION_STATUS.md)、[持续开发日志](DEVELOPMENT_LOG.md)。
下文包含 R1 各历史阶段快照，不能将早期结论替代上述最新 R2 范围。

Efinity 的 staging 目录约定、IP Manager 生成边界和隔离 RISC-V IDE 启动方式见
[`efinity/README.md`](efinity/README.md)；对应启动脚本是
[`scripts/launch_efinity_riscv_ide.ps1`](scripts/launch_efinity_riscv_ide.ps1)。

本目录已经形成一条可复现的板卡无关开发链：公开测试图片 → Python/QAT 与整数 Golden → 固定点和 ABI → 可综合 SystemVerilog → WMI 脱离式 Vivado/xsim 回归 → Vivado 结构/时序代理。

当前结论必须分成三层：

- **算法与模型工件已闭合到功能基线**：`model/microstyle24_starry_functional/` 包含经过 float 训练和 QAT 的 checkpoint、22×64 B descriptor、16,896 B 参数 arena 与整数回归向量。独立的 32×32 artifact 回归可 exact replay 22 个 stage；另一个 6×64×64 图片回归比较 QAT checkpoint 与整数模型的最终 RGB，最大误差为 0。两者都不是 RTL 逐层结果。该小数据集工件只证明优化、导出和 bit-exact 合同，不代表竞赛级风格画质已经收敛。
- **板卡无关 SoC 架构已闭合到可缩放的小帧全链功能回归**：真实 22-stage `c1_r1_microstyle_engine`、参数调度、三 bank 顺序 tensor adapter、可选三行 C8 window cache、64→AXI128 bridge、采集/显示/控制与七客户端 AXI 组合已经落入 `c1_r1_portable_soc`。当前源码下 8×8 单帧 `c1_8x8_gate_20260825`、16×8 两帧 `c1_16x8_two_gate_20260825`、64×48 单帧 `c1_64x48_single_gate_20260825` 和 64×48 两帧 `c1_64x48_two_gate_20260825` 均通过；64×48 两帧完成 `done=2 descriptors=44 swaps=2 drops=0 display_done=1`，并产生 `AW/W/B=80448/83328/80448`、`AR/R=96793/102295`。另外，8×8 trained-artifact 路径已用 production parameter bank 完成 stage-0 全写回、stage-1 首像素/完整 2×2、stage-2…stage-7 以及 stage-8…stage-21 的完整 2×2 handoff gate；stage-21 还完成 64 个最终 RGB beat 的自然收口。上述动态证据证明板卡无关的小帧生命周期、frame ownership 和共享 DDR 协议；不等于 native 640×480 trained-model 端到端或实时性能。
- **物理实现和实时性能尚未闭合**：赛题指南已指定 Ti60F225I3 的 Ti60F225 开发板（MIPI CSI-2、HDMI、DDR3、千兆以太网）；Efinity IDE 2026.1.132（已应用 patch 2026.1.132.3.9）与 Efinity RISC-V IDE 已安装，`efx_run.bat --help`、本地 GCC/OpenOCD/QEMU 入口均已核验。但本次板卡 revision、DDR 颗粒/控制器配置、时钟和引脚约束尚未从官方工程核验，尚未做 Ti60 原生综合、布局布线或 MIPI/DDR/HDMI 实测。当前 tensor adapter 是 correctness-first、单 outstanding 的 64-bit 顺序访存方案，远达不到 15 fps；三个 8 MiB tensor bank 是外部 DDR 地址区，共 24 MiB，绝不是片上 RAM。Vivado display FIFO proxy（bypass 对 fifo128：`2600→3094 LUT`、core WNS `+3.265→+2.470 ns`）和最终源码 native SoC proxy（`44792→45298 LUT`、strict FIFO128 core WNS `-53.327 ns`）都只是结构预算，详见 `DISPLAY_RESPONSE_FIFO_PROXY_SYNTH.md` 与 `PORTABLE_SOC_FIFO_PROXY_SYNTH.md`。工具链使用边界和拿到板卡后的 Efinity/Sapphire 流程见 [`EFINITY_RISCV_TOOLCHAIN_GUIDE.md`](EFINITY_RISCV_TOOLCHAIN_GUIDE.md) 与 [`BOARD_BRINGUP_CHECKLIST.md`](BOARD_BRINGUP_CHECKLIST.md)。
- **描述符/地址时序已完成第一轮量化**：最终源码 strict FIFO128 的完整 proxy core WNS 为 `-53.327 ns`；显式 `STRICT_DESCRIPTOR_VALIDATION=0` 后为 `-15.659 ns`（Q→D 专用 `-13.455 ns`），但地址生成仍是主路径。relaxed 模式只作为软件 ABI 已签名后的性能候选，仿真仍 `$fatal` 检查非法 descriptor；最终 `FAST_TENSOR_ADDRESS_ARITH` shift/add 实验增加 793 LUT、恶化到 `-16.647 ns`（Q→D `-14.216 ns`），已标记为不选用。随后可选 `PIPELINED_TENSOR_ADDRESS=1` 将 pixel-index/final-address 分成两状态；Q→D 专用报告中 tensor 地址路径已消失，系统最差数据路径为 camera FIFO→resize `-4.772 ns`（普通 max report 的 `-4.972 ns` 含高扇出控制/复位族）。再叠加可选 `PIPELINED_START_CONFIG=1` 后，640×480 relaxed proxy 为 `44670 LUT/28141 FF/84 DSP`，Q→D 最差改善为 `-4.601 ns`，代价 29 LUT、72 FF 和一拍启动延迟；`PIPELINED_DOT_TREE=1` 的 final-dot-sum 边界实验为 `44691 LUT/28606 FF/84 DSP`、Q→D `-4.752 ns`，故默认关闭。随后真正的 `PIPELINED_DOT_TREE_FULL=1` 已将 product→pair→quad→dot 分成四级弹性流水，640×480 proxy 为 `44594 LUT/31396 FF/84 DSP`、Q→D `-4.701 ns`；功能/结构链已通过，但多约 3.3k FF 且仍未闭合 100 MHz，也默认关闭。新增 `PREVALIDATE_DESCRIPTOR_REPLAY=1` 只缓存每 stage 五比特校验结果，proxy 为 `44660 LUT/31374 FF/84 DSP`、direct `-4.824 ns`、Q→D `-4.701 ns`，比 512-bit replay register 的资源代价小很多，但仍默认关闭并要求 cache-integrity 证据。所有这些开关仍默认关闭；8×8 单帧/两帧、strict 集成兼容与 native elaboration 均已通过，但 start-config 不等价 standalone same-edge CNN ABI。详见 `PORTABLE_SOC_DESCRIPTOR_TIMING_PROXY.md`。
- **native fabric 进度修正**：上条原生尺寸说明中的“下一步把 boardless job 接入七客户端共享仲裁”已由 `native_fabric_full2_20260825` 完成，随后 `native_fabric_param_full_20260825` 又替换了第一枚真实 parameter leaf；当前主线是用 portable SoC 的真实 capture/display/tensor/compute client 做并发长帧回归。复现入口见 [`NATIVE_BOARDLESS_FABRIC_PREFLIGHT.md`](NATIVE_BOARDLESS_FABRIC_PREFLIGHT.md) 和 [`NATIVE_BOARDLESS_FABRIC_REAL_PARAMETER.md`](NATIVE_BOARDLESS_FABRIC_REAL_PARAMETER.md)。
  - **15 fps 吞吐阶段（2026-08-27）**：新增独立 AXI128 读/写 pack-burst leaf、无 ID 多 descriptor 读/写 fabric、两客户端读集成 wrapper，并完成 3-row cache shell 与并行 8×8 MAC bank 的板前回归。读集成 `16 logical→6 AR/8 R beats/max_inflight=5`，写 fabric `6 AW/12 W beats/max_outstanding=3`；这些 seam 尚未改接默认 SoC，完整边界、资源代理和停止条件见 [`15FPS_THROUGHPUT_PHASE.md`](15FPS_THROUGHPUT_PHASE.md)。
  - **registered tap 坐标 A/B（2026-08-28）**：`PRECLAMPED_TAP_COORDS=1` 已完成 adapter→cache 参数传播，并以 `preclamped_registered_tap_8x8_twoframe_v1` 通过两帧 full-BFM；其 `AW/W/B=1704/1736/1704`、`AR/R=1451/2970` 与 fixed baseline 完全一致。早期 raw sign-only clamp 因 `AR/R=1463/3042` 的语义/流量偏差已拒绝；native helper=all 修复此前 full-top `common.tcl` runtime failure 后，严格 proxy A/B 已完成：baseline `47512/34821/32/85`、registered `47443/34784/32/81`（LUT/FF/BRAM/DSP），WNS 均 `-1.079 ns`，TNS `-20.120→-15.868 ns`；结果仍为 xc7a proxy/timing_failed，默认仍关闭，非 Ti60 signoff。详见 [`ADAPTER_WINDOW_CACHE_SIDEBAND.md`](ADAPTER_WINDOW_CACHE_SIDEBAND.md) 与 [`TEST_RESULTS.md`](TEST_RESULTS.md)。
  - **Soft Sapphire 控制平面 seam（2026-08-28）**：新增 `c1_sapphire_apb_master_adapter` 与 `c1_sapphire_irq_adapter`，完成生成 APB 端口→Case-1 APB、PSTRB（写 `4'hf`/读 `0`）、宽地址错误隔离和电平 IRQ→PLIC one-hot 映射；detached xsim marker 为 `C1_SAPPHIRE_APB_ADAPTER_PASS`。该 seam 已验证但尚未接入具体板卡 BSP/引脚约束，详见 [`EFINITY_RISCV_TOOLCHAIN_GUIDE.md`](EFINITY_RISCV_TOOLCHAIN_GUIDE.md)。
  - **Efinity/RV32 boardless software smoke（2026-08-28）**：`software/efinity_smoke` 已执行 `make clean all`，生成 ELF/HEX/BIN/MAP/反汇编和三个对象文件共 8 个文件、`35,952 B`（约 35.1 KiB）；ELF 为 RV32 ELF32、RVC、soft-float、默认 `rv32imc/ilp32`。本轮 housekeeping 已将 `c1_accel.o` 固定放入 `build/`，新构建不再把对象文件生成到 `software/src`；旧版本遗留文件若存在需单独清理。这是本地工具链和链接链检查，不是最终 Sapphire BSP、CPU 启动或实际 APB 访问验证；生成 BSP 后必须替换 startup/linker，并从 `soc.h`/address map 取得 MMIO 地址。详见 [`EFINITY_RISCV_TOOLCHAIN_GUIDE.md`](EFINITY_RISCV_TOOLCHAIN_GUIDE.md) 和 [`software/efinity_smoke/README.md`](software/efinity_smoke/README.md)。
- **trained artifact 已进入 portable SoC 8×8 全生命周期（2026-08-28）**：新增默认关闭的 `-TrainedArtifact` BFM 分支，真实 22 个 descriptor 和 16,896 B parameter arena 会经 DDR BFM/parameter loader、共享七客户端 AXI、boardless DMA、tensor adapter、MicroStyle engine 和 display drain。最新 marker 为 `C1_R1_PORTABLE_SOC_TRAINED_ARTIFACT_8X8_PASS descriptors=22 weight_ar=66 axi_r=2199 done=1 stage_mask=1fffff`，普通生命周期 marker 同时通过。该结果仍不是 native 640×480、逐像素 Python golden、15 fps 或 Ti60/Efinity signoff；复现入口为 `scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -Frame 8x8 -TrainedArtifact`。
- **native 640×480 artifact ABI preflight（2026-08-28）**：修复 `run_r1_microstyle_artifact_abi_xsim_detached.ps1` 的 WMI 失败 fallback 和相对向量路径；最新 detached run 通过 22 个 native descriptor、16,896 B arena、1,030 个有效参数读/写以及 6 类负向校验。该阶段只闭合 decoder/parameter-scheduler ABI，不启动 native CNN 长帧。
- **native 640×480 artifact descriptor/parameter commit preflight（2026-08-28）**：新增 `tb_c1_r1_native_artifact_preflight.sv` 与 detached runner；真实 22-stage native descriptor 逐项通过 decoder、层间 shape continuity 和 Conv/DW/Upsample/Residual/RGB 几何约束，真实 16,896 B arena 经 production AXI loader 完成 `66 bursts/1056 beats`、AR/R 与 bank 回压、generation=1 原子提交及首/中/尾读回。marker 为 `C1_R1_NATIVE_ARTIFACT_PREFLIGHT_PASS ... boundary=DESCRIPTOR_CONTINUITY_PLUS_PARAMETER_COMMIT_ONLY`。这是 native CNN 数据平面前的有界门，不启动长帧；runner 自动删除临时 xsim 树。详见 [`NATIVE_ARTIFACT_PREFLIGHT.md`](NATIVE_ARTIFACT_PREFLIGHT.md)。
 - **native 640×480 首层有限窗口预检（2026-08-28）**：新增 `tb_c1_r1_native_first_window_preflight.sv` 与 detached runner；真实 22-stage descriptor 配置后，完整源帧只经一次 64-bit tensor 写入，首层 stride-2/SAME_REPLICATE 的第一个 3×3 window 验证 9 个真实 bank-0 地址/数据，两个 output group 写入 bank-1 后立即执行 protocol-safe abort。Icarus 与 Vivado/xsim 均通过 `C1_R1_NATIVE_FIRST_WINDOW_PREFLIGHT_PASS frame=640x480 stages=22 source_writes=307200 first_window_reads=9 engine_inputs=1 output_writes=2 abort=1 ...`；同时以 `-PipelinedAddress -PipelinedPixelIndex` 完成流水化 A/B，计数保持一致。该门明确不进入后续 21 层或 native 长帧，也不等价于时序/15 fps 签核。详见 [`NATIVE_FIRST_WINDOW_PREFLIGHT.md`](NATIVE_FIRST_WINDOW_PREFLIGHT.md)。
 - **native 640×480 首层真实算术有限窗口（2026-08-29）**：在上述地址/窗口门之后，新增 `tb_c1_r1_native_first_window_engine_preflight.sv`；真实 `c1_r1_parameter_bank` 先提交 1,056×128-bit arena，再把生产 adapter 接到真实 `c1_r1_microstyle_cnn_top`，用 centered signed-s8 图案完成 stage-0 两个 C8 输出 group 的 Python golden 对照（首像素 `group0=0e09000000320005`、`group1=0000000000190006`），最后安全 abort。默认一像素与 `-PipelinedAddress -PipelinedPixelIndex` A/B 均通过；`-WindowPixels {1,2,4,8,16}` 均已预置，其中 8/16 像素流水化首行 gate 也已在 Icarus 与 detached xsim 通过（分别 `first_window_reads/engine_inputs/engine_outputs/output_writes=72/8/16/16` 与 `144/16/32/32`）。该 gate 只覆盖真实参数 bank + stage-0 有限首行算术，不进入后续 21 层、native 全网、15 fps 或 Ti60 signoff。详见 [`NATIVE_FIRST_WINDOW_ENGINE_PREFLIGHT.md`](NATIVE_FIRST_WINDOW_ENGINE_PREFLIGHT.md)。
- **8×8 production-bank stage-1/2/3 交接（2026-08-29）**：在 stage-1 首像素/完整 2×2 和 stage-2 完整 2×2 gate 之后，新增 `C1_STAGE3_FULL` 有界模式；它自动保留完整 22-stage 配置屏障、stage-1/2 写回，再让 `res0.depthwise3x3`（C48→C48、2×2、6 groups）从 bank1 读取 216 个 3×3 tap，并向 bank2 写回 24 个输出 group。stage-3 full gate 的累计计数为 `operands/results=60/92`、`stage1_reads/writes=72/12`、`stage2_reads/writes=12/24`、`stage3_reads/writes=216/24`、`stage_done=4`；Icarus 与 detached xsim 均通过，最后一个 stage-3 写响应刻意延迟 3 个周期后完成 abort drain，且三层跨 bank provenance、x/y/group-last/SOF/EOL/EOF 元数据逐项检查。该门仍不启动 stage 4–21、native 长帧、共享 DDR QoS、100 MHz 时序或 15 fps。详见 [`STAGE3_HANDOFF_PREFLIGHT.md`](STAGE3_HANDOFF_PREFLIGHT.md)。
- **stage-4/5/6/7 production-bank handoff（2026-08-29）**：在 stage-3 full gate 后，`-FullStage4`、`-FullStage5`、`-FullStage6`、`-FullStage7` 分别闭合 `res0.project1x1`、`res0.add_relu`（primary/residual 双读）、`res1.expand1x1` 和 `res1.depthwise3x3` 的完整 2×2 交接。累计 marker 计数依次为 stage4 `operands/results=84/104`、stage5 `96/116`、stage6 `108/140`、stage7 `132/164`；stage-5 的 `main/residual reads=12/12`，stage-7 的 SAME_REPLICATE reads/writes=`216/24`，最终 `stage_done=5/6/7/8`。四个 Icarus 快速门和 detached Vivado/xsim 均通过，末个写响应固定延迟 3 周期后完成 abort/drain。新增 run ID 为 `stage7_full_metadata_final_20260829`；xsim stderr 全空、私有 runRoot 已删除且无模拟器残留。该条是 stage8…21 扩展前的历史分段快照；native 长帧和 15 fps 仍未闭合。详见 [`STAGE4_6_HANDOFF_PREFLIGHT.md`](STAGE4_6_HANDOFF_PREFLIGHT.md) 与 [`STAGE7_HANDOFF_PREFLIGHT.md`](STAGE7_HANDOFF_PREFLIGHT.md)。
- **stage-8…stage-21 production-bank handoff（2026-08-29）**：新增 `-FullStage8`…`-FullStage21`，逐层闭合 `res1.project1x1`、`res1.add_relu`、`res2` 残差块、两级 decoder、`output.conv3x3` 和 `s8_to_rgb` 的完整 2×2 交接。Icarus 14.0 对 14 个终点逐一通过，累计 operands/results 从 `156/176` 推进到 `896/836`；stage-9/stage-13 的 residual 双 bank 来源、3×3 `SAME_REPLICATE` 边界重复、upsample floor 坐标、RGB final stream 均有地址/bitmap/元数据检查。detached Vivado/xsim 的 stage-14 与 stage-21 代表性端点也通过（最终复核 run 为 `stage21_full_handoff_final_20260829`）；stage-21 输出 `final=64, abort=0`，中间端点保持固定 3-cycle response-delay 后安全 abort。详见 [`STAGE8_21_HANDOFF_PREFLIGHT.md`](STAGE8_21_HANDOFF_PREFLIGHT.md)。
- **原生尺寸已推进到显示、采集写回、capture/table/ISP、两主机 input-DMA/arbiter、read→write DMA 闭环，以及真实 boardless job 分阶段预检**：runner 现支持 `-Frame 640x480 -CompileOnly`；在 tensor adapter 64-bit 几何/地址表达式修复、native 地址图切换和 associative DDR store 加入后，`c1_640x480_final_elab_20260825` 的 xvlog/xelab 均通过且 stderr 为空，最新 `portable_fifo_native_elab_final_20260825` 又确认完整七客户端顶层在 `640×480 + C1_DISPLAY_RESPONSE_FIFO` 下 elaboration 通过；最终全部可选开关组合（含 `PIPELINED_DOT_TREE`）也由 `dottree_final_native_elab_20260825` 通过。修复后的 8×8/64×48 两帧也由 `c1_8x8_u64fix_gate_20260825`/`c1_64x48_two_u64fix_gate_20260825` 重新 PASS。独立真实 `c1_display_prefetch_pair` 的 `native_prefetch_run2_20260825` 完成两路 640×480、307,200 像素/路和 `underflow=0/0`；最新 `native_display_fifo_final_20260825` 在 depth=128 FIFO 分支再次完成逐像素 `307200/307200`、`underflow=0/0`（旧 `native_display_fifo_full_20260825` 作为先前快照保留）。真实 `c1_axi_xrgb_frame_writer` 的 `c1_native_capture_writer_final_20260825` 完成三 slot、921,600 像素读回；真实 `c1_r1_capture_subsystem` 的 `c1_native_capture_table_paced_full_20260825` 完成三帧 642×482 RAW10→640×480、`pixels/sof/eol/eof=921600/3/1440/3`、Gamma 1024 次配置和 `AW/W/B=14400/230400/14400`；真实 table reader + XRGB reader + `c1_axi2_serial_arbiter_128` 的 `c1_native_input_dma_full_20260825` 又完成三 slot、`shared AR/R=14403/230403` 和逐像素 `frame_pixels=921600`；`c1_native_dma_loopback_final2_20260825` 将真实 read-side、stream、XRGB writer、write-side bridge/arbiter 和 associative DDR 回读串成三帧闭环；最新 canonical `native_boardless_job_hold_full_20260825` 再将真实 `c1_r1_boardless_frame_system` 接回 native table/descriptor、input/output DMA 和外部 CNN echo，完成 `stages=22`、`cnn_in/cnn_out=307200/307200`、`input AR/R=4800/76800`、`output AW/W/B=4800/76800/4800`、逐像素 output 回读。这些仍不等于 portable SoC 七客户端 native CNN/QoS/15 fps。复现细节见 [`NATIVE_DISPLAY_PREFLIGHT.md`](NATIVE_DISPLAY_PREFLIGHT.md)、[`DISPLAY_RESPONSE_FIFO_QOS_PREFLIGHT.md`](DISPLAY_RESPONSE_FIFO_QOS_PREFLIGHT.md)、[`NATIVE_CAPTURE_WRITER_PREFLIGHT.md`](NATIVE_CAPTURE_WRITER_PREFLIGHT.md)、[`NATIVE_CAPTURE_TABLE_PREFLIGHT.md`](NATIVE_CAPTURE_TABLE_PREFLIGHT.md)、[`NATIVE_INPUT_DMA_PREFLIGHT.md`](NATIVE_INPUT_DMA_PREFLIGHT.md)、[`NATIVE_DMA_LOOPBACK_PREFLIGHT.md`](NATIVE_DMA_LOOPBACK_PREFLIGHT.md) 和 [`NATIVE_BOARDLESS_JOB_PREFLIGHT.md`](NATIVE_BOARDLESS_JOB_PREFLIGHT.md)；下一步是把 credit-only FIFO 方案带入 native portable-SoC 长帧，再处理真实 tensor/CNN、underflow/deadline、资源和 descriptor budget。

补充：真正的 `PIPELINED_DOT_TREE_FULL=1` 全开组合已由 `treefull_final_native_elab_20260825` 完成
640×480 xvlog/xelab；它取代不了 native full-xsim/帧率验证，但比旧的 final-dot-sum
elaboration 快照多了一层真实 product→pair→quad→dot 结构证据；同一开关的 16×8
两帧和 64×48 单帧回归也已通过（分别 `done=2 swaps=2 drops=0`、
`done=1 swaps=1 drops=0`），跨帧/大尺寸 latency、drain 合同保持不变。
针对 descriptor validation 的完整 512-bit replay register 实验虽功能通过，
但 proxy 增至 `47114 LUT/41837 FF`，已作为负优化关闭。
窄结果 `PREVALIDATE_DESCRIPTOR_REPLAY` 实验则以约 66 LUT 的代价取得同样
`-4.824 ns` direct 改善；它仍未闭合 100 MHz，暂不作为默认配置。

边界和选题判断见 `IMPLEMENTATION_STATUS.md`，验证证据见 `TEST_RESULTS.md`，资源证据分类见 `RESOURCE_BUDGET.md`。

板卡资料更新：用户截图已确认 `MT41J128M16JT-125` DDR3 x16/800 Mbps 及
25/27/50 MHz、MIPI/HDMI、FT4232HL 等能力；仍缺官方 revision、DDR 控制器/IP
拓扑、pin/clock 约束。汇总与容量/带宽换算见
[`efinity/TI60F225_BOARD_PROFILE.md`](efinity/TI60F225_BOARD_PROFILE.md)。

**存储卫生（2026-08-29）**：已清理 `case1/sim` 下 769 个历史 detached
运行目录（约 4.85 GB）以及 4 个超过 1 MB 的原始 `xsim/vivado` stdout（约
295 MB）；直接放在 `sim/` 下的 testbench/RTL 源文件和 `logs/` 中的紧凑
status/marker/report 保留。后续 runner 仍应在 `finally` 中删除自己的工作树，
不要把大型波形或逐像素 stdout 当作长期证据。

本轮 stage-1 首像素/完整 2×2、stage-2/3 完整 2×2 以及 stage-4/5/6/7 完整 2×2
detached xsim 各仅保留 7 个紧凑日志文件（stage-1/2/3 约 6.1–6.4 KiB，
stage-4/5/6/7 约 6.5–6.8 KiB），Icarus runner 的
vectors/vvp 位于 `%TEMP%` 一次性目录并已自动清理；最终检查未残留这些仿真工作树、
波形或 Vivado/xvlog/xelab/xsim/vvp 进程。

stage-14/stage-21 handoff 也遵循同一策略：每个 run 仅在
`logs/stage1_handoff_runs/<run-id>/` 保留 status、短 stdout/stderr 和 marker，
不把私有 xsim 工作树写回 `case1/sim`。
`case1/sim/c1_pixel_pipeline_proxy.dcp` 若存在是有意保留的综合代理快照，
不是仿真临时目录。

## 关键文档

- `ALGORITHM_SPEC.md`：RAW/ISP、Resize、MicroStyle-24 与显示算法；
- `FIXED_POINT_SPEC.md`：RAW10、ISP、Resize、signed-INT8、舍入和饱和合同；
- `ARCHITECTURE.md`：portable SoC、RISC-V、DDR、CNN/tensor 与 vendor seam；
- `DESCRIPTOR_FORMAT.md`：64-byte、22-stage 配置 ABI；
- `FRAME_BUFFER_FORMAT.md`：三输入/双输出 XRGB8888 framebuffer ABI；
- `RESOURCE_BUDGET.md`：Ti60、片上 RAM、外部 DDR、吞吐和代理综合边界；
- `efinity/TI60F225_BOARD_PROFILE.md`：根据赛题文件和用户提供截图冻结的 Ti60F225I3 板卡事实、DDR/时钟预算与 bring-up 分层；
- `EFINITY_RISCV_TOOLCHAIN_GUIDE.md`：本机 Efinity 2026.1/RISC-V IDE、Soft Sapphire、CLI、BSP、QEMU/OpenOCD 和板前/板后工作流；
- `efinity/README.md`：不提交大体积 Efinity work/output 的 staging 约定、IP Manager 参数边界和隔离 IDE workspace 入口；
- `scripts/run_iverilog_smoke.ps1`：按需运行 Icarus Verilog-2005/SystemVerilog 与 APB/IRQ seam 的有界 smoke；
- `STAGE7_HANDOFF_PREFLIGHT.md`：8×8 production-bank stage-7 `res1.depthwise3x3` 的有限 2×2 handoff、SAME_REPLICATE 读序、bank provenance、实际 Icarus/xsim marker 与边界；
- `STAGE8_21_HANDOFF_PREFLIGHT.md`：stage-8…stage-21 的层间几何、producer-bank 地址/bitmap 检查、Icarus 全终点回归、代表性 detached xsim marker 和存储卫生边界；
- `logs/stage1_handoff_runs/stage8_21_iverilog_regression_20260829.log`：14 个 Icarus 终点的紧凑 marker 摘要（不含 vvp/波形）；
- `scripts/run_iverilog_rtl_compile.ps1`：按固定 package 顺序对 `c1_r1_portable_soc` 做全 RTL Icarus 编译/展开烟测；输出与边界见 `efinity/IVERILOG_RTL_COMPILE.md`；
- `scripts/probe_microstyle_artifact.py`：对 trained MicroStyle-24 做 native descriptor/arena 校验，并以 8×8 小图运行 22-stage 整数 golden probe；与下方 engine 向量/仿真脚本配合形成 RTL 前后对照；
- `golden/test_native_artifact_abi.py`：无依赖的 native 640×480 descriptor/parameter ABI 静态护栏，逐项检查 RTL scheduler/arena 约束并验证 `.mem` 镜像；它不运行长帧 CNN；
 - `NATIVE_ARTIFACT_ABI_AUDIT.md`：上述护栏的检查范围、结果和 native 数据平面边界记录；
- `sim/tb_c1_r1_native_artifact_preflight.sv` 与
  `scripts/run_r1_native_artifact_preflight_xsim_detached.ps1`：真实 native
  `640×480` descriptor 连续性、AXI parameter-loader/dual-bank arena 提交和边界
  读回的有界 preflight；只到 descriptor/parameter commit，不启动长帧 CNN，runner
  结束后自动清理 Vivado/xsim 工作树；范围与结果见
   [`NATIVE_ARTIFACT_PREFLIGHT.md`](NATIVE_ARTIFACT_PREFLIGHT.md)；
 - `sim/tb_c1_r1_native_first_window_preflight.sv` 与
   `scripts/run_r1_native_first_window_preflight_xsim_detached.ps1`：真实 native
   640×480 源帧写入、首层有限窗口/输出提交和可选地址/像素索引流水化 A/B；runner
   只保留紧凑摘要并自动清理 Vivado/xsim 工作树；范围与结果见
   [`NATIVE_FIRST_WINDOW_PREFLIGHT.md`](NATIVE_FIRST_WINDOW_PREFLIGHT.md)；
 - `sim/tb_c1_r1_native_first_window_engine_preflight.sv` 与
   `scripts/run_r1_native_first_window_engine_preflight_xsim_detached.ps1`：真实
   parameter-bank load、stage-0 engine/adapter 首窗口算术 golden 和共享 abort；
   `-WindowPixels 1/2/4/8/16` 可做有限首行连续像素 gate，默认/流水化 A/B 均保持兼容；
   8/16 流水化扩展已通过 Icarus 与 detached xsim，runner 只保留紧凑摘要并自动清理工作树；范围与结果见
   [`NATIVE_FIRST_WINDOW_ENGINE_PREFLIGHT.md`](NATIVE_FIRST_WINDOW_ENGINE_PREFLIGHT.md)；
  - `golden/test_native_stage0_window.py`：用 NumPy 从当前 trained arena 重算首行
    1/2/4/8/16 像素 stage-0 golden（`--pixels 1/2/4/8/16`，默认 4），防止 RTL 冻结常量与软件模型漂移；
- `golden/generate_microstyle_engine_bitexact_vectors.py`：把训练工件参数 arena 与 8×8 缩放拓扑转换为有界 engine 输入/输出向量；
- `scripts/run_r1_microstyle_engine_artifact_8x8_xsim_detached.ps1`：用 detached Vivado/xsim 对真实 trained arena 做 22-stage RTL 逐阶段 bit-exact 回归；
 - `sim/tb_c1_r1_microstyle_artifact_tensor_engine_8x8.sv` 与
  `scripts/run_r1_microstyle_artifact_tensor_engine_8x8_xsim_detached.ps1`：把真实
  trained descriptor/arena 串入 tensor adapter、MicroStyle engine 和小型 DDR BFM，
  做 8×8 全链逐拍比较；
 - `sim/tb_c1_r1_microstyle_artifact_tensor_engine_8x8.sv` 的
  `C1_USE_PARAMETER_BANK`/`C1_STAGE1_HANDOFF` 分支与
  `scripts/run_r1_stage1_handoff_xsim_detached.ps1`：使用 production dual-bank
  parameter loader，默认验证 stage-0 完整写回、stage-1 首像素 18-tap 读取/3-group
  写回；加 `-FullStage1` 可验证完整 2×2/72-tap/12-group，加 `-FullStage2` 可在
  其后验证 stage-2 完整 2×2/12 center-tap reads/24-group writes，加 `-FullStage3`
  可继续验证 stage-3 完整 2×2/216-tap/24-group writes；`-FullStage4`、
  `-FullStage5`、`-FullStage6`、`-FullStage7` 再分别覆盖 project1x1、add_relu（含 residual
  双读）、res1.expand1x1 和 res1.depthwise3x3（216-tap/24-group writes）；新增 `-FullStage8`…`-FullStage20`
  逐层覆盖剩余 residual/decoder/conv handoff，`-FullStage21` 继续到 64 个 final RGB beat 的自然完成；
  中间终点执行 protocol-safe abort，完整范围与结果见
  [`STAGE1_HANDOFF_PREFLIGHT.md`](STAGE1_HANDOFF_PREFLIGHT.md)、
  [`STAGE2_HANDOFF_PREFLIGHT.md`](STAGE2_HANDOFF_PREFLIGHT.md)、
  [`STAGE3_HANDOFF_PREFLIGHT.md`](STAGE3_HANDOFF_PREFLIGHT.md)、
  [`STAGE4_6_HANDOFF_PREFLIGHT.md`](STAGE4_6_HANDOFF_PREFLIGHT.md)、
  [`STAGE7_HANDOFF_PREFLIGHT.md`](STAGE7_HANDOFF_PREFLIGHT.md) 和
  [`STAGE8_21_HANDOFF_PREFLIGHT.md`](STAGE8_21_HANDOFF_PREFLIGHT.md)；
 - `scripts/run_iverilog_stage1_handoff.ps1`：使用本机 Icarus 对 stage-1 首像素、
  stage-1 完整 2×2、stage-2/3 完整 2×2 以及 stage-4…stage-21 有界模式做快速回归，所有
 vectors/vvp 均置于 `%TEMP%` 一次性目录并在 `finally` 清理；开关包括默认、
   `-FullStage1`…`-FullStage21`，高编号开关自动包含其前置阶段；
- `scripts/run_r1_stage1_handoff_xsim_detached.ps1`：以 WMI/Breakaway worker
  运行同一组 stage-1…stage-21 有界 gate；`-FullStage4`…`-FullStage21`
  分别选择对应终点，worker 结束时删除私有 xsim 工作树，仅保留紧凑日志；
- `BOARD_BRINGUP_CHECKLIST.md`：拿到确切板卡后从时钟/复位、DDR、视频输入输出到 Sapphire/APB/IRQ 和 QoS 的分阶段清单；
- `PERFORMANCE_NEXT_PHASE.md`：packing/cache/outstanding/MAC 性能化的实施顺序与停止条件；
- `15FPS_THROUGHPUT_PHASE.md`：本阶段 AXI128 pack/burst、cache shell、读写多 outstanding、两客户端读集成与并行 MAC 的 RTL/仿真/代理综合证据；
- ping-pong MAC 另有可选四 bank A/B runner，可量化 `max_inflight=4` 与 128 DSP 的资源/时序代价，默认双 bank 与主 SoC 不变；
- `NATIVE_DISPLAY_PREFLIGHT.md`：640×480 显示/DDR 分阶段预检的覆盖范围、复现命令和边界；
- `NATIVE_CAPTURE_WRITER_PREFLIGHT.md`：640×480 三输入 slot 写回/读回预检的覆盖范围、复现命令和边界；
- `NATIVE_CAPTURE_TABLE_PREFLIGHT.md`：642×482 RAW10→640×480、Gamma、frame-table 与真实 capture writer 三帧分阶段预检；
- `NATIVE_INPUT_DMA_PREFLIGHT.md`：三 slot 640×480 frame-table + XRGB input reader + 两主机 AXI read arbiter 分阶段预检；
- `NATIVE_BOARDLESS_JOB_PREFLIGHT.md`：真实 `c1_r1_boardless_frame_system` 的 640×480 table/descriptor/input-output DMA/外部 CNN echo 闭环；
- `NATIVE_BOARDLESS_FABRIC_PREFLIGHT.md`：真实 native boardless job 作为 client-0 与 6 个并发 AXI traffic client 共享 7-client arbiter 的 fabric 预检；
- `NATIVE_BOARDLESS_FABRIC_REAL_PARAMETER.md`：client-1 替换为真实 parameter-loader + parameter-bank、其余五个 peer 保持合成流量的 640×480 fabric 切片；
- `PORTABLE_SOC_AXI_CLIENT_MONITOR.md`：绑定 portable SoC 内部七客户端 AXI 向量的 traffic/wait 监视器及首个 QoS 诊断结果；
- `rtl/dma/c1_axi_shared_qos_monitor.sv`：生产 RTL observation-only QoS monitor；aggregate 读窗口接入 APB，per-client 明细保留层次化；
- `rtl/top/c1_r1_soc_control.sv`：prefetch transaction 的 new-pair 标签与 `display_prefetch_new_done_event` terminal；
- `rtl/control/c1_apb_csr.sv`：QoS `0x108..0x12c` live aggregate read window 与 `CONTROL[5]` 统一清零；
- `sim/tb_c1_axi_shared_qos_monitor.sv`：2-client/16-bit standalone 定向 wait/stall/owner/underflow/deadline 回归（协议/overflow 仅检查零异常路径）；
- `sim/tb_c1_r1_portable_soc_cache_ddr_bfm.sv`：native tagged two-frame、APB readback 与 FIFO A/B BFM；
- `scripts/run_axi_shared_qos_monitor_xsim_detached.ps1`、`scripts/run_axi_shared_qos_monitor_proxy_synth_detached.ps1` 与 `scripts/synth_axi_shared_qos_monitor_proxy.tcl`：monitor 独立 xsim/100 MHz Artix-7 proxy 复现入口；
- `scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1`：native portable-SoC BFM，使用 `-SharedQosMonitor -TwoFrame` 可验证 tagged new-pair terminal 与 APB aggregate readback；worker 结束时删除私有仿真目录；
- `DISPLAY_RESPONSE_FIFO_QOS_PREFLIGHT.md`：可选 display response FIFO、credit-only AR admission、单帧/两帧/native 像素预检与资源边界；
- `DISPLAY_RESPONSE_FIFO_PROXY_SYNTH.md`：bypass/fifo128 的 Vivado proxy LUT/FF/LUTRAM/时序对比及 Efinity 边界；
- `PORTABLE_SOC_FIFO_PROXY_SYNTH.md`：完整 640×480 七客户端 SoC 的 FIFO 系统级资源/时序 proxy；
- `PORTABLE_SOC_DESCRIPTOR_TIMING_PROXY.md`：strict/relaxed descriptor 校验、地址路径、compute-start 边界和负优化实验的实测对比；
- `TIMING_NEXT_AUDIT_20260828.md`：当前 full-top tensor-burst 首违例归因、descriptor-size/abort-ready A/B 证据和默认关闭的下一步门控建议；
- `FULL_DOT_TREE_PREFLIGHT.md`：真正 product→pair→quad→dot 四级流水的 RTL 合同、回归证据、资源/时序 proxy 与板前限制；
- `READY_ABORT_TIMING_PREFLIGHT.md`：full-tree 后高扇出 ready/abort Q→D 路径、协议风险和下一轮可选复制实验；
- `NATIVE_DMA_LOOPBACK_PREFLIGHT.md`：三 slot 640×480 table/read DMA→XRGB writer→write arbiter→DDR 回读闭环预检；
- `CACHE_INTEGRATION_CONTRACT.md`：adapter 的 pixel→group→tap 顺序、全 group 行布局、旁路资格、abort/drain 与资源边界；
- `ADAPTER_WINDOW_CACHE_SIDEBAND.md`：adapter 每层 cache 配置、逐请求 signed x/y/group metadata 与兼容模式；
- `rtl/dma/c1_tensor_mem_path_seam.sv`：legacy bridge/performance packer 的可插拔 memory seam；
- `software/README.md`：RV32IMC 裸机软件职责、CSR 与主机测试。

## 目录入口

- `assets/images/`：6 张许可明确、可再分发的自然图片；
- `assets/generated/`：90 张确定性合成 PNG；
- `assets/local_only/`：Lenna 等仅本地兼容测试，不能随公开交付物再分发；
- `golden/r1_isp.py`：四 Bayer/ROI、RGB10 ISP 与 Q16.16 双线性 Resize Golden；
- `model/microstyle24_starry_functional/`：功能性 QAT checkpoint、descriptor、参数 arena 和整数回归；
- `outputs/microstyle_qat/validation/`：6 张输入/输出对图和验证指标；
- `rtl/cnn/c1_r1_microstyle_engine.sv`：真实 descriptor/参数驱动的 22-stage C8 算术 engine；128-bit ABI 顺序缓存按层多拍 OIHW 重排到固定 Conv/DW 小 bank；
- `rtl/cnn/c1_r1_microstyle_tensor_adapter.sv`：三 bank、顺序单 outstanding 的 window/group/address scheduler；默认关闭、可选开启 window-cache sideband；
- `rtl/cnn/c1_window_line_cache_ctrl.sv`：独立 3-row、row-tag/refill 控制原型（只验证控制与流量，不含 pixel data BRAM）；
- `rtl/cnn/c1_window_line_cache_c8.sv`：3-row、每物理行保存全部 C8 groups 的真实 64-bit payload 缓存；行内为 x-major/group-minor，默认上限 1280 words/row；
- `rtl/dma/c1_tensor_window_cache_seam.sv`：adapter logical req/rsp 到 C8 cache/direct narrow-memory 的 owner 路由、容量/地址 fallback、coherence 与 abort/flush drain；
- `rtl/dma/c1_tensor_mem_axi128_bridge.sv`：64-bit tensor 请求到单拍 AXI4-128 的桥；
- `rtl/dma/c1_tensor_mem_axi128_read_burst_client.sv`：独立的 64-bit→AXI128 读 pack/burst leaf（默认不接 legacy top）；
- `rtl/dma/c1_tensor_mem_axi128_write_burst_client.sv`：独立的 64-bit→AXI128 写 pack/burst leaf（当前单 outstanding）；
- `rtl/dma/c1_axi_n_read_burst_arbiter_128.sv` / `rtl/dma/c1_axi_n_write_burst_arbiter_128.sv`：可选的无 ID 多 descriptor 读/写 fabric seam；
- `rtl/dma/c1_axi_shared_owner_epoch_fence.sv`：共享 read/write admission、abort/flush 排空与 epoch 控制 seam；
- `rtl/dma/c1_axi_shared_owner_epoch_arbiter_128.sv`：可选地把上述 fence 接到真实 serial arbiter 的 owner-preserving VALID gate（默认 SoC 尚未实例化）；
- `rtl/dma/c1_tensor_mem_axi128_read_fabric_2c.sv`：两个读 leaf 到读 fabric 的板前集成 wrapper；
- `rtl/dma/c1_tensor_window_cache_axi_client.sv`：显式 client-6 边界，将可选 C8 seam 与 AXI128 bridge 封装为一个可独立验证的共享 DDR 客户端；
- `rtl/common/c1_r1_unified_output_fifo.sv`：已在 bridge 内以 `ENABLE_UNIFIED_OUTPUT_FIFO` 可选接线的 depth-2、103-bit CNN 结果弹性 FIFO；独立 xsim、同步 error-gate unit、8×8 单帧/两帧和 640×480 elaboration 均通过。组合 error gate 会把 Q→D 拉到 `-6.098 ns`；bridge-local `COMBINATIONAL_ERROR_GATE=0` 后 proxy 为 direct/Q→D `-4.831/-4.702 ns`、增加约 210 LUT/80 LUTRAM，仍无 timing 收益，所以默认关闭；
- `rtl/common/c1_r1_unified_output_skid.sv`：以 `ENABLE_UNIFIED_OUTPUT_SKID` 可选接入同一 bridge seam 的 1-entry、103-bit 完整 payload registered skid；空槽无 fall-through、满态不做同拍替换、stall 保持、abort/error flush 与新 epoch 均已通过 standalone。8×8 单帧/两帧、16×8、640×480 elaboration 均通过；同条件 proxy 为 `46243 LUT/37766 FF/5636 LUTRAM/20 RAMB36/9 RAMB18/84 DSP`、direct/Q→D `-5.415/-5.415 ns`，相对无边界基线为负优化，默认关闭，仅保留协议/时序对照；
- `rtl/top/c1_r1_capture_subsystem.sv`：camera CDC、ISP、silent discard/cleanup 与 capture stream；
  - `rtl/top/c1_r1_display_subsystem.sv`：双源 DDR prefetch、720p、四种 compositor 模式和可选 OSD；
  - `rtl/top/c1_r1_portable_soc.sv`：APB、采集、frame manager、frame-job、真实 CNN/tensor、显示及七客户端 AXI 的厂商无关组合；`ENABLE_TENSOR_WINDOW_CACHE=0` 默认保持 adapter→bridge 直通，置 1 后由 `c1_tensor_window_cache_axi_client` 在 client-6 边界插入 C8 window-cache seam；
  - `rtl/vendor/c1_sapphire_apb_master_adapter.sv`：Soft Sapphire 生成 APB 端口到 Case-1 APB 的地址/方向/PSTRB seam；默认完整字写 `4'hf`、读 strobe 为 `0`，并隔离宽地址越界访问；
  - `rtl/vendor/c1_sapphire_irq_adapter.sv`：单根 Case-1 level IRQ 到 Sapphire 八路 user-interrupt one-hot 选择（PLIC 连接）；
  - `rtl/vendor/`：MIPI/DDR/Sapphire/video 可替换边界；Sapphire APB/IRQ seam 的 detached 回归入口为 `scripts/run_sapphire_apb_adapter_xsim_detached.ps1`。
  - `software/efinity_smoke/`：板卡前 RV32IMC/ELF32/RVC/soft-float Makefile smoke；housekeeping 后当前构建产生的所有对象文件均落在 `build/`，该目录仅为可清理的中间产物，生成 BSP 后替换 startup/linker 并以 `soc.h` 地址为准；`scripts/verify_efinity_toolchain.ps1` 可一键复核本地 Efinity/RISC-V 安装和可选 smoke 构建。

统一结果 FIFO 的板前协议回归可用以下 detached runner；系统集成开关仍默认关闭，
不会改变 portable SoC 默认数据通路：

```powershell
& .\scripts\run_unified_output_fifo_xsim_detached.ps1
```

同步 error-gate 变体（仅作 bridge 生命周期实验）可用：

```powershell
& .\scripts\run_unified_output_fifo_xsim_detached.ps1 `
  -RunId unified_output_fifo_registered_error_gate0_recheck_20260825 `
  -RegisteredErrorFlush
```

1-entry skid 的 standalone 与系统集成回归使用以下 detached runner；系统开关仍默认关闭：

```powershell
& .\scripts\run_unified_output_skid_xsim_detached.ps1 `
  -RunId skid_default_unit_recheck_20260826
& .\scripts\run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 `
  -RunId skid_soc_8x8_recheck_20260826 -Frame 8x8 -UnifiedOutputSkid
```

显示子系统在首次 pair 尚未激活时采用 bootstrap feed，并在 ORIGINAL/STYLED 单源模式下对未选中的 line store 做同步 drain；新 pair 预取期间由 core→pixel hold CDC 暂停消费，且控制器禁止重复启动同一 pending pair；这样两个 reader 都能越过两行 ping-pong 所有权边界，同时仍在像素域帧边界提交显示 pair。

## Python 与软件回归

在 `case1` 目录执行：

```powershell
& .\scripts\run_python_regression.ps1
& .\scripts\run_software_host_test.ps1
```

默认 Python 回归现在包含 **21 个命令**，在 QAT artifact 与 6 图 QAT/整数一致性验证后新增 tensor 性能模型、3×3 line/window cache 模型和 AXI/cache/MAC 吞吐扫描；最终标记为 `C1_PYTHON_REGRESSION_PASS commands=21`，其中性能模型标记为 `C1_TENSOR_PERF_MODEL_TEST_PASS baseline_requests=21388800 baseline_bytes=342220800 candidate_bytes=47547744`，cache 模型标记为 `C1_WINDOW_CACHE_MODEL_TEST_PASS sizes=8x8,16x16,64x48 line_rows=3 8x8_external=408 64x48_external=19584`，吞吐扫描标记为 `C1_THROUGHPUT_SWEEP_TEST_PASS`。软件主机测试标记为 `C1_SOFTWARE_HOST_TEST_PASS registers=76 descriptor=64 framebuffer=16 isp=0x200..0x268 qos=0x108..0x12c`。公开 RAW/ISP 图回归仍覆盖 6 图×4 Bayer，最低/平均 PSNR 为 29.3864/31.7270 dB；该 PSNR 与 QAT 风格画质不是同一指标。
同一回归还执行 burst geometry、读/写 response FIFO、空队列 AR bypass 和
MAC output-restart 的小模型，分别输出 `READ_BURST_PROFILE_TEST_PASS`、
`READ_RSP_POP_REFILL_TEST_PASS`、`WRITE_RSP_POP_REFILL_TEST_PASS`、
`READ_AR_BYPASS_TEST_PASS`、`MAC_OUTPUT_RESTART_TEST_PASS` 与
`MAC_TAG_POP_PUSH_TEST_PASS`；这些是握手/周期
模型，不是 DDR 或 native 15 fps 测量。

吞吐扫描现额外输出 `fabric_outstanding_sweep`：在理想三行 cache+pack2、响应延迟 4 cycle 的模型中，effective outstanding=2 已足以让 memory-only bound 越过 15 fps；这不改变共享 CNN FSM 的计算瓶颈结论。

## 下一阶段板前证据

- `model/tensor_perf_model.py` 把当前顺序 adapter 的请求、总线字节数、读复用、128-bit packing、outstanding 和 MAC 并行度转成可复现的周期下界。当前 baseline 为 21,388,800 个 64-bit 请求、342,220,800 B/frame；一个 `pack_factor=2/read_reuse=9/outstanding=16` 的乐观候选降到 47,547,744 B/frame，但 64 MAC 的纯算术下界仍为 6,691,200 cycle，略超 100 MHz/15 fps 的 6,666,667-cycle 预算。因此该模型是优化验收基线，不是 RTL 性能证明。
- `rtl/dma/c1_tensor_mem_axi128_packer.sv` 是尚未接入 portable SoC 的独立 64→128 packing 原型；detached xsim run `4d4c4edfb483422c9196b7fdc12b8e6a` 得到 100 requests→51 AXI beats、48 packed pairs、49% beat reduction，并覆盖随机 response stall 和 1 个本地错误。随后 detached Vivado proxy synth run `d011df7b1a7a4bd19275769b89a01f94` 通过，使用 412 LUT（264 logic + 148 LUTRAM）、649 FF、0 BRAM、0 DSP，100 MHz 结构时序 WNS=+2.588 ns/TNS=0。该综合是裸模块、无 P&R/IO 约束的 Artix-7 proxy；它只证明 packing/顺序响应契约与可综合性，不代表系统已达到实时吞吐。
- trained artifact ABI run `35f1aa0e76ed41d084f40e6637ac331e` 通过 RTL descriptor decoder 和真实 parameter scheduler 接收全部 22 个训练描述符，完成 1,030 个 128-bit arena 读取/缓存写（逻辑参数 payload 16,379 B，arena image 16,896 B，其中含对齐/填充）。边界明确为 `RTL_DECODER_SCHEDULER_ARENA_ONLY_NATIVE_640x480`：当前 native 描述符在真实 engine 首层参数装载后还需要 640×480 数据平面，尚未声称完整 trained-frame RTL E2E。
- 七客户端 AXI 并发 run `bbaccd1453aa43368eebc4e1f5bdae5a` 在独立 `c1_axi_n_serial_arbiter_128(CLIENTS=7)` 上完成 56 写事务+56 读事务，随机 AW/W/AR/B/R 停顿、最大等待 89/67 cycle，并观察到读写并行。它覆盖共享仲裁公平性和 forward progress，不替代 portable SoC 长帧 capture/display/tensor 全链回归。
- memory seam run `7a447dba98be413d9e36c9f20bee443d` 同时展开 legacy bridge 与 performance packer：legacy 1 response；performance 3 requests→2 AXI beats、1 packed pair、3 responses，并验证锁存式 `flush_req/flush_done` 与 `quiescent`。两种 seam proxy synth run `ca3e6b438d7e471bb39a083fc31746de` 均通过：PERF_MODE=0 为 122 LUT/176 FF/WNS +6.274 ns，PERF_MODE=1 为 413 LUT/651 FF/WNS +2.586 ns（Artix-7 裸模块 proxy）。这仍是接口/可综合性证据，不代表已接入 adapter。
- 独立 3×3 line/window cache 模型在 8×8、16×16、64×48 上分别把 tap 请求 3024→408、12096→1632、145152→19584；按真实 pixel→C8-group 交织顺序、一次 refill 整行所有 group 后，逐 tap 行命中率为 98.7434%、99.3717%、99.8429%。早期 row-tag-only 控制原型 run `8991ff1ef0954d669c3a4568208ae5a2` 及 proxy synth `7ee82460964f4926b9b5030655bd049d` 仍保留为 97 LUT/342 FF/0 BRAM 的控制壳下界。
- 完整 payload 版 `c1_window_line_cache_c8` 已保存三行、每行全部 C8 groups。最终正常 run `2a1766339f834f3b9eba6f0dd5deecd4` 通过 1445 responses/18 refills/288 words；故障/容量/维护 run `3373b871a3734d2ab2ca9607a206face` 通过 9 次配置、3 类 refill fault、2 类 maintenance；最终最大行 run `a3ac690fadf34c8fb123c8043f365cc1` 对 640×1×2 完成 1280-word refill并验证首/中/末和双 group。proxy synth run `d07c3a3c7348474ea465ff73f765707a` 为 288 LUT、203 FF、7.5 BRAM tile、0 DSP，100 MHz WNS/TNS=+1.086/0 ns。独立模块动态测试不含系统 DDR；其后已由 seam 接入可选顶层分支，但仍无 burst 或多个 outstanding。
- 最终加固后 `c1_tensor_window_cache_seam` run `1e6f562adbc34ea383932840b97aa0e4` 完成 17/17 logical req/rsp、5 row refills/40 refill reads、8 bypass reads、2 writes、50 个 downstream transaction，并定向覆盖 1 次 cache 配置拒绝和 1 次路由后 runtime-error fallback。未取得 cache owner 的请求会锁定到安全 direct bypass；已经取得 cache owner 的请求则保持原 owner，不会再发重复 direct request。地址/容量 fallback、coherence、flush、配置计算期间受阻请求的 abort drain、三向回压仍保持通过。adapter/seam 同时加入 stalled payload、stage config、cacheable 分类、WSTRB、对齐和 owner/refill 关系等仿真断言。最终合并 seam+C8 proxy synth run `6dc7d474aff34448ba590ff615927a53` 为 1,236 LUT、792 FF、7.5 BRAM tile、0 DSP，100 MHz WNS/TNS=+1.086/0 ns；相对历史基线 `209b68d9b8c9429ba659d32b399a0911` 的 1,234 LUT/787 FF 仅增加 2 LUT/5 FF。
- adapter 默认兼容 run `5cc1f6d0fcd242bf9de7fe48c5418270` 保持 2,230 requests/1,810 reads/420 writes；sideband run `513714c5626b47e99bc730cf7d3fdf9f` 通过 22 次 stage config、44 个 config stall、1,512 个 cacheable read 和 266 个 bypass read。历史 trace `61ac723d36b043d9b24272914e50856e` 的 407/2,229（18.2593%）pairable 邻接只说明 packer 不能直接替换当前单 outstanding bridge。
- 最终真实 adapter→window-cache seam→C8 cache→单 outstanding 64-bit memory BFM 动态 run `9212d5a042ae4d9895a3162869e3815f` 保留原 22-stage bit-exact scoreboard，并完成 2,230/2,230 logical req/rsp。1,810 个逻辑读中 1,512 个为 cacheable，观察到 1,493 hit、19 miss、19 次整行 refill/204 words；下游为 298 个旁路读+204 个 refill read=502 个读，较逻辑读减少 72.3%，另有 420 个写。1×1/upsample/residual、请求/响应延迟、1 次 memory error 和 5-cycle abort drain 均通过，两枚 PASS 各唯一一次，三阶段 stderr 为空。
- 最终真实 adapter→seam→C8→`c1_tensor_mem_axi128_bridge`→严格 AXI128 BFM 动态 run `be4977424d9d484e80340f970d9904d0` 进一步完成 502/502 AR/R 与 420/420/420 AW/W/B；上下 64-bit lane 为 462/460，AW-first/W-first/同拍为 318/81/21。AR/AW/W stall 为 1577/1583/1580，R/B latency gap 为 1194/915，定向 B hold 为 2，memory error 为 1，abort drain 为 5；请求守恒与 `502 = 298 bypass + 204 refill` 同时成立。至此组件级 64-bit 链和真实单拍 AXI 链都已完成；长帧、burst、多 outstanding 或 native 640×480 仍未闭合。
- 独立小帧 cache-client/DDR-fabric run `75ac975f5ec049a6b579e00c14dd41d0` 已通过显式 `c1_tensor_window_cache_axi_client(ENABLE_CACHE=1)` 把真实 `c1_tensor_window_cache_seam→c1_tensor_mem_axi128_bridge` 接入第 7 客户端，并与 6 个合成读写客户端共同穿过真实 7-client arbiter。4×4×C8 cache 完成 9 个逻辑读、16 个下游 refill 读、旁路读写/flush 和上半 lane 回读；DDR BFM 完成 `AW/W/B=19/19/19`、`AR/R=36/36`，AW/W/AR stalls `15/4/14`、R/B stalls `121/149`、R/B gaps `175/81`，marker 和三阶段 stderr 均通过。该专项是独立 fabric 压力基线；顶层 8×8 全链证据见下一条。
- seam 已由 `ENABLE_TENSOR_WINDOW_CACHE` 可选插入 portable SoC。补入 `tensor_cache_busy` 软件 quiescence fence 后，默认旁路 smoke `7e76332ea7044371af9efcf39809258a` 与最终 enabled wiring smoke `30658446f3d4442fb7f7a442bd5f9fe2` 均通过；后者确认最终 route-lock/断言源码下的 seam 实例、reset/CSR、空闲 `cache_error=0`/`quiescent=1`、无虚假 AXI，并定向证明 cache busy 会拉高 `system_busy`（`fence=1`）。顶层 `flush_req` 暂绑 0；动态 stage/refill、显示启动和两帧 ownership 由当前源码 shape-scaled gate 矩阵覆盖。
- 新增显式 `c1_tensor_window_cache_axi_client` 边界：封装 optional window-cache seam 与 64→AXI128 bridge，`c1_r1_portable_soc` 用符号索引 `AXI_CLIENT_TENSOR_CACHE=6` 接入七客户端 fabric；`ENABLE_CACHE=0` 保持原 wire-level bypass。独立 WMI 回归 `54d6d7ec0b28445f8f80edeb67281c72` 在真实 client-6→`c1_axi_n_serial_arbiter_128`→AXI BFM 上通过 `C1_TENSOR_CACHE_AXI_CLIENT6_PASS client=6 refill_ar=4 direct_ar=1 writes=1 responses=6`，xvlog/xelab/xsim stderr 均为空；顶层全链小帧证据见下条的 latest gate 矩阵。
- 完整 portable SoC 小帧动态 run 已覆盖四个层次：8×8 单帧 `c1_8x8_gate_20260825` 的 `AW/W/B=852/868/852`、`AR/R=1119/2199`；16×8 两帧 `c1_16x8_two_gate_20260825` 的 `done=2 descriptors=44 swaps=2 drops=0`、`AW/W/B=3376/3472/3376`、`AR/R=4185/5463`；64×48 单帧 `c1_64x48_single_gate_20260825` 的 `done=1 swaps=1 drops=0`、`AW/W/B=40224/41664/40224`、`AR/R=48427/51643`；64×48 两帧 `c1_64x48_two_gate_20260825` 的 `done=2 descriptors=44 swaps=2 drops=0`、`AW/W/B=80448/83328/80448`、`AR/R=96793/102295`。这些 run 将 capture、frame DMA、真实 CNN、tensor cache、共享仲裁、输出写回和显示启动串成板卡无关证据，但仍是小帧、单拍/单 outstanding，不证明 640×480@15 fps。

对应的 detached runner（均由 WMI worker 启动）为：

```powershell
& .\scripts\run_tensor_mem_axi128_packer_xsim_detached.ps1
& .\scripts\run_tensor_perf_proxy_synth_detached.ps1
& .\scripts\run_tensor_mem_path_seam_xsim_detached.ps1
& .\scripts\run_tensor_mem_path_seam_proxy_synth_detached.ps1
& .\scripts\run_r1_microstyle_artifact_abi_xsim_detached.ps1
& .\scripts\run_r1_microstyle_tensor_adapter_xsim_detached.ps1
& .\scripts\run_r1_microstyle_tensor_adapter_xsim_detached.ps1 -CacheSideband
& .\scripts\run_axi7_serial_arbiter_stress_xsim_detached.ps1
& .\scripts\run_window_cache_model.ps1
& .\scripts\run_window_line_cache_ctrl_xsim_detached.ps1
& .\scripts\run_window_line_cache_ctrl_proxy_synth_detached.ps1
& .\scripts\run_window_line_cache_c8_xsim_detached.ps1
& .\scripts\run_window_line_cache_c8_faults_xsim_detached.ps1
& .\scripts\run_window_line_cache_c8_maxrow_xsim_detached.ps1
& .\scripts\run_window_line_cache_c8_proxy_synth_detached.ps1
& .\scripts\run_tensor_window_cache_seam_xsim_detached.ps1
& .\scripts\run_tensor_window_cache_seam_proxy_synth_detached.ps1
& .\scripts\run_r1_adapter_window_cache_dynamic_xsim_detached.ps1
& .\scripts\run_r1_adapter_window_cache_axi_dynamic_xsim_detached.ps1
& .\scripts\run_portable_soc_cache_wiring_smoke_xsim_detached.ps1
& .\scripts\run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1
& .\scripts\run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -Frame 8x8 -TrainedArtifact
& .\scripts\run_r1_native_display_prefetch_xsim_detached.ps1
& .\scripts\run_r1_native_capture_writer_xsim_detached.ps1
& .\scripts\run_r1_native_capture_table_xsim_detached.ps1
& .\scripts\run_r1_native_input_dma_xsim_detached.ps1
& .\scripts\run_r1_native_dma_loopback_xsim_detached.ps1
& .\scripts\run_r1_native_boardless_job_xsim_detached.ps1
& .\scripts\run_r1_native_boardless_fabric_xsim_detached.ps1
& .\scripts\run_tensor_cache_axi_client6_xsim_detached.ps1
& .\scripts\run_cache_fabric_ddr_bfm_xsim_detached.ps1
```

## Vivado/xsim 回归

runner 通过 WMI 创建隐藏 worker，使 Vivado/xsim 不属于当前 Codex shell 的 Windows Job。每个 run 使用独立目录并要求工具退出码为 0、stderr 为空、日志无 Fatal/Error/FAIL、专属 PASS 唯一出现：

窗口缓存 proxy synth 额外使用 `case1/.vivado_rt/` 中的普通文件属性 runtime Tcl staging，避免本机 Vivado 安装目录的云占位属性使 detached helper 偶发读文件失败；它只复制工具脚本数据，不改变 RTL 或器件数据库。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\scripts\run_xsim_detached.ps1
Get-Content -Raw .\logs\xsim_status.json
```

当前收口证据包括：控制最新专项 `595748663d3541248c8ef4c1c46b1fd3`（指定历史快照 `14817510235e4da8882511ec46606626` 同样 PASS）、capture `11e14099eb784ccba3b6397650a80278`、display `aaf5846df1a84216aa88515a82b2eda8`（bootstrap/drain 修复后）、display prefetch/CDC `3bf346fd0896450681875829c29ff0e9`、tensor adapter 默认/sideband `5cc1f6d0fcd242bf9de7fe48c5418270`/`513714c5626b47e99bc730cf7d3fdf9f`、最终加固 seam `1e6f562adbc34ea383932840b97aa0e4`、adapter/cache 64-bit 动态链 `9212d5a042ae4d9895a3162869e3815f`、真实 AXI 动态链 `be4977424d9d484e80340f970d9904d0`、tensor bridge 专项 `b587aa890cc04165bd5a88ce76868087`，以及当前源码 shape-scaled portable SoC 门控矩阵 `c1_8x8_gate_20260825`、`c1_16x8_two_gate_20260825`、`c1_64x48_single_gate_20260825`、`c1_64x48_two_gate_20260825`。四个 run 均严格 PASS、stderr 为空；native 640×480 的最终 compile/elaboration `c1_640x480_final_elab_20260825`、独立显示/DDR 预检 `native_prefetch_run2_20260825`、三 slot capture-writer 预检 `c1_native_capture_writer_final_20260825`、真实 capture/table/ISP 预检 `c1_native_capture_table_paced_full_20260825` 和两主机 input-DMA/arbiter 预检 `c1_native_input_dma_full_20260825` 也通过，后者完成 `frame_pixels=921600`、table/frame `AR/R=3/3` 与 `14400/230400`、shared `AR/R=14403/230403`；这些仍不等于完整 native CNN/QoS/15 fps。覆盖等级与复现路径见 `TEST_RESULTS.md`、`NATIVE_DISPLAY_PREFLIGHT.md`、`NATIVE_CAPTURE_WRITER_PREFLIGHT.md`、`NATIVE_CAPTURE_TABLE_PREFLIGHT.md`、`NATIVE_INPUT_DMA_PREFLIGHT.md`。

本阶段在上述 input-DMA 之后新增 `c1_native_dma_loopback_final2_20260825`：真实 read-side、XRGB writer、`c1_axi_write_skid_bridge`、write-side serial arbiter 与 associative DDR 回读完成三帧 `frame_pixels=921600`，input `AR/R=14400/230400`，output `AW/W/B=14400/230400/14400`；写侧仲裁器改动后的 `c1_native_input_dma_after_arbiter_20260825` 也重新通过。该 loopback 仍是 native DMA 集成门，不是 portable SoC/CNN/QoS/15 fps 结论。细节见 `NATIVE_DMA_LOOPBACK_PREFLIGHT.md`。

紧接着的 `native_boardless_job_hold_full_20260825` 已把真实 `c1_r1_boardless_frame_system` 接回 native table/22 descriptor/input-output DMA 和外部 CNN echo：`stages=22`、`cnn_in/cnn_out=307200/307200`、`input AR/R=4800/76800`、`output AW/W/B=4800/76800/4800`，并完成 output associative DDR 逐像素回读；这是 boardless job 集成证据，下一步才是 portable SoC 七客户端并发。

boardless TB 的最终 canonical run 是上面的 `native_boardless_job_hold_full_20260825`：外部 CNN echo 的 VALID 在 READY 前保持稳定；较早的 `c1_native_boardless_job_full_20260825` 仍是同一结构的初步 PASS，但文档指标以 hold-compliant run 为准。

`native_fabric_full2_20260825` 已将该 canonical job 放入真实七客户端仲裁器的
client-0，并以六个 synthetic peer 通过随机背压/延迟竞争；这一步完成的是
fabric forward-progress 预检，不是 portable SoC 七个真实 client 的并发 signoff。

随后新增的 `native_fabric_full2_20260825` 将同一个 640×480 boardless job 接到真实 `c1_axi_n_serial_arbiter_128(CLIENTS=7)` 的 client-0，并让 client-1..6 各完成 3 个四拍写入/读回事务。主 marker 记录 synthetic client `AW/W/B/AR/R=18/72/18/18/72`、job `AW/W/B/AR=4800/76800/4800/4800`、输入 `R=76800`、输出 `307200` 像素，最大 synthetic client 等待 `118` cycles；这一步是 native fabric/公平性预检，不是 portable SoC 七个真实客户同时运行的 signoff。

下一切片 `native_fabric_param_full_20260825` 已把 client-1 换成真实
`c1_axi_parameter_loader` + `c1_r1_parameter_bank`，完整读取/提交 16,896 B
arena（`AR/R=66/1056`、`generation=1`），其余五个 peer 与 640×480 job 同时
前进；三阶段 exit 0、stderr 为空。它仍只替换了一个真实 leaf，不等于七个
portable SoC 真实 client 并发。

同时，新的 portable SoC 内部 client monitor 首次 64×48 run
`portable_client_gate_64x48_20260825` 观察到所有架构方向均有事务，但 client-5
styled-display reader 的单次连续 AR 等待达到 `1,243,738` cycles，超过一百万
cycle guard，因而该 run 正确记为诊断 FAIL；follow-up 确认 client-4 的
`RVALID&&!RREADY` hold 为 `1,243,662` cycles。随后 protocol-safe display
response FIFO 单帧 run `portable_display_fifo_reader_gate_full_64x48_20260825`
把 c4/c5 wait 降到 `76/83`、response hold 降到 `2/2`，credit-only 8×8 两帧
再验证 `swaps=2 drops=0`。最新 tagged QoS 两帧回归
`native_qos_fifo_tagged_64x48_twoframe_v2` 也完成 `done=2 swaps=2 drops=0`，
并通过 APB `0x108..0x12c` 逐字段读回；其 `underflow=3` 是缩小 SoC 图像仍使用
固定 720p/640×480 请求窗造成的尺度回归伪影，不代表 native 画面质量，native
640×480 display-only FIFO 预检仍为 `underflow=0/0`。默认 bypass 的功能回归仍
PASS，默认 monitor/FIFO 仍保持可选；详见 `PORTABLE_SOC_AXI_CLIENT_MONITOR.md`
和 `DISPLAY_RESPONSE_FIFO_QOS_PREFLIGHT.md`。

## 代理综合与未完成边界

Vivado/Artix-7 代理只用于检查可综合性、RAM 推断和组合深度，不能换算成 Ti60 签核。最新 14 组件代理 run `4fdb28345b6b4b2c8342357e2e0d82ec` 中，含 DMA 的 boardless top 与 Resize 的 100 MHz 综合后 WNS 分别改善到 `-0.191 ns`、`-0.154 ns`；最终 DW 专项 run `ba43851ef5a24071bad06edeb2460c7c` 为 `+3.039 ns`。最终重排版完整 CNN proxy run `6cb8dfd59ed5473383eed87f52b2a013` 严格 PASS、stderr 为空，使用 28,298 LUT（25,542 logic + 2,756 LUTRAM）、11,168 FF、2 BRAM36、35 DSP、32 个 F7 和 8 个 F8；但 `WNS/TNS=-4.965/-2511.307 ns`，100 MHz 明确未闭合。最差路径已经从旧 window→dot overflow 转为 `replay_index`→descriptor decoder error reset（14 级、14.351 ns），首条计算路径仍约 `-4.601 ns`。

完整 CNN 旧 flat-cache run `50e2f738693246b2a2f05191bb10a4f7` 只完成 `synth_design`（0 error）并生成 utilization，随后因 735,256 Slice LUT（Artix-7 容量的 546.25%）和巨量 F7/F8 mux 已明确不可实现而被手动终止；没有 timing report 或最终 PASS。其 status 可能残留 `running`，不得写成“综合通过”。当前重排版相对该历史失败基线的 LUT 下降约 96.15%，说明结构重构有效，但负 WNS、Ti60 映射和实时性能仍未闭合。

达到 640×480@15 fps 仍需在已完成的 8×8/16×8/64×48 小帧全链回归和 display FIFO 单帧/两帧 preflight 基础上，完成 native 640×480 portable-SoC 长帧的请求/周期/QoS/underflow/deadline 测量，并实现 AXI burst/packing、多 outstanding、MAC/通道并行以及据实重定 watchdog/cycle budget。之后还必须用 Efinity 做 Ti60 实际映射，并在实体板完成 MIPI、DDR、显示、CDC、功耗和长时间稳定性验证。

### 最新 15 fps 吞吐 seam（2026-08-27）

已新增可选 `c1_tensor_mem_axi128_write_parallel_fabric`（双写 leaf、连续
block 分发、tag FIFO 保序）并完成读写 response-ready 时序解耦。小型 xsim
验证了 `max_outstanding=2`、pack2、AW/W/B stall/hold、错误传播和孤立 B
containment；Artix-7 100 MHz proxy 为 read fabric `31,905 LUT/10,075 FF/
WNS +1.928 ns`，双 lane write fabric `4,308 LUT/10,091 FF/WNS +1.203 ns`。
这些是板卡前的可复用 seam，默认 SoC 尚未接入；读 response arrays 的 0 BRAM
仍需 Efinity/EBR 对照，且默认 64-bit logical writer 仍是
`MAX_OUTSTANDING=1`（burst-level MLP 另见下方可选 seam）。复现命令和
限制见 `15FPS_THROUGHPUT_PHASE.md`、`TEST_RESULTS.md`。

本阶段随后增加两项可选优化：

- 读 leaf `RSP_FIFO_BEAT_MODE=1` 将一个 AXI128 beat 保存为单条记录，再按
  lane 顺序输出 64-bit 响应；同参数 Artix proxy 为 `1714 LUT/1182 FF/+1.380 ns`，
  对照 logical-entry 为 `12045/5378/+1.046 ns`。它不减少 AXI 流量，当前
  fabric/cache 仍保持默认关闭，需先做 Efinity EBR/长帧验证。
- `c1_dot8x8_requant_pingpong` 以两个 bank 轮转隐藏 inter-pixel latency；6
  事务 xsim 保持顺序且 `max_inflight=2`，full-tree proxy 为
  `31165 LUT/22833 FF/64 DSP/WNS +1.247 ns`（同脚本可选 output-restart 为
  `31163 LUT/WNS +1.247 ns`）。这不是完整 stage scheduler，
  不能单独解释为 15 fps 已达成。
- 新增可选 `c1_axi128_write_mlp` burst-level seam：descriptor payload 先入槽，
  AW 可预排，W/B 仍按 descriptor 顺序返回。xsim 为
  `desc=6/aw=3/w=12/b=3/max_out=3`，Artix proxy 为
  `5882 LUT/10308 FF/0 BRAM/0 DSP/WNS +3.249 ns`。新的
  `c1_tensor_mem_axi128_write_mlp_adapter` 已将 64-bit logical pack2 接到该
  backend：小配置 xsim `desc=5/req=26/rsp=26/aw=4/beats=12/packed=13/errors=2/
  max_out=4`，`MAX_BEATS=16` proxy 为 `15961 LUT/27771 FF/0 BRAM/0 DSP/WNS
  +2.551 ns`；两者仍未接默认 SoC，不能直接当作整帧带宽结果。
- 新增可选 `c1_tensor_mem_axi128_write_mlp_fabric_2c`，把 logical adapter
  和 raw AXI128 peer 接入同一 ID-less write arbiter，用来验证跨 client 的
  AW 预排、W/B 有序和响应反压；xsim `aw=4/w=7/b=4/adapter_rsp=8/
  peer_b=2/max_inflight=4/packed=4`，Artix proxy `16291 LUT/28296 FF/WNS
  +2.197 ns`；它仍是板卡前 seam，不改变 legacy top。
- write parallel fabric 另有四 lane A/B：四个单 outstanding leaf 按 block
  轮转，xsim 为 `req=32/aw=8/beats=16/packed=16/errors=4/max_outstanding=4`，
  Artix proxy 为 `9858 LUT/20168 FF/0 BRAM/0 DSP/WNS +2.166 ns`。这是横向
  并行度实验，不等价于单 writer AXI-ID/乱序 B，也未接入默认 SoC。
- ping-pong 另有可选四-bank A/B：12 事务 xsim 为
  `max_inflight=4/first_overlap=8/cycles=47`，full-tree proxy 为
  `59912 LUT/45674 FF/128 DSP/WNS +0.337 ns`。四-bank只用于评估并行度上限，
  资源及时序余量不足以替代默认二-bank配置，也尚未接入真实 stage scheduler。
- 当前 engine 又增加两个默认关闭的吞吐开关：`MAC_PREFETCH_OVERLAP` 在
  Conv/1x1 beat 接收边沿捕获下一 tile，`CACHE_DW_WEIGHT_TILES` 在同一阶段
  缓存 DW 的 9-tap 权重。小型 22-stage xsim 首轮 cycles 为 baseline/cache/
  overlap/cache+overlap=`30570/28553/29192/27174`，输出计数和 fault/abort
  检查均保持一致；native 模型计算上界约为 `2.527/3.328/3.201/4.605 fps`
  （cache 与 overlap 组合取 4.605）。DW cache 的 full-top Artix proxy 为
  `36413 LUT/14889 FF/2 BRAM/35 DSP/WNS -4.959 ns`（tap-bank×64-bit
  RAM-friendly layout + MAC overlap），因此目前只作为实验 seam，仍需
  Efinity EBR/同步读和时序验证后再决定是否启用。
- `c1_tensor_mem_axi128_read_fabric_2c` 现在可通过
  `LEAF_RSP_FIFO_BEAT_MODE` 将 beat-record 选项转发到两个 leaf；集成 xsim
  仍为 `16→6 AR/8 R beats/max_inflight=5`，对应 proxy 为
  `2194 LUT/1630 FF/WNS +1.815 ns`（beat leaf RSP16；logical RSP64 对照
  `31905/10075/+1.928 ns`）。
  默认 top 仍关闭该选项，需经过 Efinity/EBR 与 native 长帧 gate。
- 同一选项已沿 cache burst shell 转发，独立 refill/tap 回归在 beat mode 下
  保持 `taps=6/refills=5/words=80/bursts=10/beats=40/max_outstanding=2`；
  这只证明逻辑供数接口兼容，不代表板上 EBR/帧率已闭合。

新增回归入口见 `scripts/run_tensor_mem_axi128_read_burst_client_beatfifo_xsim_detached.ps1`、
`scripts/run_tensor_mem_axi128_read_burst_client_beatfifo_proxy_synth_detached.ps1`、
`scripts/run_tensor_mem_axi128_read_burst_client_logical_proxy_synth_detached.ps1` 和
`scripts/run_tensor_mem_axi128_read_fabric_2c_beatfifo_xsim_detached.ps1`、
`scripts/run_tensor_mem_axi128_read_fabric_2c_beatfifo_proxy_synth_detached.ps1`、
`scripts/run_window_line_cache_c8_burst_shell_beatfifo_xsim_detached.ps1` 以及
`scripts/run_dot8x8_requant_pingpong_proxy_synth_detached.ps1`、
`scripts/run_axi128_write_mlp_xsim_detached.ps1`、
`scripts/run_axi128_write_mlp_proxy_synth_detached.ps1`、
`scripts/run_tensor_mem_axi128_write_mlp_adapter_xsim_detached.ps1`、
`scripts/run_tensor_mem_axi128_write_mlp_adapter_proxy_synth_detached.ps1`、
`scripts/run_tensor_mem_axi128_write_mlp_fabric_2c_xsim_detached.ps1`、
`scripts/run_tensor_mem_axi128_write_mlp_fabric_2c_proxy_synth_detached.ps1`、
`scripts/run_tensor_mem_axi128_write_parallel_fabric_lanes4_xsim_detached.ps1`、
`scripts/run_tensor_mem_axi128_write_parallel_fabric_lanes4_proxy_synth_detached.ps1`、
`scripts/run_dot8x8_requant_pingpong_banks4_xsim_detached.ps1` 和
`scripts/run_dot8x8_requant_pingpong_banks4_proxy_synth_detached.ps1`；它们均用 WMI
脱离当前 Windows Job，并在结束时删除私有 Vivado/xsim 工程。

engine A/B 入口为 `scripts/run_r1_microstyle_engine_dwcache_xsim_detached.ps1`
（默认 cache=1；`-DisableCache` 关闭，`-OverlapMac` 打开），full-top DW cache
proxy 为 `scripts/run_microstyle_cnn_top_dwcache_proxy_synth_detached.ps1`。

本阶段新增的边界优化入口：

- `scripts/run_tensor_mem_axi128_read_burst_client_xsim_detached.ps1
  -ReqPopRefill`：读请求 FIFO 满槽同拍 pop/refill；
- `scripts/run_tensor_mem_axi128_read_burst_profile_xsim_detached.ps1`：读 leaf
  `BURST_BEATS=16` 与 `-Burst32` 的紧凑 A/B（189 logical requests、94 AXI
  beats），同时检查 pack2、4-KiB split、R 顺序和多 outstanding；两组 marker
  的 AR 数为 `9→7`，payload/响应顺序不变，均为 `397` 个 BFM 周期。该
  profile 不改 default SoC，且周期不是 native fps 证据；详细数据见
  [`READ_LONG_BURST_PROFILE.md`](READ_LONG_BURST_PROFILE.md)。
- `scripts/run_axi_n_read_burst_arbiter_xsim_detached.ps1 -EmptyArBypass`：
  空 descriptor ring 的首个 AR 直通；
- `scripts/run_tensor_mem_axi128_read_fabric_2c_xsim_detached.ps1
  -EmptyArBypass`：上述 AR 直通的两客户端传播回归；
- `scripts/run_dot8x8_requant_pingpong_xsim_detached.ps1 -OutputRestart`：
  MAC 结果退休同拍复用 bank；可与 `-FirstBeat` 组合。
- `scripts/run_dot8x8_requant_pingpong_xsim_detached.ps1 -TagPopPush
  -OutputRestart`：在 `TAG_FIFO_DEPTH=BANKS` 的满槽边界允许同周期
  pop+push；4-bank 对照可用 `run_dot8x8_requant_pingpong_banks4_xsim_detached.ps1`
  的同名开关。2-bank×2-lane 小 TB 为 `52→48 cycles`、
  `full_tag_pop_push=0→6`；4-bank×2-lane 为 `59→57 cycles`。该选项默认关闭，
  只消除窄边界气泡，不增加 DSP 或证明 15 fps。

读 AR 直通与 MAC 同拍重启的确切 A/B marker 见
`READ_AR_EMPTY_BYPASS_OPTIMIZATION.md`、`MAC_OUTPUT_RESTART_OPTIMIZATION.md`。
满 TAG FIFO 设计和模型见 `MAC_TAG_POP_PUSH_OPTIMIZATION.md`；A/B 汇总在
`model/axi_burst_proxy_summary.json`。这些选项均默认关闭，只削减边界 bubble，
不能替代 native 长帧 QoS/EBR/时序验证。

同一 `ALLOW_OUTPUT_RESTART=1` 的 2-bank×2-lane Artix-7 proxy 切换
`ALLOW_TAG_POP_PUSH` 时为 `31163 LUT/22833 FF/64 DSP/WNS +1.247 ns` 与
`31159/22833/64/+1.845 ns`（TNS=0）；该小 proxy 仅作结构观察，WNS 差异
不应视为确定性时序收益。

写侧 request FIFO 边界优化入口：

- `scripts/run_tensor_mem_axi128_write_burst_client_xsim_detached.ps1
  -ReqPopRefillBaseline`：保守 ready 基线；
- 同 runner `-ReqPopRefill`：满 FIFO 时允许 builder 同拍 pop/refill。

两种模式都使用独立小型 TB；确切 marker、模型和启用前时序注意事项见
`WRITE_REQ_POP_REFILL_OPTIMIZATION.md`。参数默认关闭，并已透传到可选
`c1_tensor_mem_axi128_write_parallel_fabric`。

并行 fabric 的透传回归入口为
`scripts/run_tensor_mem_axi128_write_parallel_fabric_xsim_detached.ps1
-ReqPopRefill`；该开关只验证参数传播与 traffic 不变，不代表默认 SoC 已启用。

cache burst shell 还支持
`scripts/run_window_line_cache_c8_burst_shell_xsim_detached.ps1 -RspPopRefill`；
可与 `-LongBurst -BeatFifo -TailFlush -ReqPopRefill` 组合做板前协议 smoke。
组合结果为 `640 words/20 bursts/320 beats/max_outstanding=4/tail_flush=5/
rsp_pop_refill=1/req_pop_refill=1/cycles=1883`。该开关默认关闭，read-leaf
专用 A/B 才是满 response FIFO 同拍 pop/refill 的覆盖证据，组合周期不等于
native 15 fps。

本阶段还完成了真实 tensor client 接入审计，见
[`TENSOR_CLIENT_INTEGRATION_AUDIT.md`](TENSOR_CLIENT_INTEGRATION_AUDIT.md)。当前
adapter/cache 仍是单 logical outstanding，read burst shell 只覆盖 cache 行
refill，write MLP 需要显式 descriptor/payload/flush 边界；因此没有把这些 seam
直接替换到默认 client-6。native `640×480` compile-only gate 已通过 detached
WMI worker，runner 通过私有 `xvlog -f` 源文件清单并自动删除 runRoot；此结果只
证明编译/展开可行，不是端到端 CNN、DDR QoS 或 15 fps 结论。

最大冻结行的板前门控也已加入：
`run_window_line_cache_c8_burst_shell_xsim_detached.ps1 -MaxRow` 使用
`W=640/H=1/G=2`、1280 logical words、32-beat、四 outstanding，实测
`refills=1/bursts=20/beats=640/packed=640/ar=20/page_splits=2/
max_outstanding=4/cycles=1636`。该数字只用于确认最大行的地址、pack2、
跨页和 cache 命中合同，不能当作 640×480@15 fps；默认 SoC 仍不切换。

只读 cache-refill 调度 seam 已独立实现于
[`CACHE_REFILL_SCHEDULER.md`](CACHE_REFILL_SCHEDULER.md)：命令 FIFO、
`MAX_OUTSTANDING` credit、注册 pending request hold、`leaf_req_flush` 关单和
epoch/stale-response drain 均已覆盖；默认 SoC 接线保持不变。紧凑 detached xsim
marker 为 `C1_CACHE_REFILL_SCHEDULER_PASS`（stale_drop=1、orphan=1、
max_outstanding=2、abort_done=1、flush_done=1）。

当前阶段又新增了可复用的
`rtl/dma/c1_cache_refill_scheduler_read_client.sv` 及其
`scripts/run_cache_refill_scheduler_read_client_wrapper_xsim_detached.ps1`。
wrapper 将 scheduler logical-word credit（`SCHED_MAX_OUTSTANDING=16`）与
AXI burst descriptor credit（`READER_MAX_OUTSTANDING=4`）分开，并导出
`drain_word_*` 与 reader 性能计数器。最新 boardless marker 为：

```text
C1_CACHE_REFILL_SCHEDULER_FENCE_STALL_PASS req=2 rsp=2 words=2 flush_done=2 epoch=2 cycles=31
C1_CACHE_REFILL_SCHEDULER_DRAIN_PASS req=2 rsp=2 drain=2 stale=2 max_outstanding=2 epoch=1 flush=1 cycles=23
C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_PASS commands=2 words=25 req=25 rsp=25 ar=13 axi_beats=13 max_outstanding=2 flush=1 cycles=156
C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_WRAPPER_PASS words=3 bursts=1 beats=2 cycles=18
```

`drain_word_*` 只排出已被 leaf 接受的 stale 请求；line-cache 要求的未发出
word suffix 现在由独立 exact-count cancellation/completion adapter 处理，
并已接入真实 line-cache optional shell；它仍未接入 default SoC。因而该
wrapper 仍是板前协议层，不代表 default SoC 已启用，也不代表 15 fps。

当前已把该缺口实现为可复用的 exact-count 组合：

- [`rtl/dma/c1_cache_refill_completion_adapter.sv`](rtl/dma/c1_cache_refill_completion_adapter.sv)：合并 normal/drain，取消后补 zero/error suffix；
- [`rtl/dma/c1_cache_refill_scheduler_read_client_exact.sv`](rtl/dma/c1_cache_refill_scheduler_read_client_exact.sv)：scheduler + AXI128 reader + completion adapter；
- `scripts/run_cache_refill_scheduler_read_client_exact_xsim_detached.ps1`：端到端 boardless xsim；
- `scripts/run_cache_refill_scheduler_read_client_exact_proxy_synth_detached.ps1`：wrapper-only Vivado 资源/时序代理。

最新紧凑回归 marker：

```text
C1_CACHE_REFILL_COMPLETION_ADAPTER_PASS words=5 drained=2 synthetic=3 req=2 rsp=2 flush=1 cycles=23
C1_CACHE_REFILL_COMPLETION_ADAPTER_NORMAL_PASS normal=5 synthetic=2 done=4 error_done=2 req=5 rsp=5 cycles=46
C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_EXACT_PASS words=5 drained=2 synthetic=3 req=2 rsp=2 ar=1 beats=1 flush=1 cycles=25
```

normal gate 在第一行最终词后立即保持下一条 command，覆盖 late `cmd_done`
竞态。适配器的 `refill_done` 必须等待 exact count 与 scheduler terminal
token 同时收口；`word_count=0` 只会产生错误 completion，line-cache 接线须
保证 count 非零。proxy 资源为 `35435 LUT / 11743 FF / 0 BRAM / 0 DSP /
WNS +0.799 ns`（Artix-7、100 MHz），仅作板前边界参考；default SoC、读写
owner mux 和 15-fps 结论均未改变。

真实 line-cache 接线现已形成独立 optional shell（默认 SoC 仍不实例化）：

- [`rtl/dma/c1_window_line_cache_c8_exact_burst_shell.sv`](rtl/dma/c1_window_line_cache_c8_exact_burst_shell.sv)：真实 3-row C8 cache + row-specific base/8-byte stride + epoch command hold + exact refill；
- `scripts/run_window_line_cache_c8_exact_burst_shell_xsim_detached.ps1`：正常行、flush drain、synthetic suffix 和新 epoch 恢复；
- `scripts/run_window_line_cache_c8_exact_burst_shell_proxy_synth_detached.ps1`：真实 cache RAM + read-only exact seam 的 compact proxy。

```text
C1_WINDOW_LINE_CACHE_C8_EXACT_BURST_SHELL_PASS responses=4 refills=3 words=24 ar=5 beats=10 flush=1 epoch=1 cancel_req=3 cancel_source=3 cancel_drain=3 cancel_synthetic=5 cancel_unified=8 cycles=143
```

默认 `REFILL_SKID_DEPTH=2` 保存 data/error/last/row/index/epoch，并使输入 ready
只依赖注册 occupancy。100 MHz Artix-7 proxy 从无 skid 的
`35543 LUT / 11923 FF / 7.5 BRAM / WNS -1.622 ns` 收敛到
`35639 LUT / 11930 FF / 7.5 BRAM / WNS +0.302 ns / TNS 0`。这仍不是
Ti60/Efinity 或 15-fps 签核；shared read/write owner+epoch mux、真实 DDR QoS、
native 长帧和并行 MAC 供数仍待完成。flush/abort 后外部必须最终恢复已接受
AR/R 的服务，否则 drain 会按协议持续反压。

共享 owner/epoch 的可选 integration shell 现已具备：
`rtl/dma/c1_axi_shared_owner_epoch_arbiter_128.sv` 在真实
`c1_axi_n_serial_arbiter_128` 前执行当前 owner 保持 gate，并与
`c1_axi_shared_owner_epoch_fence` 联动。focused xsim marker 为
`C1_AXI_SHARED_OWNER_EPOCH_ARBITER_PASS ar=1 r=1 aw=1 b=1 epoch=2 cycles=23`；
7-client、`READ_RESPONSE_SKID=1` 的 100 MHz Artix-7 proxy 为
`1411 LUT / 407 FF / 0 BRAM / 0 DSP / WNS +2.144 ns`。这是默认 SoC 之外的
板前协议/资源参考，仍不代表 native 长帧 QoS 或 15 fps 签核。

对应 detached runner 为
`scripts/run_axi_shared_owner_epoch_arbiter_128_xsim_detached.ps1`（可用
`-ReadSkid 1`）和 `scripts/run_axi_shared_owner_epoch_arbiter_128_proxy_synth_detached.ps1`
（可用 `-Clients 7 -ReadSkid 1`）。所有 xsim/Vivado 私有 runRoot 在 worker
结束时删除；完整 cache-enabled SoC wiring smoke 仍通过
`C1_R1_PORTABLE_SOC_CACHE_WIRING_SMOKE_PASS`，但该 smoke 只证明旧 default
fabric 的兼容性，不表示 owner/epoch shell 已接入默认路径。

### 默认关闭的 native QoS 观测边界（2026-08-28）

新增 `rtl/dma/c1_axi_shared_qos_monitor.sv`，并以
`ENABLE_SHARED_QOS_MONITOR=0`（默认）接入 `c1_r1_portable_soc`。它只观察七个
AXI client 的 AW/AR wait、W/R/B stall、accepted beat、arbiter owner hold，
以及 display underflow 和端到端 frame deadline；`csr_clear_stats_pulse` 可同步
清零。per-client 向量仍保留为层次化诊断，选定 live aggregate read window 已映射到
APB `0x108..0x12c`，并在 monitor 关闭时确定性返回 0。24-bit 计数覆盖 100 MHz
下约 167 ms 连续等待，标量 owner max 避免额外的变量索引时序路径。

独立回归与资源参考：

```text
C1_AXI_SHARED_QOS_MONITOR_PASS aw0_wait=3 ar1_wait=2 b0_stall=2 r1_stall=4 read_hold=4 write_hold=3 underflow=1 deadline_miss=1
proxy: 2268 LUT / 4000 FF / 0 BRAM / 0 DSP / WNS +1.465 ns @ 100 MHz
```

真实 native 8×8 BFM 可用（终点使用“新帧标签”的 prefetch 完成事件）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\case1\scripts\run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -Frame 8x8 -TwoFrame -SharedQosMonitor -RunId native_qos_8x8_tagged_twoframe_v7
```

该 run 实测 `event_start=2`、`raw_prefetch_done=3`、`event_new_done=2`、
`event_swap=2`，并通过 `C1_QOS_APB_READBACK pass=1` 逐字段核对 APB aggregate
读回（见 `TEST_RESULTS.md` §6.14）。QoS 帧窗口覆盖 accepted start 到对应新
pair 的 AXI/FIFO/line-store 排空；`display_swap_event` 是独立的 VSYNC ownership
commit，当前允许与 prefetch overlap，不能把 swap 时间当作 QoS terminal。该证据
仍不是 640×480/15 fps 签核；owner/epoch payload mux、burst/multi-outstanding 和
Efinix/Efinity 映射仍待后续阶段评估。

在同一 BFM 上打开 `-DisplayResponseFifo` 做 A/B（run
`native_qos_fifo_tagged_twoframe_v1`）后，`r4/r5` stall 从 bypass 的约 5.34 M
降到 `27/27`，`ar4/ar5` wait 降到 `194/234`，`read_busy` 降到约 17 k；
`last_frame_cycles=3446518`、`deadline_miss=2`、`underflow=2` 未变。因而 FIFO
已经隔离 display response HOL，但当前端到端瓶颈不在这一段，下一阶段应把同一
归因方法移到 client-6 tensor/compute-start 和共享调度。

### client-6 可选 tensor burst/refill（2026-08-28）

新增 `rtl/dma/c1_tensor_window_cache_burst_axi_client.sv`，只把 cacheable
3×3 tensor row refill 接到 exact-count/AXI128 burst reader；写、普通读和
fallback 仍走历史 bridge。默认 `ENABLE_TENSOR_BURST_REFILL=0` 不变，并新增
`TENSOR_BURST_CANCEL_IS_PROTOCOL_ERROR` 显式控制 fence cancellation 是否成为
sticky protocol fault。

standalone 契约 TB 已覆盖 packed miss/hit、AR/R/AW/W 回压、response hold、
flush-before-AR 和 abort-before-AR：

```text
C1_TENSOR_CACHE_BURST_AXI_CLIENT_PASS burst_ar=4 single_ar=5 beats=13 aw/w/b=2/2/2 flush_done=2 abort_done=3 ar_stall=3 r_stall=0 r_gap=21 aw_stall=1 w_stall=2 cycles=265
```

64×48 optional top 的 compile-only gate 也已通过；此前两帧 full BFM 中
client-6 `AR/R=59664/76800`（legacy `96384/96384`），但端到端帧周期未下降，
所以这仍是板前协议/带宽候选而非 15 fps 结论。完整维护边界、资源判断和板卡后
bring-up 顺序见 [`TENSOR_CLIENT_BURST_REFILL_INTEGRATION.md`](TENSOR_CLIENT_BURST_REFILL_INTEGRATION.md)。

### 2026-08-28：tensor burst logical/beat full-top 与 native beat gate

logical full-top proxy 的最终 v4 结果为综合完成但 timing failed：
`portable_soc_tensor_burst_logical_v4`，`80791 LUT/39369 FF/32 BRAM/100 DSP`、
WNS `-52.20 ns`（此前 v3 的 `+14.92 ns` 解析值已废弃）。beat-record proxy
`portable_soc_tensor_burst_beat_v1` 完成综合并输出 `48411 LUT/30950 FF/32 BRAM/100 DSP`，
但 WNS `-52.55 ns`，仍是未闭合的 timing 观察结果。native beat 两帧
`tensor_burst_beat_8x8_twoframe_v1` 与 `tensor_burst_beat_64x48_twoframe_v1`
均 PASS（`done=2 swaps=2 drops=0 descriptors=44 display_done=1`）；两者分别为
`AR/R=1451/2970` 与 `60165/84187`。beat 选项仍默认关闭，不代表
640×480@15 fps；后续需完成 beat path 分级及 Ti60/Efinity 复核。

### 2026-08-28：REGISTER_ABORT_RESET A/B

native resize PASS；native 8×8/64×48 abortreg 均 PASS，`protocol=0`。proxy
baseline 资源/时序为 `48192 LUT/31227 FF/32 BRAM/88 DSP`、WNS/TNS
`-5.900/-67577.578`；abortreg v2 为 `48211 LUT/31237 FF/32 BRAM/88 DSP`、
WNS/TNS `-5.416/-66644.070`，`timing_met=false`。剩余最差路径为 reset 相关的
descriptor decoder path。

### 2026-08-28：PIPELINED_DECODER_VALIDATION

decoder pipeline 已在 engine→cnn_top→system_bridge→portable_soc 参数化，默认为 0。
MicroStyle engine xsim PASS：`C1_R1_MICROSTYLE_ENGINE_PASS ... outputs=836 ... first_run_cycles=30570`。
完整 8×8 两帧组合（burst+beat+address+adapter descriptor pipeline+narrow+abort reset+QoS+display FIFO+decoder pipeline）PASS，
`done=2/swaps=2/drops=0`、`protocol=0`、`last_frame_cycles=3446518`、
`r4/r5 stall=29/29`、`ar4/ar5 wait=202/244`。

proxy `tensor_burst_beat_pipelined_split_addr_abortreg_decoderpipe_v1` 为
`47493 LUT/31441 FF/32 BRAM/88 DSP`、WNS/TNS `-5.362/-66042.227 ns`，
`timing_met=false`；相比 abortreg v2 `48211/31237/-5.416/-66644.070`，配置阶段
每 descriptor 固定增加两拍，运行期协议不变，仍非 timing signoff。
