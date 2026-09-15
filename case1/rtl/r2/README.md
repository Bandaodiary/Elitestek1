# R2：CNN执行架构可行性原型

最新完整候选为[C31](../../review/R2_RGB2_HOST_INTEGRATION_20260914.md)：`c1_r2_rgb2_host_system` → `c1_r2_video_rgb2_system`，整合C30双像素raster、`c1_r2_camera_decimated_ingress`与overlap Resize，计算核心仍为C29 `c1_r2_cnn_capacity_engine`。45生产源、43,152 XLR/145 RAM/130 DSP；小图/定向PNR及修复后的原生六次功能闭环，AW2下约14.10171fps，15fps/真实平台/板测未闭环。独立[C32](../../review/R2_CUTTHROUGH_WRITER_20260914.md)虽通过写回数据测试，但实测共享W队首阻塞，未替换当前写回器。以下各阶段“当前/尚未接入”是历史说明，旧闭包全部保留。

本目录与原`rtl/cnn`、portable_soc执行路径隔离；没有替换默认整机，未接实际CPU/DDR IP。

新增[C30前端](../../review/R2_DEMO_RGB2_INGRESS_20260914.md)：`c1_r2_rgb2_raster_source`→`c1_r2_camera_pair_ingress`→`c1_r2_resize_overlap_capture`，内含独立overlap pipeline/system，其余计算/AXI模块复用。49位FIFO单位是像素对记录，选512深度；完整1080p双像素视频流峰404，两帧逐数据正确。官方五个Debayer文件实际参与Icarus/xsim；前端MAP 20 RAM/18 DSP。该入口仍是独立前端，未替代下面的C29完整主机；无新PNR/板测/整网fps证明。

当前联合候选[C29](../../review/R2_CAMERA_CAPACITY_20260914.md)是`c1_r2_camera_capacity_host_system`→`c1_r2_video_camera_capacity_system`。新执行器为`c1_r2_cnn_capacity_engine`，勿与保留C21的`c1_r2_cnn_compact_engine`混用；C28的入口/FIFO/快照guarded模块保持原样。量化饱和前中间记录缩至10位，窗口row1/2改64位bank，完整参数精度、5级流水和已测周期不变。整机回归/xsim/定向CDC/PNR门禁通过，42,777 XLR/144 RAM/130 DSP、核心150MHz级+0.650/+0.026ns。粗加官方平台只余662 XLR/7 RAM，未完成双像素实际接口、全量CDC、板测或C29原生fps证明。

保留[C28](../../review/R2_CAMERA_CDC_HARDENING_20260913.md)的safe主机与43,749 XLR/148 RAM/130 DSP结果；本轮没有覆盖其生产源。

保留联合基线C26是`c1_r2_camera_host_system`→`c1_r2_video_camera_system`，把下述C25前端实际接到C24/C22主机。
相机最终结果接lease完成，坏帧/未接纳帧分别排空或只记错误；81位快照和只读APB相机页已加入。
44源MAP为148 RAM/130 DSP；小图全链路及故障恢复通过。C26原生六帧已独立完成，150MHz/既定DDR模型最慢约15.31588fps；物理CDC/板测仍未闭合，此帧率不能向C29/C30继承。
详见[C26报告](../../review/R2_CAMERA_HOST_INTEGRATION_20260913.md)。下面C25“尚未接完整主机”是历史状态，已由C26接通。

后续[C27审计](../../review/R2_CAMERA_PHYSICAL_CDC_20260913.md)已取得同功能探针43,577 XLR/148 RAM/130 DSP、150MHz级+0.365/+0.026ns结果；不是CDC签核。发现Gray同步链被重定时到组合解码前及enable/cancel组合入同步器，保护原型已验证，生产FIFO仍冻结以保留C26长仿真证据。

