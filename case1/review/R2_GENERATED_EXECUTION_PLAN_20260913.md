# R2-C16：由算子与张量依赖生成执行计划

日期：2026-09-13。范围：独立的 CNN 行执行核心候选，不覆盖 R1 或 C8～C15 的生产 RTL；C13/C14/C15 原生系统仿真属于各自候选，结果不归入 C16 性能。

后续进展：[C17配套参数包与实际变体RTL验证](R2_BOUND_PLAN_PACKAGE_20260913.md)已完成；下文“18项仅规划”的表述保留C16当时边界。C17没有覆盖本阶段源码，也尚未替换C15完整系统。

## 1. 本阶段解决的问题

架构决策要求同时解决吞吐和维护成本。此前 R2 已建立连续归约阵列、行缓存、加载/计算/双页写回重叠及共享 AXI；但执行器仍通过固定层号选择算子、工作区、残差来源、上采样融合与结束条件。更改残差块数量时，容易遗漏其中一个分支。

C16 将这些选择移到 Python 编译期规划器。RTL 仍负责行级推进、真实读写响应排空、错误屏障和计算流水；不会因为生成了计划而省略数值仿真。此次目标是降低图结构变更的风险，并确认不会明显增加硬件成本，**不是新增 MAC 或宣称提升 FPS**。

## 2. 文件关系与工作方式

```text
microstyle_layout.layer_specs
  → microstyle_nodes：补入该网络明确的残差边
  → lower：算子能力/形状检查 → 别名融合 → 张量生存期 → 三工作区分配
  → render_sv：生成 c1_r2_microstyle_plan.sv
  → c1_r2_planned_pingpong_graph：锁存计划项，执行整层的行任务
      ├─ tensor_stream_loader：参数/特征加载、行缓存回填
      ├─ cnn_bulk_engine：保留的 96 MAC 与量化流水
      └─ tensor_pingpong_writer：计算/写回双页及真实响应退休
```

`microstyle_nodes` 是网络适配层，使用现有层名称识别残差块的扩展入口；它不是通用网络导入器。真正的 `lower` 接收显式 `Node(spec, inputs)`，不从名称或层号猜测语义。将全部节点改名而保持边不变，所得执行配置与工作区分配不变。

| 文件 | 职责 |
| --- | --- |
| `model/r2_execution_plan.py` | 显式 DAG、后端能力检查、生存期分配及 SystemVerilog 表生成 |
| `rtl/r2/c1_r2_microstyle_plan.sv` | 编译期生成的组合译码表，默认无效指令不启动操作 |
| `rtl/r2/c1_r2_planned_pingpong_graph.sv` | 独立行执行器，不再以 `stage_q == 0/20/21` 决定输入、输出或结束 |
| `golden/test_r2_execution_plan.py` | 固定合同、改名、图变体、容量和非法图拒绝 |
| `sim/tb_c1_r2_plan_decode.sv` | 与实际保留 C8 译码逻辑比较；不是图执行证据 |
| `sim/tb_c1_r2_planned_pingpong_graph.sv` | 真实中间张量 RAM、逐级 golden、反压、故障和复位验证 |
| `golden/run_r2_plan_graph_probe.py` | Icarus 数值及负对照入口，私有产物自动清理 |
| `golden/check_r2_plan_graph_evidence.py` | 数值、资源、时序与证据范围的汇总检查 |
| `scripts/run_r2_plan_graph_xsim_detached.ps1` | WMI 隐藏、脱离 Windows job 的 xsim 入口 |
| `efinity/c1_ti60_r2_plan_graph96.{sv,xml,sdc}` | Ti60 I3 核级资源与 150 MHz 实现探针 |

## 3. 编译与运行合同

