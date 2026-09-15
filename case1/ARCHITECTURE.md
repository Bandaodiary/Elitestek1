# 赛题一：板卡无关 RTL 系统架构

最新C31完整链路：RGB48/VS/DE → `c1_r2_rgb2_raster_source` → `c1_r2_camera_decimated_ingress` → overlap Resize/Capture → 帧池/C29 CNN/双画面scanout/CPU适配 → 共享AXI128。默认整帧除数2，FIFO以49-bit像素对记录计；相机只读扩展升级R2C2。详见[C31连接与边界](review/R2_RGB2_HOST_INTEGRATION_20260914.md)。尚未接真实CPU/DDR PHY/CSI/HDMI，原生15fps未闭环；以下旧阶段状态为保留的历史设计说明。

19时验证更新：原生六次功能已通过，AW2下约14.10171fps，当前结构仍保留原整行写回器。[C32](review/R2_CUTTHROUGH_WRITER_20260914.md)的逐完整字提前写回在单元/真实写侧AXI上数据正确，但过早授权AW会占住共享W并扩大其他客户端等待，因此未接入此主链。下一阶段拟增加逐物理突发就绪信用和已授权范围排空控制，尚未实现或证明整机收益。

## 1. 架构定位与证据边界

本目录把 Efinix 加密 IP/原语与便携 RTL 严格隔离，使 APB 控制、RAW ISP、framebuffer、CNN、DDR 调度和显示可以在没有 Efinity 与实体板时继续开发。

### R2 当前主线（2026-09-14 更新）

独立[C30官方双像素前端](review/R2_DEMO_RGB2_INGRESS_20260914.md)已通过验证：源域VS/DE/VALID转换为规范像素对并延迟末对到下一VS确认，49位pair FIFO跨域后逐RGB交给新增overlap Resize/Capture。此路径保持最终B排空，不新增PLL；512深度通过完整1080p两帧，峰404。尚未替换C29主机，C31还需解决统计单位、约58.5fps源的帧接纳、共享DDR及新完整闭包PNR/CDC。

R2 已从早期阵列探针推进到完整 CNN/共享 AXI/采集/配对显示与主机封装，不再是“尚未接 tile、量化或 DDR”的 R2-A 状态。R1 源码仍保留，默认整机未被替换。

当前独立候选为[C29](review/R2_CAMERA_CAPACITY_20260914.md)：`c1_r2_camera_capacity_host_system`→`c1_r2_video_camera_capacity_system`，保留C28 CDC整改，将量化饱和前记录压缩并重排row1/2 RAM，另7层仅类型替换，仍44源。回归/xsim的数值与周期等于C28，完整探针42,777 XLR/144 RAM/130 DSP，核心150MHz级+0.650/+0.026ns；56同步FF/8控制链/141端点检查通过，分类器仍内部断言。官方双像素接入、联合容量、全量CDC/板测未闭合，无新增原生fps结论。[C28](review/R2_CAMERA_CDC_HARDENING_20260913.md)及以下基线继续保留。

C27沿用C26冻结功能闭包，完成[物理CDC审计](review/R2_CAMERA_PHYSICAL_CDC_20260913.md)：43,577 XLR/148 RAM/130 DSP，核心150MHz级setup/hold +0.365/+0.026ns。141寄存器跨域端点与Gray慢角skew有实际报告，但同步链重定时和组合控制跨域仍需整改，分类器内部断言未解决；保护FIFO原型通过独立综合/仿真但尚未接入整机。该阶段没有新增CNN吞吐结论。

- 保留C26入口`c1_r2_camera_host_system`把C25相机入口接入C24/C22实际主机，44生产源；源为独立时钟不可回压RGB，经固定ROI、FIFO、Resize与RGBX Capture进入DDR。帧池只能根据`camera_result_valid && camera_result_admitted`完成预约，坏帧/取消等待真实B与源排空，不直接使用Capture内部done。APB增加只读相机统计，跨域遥测用81位最新值快照，不能作为无损事件队列。见[完整联合报告](review/R2_CAMERA_HOST_INTEGRATION_20260913.md)。MAP148 RAM/130 DSP，物理CDC和整机资源仍未闭合；C26原生六帧已独立完成，最慢9,793,756周期、150MHz模型约15.31588fps，不能继承到C29/C30。C21/C22也各自完成约15.3145fps。下方C25/C24条目为历史阶段记录。
- C25新增独立相机前端`c1_r2_camera_ingress`与同步读RAM双时钟FIFO，RGB源不可回压、固定ROI，末ROI像素等待全源EOF验证；错误通过独立保持状态跨域，队列与Capture真实B事务全排空才发布`result_valid/admitted/failed`。实际Resize/Capture、1080p连续源及溢出恢复通过，512/256均映射2 RAM，见[相机入口报告](review/R2_CAMERA_INGRESS_20260913.md)。尚未替换C24完整主机；下一阶段帧池应使用前端最终完成，而非内部Capture提前完成。物理CDC和板级像素并行度仍待验证。
- 最新C24入口`c1_r2_resize_host_system`：CPU/APB桥保持，`video_resize_system`在帧池预约时锁存源配置，`resize_capture_rgbx32`将C23 Resize与原Capture的任务接纳、错误/取消和真实B排空绑定；缩放后的原图与C22 CNN结果配对显示。41源联合探针43,665 XLR/146 RAM/130 DSP，150MHz +0.387/+0.026ns；数值/恢复/xsim/PNR通过，见[联合接入报告](review/R2_RESIZE_HOST_INTEGRATION_20260913.md)。源是可回压、同核心时钟的RGB，实际相机ROI/CDC/FIFO与CPU源配置寄存器未集成；无C24原生帧率证明。以下条目按历史时点保留，C23“未接Capture”已由本项完成。
- C23外围候选`c1_r2_resize_pipeline`仅替换R1采样器的行存储为奇偶银行，独立Resize20→12 RAM，Q16/Q0.12算术与流水合同不变。完整1440×1080→640×480为2,477,887拍、逐像素与旧/新RTL和golden一致；源允许回压，未与C22 Capture或实际摄像头连接。见[Resize缓存与集成边界](review/R2_RESIZE_BANKED_20260913.md)。新增模块不是新整机top，CSI/ROI/CDC和错误排空合同仍待集成。
- 最新C22入口`c1_r2_overlay_host_system`：PW/残差共享空间缓存物理行0，8个512×32位SDP实现两种一拍读视图；另一视图被覆盖后必须重填。生成式图已有切层失效/排空屏障，新增所有权断言。完整主机134 RAM、41,252 XLR、112 DSP，150MHz +0.349/+0.026ns；全算子/两套图/恢复/xsim及PNR通过，周期保持。见[共享特征存储报告](review/R2_FEATURE_OVERLAY_20260913.md)。C22自身原生六帧在途，不继承旧版帧率；以下条目为各阶段保留设计。
- 当前新增C21入口`c1_r2_compact_host_system`，继承生成计划/外部ABI，六份完整权重表以混合位宽供六个计算lane直接读取；PW/Encoder/DW/RGB接口均实际接入，新增残差容量尾批屏蔽。全图/全算子/主机/xsim及Ti60联合核心通过，41,620 XLR/150 RAM/112 DSP、150MHz +0.586/+0.027ns，见[紧凑主机报告](review/R2_COMPACT_HOST_INTEGRATION_20260913.md)。周期保持，不声称吞吐提升；C21原生另在运行。C18原生现已自身通过15.3145fps门禁，不再在途，旧段落为相应阶段历史。
- C20新增独立六路权重表，混合位宽SDP映射42 RAM，对比旧八银行64 RAM；数值/Icarus/xsim/PNR已通过，但尚未修改完整CNN的feeder接口。按官方现有平台资源估算，集成这22块节省后含CPU/DDR/CSI/Debayer仍约255/256 RAM，Resize/CDC未计入；必须继续处理平台容量。见[存储组织与平台容量](review/R2_WEIGHT_MEMORY_BUDGET_20260913.md)，不能把独立探针结果转称整机收益。
- C19在不改C18生产RTL的条件下补齐实际SLVERR、失败输出隔离、错误IRQ和无复位恢复，含同一CNN两笔真实B债务排空；见[系统错误恢复](review/R2_HOST_ERROR_RECOVERY_20260913.md)。协议畸形后的整系统协调复位仍是独立缺口。计数检查器已按实际DONE修正绝对时间+1，原生完成间隔/FPS不变。
- 当前联合入口为 `rtl/r2/c1_r2_host_video_system.sv`（C15）：APB3 本地16位窗口与IRQ → CPU DDR适配器＋C14帧所有权/视频核心 → 四主机共享AXI → 外部DDR控制器接口。CNN内部为96MAC、量化、行缓存、加载/计算/双页写回重叠；输入/输出RGBX32，内部P2C8。见[主机集成记录](review/R2_HOST_INTEGRATION_20260913.md)。
- C16 `c1_r2_planned_pingpong_graph.sv` 由Python显式算子/DAG生成 `c1_r2_microstyle_plan.sv`，替代手工层号译码并保留计算/行传输屏障。它不修改C15，而是已接入新的C18 `c1_r2_planned_host_system`；原图/18项结构试验均有完整主机数值回归。见[计划化联合报告](review/R2_PLANNED_HOST_INTEGRATION_20260913.md)。
- C17进一步由 `r2_plan_package.py` 配套生成计划表、参数镜像与节点/尺度清单；同一执行器已实际通过原22项与删块18项图的数值回归。后者只作结构变更验证、未重训或验证风格质量，不替代比赛模型。见[配套包报告](review/R2_BOUND_PLAN_PACKAGE_20260913.md)。
- C12/C13/C14/C15各自原生640×480六帧、30fps采集/720p60配对显示/CPU竞争行为模型已通过，四个完整负载间隔最慢15.3145fps@150MHz。C14/C15六次均选中最新完成帧；不是C16/C17/C18性能或板测，目前仅C18自身原生在途。
- C15联合核心为45,817 XLR/172 RAM/112 DSP；C18原22项联合核心为46,531 XLR/172 RAM/112 DSP，150MHz setup/hold +0.536/+0.028ns。C16/C17核级资源不能混用为整机范围。实际Sapphire、DDR/MIPI PHY、ISP/Resize、时钟CDC与板卡外设尚需独立集成，最终模型质量仍未完成。

### 下文为保留 R1 架构与历史优化记录

当前仍可运行的R1整机基线顶层是 `rtl/top/c1_r1_portable_soc.sv`：

最新增量是列读分支中scalar客户端的可选双条目全相联缓存：
`TENSOR_SCALAR_READ_CACHE_ENTRIES=2`经packing bridge传给single-beat桥，保留
两个16-byte地址行，优先无效槽、再LRU替换。残差A/B交替访问时，各自第二个C8
半字不再被另一输入挤走。精确失效允许第三bank写回时保留两输入，但写命中任一
tag、总线错误和stage/abort fence仍保守清空全部；不是CPU/DMA一致性cache。
填充way/资格绑定已接纳miss，取消后晚到R不能重新安装；已呈现响应保持稳定。
packing桥继续等真实B及逻辑写全部退休，缓存命中不能越过写屏障，读owner仍1笔。