C25新增前端`c1_r2_camera_ingress`/`c1_r2_async_pixel_fifo`，与C24实际Resize/Capture验证了不可回压RGB的
固定ROI、双时钟RAM、源尾部错误、整帧跳过、取消/排空及下一SOF恢复。前端最终结果区分是否接纳过下游任务；
完整帧池只能用该最终完成发布READY，不能直接使用内部Capture done。当前还未接完整CNN主机，主机入口仍为C24。
完整1080p源两帧测试及资源见[相机入口报告](../../review/R2_CAMERA_INGRESS_20260913.md)，512与256容量均2 RAM。
现工程仅MAP/数字CDC仿真，Gray/bundled-data物理约束未签核；不要将前端探针当作整机工程下载。

C24最新联合候选`c1_r2_resize_host_system`，以`efinity/c1_ti60_r2_resize_host96.xml`选择41个生产源。
`c1_r2_video_resize_system`预约帧池时锁存源尺寸/Q16配置；`c1_r2_resize_capture_rgbx32`统一拥有C23 Resize
和原Capture写入器，取消/源错误停止输入但等待真实B排空，失败帧不交CNN/显示。CNN计算仍为C22。
实际联合43,665 XLR/146 RAM/130 DSP，150MHz +0.387/+0.026ns；数值/错误恢复/xsim/PNR结果与接口合同见
[Resize联合报告](../../review/R2_RESIZE_HOST_INTEGRATION_20260913.md)。源必须可回压；未接CSI/ROI/CDC/实际CPU寄存器，
不能将资源探针当板级下载工程或声称C24原生15fps。以下保留C23/C22阶段记录，C24已完成Resize/Capture接入。

C23新增独立外围`c1_r2_resize_pair_ram`/`c1_r2_resize_line_sampler`/`c1_r2_resize_pipeline`，
利用双线性相邻/重合坐标使行缓存20→12 RAM。原R1保留；新sampler不支持任意两点，但完整pipeline配置集合不变。
完整1080行输入golden、旧新逐拍对照、取消恢复、xsim/PNR已通过，见[Resize报告](../../review/R2_RESIZE_BANKED_20260913.md)。
尚未接入C22 Capture，不要把Resize资源探针当作新host工程；当前CNN/主机仍是下述C22。

最新C22主线候选`c1_r2_overlay_host_system`，用`efinity/c1_ti60_r2_overlay_host96.xml`的34源闭包。
PW/残差与空间行0复用16KiB物理RAM，切换后被覆盖视图须重填，不能同时预装两套特征；空间行1/2保持独立。
Ti60 I3：41,252 XLR/134 RAM/112 DSP、150MHz +0.349/+0.026ns；完整算子/主机/恢复/xsim及PNR通过，
见[共享特征存储](../../review/R2_FEATURE_OVERLAY_20260913.md)、`r2_c22_gate_20260913_b.log`。原生六帧独立在途。
C21及之前源码保留；下方按各阶段记录，不要全目录加源。

最新C21主线候选`c1_r2_compact_host_system`已将C20六路权重接入三类lane feeder和完整生成计划/主机系统。
请使用`efinity/c1_ti60_r2_compact_host96.xml`选取33源闭包，不要全目录加源。原R1/C18文件保留。
最终41,620 XLR/150 RAM/112 DSP、150MHz +0.586/+0.027ns；374算子、原/变体主机golden、故障恢复和xsim通过，
见[紧凑主机集成](../../review/R2_COMPACT_HOST_INTEGRATION_20260913.md)。C21原生在途；C18自身原生已收口15.3145fps。
旧bulk引擎残差8192标量末批限制只在C21修复；旧备用源没有被回写修补。

