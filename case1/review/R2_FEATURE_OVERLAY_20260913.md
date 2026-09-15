# R2-C22：PW/残差与空间卷积共享特征存储

日期：2026-09-13。保留 R1、C18、C21 全部生产源码；C22 为独立候选，不替换原整机默认顶层。

本阶段完成特征存储重组、完整算子/主机回归、故障恢复和 Ti60 I3 布局布线。最终局部验收为 [r2_c22_gate_20260913_b.log](../logs/r2_c22_gate_20260913_b.log)。后续C26阶段已收口C22自身原生六帧，见[r2_c22_native_gate_20260913_a.log](../logs/r2_c22_native_gate_20260913_a.log)：9,335.931秒、Job=false、私有工程已删除；最差满负载完成间隔9,794,650周期，按本工程已通过的150MHz约15.3145fps，与C21/C18逐周期一致。它是C22自身证据，不是继承结果，也不是板测或C26帧率；下文在途状态为历史过程。

## 1. 实际收益和代价

| 同范围完整主机探针 | XLR / 60,800 | RAM / 256 | DSP / 160 | 150 MHz 最终 setup / hold（ns） |
| --- | ---: | ---: | ---: | --- |
| C18 原计划化主机 | 46,531 | 172 | 112 | +0.536 / +0.028 |
| C21 最终紧凑权重版 | 41,620 | 150 | 112 | +0.586 / +0.027 |
| C22 共享特征存储版 | 41,252 | 134 | 112 | +0.349 / +0.026 |

本轮实测再省 **16 RAM（相对 C21 减少10.67%）和368 XLR**；相比 C18 累计减少38 RAM、5,279 XLR。不是增加 MAC 数，也不宣称本轮提高帧率。实际已完成的算子、整机矩阵和小图 xsim 周期/访存均与对应保留版本一致。

实现运行：`c22_overlay_host96_i3_20260913_a`，359.993秒，Efinity 2026.1.132.3.9，Ti60F225 I3；[summary.json](../logs/efinity_resource_runs/c22_overlay_host96_i3_20260913_a/summary.json)。最终周期6.317 ns，150 MHz 建立与保持时序均通过，但建立裕量比 C21 小0.237 ns。不能把报告的内部最高频率直接用作板级工作频率。

资源范围是 pin-reduced host/CNN/采集/显示/fabric，不含实际 Sapphire、DDR/MIPI PHY、Debayer/Resize、CDC 和板级接口。实际层次确认：PW feeder 为0 RAM，空间 feeder 为48 RAM，其中共享子模块16 RAM；权重42 RAM、operator90 RAM、graph122 RAM、完整探针134 RAM。不是把单模块估计值直接从整机相减。

## 2. 为什么能够共享

生成式图执行器每层进入 `SETUP` 都清空 `cache_valid`；切层前通过 `FINAL_WRITE_WAIT` 等待写回完成。逐行计算在旧窗口和输出排空后才接纳下一轮特征覆盖。PW/残差与空间卷积不会在同一时段消费特征，因此可以复用空间缓存的物理第0行。

| 逻辑视图 | 原独立组织 | C22 组织 |
| --- | --- | --- |
| PW / 残差 | 两个奇偶像素银行，各512×128位，共16 KiB / 16 RAM | 使用共享区域，读两个128位向量 |
| 空间物理行0 | 两个奇偶列银行，各1024×64位，共16 KiB / 16 RAM | 使用同一共享区域，读两个64位向量 |
| 空间物理行1、2 | 合计32 KiB / 32 RAM | 保持独立，不改地址/窗口语义 |

共享区域拆为8个512×32位同步 SDP RAM。空间地址最高位选择512深度的上/下半区；线性视图同时读取两半组成128位。空间半区选择位与RAM读请求同拍寄存，因此两种视图仍是一拍响应。无需额外读事务，也不依赖 Efinix 专有 primitive；实际 Efinity 推断为16个 Memory Block。

**合同变化：两套逻辑特征数据不再同时持久有效。** 一方写入后，另一方若要消费被覆盖的数据，必须重新填充。当前图执行器已满足此条件；将来替换调度器、跨算子预取或把两套缓存同时预装时，必须遵守这个约束，不能把共享模块当作两套独立数组的即插即用替代。