默认容量1、缓存开关关闭不变，无新端口/ABI；最佳新组合另外要求列读、scalar缓存
及精确写失效开启。64×48同条件310,689→299,189拍，scalar AR/R各减半，列回填、
实际写事务和工作量不变；约新增159个逻辑存储位，目标资源/时序及原生15fps未测。
统一入口增加`-ScalarReadCacheEntries 2`；详见
[双条目缓存报告](review/RTL_SCALAR_ASSOC_CACHE_20260912.md)。

此前列回填集成复用既有`TENSOR_BURST_SCHED_REQ_HANDOFF=1`和
`TENSOR_BURST_SCHED_MAX_OUTSTANDING=32`，由portable_soc的列读分支经
column owned shell→exact backend传到scheduler。旧pending握手后可同拍装入下一笔，
已接收metadata与待发送pending共同预留容量；真实AXI响应仍按原顺序退休。
32个C8逻辑容量使16-beat AXI突发更充分，reader物理上限仍4笔；不是增加MAC，
也没有新行预取/RAM。生产逻辑/default不变，本轮修复选择入口并补齐实际列路径验证。
同64×48任务329,619→310,689拍，AR1,680→864而R仍13,440；目标时序未测。
统一复现入口为`scripts/run_r1_column_refill_profile.ps1`，参数与证据详见
[列回填集成报告](review/RTL_COLUMN_REFILL_INTEGRATION_20260912.md)。

上一轮吞吐优化为默认关闭`STREAM_DW_FRAME`，只沿portable_soc→system_bridge→cnn_top
传给engine。原DW核已支持每组独立绑定窗口/权重/偏置/量化/坐标；第一像素按旧规则
填充权重缓存并排空，后续暖像素连续使用同一个batch，真正层尾最后一组才送EOF。
下一像素只有在旧窗口全部组交付乘法流水后才覆盖输入缓存；输出按核中保存的坐标
及独立retire-group游标还原，因此允许多像素同时在流水内而不混淆参数/坐标。
层完成仍等真实输出EOF，像素写DMA与任务成功排空屏障不变。

没有新生产寄存器/数据缓冲/MAC/RAM数组，外部接口和adapter均不变；要求已有DW
像素流水、group streaming和缓存权重。64×48同配置342,287→329,619拍，完整golden/
DDR/显示及取消恢复通过。不能据此声明原生15fps或Efinity时序通过，见
[DW连续调度报告](review/RTL_DW_FRAME_STREAM_20260912.md)。

最新公共控制修复在`c1_r1_job_controller.sv`：四个runtime完成事件仅允许进入暂定成功
排空，并不立即提交成功。直到所有client busy降低并真正发布`job_done`的边沿，仍须
按abort优先、input DMA→descriptor→engine→output DMA错误优先级否决成功。
已选择错误/取消后只排空原事务，不被晚到诊断改写首个原因，也不重复发送取消脉冲。

关系是job frontend调用controller，boardless frame system提供四个执行client与真实
DMA busy/done/error，portable SoC在有效job_done后才交由帧管理器发布显示候选帧。
即使输出区域已写完像素，取消命中的未发布任务也不能报告成功。本修复不改AXI/data
路径、端口或描述符ABI，不新增寄存器；正常64×48周期仍342,287。定向反例、预览开/关
真实DMA取消恢复及完整golden结果见[审查报告](review/RTL_SUCCESS_DRAIN_PUBLICATION_20260912.md)。

上一阶段优化为默认关闭`FUSE_FINAL_OUTPUT`，传递路径为portable top→system bridge→
CNN top→engine，并由portable top同步配置tensor adapter。它仅融合固定MicroStyle
stage20最终3通道卷积到stage21 identity输出的中间存储，不改变卷积、量化或RGB转换。

数据/完成关系：stage20真实C8结果→adapter原final寄存器→原signed-RGB egress→
输出帧写DMA；最后EOF必须先捕获保持，随后stage21描述符/参数校验→view_commit
握手→cnn_done→原bridge允许EOF→最终写完成/帧提交。view_commit绝不能等待
EOF下游READY，否则与bridge的完成屏障构成循环等待。帧的部分内容可先写入私有
输出区域，未通过原job/DDR完成屏障不能交给显示。

adapter逐结果检查raster坐标、group=0/last、SOF/EOL/EOF与高40位padding；结果接收
与下一窗口读解耦。若坏结果恰遇已呈现/接纳读，必须保持请求/排空真实响应后停在错误
状态，取消后才回idle；idle旧结果不会被接纳。没有伪造内存ACK或丢弃读债务。
复用原final数据寄存器，仅新增2位pending/history控制及比较逻辑，不增RAM/MAC，
不修改软件/总线ABI或三bank容量。结合UPS视图后仍22个逻辑层，19个物理数据输出层。

64×48同配置370,509→342,287拍（-7.6171%），stage21为40拍；全golden、双帧、
取消恢复与最小scalar-only模式已验证。新ready路径的Fmax/物理资源尚待Efinity综合，
保持默认0，不将小图周期收益外推为原生15fps；原生理想下界8,928,000拍仍不含开销。
详见[开发日志](DEVELOPMENT_LOG.md)。

上一阶段列缓存优化为默认关闭的`TENSOR_COLUMN_REUSE_ROW_MAP`：portable top→owned
column shell→exact-burst backend shell→`c1_column_line_cache_c8.REUSE_ROW_MAP`。
既有成功lookup留下的bank mask/lane映射可供相同17位signed center Y的下一笔列
请求复用；实际接纳当拍用新的x/group offset读RAM，绕过重复lookup，不缓存旧数据。
不同Y、重配置、非法group、维护操作失效资格，原请求/响应保持和取消排空协议不变。
不能以clamped center相等代替signed Y相等；边界-1/0可能有不同的三个输出lane。

该路径不改CNN/CPU接口、不增加MAC、RAM bank或在途事务，只增加18位控制状态和
RAM地址选择逻辑（实际资源仍待综合）。LOOKUP read和response bypass均可独立开关；
二者开启时暖行端点接纳间隔3→2拍，默认全部注册时5→3拍。每列仍一次真实RAM读，
DDR流量不变。64×48整网375,029→370,509拍，只减少1.21%，不能从端点间隔外推帧率。
新输入地址路径可能影响Fmax，保持默认关闭至目标综合验证净吞吐；原生15fps未证明。
数值、生命周期、最小组合和检查器负测试证据见[开发日志](DEVELOPMENT_LOG.md)。

上一阶段优化为默认关闭的`ELIDE_VIRTUAL_UPSAMPLE`。它与既有虚拟上采样存储配合，
只把固定22层MicroStyle的stage14/17作为最近邻视图提交，不再遍历重复的C8数据。
逻辑网络仍有22层，实际数据输出为20层；完整golden仍计算22层，不改变模型语义。

控制路径为tensor adapter→`view_commit_valid/stage/generation`→system bridge→
CNN top→engine，ready反向返回。adapter先完成本层cache配置握手并等待自身旧写
响应、预取和pixel sink排空；engine保留原描述符/连续性/参数校验，并等待core空闲。
合法握手时双方同拍推进stage，没有dummy输入、假输出或提前的DDR写完成。
generation与stage不匹配按原协议错误07拒绝，背压保持身份，取消不提交未接受视图。

stage14/17的输入仍在物理bank0，output bank3仅为虚拟标记；stage15/18沿用原半尺寸
backing和坐标映射。新选项经portable top同时配置engine和adapter，要求既有
`VIRTUAL_UPSAMPLE_TENSORS`、列读/cache sideband及固定拓扑。外部CPU/AXI端口、
软件/张量/参数ABI均不变；若单独例化CNN或adapter并开启本选项，必须连接新增内部
握手，不能只在一侧开关或省略信号。默认关闭维持原22层物理数据输出契约。

本轮不增加MAC、payload FIFO、RAM bank或FSM状态，但控制逻辑面积/时序仍待综合。
同配置64×48 A/B为435,864→375,029拍，stage14/17各3拍且没有张量数据传输；
取消/双帧/最小组合及完整数值证据见[开发日志](DEVELOPMENT_LOG.md)。原生640×480
理想工作量下界9,235,200拍，15fps至少138.528MHz且尚未计入开销，不代表板卡达标。
以下各项性能数字保留其对应历史开关组合，不应与最新组合混用。

最新首层优化是默认关闭的`PACK_RGB_CONV_REDUCTION`。该参数仅沿portable top→
system bridge→CNN top→engine传递，不改变tensor adapter或软件ABI。仅对Conv3且
Cin=3生效，其他卷积、DW和线性层继续原调度；不依赖DOT/DW跨像素流水开关。
MicroStyle首层实际为3→12通道，包含两个输出C8组。

内部将27个tap/channel乘积映射为四个C8 reduction beat（8/8/8/3）：
`p=3*tap+cin`，权重bank仍为`cout_lane*8+(p%8)`，tile地址为`cout_group*4+p/8`。
参数输入仍按OIHW遍历九个tap，在每层准备期重排一次；窗口输入仍是九个tap-major
C8 word。激活通过常量布线和四选一mux选出对应八项，最后五个无效lane与无效输出
lane显式置零/屏蔽。未增加架构上的MAC/weight bank/window bank，但额外mux和
地址选择的实际面积、RAM推断和时序影响仍需综合验证，不能宣称资源完全不变。
32位累加仍覆盖全部27项，仅改变分组，原bias、量化、ReLU和输出C8顺序不变。

本轮还修复ALL_DOT旧路径的功能漏洞：COLLECT已允许旧结果退休，输出mask也必须
使用`dot_retire_group_q`，不能用下一像素的计算group。定向密集带符号测试在开/关
RGB打包两种情况下，将旧group0背压至COLLECT/issue_group1，检查有效lane4不被
误屏蔽。该修复不是新增模式的前提限制，而适用于所有现有多输出组DOT流水。

相同64×48配置下，新模式435,864拍、关闭443,465拍；开启完整22层/DDR/视频golden
已通过，stage0由41,426降至33,797拍。最新回归完成情况见开发日志，后文保留历史结果。
640×480理想计算下界由10,848,000降至10,080,000拍；15fps仍至少需要151.2MHz，
还没计访存/调度/量化空泡，不能由小图周期直接宣称原生15fps。

DOT多输出组扩展由`PIPELINE_ALL_DOT_GROUPS`控制，默认0，并要求已有`PIPELINE_DOT_PIXELS`。
不启用时仍只有单输出C8组卷积可以跨像素；启用后适用于所有符合adapter列读、独立输入/
输出bank条件的Conv3/Conv1（Conv1还需pointwise列接口，否则adapter保留旧路径）。该参数
分别经system bridge→CNN top→engine，以及直接到tensor adapter两条链透传。