C20独立`c1_r2_weight_store6.sv`/`c1_r2_weight_asym_ram.sv`通过单元Icarus/xsim与Ti60 PNR，六份表混合位宽
使权重RAM64→42。它不是`weight_store8`的读侧即插即用替代，尚未加入C18源闭包；需要把各feeder改为六路lane地址。
平台RAM仍十分紧张，见[容量审计与存储实现](../../review/R2_WEIGHT_MEMORY_BUDGET_20260913.md)。
`c1_r2_weight_pair_ram.sv`/`c1_r2_weight_store8_tdp.sv`为REJECTED实验，不可加入生产工程。

最新C19对C18生产RTL零改动，补齐13个实际SLVERR场景、失败结果隔离与无复位恢复，含同一CNN两笔B债务。
39成功/13预期失败，xsim跨模拟器复核一致；见[主机错误恢复](../../review/R2_HOST_ERROR_RECOVERY_20260913.md)。
不新增一套C19生产顶层/PNR，也不宣称恶意协议错误后的系统复位、板测或新的原生FPS。

最新C18入口`c1_r2_planned_host_system`经`c1_r2_video_planned_system`、`c1_r2_planned_rgbx_axi_graph`
将C16执行器/C17包接到完整主机、视频和AXI；所有旧生产RTL保留。原22项和18项结构试验各24次CNN、
RAM负对照8次、窄访问256任务、小图六帧xsim及联合PNR通过，原图周期/流量/调度与C15一致。
46,531 XLR/172 RAM/112 DSP，150MHz setup/hold +0.536/+0.028ns；见[C18报告](../../review/R2_PLANNED_HOST_INTEGRATION_20260913.md)。
仅C18自身640×480六帧还在运行，未取得该版本FPS，未包含CPU IP/PHY/CDC/板卡接口。

C17以配套生成的`execution_plan.sv`＋参数镜像运行同一个C16行执行器；22项/18项图的实际RAM数值、
故障/复位/配套负对照与xsim通过，18项核级38,660 XLR/160 RAM/112 DSP，150MHz setup/hold +0.737/+0.026ns。
见[绑定参数包与实际变体](../../review/R2_BOUND_PLAN_PACKAGE_20260913.md)。18项变体未重训/验证质量，不替代比赛模型；
C15默认候选未切换，新独立完整host见C18。每次编译只选一份`c1_r2_microstyle_plan`模块，不能同时加入静态表和包内表。

新增C16独立核心`c1_r2_planned_pingpong_graph.sv`，使用Python显式算子/DAG生成的`c1_r2_microstyle_plan.sv`，
移除固定层号的行为分支；原C8～C15不覆盖。当前22项图的数值/故障/复位、xsim及150MHz实现通过，
资源38,846 XLR/160 RAM/112 DSP，setup/hold +0.615/+0.065ns。C16时18项变体只规划，后续实际执行见C17；尚未接入host/原生FPS。
见[生成式执行计划](../../review/R2_GENERATED_EXECUTION_PLAN_20260913.md)及`r2_c16_gate_20260913_c.log`。

新增C15生产封装`c1_r2_host_video_system.sv`，组合原CPU适配器、C14和新`c1_r2_host_control_bridge.sv`。
16位APB3本地窗口/R2H1只读诊断/标量IRQ，详见[主机联合记录](../../review/R2_HOST_INTEGRATION_20260913.md)。
实际host/fabric窄访存（视频关闭）、多尺寸CNN及小图xsim通过；`c1_ti60_r2_host_video96`为
45,817 XLR/172 RAM/112 DSP，150MHz setup/hold +0.263/+0.026ns。C15原生六帧现已完成，未验证真实CPU/CDC。
C12/C13/C14/C15各自六帧已完成，四个全负载间隔最慢均15.3145fps@150MHz，
最新`r2_c15_native_gate_20260913_a.log`确认C15六次均选最新完成帧；不能移用为C16/C17/C18性能，也不是板测。后文早期记录保留历史条件。

