# R2-C29：保持周期与数值不变的容量优化

本轮容量优化已完成验证闭环，当前独立候选切至C29；C28及此前基线保留，未覆盖C26长仿真的源闭包。完整[证据门禁](../logs/r2_c29_gate_20260914_b.log)通过：整机减少972 XLR、4块RAM，DSP/模型/已测周期不变。板级集成、全量CDC签核与C29原生帧率证明仍未完成。

## 1. 两项实现变化

- [紧凑量化](../rtl/cnn/c1_requant_bank8_compact.sv)：保持32位累加值、18位有符号乘数、0–47位移位和5级弹性流水；第4级只保存“符号、8位以上溢出、低8位幅值”10位记录，替代52位有符号中间值。最终饱和只需要这些信息，包含负零、−128、127及ReLU边界。移位前乘积和舍入没有截位。
- [窗口RAM重排](../rtl/r2/c1_r2_overlay_window_store_packed.sv)：row0共享overlay保持不变，row1/2由8个32×1024切片改为4个64×1024 bank。实际路径一直使用完整64位bulk写，因此不改变地址、写掩码合同、同步读延迟、II=2及两槽预留控制。旧的legacy write端口不是本轮新增可用功能。

实际行为变化仅在以上两个叶模块。另7个compute/feeder/engine/graph/system/host封装只替换模块类型，完整生产闭包仍为44源；C28的3个guarded CDC模块、原执行计划、CPU ABI、AXI、Resize与显示调度均保留。

相关新增层次如下（只画本轮替换链，CPU/总线/采集/显示等保留子模块未全部展开）：

```text
c1_r2_camera_capacity_host_system
└─ c1_r2_video_camera_capacity_system
   └─ c1_r2_capacity_rgbx_axi_graph
      └─ c1_r2_capacity_pingpong_graph
         └─ c1_r2_cnn_capacity_engine
            ├─ c1_r2_spatial_packed_feeder
            │  └─ c1_r2_overlay_window_store_packed
            └─ c1_r2_compute6_compact
               └─ c1_requant_bank8_compact
```

完整工程入口为[c1_ti60_r2_camera_capacity96.xml](../efinity/c1_ti60_r2_camera_capacity96.xml)，用于板级接入前的Ti60探针，不是可直接下载的官方IP整机。C21的`c1_r2_cnn_compact_engine`与本轮的`c1_r2_cnn_capacity_engine`必须区分。

## 2. 已得到的独立证据

叶模块回归同时与原RTL逐周期比较，并检查独立数值/坐标golden。量化覆盖7,168组、57,344通道结果、全部48种移位及背压；窗口覆盖36种合法尺寸/组数/up2配置、3,960请求、30,348次bulk写、边缘复制、行映射与输出保持。

| 独立MAP探针 | 原实现 | C29实现 | 变化 |
| --- | --- | --- | --- |
| 8通道量化 LUT4 | 5,964 | 3,737 | −2,227 |
| 8通道量化 FF | 1,671 | 1,399 | −272 |
| 8通道量化 DSP | 16 | 16 | 不变 |
| 窗口 RAM | 48 | 44 | −4块 |
| 窗口 LUT4 / FF | 2,904 / 1,608 | 2,909 / 1,608 | +5 / 0 |

这是独立MAP结果，不能直接代替完整6有效量化通道整机的PNR节省。探针I/O也不是实际板卡引脚分配。[最终叶测试](../logs/r2_capacity_leaf_20260914_b.log)对完整窗口测试源码重跑通过；[C29编译](../logs/r2_camera_capacity_host_compile_20260914_b.log)44源及[恢复C21编译](../logs/r2_c21_restored_compile_20260914_a.log)33源均通过。

最终整机RunId均为`c29_camera_capacity_*_20260914_b`：