engine只在最后输出group的最后reduction输入被core接纳之后才能复用窗口缓存；之前仍
逐group调用原量化重叠调度。`dot_retire_group_q`按实际结果握手循环，不因新输入group0
到来而清零；输出坐标和SOF/EOL/EOF仍来自core捕获的旧事务metadata，不能使用新输入游标。
换层等最后真实EOF结果退休，adapter再等全部sink写响应和列事务排空，不产生posted ACK。
writer的MULTI_GROUP由DW或ALL_DOT选项置1，共用原最多15笔逻辑预留。core仍最多6笔
事务；其全部结果受阻时，pointwise streaming最多预收下一像素首组，不能无界接纳。

不新增MAC、窗口bank或payload FIFO。64×48同条件完整golden开关对照为470,765→443,465拍，
stage0为50,343→41,426；stage0统计包含源复制和启动，新增两侧FSM驻留记录可独立核对。
其最终输出等待状态4608→6拍，但总收益还包含其他多group卷积，不是单独stage0消融。
完整回归、双帧及真实读/写取消恢复证据见开发日志；默认仍兼容，目标资源/Fmax和原生
640×480/15 fps没有新验证，不能用软件状态或模拟DDR延迟代替板卡证据。

新增默认关闭`PIPELINE_DW_PIXELS`，同时经system bridge→CNN top→engine和tensor adapter
两条配置链传递。暖权重DW像素的所有C8窗口被core接纳后，engine立即复用原窗口缓存
收集下一像素；core仍等待旧像素实际EOF输出退休才接受下一START，因此没有增加窗口bank
或MAC，也不是跨像素无限队列。冷像素保留原九tap权重准备/逐组流程。

输入坐标与退休坐标分离：DW结果采用core已有的`out_x/out_y`及engine独立3-bit退休group，
按冻结的宽高重建SOF/EOL/EOF和尾通道mask，不能引用已提前的输入metadata。adapter在
列读、不同输入/输出bank、非最终显示阶段的DW算子上启用独立结果sink；按C8顺序写回，
最后帧结果被接纳后仍须等待真实写响应及列事务排空才能换层/取消完成。

`c1_pixel_result_writer.MULTI_GROUP`默认0，新端口`start_groups`此时忽略；DW流水置1后
START锁存1..8个C8 group/像素，地址按group逐次+8，最后group才推进x/y。输出坐标、group、
group_last和帧标志逐项校验。batch单位统一为C8 word，由3-bit计数器跨group/像素累计，
行尾关闭；不能再按“若干像素”解释多group模式。总逻辑预留仍最多15且包含保持的请求，
物理AW outstanding由下游另行统计。新选项依赖stream DW、缓存权重及列读/写重叠，
可不启用DOT流水、量化重叠或列预取。

同条件64×48、单事务、batch8/timeout64的完整golden：仅打开DW新选项使513,059→470,765拍
（-8.24%），stage18为63,565→38,955拍；stage0仍50,343拍。收益组合了窗口准备重叠和独立
多group写回，不改变MAC工作量。双帧及真实读/写取消恢复通过；默认关闭仍保持原周期。
这些是便携RTL行为证据，非新综合、Fmax、板卡DDR性能或原生15 fps证明。详见开发日志。

单输出C8卷积和多group DW的跨像素写回使用`PIXEL_WRITE_BATCH_WORDS=1/2/4/8`，默认1，
只经top→tensor adapter→pixel writer透传，不进入计算engine。writer按行内批次末尾
或EOL生成与地址/数据一起保持的`mem_req_end`，adapter转交原有tensor memory端口。
它只是有序打包提示，不是写完成；每行不足一批和EOF均明确关闭，取消/错误不能
修改已呈现的end。跨word批次要求dot或DW像素流水，以及packed writes和end消费均开启。

`TENSOR_WRITE_BUILD_TIMEOUT`默认8，允许1..255，仅在packed column分支允许非默认值，
统一传入串行和MLP packer。必须保留有限超时，使没有末尾end的取消/错误部分批次
仍可排空。超时与批次需分开评估：64×48四槽/相同queued fabric下，batch1/timeout8
为513,605拍、15,591 AW；仅timeout64为513,605拍、14,422 AW；batch8/timeout8仍为
513,605拍、15,591 AW；batch8/timeout64为513,629拍、9046 AW。全部22层数值、DDR与
视频golden一致。组合减少AXI事务和无效byte传输，但本例几乎不改变关键路径周期；
不能把打包改善写成MAC加速或已满足15 fps。默认参数不变，生命周期/性能追加结果见开发日志。

张量写通路新增`TENSOR_WRITE_OUTSTANDING=1/2/4`，默认1。在packed column分支中，
1保留旧`c1_tensor_mem_axi128_write_burst_client`；2/4选择新
`c1_tensor_mem_axi128_ordered_write_client`，再接现有`c1_axi128_write_mlp`。
前端从连续C8请求收集最多4个AXI128 beat，按可配置空闲超时（默认8）、ordered end、地址不连续、
重复lane、4 KiB或32-bit地址边界关闭批次。冲突地址不同数据拆成不同burst，不重排。
command、payload、逻辑响应各自按分配顺序推进；响应存储直到该descriptor的最后
逻辑ACK被消费才释放，不因物理B已经返回而覆盖仍被背压的响应数据。

MLP backend的新`PIPELINE_WRITE_DATA`默认0，新有序前端将其置1：W游标在自己的
WLAST后前进，B退休游标仍等真实响应。已完成但尚未收到B的payload不能复用。
本地未对齐错误作为有序poison descriptor通过backend，不发AW；物理outstanding
只计真实AW−B，不包括本地错误和孤立B。读请求仍必须等待全部旧写逻辑ACK及backend
busy排空，已有读响应被持有时禁止写入；原cache失效策略不变。取消不复位写通路，
上层停止新请求，已呈现/接纳的事务必须继续排空，包括由超时关闭的部分批次。

该选项增加有界存储而非MAC：前端payload/strobe/echo与backend payload/strobe
合计逻辑数据容量为2槽416字节、4槽832字节，不含metadata、计数器和选择器。
这里包含完整模块的响应echo，SoC不使用写echo，综合器还可能剪除该部分。
没有新Efinity/Vivado综合/P&R证据，不能把这些字节直接换算为RAM Block/LE。
在相同queued fabric的64×48测试中，默认B延迟下1槽513,059拍、2/4槽513,605拍
（回退0.11%）；额外32拍B延迟下1槽827,478拍、4槽539,759拍（减少34.77%）。
这是条件性延迟隐藏，不是无条件加速；默认保持1。压力模型不是实际DDR测量，也未
证明原生640×480/15 fps。详细运行、数值和取消证据见开发日志最新一节。

新增默认关闭的`PIPELINE_DOT_PIXELS`将单输出C8组的卷积输入调度与结果写回解耦。
engine在该像素最后一个MAC输入被接纳后，可收集下一像素；旧结果的数据、坐标和
EOF从dot量化流水退休，不能使用已经前移的输入游标。最后结果实际退休才允许换层。
adapter在缓存层配置握手时启动独立`c1_pixel_result_writer`，该模块验证group0/last、
像素顺序及SOF/EOL/EOF，将C8线性写入独立输出bank。输入调度提前不代表写回完成：
只有sink的保持请求和所有已接纳写响应均排空后，adapter才能切换层或完成取消。

当前系统适用stage19（需`POINTWISE_COLUMN_READS`）和stage20；多输出组、DW、残差、
源上传及最终输出仍用原路径。依赖`OVERLAP_MAC_REQUANTIZATION`和
`OVERLAP_COLUMN_WRITEBACK`及其列读/流水写前提，不要求下一像素预取。保持原32状态
编码，不新增MAC、量化阵列、窗口计算bank、CPU寄存器或描述符字段；新增有界写回
控制器、97-bit保持请求寄存器（包含新end位）、地址/坐标及credit寄存器。新ready路径尚未做物理时序验证。

必须区分三层容量：sink最多15笔总逻辑预留（包含保持请求）；标量packing桥默认每次
仅一笔物理AXI事务，可选上方2/4槽通路；共享fabric的多笔outstanding来自其实际已接纳的主机/事务。
逻辑队列深度不等于单主机物理outstanding。真实取消测试把第二路摄像头写入安排在
stage20，形成两笔全局AW/W/B债务并暂停B 64拍，再排空及无复位恢复；没有伪造写ACK。
同配置64×48完整golden为562,652→514,442拍（-8.57%），仍不是原生15 fps或板上Fmax证明。
以下旧选项描述其单独作用；未启用本开关时保持此前的逐像素窗口/结果寿命。

默认关闭的`PREFETCH_ALL_PIXEL_GROUPS`扩展既有下一像素首列预取，依赖
`PREFETCH_NEXT_PIXEL_COLUMN`及其列读/流水写前提。adapter在当前像素全部输入被
engine接纳后，按序请求下一像素所有输入组的第一列，外部仍只有一个column请求
在途。最多8×192-bit数据暂存（192字节，原单槽24字节），每组独立valid/error，
共用stage/坐标/tap标签和有界发射/消费计数；数据不复位，valid复位阻止陈旧数据
外泄。group0已返回就可被使用，不必等全部组返回；后续组可继续预取。

同组后续需求列与预取共用外部通道。必须区分“预取还存有未来组”和“通道由预取
请求/响应占用”：前者不能替普通需求读排空，后者也不能被当作需求握手。未呈现
需求的取消直接转入独立预取排空；已经呈现/接纳的普通需求保持VALID/响应债务，
即使还有未来组缓存也不能提前完成取消或错误清理。有限暂存不能跨像素/层复用，
层切换仍等全部列/写事务退休，不增加MAC或跨像素计算能力。
64×48完整golden由588,440→562,652拍（-4.38%），stage18/19降至63,569/66,858拍；
单输入组stage20无实质改善。逻辑暂存容量不等于Efinity实测RAM/LE消耗，尚未重新
综合/P&R，也未证明原生15 fps。

默认关闭的`OVERLAP_MAC_REQUANTIZATION`将同一像素内不同输出通道组的计算与量化
退休解耦。engine保留发射游标用于权重、偏置和START，另用退休游标生成输出组号、
尾通道mask和group_last。当前组最后一个MAC输入被接纳后即可准备下一组；dot core
只有在旧累加结果及其量化配置真正进入现有5级量化流水后，才接纳下一START。
最多5个量化事务＋1个活动dot，不增加MAC、量化数组或窗口bank，结果严格按序。
全部输出组实际被下游接纳后才释放当前像素窗口/切换层；不提前计算下一像素。

