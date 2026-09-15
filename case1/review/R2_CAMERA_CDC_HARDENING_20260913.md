# R2-C28：同步链保护与源控制寄存器化

日期：2026-09-13。状态：本轮同步链/控制整改已接入独立整机并通过功能、网表连接及定向时序验证；完整板级集成/全量物理CDC签核未完成。保留 R1、C18、C21、C22、C24、C26；不覆盖默认板级 top。本文承接 [C27 物理审计](R2_CAMERA_PHYSICAL_CDC_20260913.md) 的两个实际问题，不新增 CNN 吞吐结论。

## 1. 实际改动

建立独立 [C28 主机](../rtl/r2/c1_r2_camera_safe_host_system.sv) 与 [视频系统](../rtl/r2/c1_r2_video_camera_safe_system.sv)，生产闭包仍为44源，仅替换以下5个模块；其他CNN算子、模型计划、量化、Resize/Capture、AXI fabric、CPU适配器/APB桥不变。

| 新文件 | 改动 |
| --- | --- |
| [c1_r2_async_pixel_fifo_guarded.sv](../rtl/r2/c1_r2_async_pixel_fifo_guarded.sv) | 全部Gray两级同步寄存器加入`async_reg="true", syn_keep="true"`，防止Gray解码被移到同步完成之前；逻辑主体不变 |
| [c1_r2_camera_ingress_guarded.sv](../rtl/r2/c1_r2_camera_ingress_guarded.sv) | 六条控制同步链加同样保护；新增核心时钟域`enable_source_q/cancel_source_q`，保护源端寄存器，之后才跨域 |
| [c1_cdc_latest_snapshot_guarded.sv](../rtl/common/c1_cdc_latest_snapshot_guarded.sv) | request/ack两级同步器保护；保持payload/ACK协议不变 |
| 视频系统 safe 封装 | 仅替换入口与快照模块类型，保留实例名、最终结果/lease栅栏和CPU相机寄存器 |
| 主机 safe 封装 | 仅替换视频系统类型，CPU AXI和APB桥不变 |

工程入口为 [c1_ti60_r2_camera_safe96.xml](../efinity/c1_ti60_r2_camera_safe96.xml)。保持1920×1080源、1440×1080固定ROI→640×480、FIFO512、96 MAC、同一22节点模型。当前属性针对本机Efinity验证；没有宣称所有厂商综合工具都会以相同方式保护这些属性。

## 2. 新增延迟与接口合同

enable/cancel比C26多一个**核心周期**的源寄存延迟，目的域仍为两级同步器。源寄存器在核心复位时清零，并逐核心上升沿采样；不能把组合源控制直接接回第一级同步器。

禁用只禁止后续帧，不中断已接纳帧。取消仍首先由核心故障状态锁存，再保持到源和实际Capture/AXI B排空；只在最终结果发布时释放lease。取消撤销经寄存器和同步器传播时，可能继续跳过极近的下一SOF；不得为了“零额外跳帧”破坏整帧丢弃或所有权边界。两域仍需要协调复位和实际运行的时钟。

## 3. 本轮已完成证据

- 44源编译通过：`logs/r2_camera_safe_host_compile_20260913_b.log`。首次a仅因沙箱拒绝编译产物写入而失败；核实精确目录后清理该编译私有目录，再按正常工具权限重试。无生产RTL修复用于掩盖该权限失败。
- 实际Resize/Capture生命周期：背压0/1均通过，合计8好帧/2预期坏帧；每配置8源帧、3整帧跳过，覆盖持有真实Capture完成时跳帧、禁用不中断已拥有帧、意外SOF后无复位恢复。见 [生命周期日志](../logs/r2_camera_safe_lifecycle_20260913_a.log)。
- 独立源寄存器观察器共18,428次检查、10次控制输出变化，逐次匹配核心沿采样值，未发生非核心沿输出变化。观察器不依赖新RTL自己输出PASS。
- 十类前端错误 × 背压0/1：42结果、22好帧、20预期坏帧，覆盖标记/尾部错误、FIFO溢出、超时、未接纳故障、实际写B债务取消、下游错误和最终ACK边界取消，全部无复位恢复。每配置64拍真实B保持，AW/B各113且排空。见 [前端故障日志](../logs/r2_camera_safe_capture_20260913_a.log)。

## 4. 整机验证与Ti60结果