新增C14独立`c1_r2_video_fresh_leases.sv`/`c1_r2_video_fresh_system.sv`，
只修正有替代READY时应保留最新输入的回收策略，见[调度修复记录](../../review/R2_FRESH_INPUT_SCHEDULING_20260913.md)。
与原CPU适配层联合，数值golden不变；专项、多尺寸及小图xsim通过。
`c1_ti60_r2_fresh_video96`：45,937 XLR/172 RAM/112 DSP，150MHz setup/hold +0.210/+0.026ns。
独立原生六帧和新鲜度轨迹已通过，不覆盖C12/C13；当前只剩C15原生仍在原进程运行。

新增C13 CPU接口候选`c1_r2_cpu_axi_adapter.sv`，见[接口合同和验证](../../review/R2_CPU_AXI_ADAPTER_20260913.md)。
完整ID恢复，读写各一笔在途；128位数据、对齐INCR SIZE0～4，明确拒绝独占/非零REGION等未支持行为。
适配模块及与C12的六帧小图联合验证、核心150MHz物理实现通过；实际Sapphire/BSP/窄访存全系统验证仍待完成。
独立资源入口`c1_ti60_r2_cpu_video96`：45,842 XLR、172 RAM、112 DSP；C13原生六帧已独立通过，实际CPU未执行。

当前 R2-C12：[RGBX32与连续帧池](../../review/R2_RGBX_BUFFER_PIPELINE_20260913.md)。
入口`c1_r2_video_rgbx_system.sv`：新R2V2控制器、四原图/三结果所有权、真实RGB采集和双图显示，
通过保留C10 fabric与CNN共享DDR。`c1_r2_microstyle_rgbx_axi_graph.sv`只在输入/输出RGB槽
使用`c1_r2_rgbx_row_read/write.sv`转换，内部P2C8特征、C8计算/预取/双缓冲和96MAC阵列不变。
Ti60 I3固定640×480核心150MHz map+PNR通过：45,517 XLR、172 RAM、112 DSP；非整板资源/时序。
R2V2 ID为`0x52325632`，不要混用C11/R1帧存储或软件ABI。原生三次CNN＋30fps采集＋720p60双图
联合仿真已通过，最后完成间隔15.42fps@150MHz；六帧连续验证进行中，非板测帧率。
C11 `c1_r2_video_cnn_system.sv`及更早版本保留，C11全负载最终完成间隔9.63fps，未达标。

此前 R2-C10：[APB 控制与共享 AXI 系统](../../review/R2_SHARED_AXI_SYSTEM_20260913.md)。
入口 `c1_r2_shared_subsystem.sv`，复用 C9 图核；新增 `c1_r2_apb_job_control.sv` 和
`c1_r2_axi_fabric.sv`，外部三个规范化128位/ID0 AXI主口。已通过竞争流量原生仿真，
9,814,854拍 / 15.28fps@150MHz；不是实际视频外设或板测。新 ABI/软件驱动和 lease
合同见阶段报告。C10仿真入口 `run_r2_shared_system_probe.py`，Efinity `shared_system96`；
不要与 C2 的 `run_r2_shared_probe.py` / `shared96` 算术原型混淆。
首轮证据见[阶段报告](../../review/R2_ARRAY_FEASIBILITY_20260913.md)。
新增R2-B：[真实双bank供数与量化闭环](../../review/R2_PW_TILE_FEASIBILITY_20260913.md)。
新增R2-C1：[3×3 RGB末层窗口与跨拍归约](../../review/R2_RGB_ROW_FEASIBILITY_20260913.md)。
此前R2-C9：[AXI行DMA与完整图核](../../review/R2_AXI_ROW_DMA_20260913.md)。
入口`c1_r2_microstyle_axi_graph.sv`复用下述C8，新增`c1_r2_axi_row_read/write.sv`。
128位、默认16拍burst/4笔同ID在途，4KiB拆分，AW/W独立握手和全部B响应后完成。
协议错误锁定后仍本地拒绝/排空未交给DMA的writer页；普通RESP错误排空后可无reset恢复。
DMA30配置/828行用例通过，最终Ti60核级150MHz：40,015 XLR/160 RAM/112 DSP，
setup/hold=+0.732/+0.089ns。完整原生AXI仿真通过22节点/21,043,200有效标量对应结果，
9,297,258拍，150MHz折算16.13fps（共享1.2GB/s＋每物理burst延迟20拍）。读写实际峰值均4笔，
全部89,400个B返回后才完成；完整矩阵34正常/恢复帧、18错误帧通过，非已集成CPU/DDR/视频。