底层`c1_dot8x8_requant_core.OVERLAP_REQUANTIZATION`默认0，开启时优先于
`ALLOW_OUTPUT_RESTART`。`busy`覆盖所有已接纳未退休事务，`start_ready`表示累加器
可以接收新事务，因此可能出现`busy=1 && start_ready=1`；不能继续用busy当作START
许可。新模式`overflow_seen`是连续busy区间内的汇总黏滞状态，不是逐结果标签。
与`STREAM_POINTWISE_REDUCTION`组合时，首输出组的输入流状态在最后MAC beat
接纳时结束，后续输出组使用已经收齐的缓存。取消/错误清空内部算术事务，外部
DDR仍按既有合同排空。新ready组合路径和控制寄存器尚未经过本轮物理时序验证。
同配置64×48完整golden为622,498→588,440拍（-5.47%）；stage18/19/20基本不变，
不能据此推定原生15 fps。最新证据以IMPLEMENTATION_STATUS和DEVELOPMENT_LOG为准。

默认关闭的`STREAM_POINTWISE_REDUCTION`使1×1的第一个输出通道组按输入组提前归约。
当输入组数大于1时，第一组到达就启动现有dot core；每次真实MAC接纳后返回COLLECT，
等待下一组，不读取尚未到达的window_cache项。最后一组才结束该dot事务，其他输出
组仍复用已经完整收齐的window_cache执行原调度。它与1×1是否走column cache独立，
也与MAC_PREFETCH_OVERLAP独立；不增加MAC或窗口bank，不改变CPU/描述符及C8接口。
所有输入组仍先通过原坐标/组号/帧标志校验，部分归约发生取消/错误时清空内部算术
事务，不允许输出不完整结果。现有stage/DDR写响应边界不放松。

默认关闭的`PIPELINED_SOURCE_WRITES`将源帧上传与结果写流水分开控制，不要求列缓存或
`PIPELINED_RESULT_WRITES`。adapter用4-bit计数管理最多15笔已接纳未退休源写，继续使用
原请求寄存器和后端FIFO；每8个C8或EOL发出有序end，便于已有128-bit写后端合并。
end是合批提示，不是应答前提：后端必须按有限空闲时间/取消提交不完整批次，现有写
客户端已有该能力。EOF后必须等每一笔真实响应，再发布首层cache配置或engine操作数。
错误/取消保留已经呈现的写请求，并排空所有信用；源写和结果写的信用不能同时有效。
该选项改善搬运调度，不改变源C8布局、算法、模型权重或CPU ABI。当前64×48全22层
golden实测662,984→637,364拍；并不等于已证明原生640×480/15 fps或物理时序。

默认关闭的`PREFETCH_NEXT_PIXEL_COLUMN`允许在当前像素最后一个输入group被接纳后，
提前读取下一像素group0的第一列。它依赖既有列读/流水写/跨像素写重叠，只允许不同
输入/输出bank；不提前向engine发送下一像素。adapter增加一个192-bit数据暂存项及
stage、逻辑坐标、物理列坐标、tap标签，独立请求/响应状态负责保留已呈现的VALID和
接收在途应答。下一像素消费时核对标签，EOF不预取，层切换/取消必须清空该义务。
不增加行缓存/MAC阵列，但有新增暂存与控制逻辑，资源和时序需由EDA验证。
SoC同时允许受授权的不同bank结果写与列事务并行；标量读、同bank访问和层切换仍隔离。
同配置64×48为695,256→662,984拍，13,424次预取请求/响应/消费守恒，13,154次
在消费者进入等待前返回；全22层和两路视频golden一致。

取消生命周期修正：`c1_r1_microstyle_system_bridge.active_q`只能由新launch获取。
已取消adapter的迟到错误仍对外诊断，但不能重新置active；未活动时的CNN done也不
进入新任务的完成记录。bridge busy不是外部DDR债务总和，SoC仍分别等待adapter、
cache/owner、AXI和其他活动域排空。真实stage18下一行预取refill取消已验证此边界。

2026-09-11性能分支补充：`ENABLE_TENSOR_COLUMN_READS=1`时，3×3窗口走独立
`c1_column_cache_owned_exact_burst_shell`（标量仍为client-6，列读新增一个AXI客户端；
叠加preview时共9个，否则8个）。以下示意图保留默认七客户端路径。

列接口还可独立启用`TENSOR_COLUMN_RESPONSE_BYPASS=1`（默认0）：参数经owned shell、
exact burst shell传到`c1_column_line_cache_c8.RESPONSE_BYPASS`。数据仍由同步行RAM
在时钟边沿读出，只将其后的capture→response强制等待去掉；可接收时直接退休，
背压时保存到原响应寄存器。RAM读边沿之前的维护可以返回错误；响应首次呈现后的
维护不得改写成功/数据，ACK仍等应答退休后再完成。没有组合READY环或新增存储阵列。
配合read-on-lookup，纯命中列II由4降到3；不启用lookup时由5降到4。
同组合64×48为727,176→695,256拍，实际31,824次直通和全链路golden已通过。
它将行选择mux移到接口组合路径，不能据此推断物理Fmax提高；默认寄存边界保留。

进一步可用默认关闭的`POINTWISE_COLUMN_READS=1`把1×1输入也送到同一列端口：
每个输出坐标、每个输入C8 group只申请一次，在192-bit三行响应中仅消费中间
`[127:64]`，放入引擎576-bit窗口的tap4，其余八个tap保持零。仍使用原标量1×1
的raster坐标与数值ABI，不引入新算子或改动模型；残差、upsample与RGB读取仍走标量。
该选项仅依赖列接口，不强制虚拟上采样、流水写或重叠。若同时启用
`OVERLAP_COLUMN_WRITEBACK`，1×1也按不同输入/输出bank规则重叠旧写和下一像素列读，
保持stage边界/取消/错误时真实应答排空。CPU不得并发修改活动输入bank。

复用现有三行缓存及MAX_ROW_WORDS=1280、MAX_GROUPS=8，不增加缓存或MAC阵列容量。
原生640×480描述符的1×1最大输入行恰为1280 C8；整机实测范围仍止于64×48：
同配置778,326→727,176拍，完整22层、DDR与两路视频golden一致。逻辑标量读
28,608→14,976，13,632次1×1读转为列请求；这不是少算模型输入，也不能把返回的
三个C8都统计成1×1有效运算数据。未测物理资源、Fmax或原生15 fps。

此分支可再启用默认关闭的`VIRTUAL_UPSAMPLE_TENSORS=1`：stage14/17仍在引擎执行并
逐个校验结果，但不产生中间张量写；stage15/18利用小图列缓存加行选择构造等价的
最近邻放大窗口。它修改的是tensor adapter，不替换CNN算术核，不跳过任何模型层。
stage13后bank流为`0 → (虚拟14) → 1[15] → 0[16] → (虚拟17) → 1[18]`，
随后恢复原映射；虚拟阶段输出bank标记3表示“无物化输出”，不是第四块DDR空间。
列坐标先按逻辑大图夹紧再除2；物理三行对偶数/奇数输出行分别选`[0,1,1]`/
`[1,1,2]`，水平窗口历史保存映射后的值。必须保持输入bank不可被CPU/其他DMA并发修改。

此模式保留三块8 MiB预留区，没有新增行缓存数组。64×48训练模型完整golden对照
从1,008,032降到902,900拍（约-10.43%），张量逻辑写40,128→31,680，
所有22阶段/40,128 C8数值仍一致；stage18在途读取消恢复和不同输入双帧也通过。
这是测试DDR延迟下的吞吐改善，不是原生640×480/15 fps证明或物理时序结果。

DW计算还可独立启用默认关闭的`STREAM_DW_GROUPS=1`（要求
`CACHE_DW_WEIGHT_TILES=1`，不要求列读、虚拟上采样或MAC overlap）。首像素
仍逐组装载DW权重；本层各组缓存有效后，逐拍把不同C8组送入同一个DW核，并独立
按组退休输出。最后输出退休前不采集下一个像素，也不换层。window/权重/量化参数
在START及每次真实feed握手时预取到寄存器；核内参数随弹性流水传播，不将缓存选择
直接接到乘法器输入。未增加DW乘法器或参数缓存容量，但新增流水寄存器的实际资源
与时序需综合评估。

单核的`PER_BEAT_CONFIG=1`下，现有`start_*`配置总线改为随每个输入窗口握手取样，
`start_valid/start_ready`仅开启一批；配置必须与受阻输入一起保持。默认0仍维持
原批次参数快照契约。SoC内部由引擎驱动该模式，CPU/描述符ABI不变。

实测64×48写合并组合1,000,190→917,576拍（-8.26%），普通写路径仍为902,900拍：
新DW流水在普通路径被写回等待掩盖，不能认为计算核加速就会降低所有系统配置周期。
以上为DW流水完成时的对照；各可选功能的默认值不变。

后续写桥优化已消除两种结束控制气泡：`USE_REQUEST_END=1`时，消费FIFO末项的同一
边沿关闭完整burst；空闲且FIFO为空的末项则直接装载原descriptor寄存器，省去入队
再出队。不是从请求组合直通AXI，也不提前应答；AW/W独立等待，B及所有逻辑应答
退休后才允许后续读。未带end的部分请求仍由有限超时关闭，以支持取消前缀排空。
此优化位于通用write burst client，不读取CNN层号，不新增RAM/DSP或总线接口。
已有`USE_TENSOR_WRITE_END`控制该契约，无新增SoC开关。

同一64×48 packed组合从917,576→891,633拍（-2.83%），比普通写902,900拍快约1.25%；
完整22阶段数值与两路显示通过。AW/W/B=21,918/25,538/21,918，逻辑读写预算不变。
更早发出请求会改变BFM仲裁/后续合并相位，不能用固定的“每事务省两拍”外推所有组合。
还需继续减少读算写串行等待；这不证明原生15 fps、物理Fmax或任意DDR延迟下均加速。

`OVERLAP_COLUMN_WRITEBACK=1`进一步解除窗口层的逐像素写完成等待，默认关闭，要求
列接口和`PIPELINED_RESULT_WRITES`。本像素最后一个结果写请求已被接纳后，若输入/
输出bank不同，adapter开始下一像素列读取和计算；原像素的真实写应答独立退休。
不是引擎结果未握手就覆盖输入，也不是提前确认DDR完成。利用原4位pending计数，
在结果接纳处限制最多15个未退休写，既避免计数溢出，也不撤销已经呈现的写请求。

adapter输出内部`column_allow_pending_writes`授权，SoC仅在没有标量读归属时允许
独立列请求跨越旧写；新标量请求仍不能撞到活动列事务。所有标量读、阶段cache配置、
层切换、任务完成/重新启动保持旧写全部退休的fence。写错误或取消若与列请求/应答
受阻重合，先保留并排空这个列义务，再等待剩余写，不允许仅一条通道结束便返回idle。
输入bank仍要求在整层内不可被CPU/其它DMA修改。

同一64×48 packed组合891,633→778,326拍（-12.71%）；14,813次列请求确实发生在
旧写未退休时，峰值6个逻辑写在途。普通写桥也兼容（本轮另启用流水写），为825,080拍。
两种配置均完成22层/40,128 C8和物理DDR/显示golden，真实stage18读取消恢复及不同
输入双帧也通过。没有新增window缓存或MAC阵列，新增控制的真实资源/Fmax仍待EDA。