- 当前 MicroStyle24 自动生成 22 项，19 项实际计算写回、3 项视图；参数仍为 2,333 个 128-bit 字，逐项保留 8 KiB 参数块布局。
- 三个工作区各 8 MiB。分配目标槽时不能覆盖本操作的任一输入，即使该输入在本层之后不再使用；空间卷积后续行仍可能读取其较早行。
- 最近邻 2 倍上采样只有在单一 DW 消费者、无不支持的链式视图时才成为虚拟视图。输入根张量的生存期延伸至实际 DW 消费，而不是在视图节点提前结束。
- 最后的 S8→RGB 只融合到独占输出的 8→3 空间卷积。输出写回和层完成仍等待真实行写响应；终止由计划的 `last` 决定。
- 帧尺寸仍为宽 4～640、高 4～480，均为 4 的倍数。生成 RTL 时必须以 640×480 最大包络验证，表中几何只支持全、半、四分之一尺寸；不能用小图容量通过冒充原生容量通过。
- PW/DW/空间卷积的通道组合、行 SRAM 与参数块容量按实际后端拒绝不支持配置。残差后端目前明确限定 **24 通道、ReLU**，不是任意通道的通用 add。
- 卷积激活及量化仍随参数装载；改变图、通道或量化时必须同步重导参数并验证，不能只替换译码表。此次没有实现任意模型权重导入。

这是**编译期生成计划**，不是软件可写微码、运行时任意 CNN 或 ONNX 编译器。当前图仍是功能性 QAT 检查点，不是已完成风格质量训练的比赛模型。

## 4. 已取得的验证

| 验证层级 | 实际结果与边界 |
| --- | --- |
| Python 规划 | 12 项通过；固定槽/参数合同、独立生存期回放、全图改名、删残差块、非法图/容量拒绝 |
| 实际旧译码对照 | 9 组尺寸、1,107 检查；171 可执行项、27 视图、90 无效索引；不是数值执行 |
| Icarus 数值矩阵 | 4×4、12×12、32×32、640×12，各反压 0/1；18 次正常/恢复帧、24 次故障帧；正常部分核对 2,448,464 个有效标量 |
| 共享服务延迟 | 12×12、反压 0/1、每两拍服务与 20 拍命令延迟；6 次正常帧、24 次故障帧 |
| 复位 | 反压 0/1 × 6 个阶段，写节流开启；12 次完整 golden 重启 |
| 真实 RAM 负对照 | 两类中间张量破坏共 4 次均检出，不是只修改最终报告 |
| xsim | 12×12、每两拍服务＋20 拍延迟，单帧 17,232 拍，与 Icarus 对应无额外反压配置一致 |
| Efinity | 实际 map＋PNR 完成，150 MHz setup/hold 均非负，资源层次保留计划表与计算/写回模块 |

删去一个残差块后，规划器确实生成 18 项：视图移至 10/13/17，虚拟 DW 移至 11/14，RGB 生产移至 16，终止移至 17。**这仅证明规划和 RTL 表生成；尚未对该 18 项变体导出权重并运行 RTL 数值验证。**

原始证据：

- `logs/r2_execution_plan_unit_20260913_b.log`
- `logs/r2_plan_decode_20260913_a.log`
- `logs/r2_plan_graph_{matrix,shared,reset,negative}_20260913_a.log`
- `logs/r2_plan_graph_xsim_runs/c16_plan_graph_xsim_12x12_20260913_a/`
- `logs/efinity_resource_runs/c16_plan_graph96_i3_20260913_a/`
- 最终本阶段门禁：`logs/r2_c16_gate_20260913_c.log`。9 种错误证据均被拒绝；这与实际 RAM 破坏测试分开计数。

## 5. 资源与旧路径对照

| Ti60F225 I3 核级实现，目标 150 MHz | 保留 C8 | C16 |
| --- | ---: | ---: |
| XLR | 38,819 | 38,846 |
| Memory Block | 160 | 160 |
| DSP | 112 | 112 |
| 最终 setup slack / ns | +0.540 | +0.615 |
| 最终 hold slack / ns | +0.031 | +0.065 |