此前R2-C8：[双缓冲writer与计算/写回重叠](../../review/R2_PINGPONG_WRITE_OVERLAP_20260913.md)。
新入口`c1_r2_microstyle_pingpong_graph.sv`＋`c1_r2_tensor_pingpong_writer.sv`，复用C7
bulk loader/operator及此前唯一96-MAC、六路量化。两页结果RAM和实际RTL预取优先控制
把写回放到计算期间；最多两页已保留不代表已有两个AXI outstanding。
完整640×480、22节点实际层间交接与golden已通过：共享1.2GB/s、逻辑命令延迟20拍，
实测9,289,054拍，150MHz折算16.15fps，非整机/板测。核级Efinity150MHz为38,819XLR、
160RAM、112DSP，setup/hold为+0.540/+0.031ns。下一步实际AXI/CPU/DDR/视频集成。
P2C8及参数映像仍为新内部布局；行描述符不是AXI burst，窄命令仅用于参数。
C7及此前入口保持不变，见[原C7报告](../../review/R2_STREAM_REFILL_CACHE_OVERLAP_20260913.md)。

此前R2-C5：[encoder与虚拟上采样算子核](../../review/R2_ENCODER_VIRTUAL_UP2_20260913.md)，
入口`c1_r2_cnn_operator_engine.sv`。两层stride2 encoder、通用PW、RGB/DW、虚拟
最近邻2×DW及残差共用计算阵列和参数/特征RAM。187作业×连续/背压验证通过，
但各层输入仍由Python提供；图调度、统一张量写回、DMA和最终显示格式转换待完成。
Ti60核级150MHz map+PNR通过：33,476XLR、128RAM、108DSP；不是板级时序签核。

下文为各历史入口说明；新增图接口见C6报告，算子接口见C5报告，不能混用各入口的限制。
此前R2-C2：[共享执行器](../../review/R2_SHARED_ENGINE_20260913.md)，入口
`c1_r2_shared_row_engine.sv`；旧独立PW/RGB顶层保留作参考。

- `c1_r2_dot16_array.sv`：6/8行×16路INT8乘积。每行独立激活/权重，可把输出行映射
  为不同像素/输出通道。一个事务的各beat顺序累加，first加载bias，last输出signed32
  模2^32结果；无需独立START拍。产品、两两归约到16项和、累加/结果均有寄存器切分。
- `c1_r2_array_host_probe.sv`：仅用于资源评估的窄主机装载/观察壳。32-bit写地址0～31
  装载各行A，32～63装载B，64～71装载bias；6行时未实现的行地址忽略。
  每行四个32-bit字，低字为较低的term。`result_row`选择一行32-bit结果。

输入布局：`in_a/in_b[(row*16+term)*8+:8]`，`in_bias[row*32+:32]`，输出同样row-major。
一个事务中first仅在首beat、last仅在末beat；mask/tag在事务内保持一致，最后输出
mask为0的行数据为0。支持单beat first+last以及相邻事务无空拍输入，不支持交错多个
尚未结束的累加上下文。输出受阻时全算术/元数据冻结；输入方必须遵守ready/valid保持。
从输入接收沿到输出有效，空流水、无阻塞时经过5个时钟间隔；稳态可每拍接收一个beat。