```text
Sapphire/APB ── CSR + ISP shadow/commit ── lifecycle/frame manager
                                                │
camera_clk RAW10 ─ async FIFO ─ R1 ISP ─ capture XRGB writer ─┐
                                                               │
DDR parameter arena ─ loader ─ atomic parameter bank ─┐        │
                                                       ▼        ▼
input XRGB reader ─ Resize/C8 ─ MicroStyle bridge ─ 22-stage engine
                                   │                    ▲
                                    └ tensor adapter ────┘
                                      3×8 MiB DDR banks
                                              │
                              optional 3-row C8 window-cache seam
                                 (`ENABLE_TENSOR_WINDOW_CACHE=1`)
                                              │
                                    64→AXI128 tensor bridge
                                              │
output XRGB writer ─ frame pair ─ dual display prefetch ─ 720p/OSD

seven ID-less AXI128 clients ─ round-robin transaction-lock arbiter ─ DDR seam
```

这里的 22-stage engine 是真实 signed-INT8 算术实现，不再是“opaque CNN”。其参数路径不再使用旧 flat-cache 的全局随机选择：128-bit ABI word 先顺序写入可推断 BRAM，每层开始时由多拍 OIHW walker 重排到固定的 64 个 Conv lane bank或 8 个 DW lane bank，再由 dot/DW core 顺序寻址。但当前 tensor adapter 仍是单 outstanding 的顺序 correctness-first 调度器，不是实时 tile accelerator。板前新增的 `model/tensor_perf_model.py`、`model/window_cache_perf_model.py`、独立 `c1_tensor_mem_axi128_packer`、`c1_tensor_mem_path_seam` 和七客户端 arbiter 压力回归分别量化优化方向、验证局部 packing/flush 协议和共享仲裁 forward progress；window cache 现在由显式 `c1_tensor_window_cache_axi_client` 封装并固定接入 portable SoC client-6，默认参数仍是 wire-level bypass。真实 adapter→cache→64-bit BFM、adapter→cache→单拍 AXI128 bridge→BFM、wrapper→client-6→arbiter→AXI BFM，以及当前源码 shape-scaled gate 矩阵 `c1_8x8_gate_20260825`/`c1_16x8_two_gate_20260825`/`c1_64x48_single_gate_20260825`/`c1_64x48_two_gate_20260825` 均已 PASS；这些都不是 640×480 端到端性能证明。

`c1_r1_integration_skeleton` 和 `c1_r1_boardless_frame_system` 继续保留作为较小回归层级；它们不是最终主顶层。

## 2. 模块层次与当前完成度

| 层次 | 已实现的真实功能 | 尚未闭合 |
|---|---|---|
| APB | 主 CSR、ISP CSR mux、PSTRB、PSLVERR、sticky IRQ/W1C | Sapphire 地址映射/PLIC |
| lifecycle | START 快照、参数换代、single-shot/continuous capture admission、3入2出 ownership、NN job、display pair swap、abort/flush | 长时间全系统随机并发 |
| capture | RAW10 CDC、R1 ISP、frame-table lookup、XRGB writer、silent discard/cleanup | MIPI packet/CRC 与真实传感器 |
| frame job | pair/config preflight、descriptor 双 bank、dispatcher、input/output DMA、safe drain | DDR QoS 与长帧压力 |
| CNN engine | 22 descriptor cache；Conv3×3、Conv1×1、DW、upsample、residual、final；128-bit ABI BRAM→逐层多拍 OIHW 重排→固定 Conv/DW lane bank；参数 scheduler/active generation；训练工件的 22 descriptor 已通过 RTL decoder/arena ABI 回归 | 640×480 trained artifact 全层 RTL 对比；负 WNS 关键路径继续流水化；Ti60 资源/时序签核 |
| tensor adapter/cache | 三 bank ping-pong/残差映射；SAME/stride2、window/group/raster；单 outstanding 64-bit req/rsp；三行 all-group C8 cache、注册化 seam、adapter sideband 与 `c1_tensor_window_cache_axi_client` client-6 边界已实现；动态 64-bit、真实 AXI bridge、client-6→arbiter→DDR BFM 及 portable SoC shape-scaled gate 矩阵已完成 | native 长帧的 burst/系统级 packing、多 outstanding、并行供数仍未闭合；native 性能待测 |
| tensor bridge | 64-bit read/write→单拍 AXI128，`addr[3]` 半字选择、WSTRB、RRESP/BRESP/RLAST | 性能合并/队列 |
| display | 原图、风格图、分屏、fail-black 四模式；bit7 OSD；双源 prefetch、720p timing、underflow CDC；首次 pair bootstrap feed 与单源未选中 line-store drain | HDMI/TMDS/PLL 与板上 FIFO 深度 |
| vendor seam | APB、RAW stream、AXI128、RGB/DE/HS/VS | Efinix MIPI/DDR/Sapphire/PLL/显示 IP |

## 3. 数据与控制路径

### 3.1 START 原子快照

软件先写 shadow CSR，再向 `CONTROL.START` 写 1。`c1_apb_csr` 在 busy 时拒绝 START 并返回 `PSLVERR`；`c1_r1_soc_control` 接受 START 后锁存当前 run 的 framebuffer table、width/height、pixel format、descriptor base/count、weight base、`0x098 TENSOR_BASE` 和 continuous/drop 策略。后续 APB 写只影响下一次任务，不能撕裂已启动任务。

参数 active bank 与 stage-config active generation 都采用完整批次成功后切换；失败的 shadow 装载不污染 active。config 允许作为可复用 preload cache 提前提交，因此失败 frame job 可能留下新 generation，但绝不会误 launch，也不承诺 job-level rollback。

### 3.2 Capture、silent discard 与 cleanup

camera seam 假定 vendor 侧已完成 CSI packet 校验和 RAW10 解包，sideband 与像素同 beat：

```text
raw10, x, y, valid/ready, SOF, EOL, EOF
```

capture FIFO 只是 CDC/弹性缓存，不是整帧缓存。single-shot 首帧被接纳后或系统未 armed 时，controller 关闭新帧 admission 并令 frontend 在 idle 状态持续消费 FIFO：无论 FIFO 头是 SOF 还是复位/禁用遗留的半帧，都静默丢弃到 EOF，不产生软件 drop 事件。显式资源不足的 `drop_frame` 才计数；abort、overflow 或输出 FIFO 错误进入 drain/recover，`cleanup_busy` 直到恢复到安全帧边界才释放。

### 3.3 真实 CNN 与 tensor 执行

`c1_r1_microstyle_system_bridge` 将同一份 22-descriptor snapshot 无损送给算术 engine 和 tensor adapter；两者都完成配置前不放行首个 C8 像素。engine 负责 OIHW signed-INT8 MAC、bias、per-channel multiplier/shift、round-away、saturation/ReLU；adapter 负责空间窗口、stride/padding、C8 group、upsample、residual bank 和中间 tensor 地址。

当前三 bank 固定映射避免 residual 被覆盖，默认每 bank 8 MiB：

```text
bank0 = tensor_base + 0 MiB
bank1 = tensor_base + 8 MiB
bank2 = tensor_base + 16 MiB
```

24 MiB 全部位于外部 DDR。software/SoC 合同要求 `tensor_base` 以 8 MiB 对齐并保证三个 bank 不越过 32-bit 空间；adapter 自身另做 8-byte 对齐与地址溢出防线。每个 64-bit read/write 都必须收到一次 response，且仅允许一个请求 outstanding；写请求也有 completion response。该协议便于自检，但不具备 15 fps 吞吐。

当前 engine 专项使用 8×8 定向/合成参数，adapter 专项使用 4×4 的完整 22-stage 小模型；portable SoC 的 shape-scaled 8×8/16×8 BFM 仍使用零参数功能性 arena，两者都没有装入 functional QAT arena 做 trained artifact RTL E2E。该缺口必须保留为 P0。

软件收到 DONE/ERROR terminal IRQ 后也不能立即复用本 job 的 framebuffer、descriptor、parameter 或 tensor 区。abort、display flush 或已提交 AXI transaction 可能仍在安全排空；必须通过 `c1_accel_wait_idle()` 观察 STATUS.BUSY=0 后才允许释放/复用内存。

### 3.4 三行 C8 tensor window cache

adapter 的真实循环是 `output_y -> output_x -> input_group -> 9 taps`。因此 resident row 不能只保存当前 group；完整行按 `x-major/group-minor` 保存所有 groups，索引为 `x * groups + group`。`c1_window_line_cache_c8` 的默认 payload 为三行×1280 words×64 bit，即 245,760 bit，并在 Artix-7 proxy 中推断为 7.5 BRAM tile、288 LUT、203 FF、0 DSP，100 MHz WNS +1.086 ns。

`c1_tensor_window_cache_seam` 位于 adapter 逻辑 req/rsp 与现有 64-bit memory path 之间。只有 Conv3×3/DWConv3×3 tap read 进入 cache；write、1×1、upsample、residual、final、sideband/address 不匹配和容量超限均旁路。注册前端先接受并快照一个上游逻辑请求，再以多拍 shift-add 完成范围和物理地址一致性分类；miss 后保持/重试的是内部 cache tap，不是已握手的上游请求。cache miss 逐 word refill 完整行，命中返回本地响应；所有 direct/refill response 都由注册 owner 路由。输入 tensor 范围内出现 write 后进入 coherence fallback，直到 flush 或下一 stage。加固后 seam 还会等待底层 cache 的配置完成结果：配置被拒绝时以 `CONFIG_REJECT` 禁用本 stage cache；请求已进入路由后若 cache 出现 runtime error，则后续请求安全降级为 direct bypass，而不留下悬空 cache owner。adapter 的仿真断言同时检查 stalled memory request/sideband、stalled stage config、cacheable 分类、WSTRB 和 8-byte 对齐。

abort 是 drain 而不是 cancel：已接受的前端请求、downstream transaction 与逻辑响应先排空；若配置范围计算期间 adapter 已呈现但尚未握手请求，`drain_front` 会在配置完成后接收并完成它，再清 cache/config。完整接口、地址公式、容量 guard 和后续 burst 条件见 `CACHE_INTEGRATION_CONTRACT.md`。portable SoC 默认 `ENABLE_TENSOR_WINDOW_CACHE=0` 仍直通；置 1 后 seam 已位于 adapter 与 bridge 之间，且 `tensor_cache_busy` 纳入软件 `system_busy` quiescence fence。enabled smoke 尚未发动态 tensor 请求，顶层 `flush_req` 也暂绑 0。