| 场景 | 结果 | 秒 |
| --- | --- | ---: |
| matrix，8×8/32×32，各ST0/1 | 原22节点图，24正确CNN、36,736显示像素、138,448源像素 | 540.858 |
| faults，4故障模式，各ST0/1 | 8预期坏源帧、48正确CNN、40个故障后新任务，无复位恢复 | 303.756 |
| variant，同4配置 | 18节点未训练变体，24正确CNN、31,872显示像素、117,552源像素 | 474.142 |
| negative | 8项真实RAM破坏均检出 | 136.442 |
| xsim_12x12，ST1、AW等待W模式2 | 6正确CNN、20采集、4,320显示像素，Job=false | 34.304 |

[检查器](../golden/check_r2_camera_capacity_host_evidence.py)先证明源闭包与保留C28仅有约定差异，再复用独立源/帧池/CPU/AXI/逐层golden核验。上述五类日志与C28同配置的全部带前缀记录逐条相等，共1,792条，包含源/帧/层事件、实际周期和流量计数，不只是最终PASS相同。xsim六次完成周期为25,728/50,787/75,464/100,053/124,411/148,824；这些是12×12测试，不能线性外推为原生fps。另有6类日志篡改负控全部被拒绝。

## 3. 官方接口的下一步边界

对企业v1活动源的定向复查确认：`debayer_top_2to1.v`在约70 MHz的`vid_clk_dvi2`时钟下提供48位、每拍2个RGB像素，无ready。实际拼接为`{R高,G高,B高,R低,G低,B低}`，其“b,g,r”注释不能作为交换颜色的依据。HDMI处按`vid_cnt`选择高/低24位，仍需联合时钟、相位及DE/VALID定义核实左右像素先后，不能只凭拼接名称决定。

当前C29入口是每valid一像素，不等于已经能直连上述接口。复查顶层708–718行，`vid_cnt`是在独立`hdmi_tx_slow_clk`域自由翻转，SDC给出约140 MHz；不能未经相位/复位验证将这一截取方法移植为通用跨域器。`raw_to_rgb.v`把DE和VALID各延迟两拍，数据仅在有效条件下更新，两信号不能凭名称混用。

下一阶段按以下门槛推进，不增加MAC并行度：

1. 用非对称颜色/坐标测试图，核实企业Debayer低/高24位的左右像素顺序、DE/VALID、VS极性、有效行长及帧尾。先使用本地企业RTL/行为存储，不引入DDR PHY。
2. 以“源域完整双像素+边界元数据入队、核心域按序取出”的方式设计独立适配候选，复用150 MHz核心，不额外消耗PLL。2×70 MHz的峰值像素率为140 Mpixel/s，理论核心吞吐余量仅6.67%，必须同时量化Resize停顿、ROI丢弃及FIFO峰值；不靠异步域组合多路选择。
3. 复用本轮帧池的整帧失败/源与AXI排空合同，验证队列溢出、禁用、取消和异常SOF之后无复位恢复。队列满时不能对不可回压源伪造ready。
4. 以最小CPU+DDR+CSI+Debayer子集联合编译，核实RAM/PLL/Clock Mux和实际时钟关系；不复制企业SDC中的宽泛异步/互斥时钟切断来替代CDC验证。物理PHY、外设时钟/引脚与实际板测仍是后续门槛。

## 4. 审计发现与命名隔离修复

完整保留基线检查器捕获了C29命名错误：新执行器误用了已有C21的`c1_r2_cnn_compact_engine.sv`路径。这不是可忽略的文档问题，会破坏C21独立复现。首批a运行全部终结后，C29执行器改为独立的[c1_r2_cnn_capacity_engine.sv](../rtl/r2/c1_r2_cnn_capacity_engine.sv)，同步更新graph实例及XML；C21文件按保留C18源码与C21已审计的增量恢复，C18→C21→C22→C28源门禁重新通过。恢复是经派生关系核验的RTL功能恢复，不声称字节级备份还原。

原C26/C28实际闭包不引用该C21路径，C26在途仿真未受改名影响。为防止把改名前结果直接算作最终闭包验证，启动独立b整机回归/xsim/PNR，a证据仅作前期对照，不合并重复计数。