资源壳的load与issue是两个测试接口：被阻塞的issue尚未接收时不能修改其操作数或
配置；result_ready只能在主机读完所需行后拉高。独立加载寄存器用于防止常量裁剪，
**不是可每拍供给整个阵列的tile SRAM证明**。其TAG_BITS=8，直接MAC测试为16。

R2-B已经实现固定16→8通道1×1层的双bank特征RAM、无气泡调度与六路量化连接。
R2-C1进一步实现固定Cin8/Cout3的3×3窗口与五拍归约，但仍是独立代表层原型。
尚未实现：通用tile SRAM banking、DW供数、burst DMA、重叠load/compute/store、
跨层融合、残差线性路径、任务取消/CPU接口。局部reset只清计算流水，
不能取消已被外部AXI接纳的事务。旧量化/错误排空协议必须在正式集成时接回。

复现（Icarus与Python路径按本机安装）：

```powershell
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B case1/golden/run_r2_array_probe.py
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B case1/golden/r2_architecture_budget.py
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B case1/golden/r2_architecture_budget.py --requant-lanes 4
./case1/scripts/run_efinity_ti60_resource_map_detached.ps1 -DesignName c1_ti60_r2_array96 -RunId my_r2_96 -ProjectInPlace -RunPnr -TimeoutSeconds 600
```

EDA只能调用既有外层运行器，不能直接运行Worker。命令必须使用新的RunId；本地临时
映像/向量及EDA数据库结束后清理。受限环境如果拒绝临时目录访问，需要对定向测试
取得相应执行许可，不修改整个目录树的ACL。

## R2-B pointwise tile接口

`c1_r2_pw16x8_tile.sv`默认容量1024像素，每像素16个signed8输入；8个输出通道。
奇偶像素分bank，每bank四个32-bit同步RAM切片；特征不按六路复制。
一次作业只需1～1024个连续HWC像素，不依赖行宽；这里不处理空间卷积。

装载接口为`load_valid/ready`、`load_kind`、`load_addr`、`load_data[31:0]`：

| kind | addr | data |
|---|---|---|
| 0 | pixel×4+word，word=0..3 | 4个signed8特征，低通道放低字节 |
| 1 | output_channel×4+word | 对应通道4个signed8权重，OI顺序 |
| 2 | output_channel=0..7 | signed32 bias |
| 3 | output_channel=0..7 | bit24 ReLU；23:18 shift(0..47)；17:0 signed multiplier；31:25必须0 |

所有作业使用的特征与8组参数须先初始化；未初始化数据没有默认值。
`start_valid/ready`接纳时锁存`pixel_count`。0或超过容量的长度在硬件上不接纳。
`busy`覆盖RAM发射、MAC、量化和最终输出握手；期间禁止参数/特征重装载，
`load_ready=0`。start_valid优先于装载，即使其长度无效也会阻止load；调用者须撤销
无效start，不应等待它永久变ready。连续作业可改全部权重/量化配置，无需复位。

输出为六路signed8数据、6-bit有效mask、flattened scalar `out_base`和`out_last`；
第r路对应scalar out_base+r，pixel=scalar/8、channel=scalar%8。无效尾路输出0。
接收方必须按mask处理，不得把48bit结果直接当作自然对齐的64/128bit tensor字。
输出背压可无限保持；最后一个结果未消费前，busy不能释放。局部同步reset丢弃
未完成作业及全部流水结果、保留RAM/参数，但不是外部总线取消协议。

核心复用既有`c1_requant_bank8.sv`，补零两路并只观察前六路；没有修改R1源文件。
`c1_ti60_r2_pw96.sv`为Efinity窄观察壳，result_row选一路输出；读取六路期间须保持
out_ready=0，属于资源探针，不代表每拍能从这个8-bit外部接口排出六路结果。