最终加固 seam 专项 run `1e6f562adbc34ea383932840b97aa0e4` 完成 17/17 logical req/rsp 与 50 个 downstream transaction，并定向命中 `cfg_rejects=1`、`runtime_fallbacks=1`；route lock 保证未取得 cache owner 的请求固定旁路、已取得 owner 的请求不产生重复 direct transaction。随后 64-bit 动态 run `9212d5a042ae4d9895a3162869e3815f` 让真实 sideband-enabled adapter 的完整 22-stage 4×4/8×4 自检流量穿过 seam/C8 到单 outstanding 64-bit BFM；它保持原 448 个 engine operands/32 个 final beats，得到 2,230/2,230 logical req/rsp、1,493 hit/19 miss、19 row refills/204 words，并把 1,810 个 logical reads 降为 `298 bypass + 204 refill = 502` 个 downstream reads，另完成 420 writes、1 次 memory error 与 5-cycle abort drain。

真实 AXI 动态 run `be4977424d9d484e80340f970d9904d0` 在相同 scoreboard 下继续串入 `c1_tensor_mem_axi128_bridge` 和严格 AXI128 BFM，完成 502/502 AR/R、420/420/420 AW/W/B、上下 lane 462/460、AW-first/W-first/same 318/81/21，并覆盖 AR/AW/W stall 1577/1583/1580、R/B gap 1194/915、B hold 2、error 1 和 abort 5。这里已经是真实单拍 AXI bridge 事务，但仍是小尺寸、单 outstanding；随后显式 client-6 wrapper 回归 `54d6d7ec0b28445f8f80edeb67281c72` 又穿过七客户端 arbiter 与 AXI BFM。当前源码 shape-scaled latest gate 矩阵完成：8×8 `AW/W/B=852/868/852`、`AR/R=1119/2199`；16×8 两帧 `AW/W/B=3376/3472/3376`、`AR/R=4185/5463`、`swaps=2 drops=0`；64×48 单帧 `AW/W/B=40224/41664/40224`、`AR/R=48427/51643`；64×48 两帧 `AW/W/B=80448/83328/80448`、`AR/R=96793/102295`、`swaps=2 drops=0`。tensor adapter 的 64-bit 几何/地址修复后，8×8 与 64×48 两帧又分别由 `c1_8x8_u64fix_gate_20260825`/`c1_64x48_two_u64fix_gate_20260825` 重跑通过；仍需长帧/QoS/性能化。

### 3.5 帧缓冲与显示

输入状态：

```text
FREE → CAPTURING → READY_NN → PROCESSING → READY_DISPLAY → DISPLAY → FREE
```

输出状态：

```text
FREE → PROCESSING → READY_DISPLAY → DISPLAY → FREE
```

采用 3 个输入和 2 个输出，因为 display 必须同时持有原图/风格图 pair，而 capture 与 NN 仍需前进。prefetch 在 core 域可提前运行；pixel 域只在 frame boundary/VSYNC 提交新 pair 的 ownership。没有新完整 pair 时重复当前 pair。首次 pair 尚无 current feed 时，`c1_r1_display_subsystem` 在两行 store primed 后启动 bootstrap feed；在 ORIGINAL/STYLED 单源模式中，未选中的 reader 由同一活动窗口发出 drain 请求，避免其 ping-pong bank 永久占用。core 域 pending pair 预取期间由 `display_hold_requests` 经两级 CDC 门控 pixel 请求，且控制器以 `!prefetch_loading_new_q` 禁止重复启动同一 pending pair；最终两帧回归验证了该 ownership 闭环。可选 display response FIFO（默认关闭）在 reader 与 line-store 之间保存 59-bit `{eof,eol,sof,y,x,rgb}` token；credit-only pre-AR gate 只限制尚未呈现的 burst，并保持 `ARVALID/payload` 稳定，`done/start_ready` 还要等 FIFO 与两组 line-store 排空。单帧 64×48、8×8 两帧和 64×48 两帧均已通过 QoS/ownership 回归，native 640×480 已完成逐像素 FIFO 预检；Vivado proxy 已测得 fifo128 相对 bypass 为 `+494 LUT/+44 FF/+304 LUTRAM`，但 FIFO 资源和 native 长帧 deadline 仍需 Efinity/板卡测量。四个 compositor mode 为：0 风格图居中、1 原图居中、2 左原图/右风格分屏、3 保留模式 fail-black；`DISPLAY_MODE[7]` 独立使能十六进制状态/告警 OSD。

## 4. AXI128 内存结构

`c1_r1_portable_soc` 的七个 client 为：

| client | 方向 | 功能 |
|---:|---|---|
| 0 | R/W | boardless frame job：表/config/input reader/output writer |
| 1 | W | capture XRGB writer |
| 2 | R | parameter loader |
| 3 | R | capture framebuffer-table reader |
| 4 | R | display original prefetch |
| 5 | R | display styled prefetch |
| 6 | R/W | `c1_tensor_window_cache_axi_client`：optional window-cache seam + tensor 64→AXI128 bridge |

仲裁器是 ID-less、按事务锁定的 round-robin baseline。被授权的 burst 必须通过终止 response/RLAST 后才释放 owner；这保证返回路由明确，但当前没有 per-client response FIFO。独立七客户端压力 run `bbaccd1453aa43368eebc4e1f5bdae5a` 已在 56 写+56 读、随机 AW/W/AR/B/R 停顿下观察到每客户端完整配额和读写并行；新增 client-6 wrapper 回归 `54d6d7ec0b28445f8f80edeb67281c72` 又在真实 slot 6→fabric→AXI BFM 上完成 4 次 refill AR、1 次旁路 AR 和 1 次写。顶层 gate 期间控制层在 foreground CNN admission 前等待 display prefetch quiescent，并在 boardless/NN active/request 期间禁止新 display refresh，以规避 display reader held R beat 对 tensor/NN 的头阻塞；可选 response FIFO 现在提供了一个板卡无关的、单帧/两帧已验证的 credit-only 修复路径，但默认仍是 compatibility bypass。由于 gate 不冻结 raster，双 bank line-store 在长 CNN 期间仍可能 underflow；native portable-SoC 长帧尚未把 `display_underflow_event`、FIFO occupancy 和 deadline 纳入 PASS。真实 15 fps 需要 QoS/优先级、burst 和 outstanding 重新设计。

现有 tensor bridge 将每个 64-bit 请求变成一个 `ARLEN/AWLEN=0`、`AxSIZE=4`、INCR 的 16 B AXI beat：地址对齐到 16 B，`addr[3]` 选择低/高 64 bit，写 strobe 映射到对应 8 byte。AW 与 W 可任意先后握手，所有 VALID payload 在 READY 前稳定；非 OKAY response 或读缺 `RLAST` 返回 `mem_rsp_error`。

frame/descriptor/parameter DMA 仍各自遵守 4 KiB、RLAST/WLAST 和 cancel/drain 合同。AXI VALID 一旦呈现不能撤回；取消后必须排空已提交事务，真实 R/B 错误不能被 cancel 掩盖。

### 4.1 共享 read/write owner+epoch fence（2026-08-28）

当前共享 AXI 数据路径仍由 `c1_axi_n_serial_arbiter_128` 负责；本阶段新增的
`c1_axi_shared_owner_epoch_fence` 只提供一个板卡无关的维护/epoch 控制 seam，
不复制或重写 AXI payload mux。arbiter 新增以下只读状态输出：

```text
read_busy / read_quiescent / read_owner
write_busy / write_quiescent / write_owner
```

`c1_axi_shared_owner_epoch_arbiter_128` 还把 `read_admit/write_admit` 与实际
`read_fire/write_fire` 作为显式端口导出，便于 CSR/监控逻辑接入而不依赖层次
探针。

它们直接观察既有事务状态和 owner 寄存器：`*_busy` 表示方向上仍有已选事务
（包括 stalled VALID/response skid），`*_quiescent` 表示该方向可安全换代，
`*_owner` 给出当前锁定的 client。新增输出不改变 round-robin 选择、事务锁定、
VALID 保持或 R/B 路由，因此 legacy named instantiation 仍可省略这些端口。

未来 owner/QoS mux 的推荐接法是：

```text
raw_client_valid[i] &&
    (read_admit || (read_busy && read_owner == i))  -> arbiter.s_arvalid[i]
raw_client_valid[i] &&
    (write_admit || (write_busy && write_owner == i)) -> arbiter.s_awvalid[i]
```

这条规则在维护边沿关闭空闲新 owner，同时保留已经锁定且可能停顿的当前
owner，直到其终止 R/B 完成。fence 在观察到
`read_quiescent && !read_busy && write_quiescent && !write_busy` 后，才发出
`abort_done`/`flush_done` 并递增一次 `current_epoch`；abort 清除 context，
flush 保留 context。`read_fire/write_fire` 是 AR/AW 接受的观测脉冲，违反
admission 且没有既有 busy owner 时只置 sticky `protocol_error`，不会撤回已
呈现的 VALID。

真实 arbiter+fence focused xsim 已通过：

```text
C1_AXI_SHARED_OWNER_EPOCH_FENCE_ARBITER_PASS ar=1 r=1 aw=1 b=1 epoch=2 cycles=23
```

该回归故意在维护边沿保持 stalled 读/写 owner，验证当前 owner 能排空、第二个
idle owner 被阻止，以及 epoch/fence 完成 token 的时序。它只是共享边界协议
证据；默认 `c1_r1_portable_soc`、client-6 和现有 read/write payload mux
尚未接入该 seam，不能据此宣称 native 长帧 QoS 或 15 fps。

在控制 seam 上还有一个可选的真实数据路径封装
`rtl/dma/c1_axi_shared_owner_epoch_arbiter_128.sv`。它实例化现有
`c1_axi_n_serial_arbiter_128`，只在进入 arbiter 前按以下规则屏蔽 client
VALID，并把 AR/AW 下游接受作为 fence 的 fire 观测：

```text
gated_valid[i] = raw_valid[i] &&
                 (admit || (busy && owner == i))
```

因此 abort/flush 边沿不会引入第二个 idle owner，同时已锁定且 stalled 的
owner 仍可完成 W/R/B。2-client shell xsim marker 为
`C1_AXI_SHARED_OWNER_EPOCH_ARBITER_PASS ar=1 r=1 aw=1 b=1 epoch=2 cycles=23`；
100 MHz Artix-7 proxy 为 2-client/no-skid `434 LUT/233 FF/+5.769 ns`，以及
默认 7-client/read-skid `1411 LUT/407 FF/+2.144 ns`。这些是独立 shell 的
结构证据，默认 portable SoC 仍未实例化，真实 Ti60/Efinity、DDR QoS、CNN
长帧与 15 fps 仍待后续接入验证。

### 4.2 Native DMA 读写闭环边界

native 640×480 的板前集成门 `c1_native_dma_loopback_final2_20260825` 使用
真实 table/XRGB read master、read arbiter、XRGB writer 和 write arbiter，把三
个输入 slot 写入三个不重叠的输出 slot，并由 DDR BFM 逐像素回读。writer 与
串行仲裁器之间的 `c1_axi_write_skid_bridge` 是一项可综合的单项 AW/W/B
缓冲；它只负责隔离 READY/VALID、保持 AW→W→B 顺序，不提供 burst packing 或
多 outstanding。仿真台在 BFM 边界另加反相时钟采样 shell，用于消除 xsim
delta-cycle 竞态，不能当作板上数据路径。该闭环证明 DMA/slot/回压组合，不
等于 portable SoC 七客户端、CNN/tensor、display QoS 或 15 fps。