首批a实际PNR为42,777 XLR/144 RAM/130 DSP，核心setup/hold +0.650/+0.026 ns，56同步FF无重定时派生、141跨域端点和Gray定向检查通过；CDC分类器仍内部断言。原图、18节点图、故障、RAM负控及xsim的实际事件/逐层周期记录与C28全部一致，见[改名前证据审计](../logs/r2_c29_prerename_evidence_20260914_a.log)。最终资源及时序以独立命名b运行结果为准。

## 5. 最终独立命名版本的物理结果

运行`c29_camera_capacity96_pnr_20260914_b`已complete/exit0，耗时363.184秒；Efinity 2026.1.132.3.9、Ti60F225 I3。资源与定向时序均与a相同，不能把两次运行累加成两次优化收益。

| 完整探针 | C28 | C29最终b |
| --- | ---: | ---: |
| PNR XLR | 43,749 | **42,777（−972）** |
| RAM | 148 | **144（−4）** |
| DSP | 130 | **130** |
| MAP LUT4 / FF | 29,459 / 20,644 | 28,426 / 20,414 |
| 核心6.666 ns setup / hold | +0.425 / +0.026 ns | **+0.650 / +0.026 ns** |
| 相机13.468 ns setup / hold | +4.846 / +0.092 ns | +4.846 / +0.097 ns |

[最终定向物理门禁](../logs/r2_c29_physical_gate_20260914_b.log)通过：56同步FF全部保留正确级联、无重定时派生，8控制链由源FF发出；127个camera→core端点最大数据延迟1.222 ns、最差slack +3.587 ns；14个core→camera端点最大0.359 ns、最差+4.574 ns且全为0组合层级。Gray慢角skew为0.031/0.019 ns，满足1 ns约束。4种不安全网表连接变异全部被拒绝。

CDC分类器仍触发内部断言，`complete=false/exit_code=1`已单独记录。以上是目标器件MAP/PNR及明确端点的定向验证，不是全量CDC签核、门级时序仿真、全工艺角验证或实体板测。

按[C20必要官方平台估算](R2_WEIGHT_MEMORY_BUDGET_20260913.md)加17,361 XLR/105 RAM/4 DSP，得到**60,138/60,800 XLR、249/256 RAM、134/160 DSP**。只余662 XLR和7块RAM，逻辑余量约1.09%；虽已从C28粗加超限变成名义上限内，但尚未加入最终适配/联合布局开销，不能宣布完整工程已可装下。

## 6. 清理、复现与未完成项

最终门禁逐项核对16个运行（4个独立MAP、改名前后各6个整机运行）均complete/exit0，16个私有工程目录均已自动删除，保留126个必要文本文件、4,107,950字节（约3.918 MiB）；不包含波形或大型仿真数据库。独立叶测试及两套编译亦自动删除临时输出。清理检查器只核验，不删除其他任务文件。C26长仿真仍保留原PID/启动时间和在途目录。

```powershell
# 每次使用全新RunId，只调用外层WMI启动器，不直接调用Worker。
./case1/scripts/run_r2_camera_capacity_regression_detached.ps1 -TestKind matrix -RunId UNIQUE_MATRIX
./case1/scripts/run_r2_camera_capacity_regression_detached.ps1 -TestKind faults -RunId UNIQUE_FAULTS
./case1/scripts/run_r2_camera_capacity_host_xsim_detached.ps1 -RunId UNIQUE_XSIM -Stalls 1 -AwWaitW 2
./case1/scripts/run_efinity_ti60_resource_map_detached.ps1 -DesignName c1_ti60_r2_camera_capacity96 -RunId UNIQUE_PNR -ProjectInPlace -RunPnr -CdcAudit -TimeoutSeconds 3600
# 核验本报告已保留的b运行，不重新启动大任务。
python -B case1/golden/check_r2_camera_capacity_host_evidence.py
```

本轮不是新增吞吐提升：C26原生六帧仍属于保留基线，不自动证明C29帧率。接下来执行第3节的双像素源合同和最小官方平台联合评估。官方CPU/DDR PHY/CSI/HDMI、PLL与引脚、全量CDC/复位签核、板测及模型训练质量仍未闭合；总体架构重构目标继续进行。