```powershell
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B -u case1/golden/run_r2_pw_tile_probe.py
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B case1/golden/check_r2_pw_tile_evidence.py
./case1/scripts/run_efinity_ti60_resource_map_detached.ps1 -DesignName c1_ti60_r2_pw96 -RunId my_r2_pw96 -ProjectInPlace -RunPnr -TimeoutSeconds 600
```

## R2-C1 RGB行接口

`c1_r2_window3x4_c8.sv`用三行×奇偶单读bank，两拍取出两个相邻输出像素所需的
3×4 C8窗口，先组装再交给输出保持寄存器。窗口请求可提前于当前窗口消费；输出
保持期间不会被后续读取覆盖。它不是每拍输出一个窗口的通用DW窗口源。

`c1_r2_rgb3x3_row.sv`消费该窗口，五拍完成两像素×三输出通道，每通道72项。
默认最大宽1024，start锁存row_width与row_top/row_bottom，后两者表示越界上/下行
应改选物理中行。输出out_x指向两像素中的首像素；后三路在奇数行尾被mask屏蔽。

装载仍是32bit、idle-only、start优先；地址是独立R2原型接口，不是旧CPU ABI：

| kind | addr | data |
|---|---|---|
| 0 | (physical_row×1024+x)×2+word | 三物理行HWC/C8，word=0/1、每字四个通道 |
| 1 | output_channel×20+beat×4+word | O(HW)I顺序权重，3通道×80字节；末8项RTL忽略 |
| 2 | output_channel=0..2 | signed32 bias |
| 3 | output_channel=0..2 | 与PW相同的signed18 multiplier / shift / ReLU字段 |

physical_row=0/1/2是相对当前输出行的上/中/下行；当前没有环形行索引转换，不能
只装下一行就默认旧行自动轮换。边界不被使用的行允许不初始化，但其余被访问内容
和全部参数须先初始化。宽度非法时start_ready=0，需调用者撤销非法请求。

保留的PW/RGB各自例化完整MAC/量化仅供独立可行性评估；不可把两个108-DSP顶层叠加。
R2-C2已提供共享计算入口，但其特征RAM池仍分离。RGB独立原型150MHz通过，108 DSP/24 RAM，640宽行
计算1,615拍，不含装载/写回；详细试验差异和复现命令见R2-C1报告。

## R2-C2共享执行入口

`c1_r2_shared_row_engine.sv`的mode=0为PW，mode=1为RGB；2/3拒绝。start_size=1..1024，
分别表示PW像素数/RGB行宽，row_top/bottom只对RGB有效。load使用上面各模式的
kind/addr/data布局，共享端口addr统一13bit；越界地址或非法affine字段load_ready=0。
start_valid优先于load，非法请求必须由调用者撤销。没有完成CPU/APB映射。

start接纳后锁定owner，直到out_valid&&out_ready&&out_last才释放。忙时load/start
均拒绝，live mode/size/边界变化不影响当前作业。out_mode标明结果模式；out_index
在PW是scalar base、RGB是首像素x；mask标识六路signed8有效位置，未对齐到C8/AXI字。

`c1_r2_pw16x8_feeder.sv`和`c1_r2_rgb3x3_feeder.sv`不含MAC/量化；finish必须等最后
结果被消费，不能仅凭最后req_last发射便清busy。内部统一req接口：六路128bit A/B、
signed32 bias、signed18 mult、u6 shift、ReLU bit，另有first/last、16bit tag、6bit mask。

`c1_r2_compute6.sv`在first接纳时捕获量化配置，非first配置忽略，归约事务的tag/mask
保持一致，不能交错两个尚未结束的归约。默认8条参数FIFO在MAC结果交给量化器时
弹出；busy另外涵盖量化流水，直到最终结果消费。局部reset清所有在途，不取消AXI。

新共享工程实测只有96 MAC DSP＋12量化DSP，两个供数器0 DSP；40 RAM仍为16＋24
两个私有池。当前mode未实现DW/残差；共享算术的DW向量测试不等于真实DW供数已完成。