随后 `native_boardless_job_hold_full_20260825` 将 `c1_r1_boardless_frame_system`
接回同一 native 地址图：table/22 descriptor barrier、真实 input/output DMA、
Resize/C8 两侧和外部 CNN echo 完成一帧 `cnn_in/cnn_out=307200/307200`，并由
associative DDR 对 output 逐像素回读。这里的 output writer 仍是 boardless top
的直连 AXI 写口，read side 只有 boardless top 内的单个 ID-less arbiter；它是
job/DMA 集成门，不是七客户端共享 fabric 或真实 CNN 性能门。

紧接着的 `native_fabric_full2_20260825` 将该 640×480 boardless top 作为真实
`c1_axi_n_serial_arbiter_128(CLIENTS=7)` 的 client-0，并在 client-1..6 接入
六个带随机 AW/W/AR 背压与 R/B 延迟的 procedural AXI peer。job 侧完成
`AW/W/B/AR/R=4800/76800/4800/4800/76890` 和 307,200 个 output 像素，六个
peer 均完成写入、B response、读回与 RLAST，最大观测等待为 118 cycles。该
结果闭合的是 native 长帧共享 fabric 的 forward-progress/响应保持风险切片；
peer 仍不是 capture、parameter/tensor、display 或真实 CNN 叶模块，不能替代
portable SoC 七客户端并发、underflow/QoS、Efinix DDR 或 15 fps 验收。

随后 `native_fabric_param_full_20260825` 将 client-1 换成真实
`c1_axi_parameter_loader` + `c1_r1_parameter_bank`，完成 16,896 B arena 的
`AR/R=66/1056`、shadow-bank commit 与三个词读回；client-2..6 保留五个
procedural peer。它证明一个真实只读参数叶能在同一七路 fabric 与 native
boardless job 共存，但仍不是七个 portable-SoC 真实叶模块的并发 QoS 证据。

### 4.3 Native 640×480 boardless job 与 portable 层次门（2026-08-29）

`run_r1_native_boardless_job_xsim_detached.ps1` 的 `-CompileOnly` run
`1fcd542bc74145c186807b22865a6ba1` 已通过 `xvlog+xelab`，marker 为
`C1_R1_NATIVE_BOARDLESS_JOB_ELAB_PASS frame=640x480`。同一 testbench 的完整
xsim run `76927b77e5b14cc998e43951d162bae8` 也通过，marker 为
`C1_R1_NATIVE_BOARDLESS_JOB_PASS`，完成 `stages=22`、
`cnn_in/cnn_out=307200/307200`、`table_ar=2`、`descriptor_ar=22`、
`input_ar/input_r=4800/76800`、`output_aw/output_w/output_b=4800/76800/4800`、
`output_pixels=307200`；随机背压统计为
`ar_stalls=517/r_gaps=115167/aw_stalls=697/w_stalls=5216/b_delays=6691`，
`stage_stalls=3/cnn_in_stalls=224913/cnn_out_stalls=80451`。该 bench 使用
`c1_r1_boardless_frame_system` 和单项外部 CNN echo，因此闭合的是 native
frame-table、descriptor barrier、输入/输出 DMA、ready/valid、AXI response 和
drain 的长帧集成，不是训练 CNN 算术或 DDR3 PHY 性能。

更高层 `run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -Frame 640x480
-CompileOnly` run `09850789d6ba4d2180fa5831cf6f26dc` 已完成 portable SoC
`xvlog+xelab`，marker 为 `C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS frame=640x480`。
这证明当前完整层次的 native 几何/连接性可展开；full portable-SoC 长帧
数据面、真实训练 CNN、DDR3 服务效率、Efinity P&R 与 15 fps 仍需单独签核。
上述 runner 均采用 WMI 失败时的 `CREATE_BREAKAWAY_FROM_JOB` fallback，且
worker 结束后删除 disposable runRoot。

## 5. CSR 地址空间

主 CSR 为 32 bit、byte address；`0x200..0x2ff` 由 APB mux 路由到 ISP shadow/commit block。

| 地址 | 名称 | 说明 |
|---:|---|---|
| `0x000` | ID | `0x43315254` (`C1RT`) |
| `0x004` | VERSION | 当前 RTL 版本 |
| `0x008` | CAPABILITY | 3 input、2 output、APB3 |
| `0x010` | CONTROL | enable、START W1P、abort W1P、continuous、drop-oldest、clear |
| `0x014` | STATUS | idle/busy、done/error、ready buffer count |
| `0x018/01c` | IRQ_ENABLE/STATUS | done/error/drop/swap/underflow；status W1C |
| `0x020/024` | ERROR | 最近 error code/address |
| `0x040..04c` | FRAME TABLES | input/output table 64-bit base |
| `0x050..05c` | FRAME FORMAT | size、stride、XRGB formats |
| `0x080/084` | DESCRIPTOR_BASE | 当前 32-bit AXI 要求高 32 bit 为 0 |
| `0x088` | DESCRIPTOR_COUNT | MicroStyle 固定 22 |
| `0x08c` | STYLE_ID | 软件风格编号 |
| `0x090/094` | WEIGHT_BASE | 16,896 B 参数 arena DDR 地址 |
| `0x098` | TENSOR_BASE | 3×8 MiB 外部 DDR arena 起址，START 快照 |
| `0x0c0` | DISPLAY_MODE | bits[1:0] 四模式，bit7 OSD |
| `0x100/104` | COUNTERS | completed frame、busy cycles |

framebuffer 固定为 little-endian XRGB8888：逻辑字 `0x00RRGGBB`，640 像素最小 stride 2560 B 且 16 B 对齐。模块间 RGB888/C8 stream 不是 DDR 格式。

## 6. 时钟、复位与 vendor 边界

至少存在 `camera_clk`、`core_clk/DDR AXI clk` 与 `pixel_clk`。camera 用 async FIFO 入 core；display line store/prefetch 跨 core/pixel；事件用 toggle/ack CDC；reset 允许异步拉低，但每域同步释放。多 bit job/config 只能通过握手快照，不能逐 bit 两级同步。

便携 RTL不实例化 XPM、RAMB、DSP48、MIG 或 Efinix primitive。RAM 采用同步 read-first wrapper且大存储不整片 reset；乘法用显式 signed 运算交给综合器；ready/valid stall 时 payload/sideband 稳定。厂商替换仅位于 shell：

```text
RAW seam  ← Efinix MIPI CSI-2 + unpack
AXI seam  ← Efinix DDR controller/PHY + clock bridge
APB seam  ← Sapphire + PLIC/BSP
video seam← PLL + HDMI/TMDS/board interface
```

## 7. 验证层次与仍缺闭环

推荐从小到大保留四层：

1. Python/QAT/整数逐层 Golden；性能模型作为请求/周期预算基线；
2. ISP、DMA、CNN 原语、engine、tensor adapter/bridge、capture/display/control 专项；
3. boardless frame job 动态 AXI 回归；
4. portable SoC compile/elaboration/CSR smoke，随后是已完成的 8×8 单帧、16×8 两帧、64×48 单帧/两帧 gate 全链；独立 native 640×480 display prefetch staged preflight `native_prefetch_run2_20260825`、capture-writer staged preflight `c1_native_capture_writer_final_20260825`、真实 capture/table/ISP staged preflight `c1_native_capture_table_paced_full_20260825`、两主机 input-DMA/table/arbiter staged preflight `c1_native_input_dma_full_20260825`、read→write DMA loopback `c1_native_dma_loopback_final2_20260825` 以及 boardless job 全帧 run `76927b77e5b14cc998e43951d162bae8` 也已完成相应地址/读回/CDC/写回/RAW10 stream/read-arbiter/slot/drain 检查；portable SoC native 640×480 目前已通过 compile/elaboration（`09850789d6ba4d2180fa5831cf6f26dc`），但其 output DMA/七客户端/CNN/QoS 长帧数据面仍待补。独立七客户端 arbiter、loopback 或 boardless echo 回归不能替代该系统回归。

当前第 1 层包含两条独立证据：32×32 stored artifact 可 exact replay 22 个整数 stage；6 张 64×64 图片的 QAT checkpoint 与整数模型最终 RGB 最大误差为 0。RTL ABI run `35f1aa0e76ed41d084f40e6637ac331e` 已把训练描述符送入 decoder，并由真实 parameter scheduler 完成 1,030 个注册 arena reads/cache writes；这仍不是逐层算术证据。第 2 层的最终 engine 专项 run `c382d6f1705041d4a7d2e3650799ebce`、adapter 默认/sideband `5cc1f6d0fcd242bf9de7fe48c5418270`/`513714c5626b47e99bc730cf7d3fdf9f`、最终加固 cache seam `1e6f562adbc34ea383932840b97aa0e4`、64-bit/真实 AXI 动态链 `9212d5a042ae4d9895a3162869e3815f`/`be4977424d9d484e80340f970d9904d0`、显式 client-6 wrapper `54d6d7ec0b28445f8f80edeb67281c72` 与 bridge/capture/display/control 专项均 PASS；第 3 层在 external loopback 时代已有严格事务回归；第 4 层新增当前源码默认/缓存启用 smoke `7e76332ea7044371af9efcf39809258a`/`30658446f3d4442fb7f7a442bd5f9fe2`，以及当前源码 shape-scaled gate 矩阵 `c1_8x8_gate_20260825`（8×8）、`c1_16x8_two_gate_20260825`（16×8 两帧）、`c1_64x48_single_gate_20260825`（64×48 单帧）和 `c1_64x48_two_gate_20260825`（64×48 两帧）（22/44 descriptors、display done、真实七客户端 DDR、`swaps=2 drops=0`）；native 640×480 `c1_640x480_final_elab_20260825` 也已通过 compile/elaboration，独立 display preflight `native_prefetch_run2_20260825` 完成双路 307,200 像素/路、4,800 AR、76,800 R beat 和 `underflow=0/0`，独立 capture-writer preflight `c1_native_capture_writer_final_20260825` 完成三 slot、921,600 像素读回和 `AW/W/B=14400/230400/14400`，真实 capture/table/ISP preflight `c1_native_capture_table_paced_full_20260825` 又完成三帧 RAW10→RGB stream `pixels/sof/eol/eof=921600/3/1440/3` 与 Gamma/table/writer 检查，两主机 input-DMA/table/arbiter preflight `c1_native_input_dma_full_20260825` 完成三 slot `frame_pixels=921600` 和 shared `AR/R=14403/230403`；这些仍未覆盖 portable SoC output DMA/boardless job/七客户端/CNN/QoS。独立七客户端 arbiter run `bbaccd1453aa43368eebc4e1f5bdae5a` 与 cache fabric BFM `75ac975f5ec049a6b579e00c14dd41d0` 仍只覆盖共享边界；下一缺口是 trained artifact 驱动的 engine+adapter 逐层/端到端 RTL 对比、native input/output DMA/CNN 长帧并发、性能优化后的周期证明，以及 Efinity/Ti60/实体板签核。