C16 为 63.89% XLR、62.5% RAM、70% DSP；物理原语为 96 个 DSP24＋16 个 DSP48。计划表层次保留 152 个 LUT、无 RAM/DSP，整个实现仅增加 27 个 XLR。布局布线差异不能用于宣称新的最高安全板级时钟，当前只确认该探针 150 MHz 约束闭合。

这些数值不包含共享 AXI/video/host 封装，更不包含实际 Sapphire、MIPI/DDR PHY、ISP、CDC 和板级 IO。不能用本表的 160 RAM 替代 C15 联合核心的 172 RAM，也不能直接与企业完整视频工程相加后当成已实现结果。

额外的旧日志对照 `r2_c16_gate_20260913_b.log` 未通过“全部逐拍相同”断言：12×12 随机等待中，故障 11/12 的排空周期，以及随后重启帧的周期/部分重叠统计不同；重启帧为 14,868→14,870 拍。正常数值、读写量、提交数与故障检测均通过。对此单配置另行重跑当前保留源码，不把差异隐藏或直接改成宽松性能容差。

随后使用**当前保留 C8 源码与原 testbench**独立重跑该配置，`r2_c16_retained_schedule_20260913_b.log` 的 3 次正常帧、12 次故障及全部汇总字段均与 C16 相同，包括重启 14,870 拍。其余 15 次正常帧与早期记录相同。因此没有发现当前两执行器的该矩阵周期回退；早期记录与当前源码回归不一致，不能只凭旧日志确定当时每个文件的状态。门禁显式分别使用历史对照和这次新对照，不篡改旧日志。`r2_c16_retained_schedule_20260913_a.log` 是误用不存在的运行器名称而未启动仿真的记录，也保留。

## 6. 复现与清理

使用现有 Python 环境与 `D:\iverilog\bin`。例如从工程根目录运行：

```powershell
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/golden/test_r2_execution_plan.py
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/golden/run_r2_plan_decode_probe.py
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/golden/run_r2_plan_graph_probe.py --shapes 12x12 --stalls 0,1 --memory-div 2 --latency 20
```

完整矩阵、reset-only 和 negative-only 使用相同运行器的独立调用。xsim/PNR 每次使用新的 RunId；不要复用已完成或仍在运行的目录，也不要把 Vivado 直接启动在会话的 Windows job 内。

C16 xsim 实测 worker 不在 Windows job，17.181 秒完成，其临时目录已删除；Efinity 292.358 秒完成，C 盘本次私有目录已删除。Icarus 向量和可执行仿真文件由 TemporaryDirectory 清理，无波形；只保留小型文本证据。15:25 快照 `logs/r2_c16_partial_cleanup_20260913.json`：C16 xsim/EDA 分别只保留 26,879/99,931 B 文本；C13 原生也已完成清理，保留 56,299 B。仍在途的 C14/C15 目录不清理、不重启。

## 7. 下一阶段与未完成项

1. 将计划与参数导出绑定，至少对一个非 22 项图变体做实际 RTL 数值验证，证明无需手工修改执行器中的层号。
2. 将此核心作为独立候选接入 RGBX/AXI/host 路径，再做共享 DDR 原生多帧验证与联合资源评估；当前 C15 仍使用保留 C8，不会自动切换到 C16。
3. 等待并核验已经在途的 C14/C15 原生结果；C13 六帧已在本阶段结束并通过独立门禁 `r2_c13_native_gate_20260913_a.log`，无需重新启动。

C12 和加入 CPU DDR 适配器的 C13 各自六帧系统证据，最慢完整负载间隔均为 **15.3145 fps@150 MHz**，周期余量仅 2.0535%。C13 是独立运行得到相同周期，不是借用 C12 数值；仍是有限 DDR 行为模型与 CPU 流量代理下的结果，不是 C16 的新 FPS、长期保证或板测。后续仍需增加吞吐余量，并完成最终模型质量、真实 CPU/BSP/时钟与企业视频平台联合。