- 原22节点图：`c28_camera_safe_matrix_20260913_a`，409.248秒，8/32方图 × 背压0/1，共24次正确CNN、36,736显示像素、138,448源像素。
- 四类整机故障：`c28_camera_safe_faults_20260913_a`，208.455秒，8配置/8预期坏源帧/48正确CNN/40个故障后新任务。包括源错/核心取消时真实Capture B债务，以及已预约未被子描述符接纳时取消；不复位、不让坏tag进入CNN/FRONT。
- 实际RAM破坏负控：`c28_camera_safe_negative_20260913_a`，129.953秒，8项输入数据/结果所有权破坏均被检出。不是修改expected冒充负控。
- 18节点图兼容：`c28_camera_safe_variant_20260913_a`，541.752秒，4配置24正确CNN、31,872正确显示像素、117,552源像素；该变体未重新训练，不作视觉质量声明。
- Vivado xsim：`c28_camera_safe_xsim_12x12_20260913_a`，32.933秒，12×12、背压1、AW等待W模式2、CPU与显示并存，6正确CNN/20采集/4,320正确显示像素。WMI worker Job=false，私有目录已删除。
- Ti60 PNR/STA：`c28_camera_safe96_pnr_20260913_a`，486.8秒。56个实际同步FF的逐级D/Q、源/目标时钟及两条新源控制FF已核验，**同步链重定时派生项为0**；8条控制跨域均是源FF→第一级→第二级。检查器主动篡改cancel/enable来源、删除Gray MSB同步器、引入第二级组合输入4项负控全部拒绝。

| C28实测项目 | 结果 |
| --- | --- |
| 资源 | **43,749 XLR / 148 RAM / 130 DSP** |
| 核心 6.666 ns setup / hold | **+0.425 / +0.026 ns** |
| 相机 13.468 ns setup / hold | +4.846 / +0.092 ns |
| camera→core 127端点 | 最大数据延迟1.070 ns，最差max-delay slack +3.739 ns |
| core→camera 14端点 | 最大数据延迟0.362 ns，最差max-delay slack +4.571 ns；所有报告路径Logic Levels=0 |
| write / read Gray慢角skew | 0.029 / 0.038 ns，均满足1 ns要求 |

141个寄存器跨域端点按身份/唯一性逐项匹配，max-delay例外未被切掉，实际数据延迟独立检查小于5 ns，skew报告覆盖两个方向全部10位。相对C27同功能未保护探针，XLR增加172、RAM/DSP不变；控制跨域最大延迟由2.236 ns降为0.362 ns。不同PNR结果的细小资源/时序差异包含布线与打包变化，不能全部归因于2个新增FF。

仍有工具限制：Efinity的CDC分类器在受保护设计上依然触发`IsValid()`内部断言，记录complete=false/exit1。本轮证明的是已识别关键同步链结构修复、受约束寄存器路径与数字功能通过；不宣称全部CDC/复位/外部接口或所有工艺角已签核。

按此前官方必要平台粗加17,361 XLR/105 RAM/4 DSP，合计 **61,110 XLR/253 RAM/134 DSP**：逻辑比60,800标称容量超310，RAM仅余3块。这个分模块粗加不是联合编译结果，新增真实接口也可能继续增加资源；下一主线需释放容量和接入实际官方视频格式。

完整[C28证据门禁](../logs/r2_c28_gate_20260913_a.log)通过。[检查器](../golden/check_r2_camera_safe_host_evidence.py)先核实新旧源差异只限5个封装/CDC模块，再复用保留数值/源时间线检查逻辑；不混合C26与C28标记，不继承C26的运行结果。验证内容包括22/18节点两套图、整机故障恢复、实际RAM负控、相机生命周期/源寄存、xsim真实执行计划、56同步FF连接、141实际跨域端点及Gray偏斜。

复用C27定向约束和审计机制，增加2个源控制FF引脚检查。报告/环境变量中`C27_*`是既有工具协议名，实际工程和证据以C28的独立RunId及闭包为准，不能拿C27资源/时序替代C28结果。

## 5. 暂未完成与保留边界

本阶段不解决官方2像素/valid接口、PLL/DDR/CSI/HDMI/CPU IP整合、全部工艺角CDC/复位签核或训练图像质量。C26原生六帧长仿真仍运行于原冻结闭包；其结果不自动证明C28帧率。下一步必须根据新的实际资源/时序结果推进板级容量和接口集成，不能无限用小规模回归替代主目标。

## 6. 复现入口

```powershell
# 每次新RunId；仅调用外层，不手动运行Worker。
./case1/scripts/run_r2_camera_safe_regression_detached.ps1 -TestKind matrix -RunId UNIQUE_MATRIX
./case1/scripts/run_r2_camera_safe_regression_detached.ps1 -TestKind faults -RunId UNIQUE_FAULTS
./case1/scripts/run_r2_camera_safe_host_xsim_detached.ps1 -RunId UNIQUE_XSIM -Stalls 1 -AwWaitW 2
./case1/scripts/run_efinity_ti60_resource_map_detached.ps1 -DesignName c1_ti60_r2_camera_safe96 -RunId UNIQUE_PNR -ProjectInPlace -RunPnr -CdcAudit -TimeoutSeconds 3600
# 只读核验已保留的证据，不启动大任务。
python -B case1/golden/check_r2_camera_safe_host_evidence.py
```

[本轮清理记录](../logs/r2_c28_cleanup_20260913.json)：4个Icarus整机回归、1个xsim和1个Efinity运行全部终结，6个私有工程目录均已删除，只保留2,024,682字节（约1.93 MiB）运行文本；独立前端/编译临时目录也无残留。C26长仿真仍在原PID/启动时间下运行，未编辑其生产源、TB或向量闭包，也未删除其在途目录。