所有 Vivado/xsim 任务使用 WMI 隐藏 worker 脱离当前 Windows Job；PASS 必须同时满足退出码、空 stderr、无 Fatal/Error/FAIL 和唯一 marker。不得用文件摘要代替像素/张量内容比较。

最新 native loopback 已补上“input read→output write”这一块此前缺失的集成证据；剩余缺口收窄为把它接入 boardless job/portable SoC 七客户端 fabric，并在真实 CNN/tensor/display 同时争用时测量长帧 QoS、abort/drain、underflow 和周期预算。

该缺口的第一半已经由 `native_boardless_job_hold_full_20260825` 完成，并由最新
detached run `76927b77e5b14cc998e43951d162bae8` 复核：真实 boardless frontend、
descriptor/table、input/output DMA 和外部 CNN echo 已在 640×480 运行；因此当前
主线缺口明确是 portable SoC 七客户端 fabric、真实 engine/tensor traffic 与
display/QoS 的并发，而不是单独 DMA 地址图。portable SoC 640×480 当前先闭合
compile/elaboration（`09850789d6ba4d2180fa5831cf6f26dc`），尚未宣称其长帧
数据面动态完成。

因此第 7 节中早先把 “native output DMA/boardless job” 列为待补的句子只保留为
历史分层说明；当前源码的 native boardless job 已有动态 PASS，尚未完成的是把
它与 portable SoC 的七客户端、capture、tensor/CNN 和 display traffic 合并。

同理，`native_fabric_full2_20260825` 已经把 boardless job 放入真实七路
仲裁器，但 client-1..6 仍为 procedural traffic。当前剩余闭环是以真实
portable-SoC client 叶模块替换这些 peer，并在同一 native BFM 中加入每客户端
等待、display underflow、abort/drain、帧 deadline 和 tensor/engine 周期门。

portable SoC 64×48 的 bind-only client monitor 已先把该风险量化：所有必需
方向均有握手，但 styled-display client-5 的连续 AR 等待达到 1,243,738
cycles，超过一百万 cycle 诊断门。该结果说明 ID-less `RD_DATA` owner 在
某个 leaf 长时间不接收 R 时会拖住其他 display 请求。随后 protocol-safe
response FIFO 的单帧 run 将 c4/c5 wait 降到 76/83、response hold 降到 2/2，
credit-only 版本在 8×8 两帧保持 `swaps=2 drops=0`；仍需在 native
portable-SoC 长帧中加入 underflow/deadline/occupancy 门，并完成 Efinity
资源与时序签核，而不是只放宽 watchdog。

本阶段的最大行 profile 已把只读 cache-refill seam 推到 `1280` logical words
和 `BURST_BEATS=32`，同时保留 ID-less 顺序与维护边界；它仍不改变上述
single-outstanding tensor adapter。任何性能接入都必须先满足统一 epoch/owner、
generation、flush/abort drain 和 read/write response credit 合同，具体审计见
[`TENSOR_CLIENT_INTEGRATION_AUDIT.md`](TENSOR_CLIENT_INTEGRATION_AUDIT.md)。

### 当前只读 cache-refill scheduler 边界（2026-08-27）

新增的 `c1_cache_refill_scheduler_read_client` 是一条独立的 boardless
composition：scheduler 负责 row command、logical-word metadata/epoch、
MAX_OUTSTANDING credit 和维护 fence；AXI128 reader 负责 request FIFO、pack2、
4-KiB-safe burst、AXI R 顺序和 response FIFO。两者之间只通过 ready/valid
以及 `leaf_req_occupancy`/`leaf_quiescent`/`leaf_req_flush` 连接，不引入
Efinix primitive，也不改 default SoC。

维护时 current word 先完成 handshake，随后才进入新 epoch；已接受的旧响应
可经 `drain_word_*` 排水。这里“尚需 cancellation-token/completion adapter”
属于 2026-08-27 historical snapshot；2026-08-28 已由 exact-count adapter
和 optional exact shell 补齐 line-cache 声明但尚未发出的 word。该边界仍不
改变默认 SoC：在 owner mux/真实 DDR QoS 完成前，scheduler proxy 的资源和
小 TB 周期都不作为整网或 15 fps 结论。

### exact-count refill ABI bridge（2026-08-27）

为接入现有 `c1_window_line_cache_c8` 的严格计数协议，当前推荐边界为：

```text
line-cache refill_req (row/count/base/epoch)
             │
             ▼
c1_cache_refill_completion_adapter
  normal word + accepted stale drain → one exact-count refill stream
  unissued suffix after fence         → zero/error poison
             │
             ▼
c1_cache_refill_scheduler_read_client_exact
  scheduler(epoch/credit/fence) → AXI128 read client(pack2/burst/R FIFO)
```

适配器只有在 declared word count 和 scheduler terminal token（`cmd_done`、
`abort_done` 或 `flush_done`）均到达后才报告 `refill_done`/释放下一命令。
这避免 late `cmd_done` 误作用于下一行，但会保留一个 correctness-first 的
行间 bubble；上层不能把 `refill_done` 当作 AXI 带宽提升。三个 token 必须
真实连线，不能绑 0。`word_count=0` 是错误诊断路径，line-cache 接线必须
保证 count 非零。

zero/error suffix 只用于让 line-cache 在取消后完成计数并触发 discard；它
不包含有效 tensor 数据。因而正常提交路径仍需确保所有 declared words 都
由当前 epoch 的 AXI response 提供，且必须在 shared read/write owner+epoch
mux 处阻止旧响应越过边界。当前 exact composition 仍是 boardless optional
seam，default SoC 和 legacy client-6 不变。

板上若发现 `refill_word_ready→scheduler→reader RREADY` 组合反压路径过长，
可在该边界加入一深度 skid，但必须连同 normal/drain 标志、row/index/epoch、
error/last 一并缓存；只延迟 data 而不延迟 sideband 会破坏 exact-count 合同。

### 真实 line-cache exact shell（2026-08-28）

当前 boardless 接线实现为

```text
stage_base + group_start
        │  (atomic capture)
        ▼
c1_window_line_cache_c8
  refill_req(row,count)
        │
        ▼
command hold: base = stage_base + row*(width*groups*8), stride = 8,
              row/count/epoch latched
        │
        ▼
c1_cache_refill_scheduler_read_client_exact
        │  exact normal/drain/poison stream
        ▼
REFILL_SKID_DEPTH=2 registered FIFO
        │
        ▼
line-cache refill_word(data,error,last)
```

`abort_req`/`flush_req` 同时送入 cache 与 exact seam；shell 的双路 done join
只在两边都完成 drain 后对外产生完成脉冲。command hold 防止 fence 改变已呈现
命令的 epoch，skid FIFO 的输入 ready 只依赖 occupancy，从而切断 cache 输出
ready 直达 AXI `RREADY` 的组合路径。FIFO 内部仍保留 row/index/epoch sideband，
即使 line-cache 只消费 data/error/last，也不会丢失 adapter 的协议校验信息。

小型 xsim 已覆盖正常行、取消行和新 epoch 重试；Artix-7 proxy 的真实 shell
在 `REFILL_SKID_DEPTH=2` 时为 `35639 LUT / 11930 FF / 7.5 BRAM / 0 DSP /
WNS +0.302 ns / TNS 0`，无 skid 对照为 `35543 LUT / 11923 FF / WNS -1.622 ns`。
这证明该 FIFO 是时序收敛措施，不是吞吐或资源优化；默认 SoC、读写 owner mux
和 Ti60/Efinity 实现仍保持隔离。已接受的 AXI 请求必须最终得到 AR/R 服务，
否则 exact drain 会有意保持反压。

### 共享 AXI QoS 观测边界（2026-08-28）

`c1_axi_shared_qos_monitor` 位于真实 serial arbiter 的 client-side 向量旁路，
只读采样，不插入 payload mux：

```text
client VALID/READY ───────┐
arbiter busy/quiescent ───┼──► c1_axi_shared_qos_monitor
arbiter owner ────────────┤       │
display underflow ────────┤       ├─ AW/AR wait + W/R/B stall
boardless start ──────────┤       ├─ per-client accepted counts
tagged new-pair prefetch ──┘       ├─ owner hold total/max+ID
                                  ├─ frame cycles/deadline miss
                                  └─ underflow/protocol/overflow
```

顶层用 `ENABLE_SHARED_QOS_MONITOR` 选择 generate 分支，默认 0；启用时
`csr_clear_stats_pulse` 是同步清零控制。帧计时从 accepted boardless start 开始，
以 `display_prefetch_new_done_event` 结束，刻意覆盖对应新 pair 的显示 R/FIFO/
line-store 排空；raw `display_prefetch_done` 还可能来自 current-pair 后台刷新，
不能直接作为跨帧 terminal。这比使用较早的 `control_done_event` 更能反映端到端
frame deadline。选定 aggregate 已成为 APB `0x108..0x12c` 只读 ABI，per-client
向量仍为层次化 diagnostic signals；`display_swap_event` 是独立的 VSYNC
ownership commit，当前可早于 tagged done，不能与 QoS terminal 混用。

实现采用 24-bit 饱和统计；仅 global owner-max 采用标量 max+owner-id，以切断
其变量索引 max-array 写回，per-client owner totals 仍保留索引更新；
Artix-7 100 MHz 独立 proxy 为 `2268 LUT / 4000 FF / WNS +1.465 ns`。在真实
8×8 native BFM 的 tagged two-frame 回归观察到
`start=2/raw_done=3/new_done=2/swap=2`；aggregate 窗口为
`last_frame_cycles=3446518`、`deadline_miss=2`、`underflow=2`，且 client-4 R
hold 约 `5.34 M` cycles，明确指出原始 ID-less display HOL。该观测边界仍不执行
owner/epoch admission，不能被解读为 QoS 修复或 15 fps 签核；下一层才是在同一
monitor 上比较 response-FIFO 和 owner-fence shell。

### Native 640×480 boardless gate（2026-08-29）

`c1_r1_boardless_frame_system` 已用 detached Vivado/xsim 完成一次完整
640×480 任务：22 个 descriptor、307200 个 C8 输入/输出 beat、4800 个输入
与输出 burst、76,800 个读/写数据 beat 均完成，AXI 背压、R gap、B delay、
CNN ready/valid stall 和 terminal drain 均通过。该 gate 证明 frame-job、DMA、
resize/C8 seam 在 native 几何下可闭合；CNN 端仍是外部 echo 模型，所以不把它
当作真实训练网络的周期或 15 fps 证据。完整 `c1_r1_portable_soc` 的 640×480
`xvlog+xelab` 也已通过，下一阶段可以在已有层次上替换真实训练 CNN/DDR BFM，
而不必再修改 frame-table 或 native DMA 地址合同。