复位只阻止新的读写并清理控制，不清空SRAM。共享模块的仿真所有权跟踪跨暖复位保留，但只检查访问顺序，不是逐地址有效位表，也不能替调用方证明整行已装满。若窗口的映射仅使用物理行1、2，则不读取共享行0，避免误消费已被线性视图覆盖的无关数据。

## 3. 源文件与集成入口

GUI 入口为 [c1_ti60_r2_overlay_host96.xml](../efinity/c1_ti60_r2_overlay_host96.xml)，生产闭包34个文件（不含观测探针），仅包含一份生成式 `execution_plan.sv`。不要把整个 `rtl/r2` 全选加入工程。`c1_ti60_r2_overlay_host96` 是缩减引脚的资源探针，不是板级 top。

- [c1_r2_feature_overlay_ram.sv](../rtl/r2/c1_r2_feature_overlay_ram.sv)：新增物理共享存储、地址/位宽映射、一拍读响应及仿真冲突断言。
- [c1_r2_pw_overlay_feeder.sv](../rtl/r2/c1_r2_pw_overlay_feeder.sv)：去除私有特征RAM，导出原地址、写掩码、写数据和读请求；保留 C21 残差容量尾批保护。
- [c1_r2_overlay_window_store.sv](../rtl/r2/c1_r2_overlay_window_store.sv)：物理行0换为共享模块，保留行1、2和原窗口排队；检查窗口尚未排空时不得交给线性访问。
- [c1_r2_spatial_overlay_feeder.sv](../rtl/r2/c1_r2_spatial_overlay_feeder.sv)：转接线性存储端口至窗口模块，空间操作数逻辑不变。
- [c1_r2_cnn_overlay_engine.sv](../rtl/r2/c1_r2_cnn_overlay_engine.sv)：连接两类 feeder 的共享端口，权重、MAC、量化、配置和完成协议不变。
- `c1_r2_overlay_pingpong_graph` → `c1_r2_overlay_rgbx_axi_graph` → `c1_r2_video_overlay_system` → [c1_r2_overlay_host_system.sv](../rtl/r2/c1_r2_overlay_host_system.sv)：继承生成式图与完整系统外壳，只换下级类型；graph另加切层缓存失效断言。

C21 encoder、权重表、参数包、loader、writer、行DMA、AXI fabric、CPU适配器、帧租约和APB/IRQ全部保持。源码门禁对9个改名模块/探针逆向还原允许的确切差异，并与 C21 直接对照；对主机、恢复、算子测试台也做对照。未依赖文件摘要验证。

## 4. 验证结果

### 共享RAM专项

[r2_overlay_ram_unit_20260913_a.log](../logs/r2_overlay_ram_unit_20260913_a.log)：独立16,384字节参考数组，1,536次线性读、2,560次空间读、6,380次线性32位写、1,537次空间写；覆盖全地址、两个半区、奇偶银行、随机稀疏写、两种视图真实字节别名、17次复位及1,536次输出保持检查。

另有8项负控，分别拒绝双视图同时读/写、同视图读与填充重叠、写覆盖后未切回填充就读取旧视图等非法访问。暖复位期间即使接口读写使能为高，也不能改变RAM内容。别名测试有意检查同一物理字节的两种解释，不表示两套业务特征可同时持久保存。

### 算子和完整系统

- [r2_overlay_operator_20260913_a.log](../logs/r2_overlay_operator_20260913_a.log)：背压0/1各187任务，共374任务、1,850,338有效标量，其中734,720来自现有训练工件。覆盖12种 PW 通道组合、DW/虚拟UP2、RGB、两类编码器、残差8191/8192边界、量化边界和六模式持有输出后复位。实际 bulk 加载，非灌入预展开MAC操作数；无额外计算气泡。
- [原22项主机矩阵](../logs/r2_overlay_host_matrix_20260913_a.log)及[18项结构变体矩阵](../logs/r2_overlay_host_variant_20260913_a.log)：8×8/32×32、背压0/1，每配置六次CNN，两套图各24次；分别36,736/31,872正确显示像素。九类实际事件与对应 C18 保留记录一致。结构变体未重训、未验证风格质量，不作为新比赛模型。
- [实际RAM负控](../logs/r2_overlay_host_negative_20260913_a.log)：8次真实内存破坏均被检测。
- [恢复矩阵](../logs/r2_overlay_recovery_matrix_20260913_a.log)及[多笔写债务恢复](../logs/r2_overlay_recovery_debt_20260913_a.log)：共9配置、27成功/9预期失败、18次失败后无复位成功、14,336正确显示像素。包括128×4末层B保持256拍、同一CNN两笔真实待回应写事务，验证排空、IRQ和失败帧不发布。
- [Vivado xsim 结果](../logs/r2_overlay_host_xsim_runs/c22_overlay_host_xsim_12x12_20260913_a/result.log)：12×12、背压1、W先于AW、六次CNN，29.471秒，周期 `[24708,24882,24373,24177,24512,24364]`，与对应旧版本一致，`worker_in_windows_job=false`。

最终门禁还拒绝3项算子证据变异、2项RAM证据变异。没有重跑 CPU 窄访存256任务：相关生产源未改，沿用 C18 证据；本轮实际主机回归包含CPU竞争。不声称恶意ID/LAST等畸形协议后的整系统协调复位已验证。

## 5. 板级预算与剩余工作

按 [C20审计](R2_WEIGHT_MEMORY_BUDGET_20260913.md) 的官方实际配置，选择一个DDR控制器，不重复叠加视频/SoC两套DDR：

- RAM：C22 134 + Sapphire 43 + DDR 22 + CSI 36 + Debayer 4 = **239/256**，余17块，尚未计入 Resize、新增CDC/接口缓冲。
- XLR粗和：41,252 + 17,361 = **58,613/60,800**，余2,187。
- DSP粗和：112 + CPU 4 = **116/160**。

这些跨工程粗和不能证明板级可装下；模块边界、复用/剪枝、布局、时钟和接口配置都会改变最终数值。官方视频例程 PLL/Clock Mux 已用满，仍不能直接与 SoC 工程拼接。资源比 C21 的255 RAM有所缓解，但逻辑余量仍偏紧。

原 C18 自身原生验证已通过，四个完整负载间隔最慢15.3145 fps@150 MHz、最小周期余量2.0535%。这只是带CPU/视频竞争的有限行为内存模型，不包含真实DDR刷新、转向、PHY或最终模型风格质量，不能承诺板上15 fps。

C22自身运行 `c22_overlay_host_xsim_native_sixframe_20260913_a` 于18:58:13.1971863启动，worker25512、Job=false：640×480、六次CNN、30fps行为采集、720p60配对显示、CPU竞争、128位共享内存每两拍一次聚合服务、命令延迟20拍。C21原worker26392（18:26:18.4304799启动）也继续运行，未重启、未改其生产源、未清理其目录。

下一阶段先取得各自六帧最终记录并执行原生门禁，再做实际平台联合工程、Resize/CDC和时钟资源审计。若联合资源超限，优先基于真实层次报告处理平台FIFO/重复缓存或可裁剪配置；不先牺牲已验证算子集合或静默更换模型。

## 6. 复现与文件清理

Python入口：`run_r2_overlay_ram_probe.py`、`run_r2_overlay_operator_probe.py`、`run_r2_overlay_host_probe.py`、`run_r2_overlay_recovery_probe.py`。证据检查器：[check_r2_overlay_host_evidence.py](../golden/check_r2_overlay_host_evidence.py)。原生验收必须另带 `--native-run c22_overlay_host_xsim_native_sixframe_20260913_a --require-15fps`，未完成时不能运行通过。

Vivado只用 `scripts/run_r2_overlay_host_xsim_detached.ps1` 的WMI外层；Efinity只用既有 `run_efinity_ti60_resource_map_detached.ps1 -DesignName c1_ti60_r2_overlay_host96 -ProjectInPlace -RunPnr`，每次唯一RunId，不直接调用Worker。

不生成波形，完成的Icarus、局部xsim和EDA临时工程已由各自运行器清理，只保留小型证据。两份仍在运行的原生工程不属于清理对象，将由原worker结束后清理；本阶段清理核验另见 [r2_c22_cleanup_20260913.json](../logs/r2_c22_cleanup_20260913.json)。整体架构目标仍未完成。
