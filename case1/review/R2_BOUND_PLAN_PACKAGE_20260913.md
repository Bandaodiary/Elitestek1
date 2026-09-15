# R2-C17：执行计划与参数绑定，以及非固定层数的 RTL 验证

日期：2026-09-13。目标是在 C16 基础上证明“改图不必手改执行器层号”，而不是选择一个尚未训练验证的新比赛模型。旧 R1/C8～C16 的生产源码和旧模型均保留。

## 1. 本阶段结论

同一个 `c1_r2_planned_pingpong_graph.sv` 行执行器，现已实际运行两套配套生成的计划与参数：原 22 项图，以及删除 `res1` 残差块的 18 项图。没有为变体增加手写的层号分支。

18 项变体不再只是 Python 规划测试：所有实际计算层的中间张量写入仿真 RAM，后层只读取这些 RTL 写回的数据；逐层与独立逻辑 DAG 整数算法比对。原 22 项包的参数二进制与保留导出完全一致，多尺寸 RTL 的周期与访存量也与 C16 一致。

这证明了现有后端能力范围内的编译期结构可变性，不代表任意 CNN/ONNX、软件可写微码、不同量化尺度的任意连线，或新变体已达到比赛风格质量。

## 2. 新文件与配套产物

| 文件/目录 | 作用 |
| --- | --- |
| `model/r2_plan_package.py` | 同时编译 DAG、绑定源参数、检查形状/算子/量化尺度，导出计划与参数包 |
| `model/r2_microstyle24_bound_plan/` | 原22项的独立配套包，不覆盖旧模型或C16译码表 |
| `model/r2_drop_res1_bound_plan/` | 18项功能性变体包，复用原检查点中保留层的参数，未重训 |
| `golden/r2_plan_vectors.py` | 按逻辑输入边执行整数 golden，并生成实际 RAM 所有权检查表 |
| `golden/test_r2_plan_package.py` | 参数解码、绑定/尺度拒绝、原网络及两残差块独立数值序列对照 |
| `sim/tb_c1_r2_bound_plan_graph.sv` | 通用层数/终止层的 testbench，复用原行执行器与真实中间 RAM |
| `golden/run_r2_bound_plan_probe.py` | 原图/变体、反压、延迟、复位与实际负对照运行器 |
| `golden/check_r2_bound_plan_evidence.py` | 本阶段证据门禁，明确不产生原生FPS或模型质量结论 |
| `scripts/run_r2_bound_graph_xsim_detached.ps1` | WMI独立隐藏xsim，Job检查、私有目录及结束清理 |
| `efinity/c1_ti60_r2_bound_plan96.{sv,xml,sdc}` | 18项配套计划的Ti60 I3核心实现探针 |

每个持久包包含三个文件：

```text
execution_plan.sv  → RTL编译时使用的组合计划表
parameters.bin     → 软件需要上传到parameter_base的命令镜像
manifest.json      → 节点/输入边、源参数绑定、量化尺度、计划项与参数偏移
```

计划表的模块名仍是 `c1_r2_microstyle_plan`，所以 GUI 工程只能选择一份计划表：不能同时加入包内 `execution_plan.sv` 和保留的 `rtl/r2/c1_r2_microstyle_plan.sv`，否则是重复定义。当前 C15 尚未切换到任何新包。

## 3. 绑定与量化检查

`compile_package(nodes, artifact, bindings)` 接收显式图和可选的“图节点→源参数层”映射。默认按节点名绑定；全部节点改名并提供映射仍得到相同参数镜像。参数选择不依赖旧层号。

除 C16 的算子/SRAM/张量生存期检查外，本阶段增加：

- 权重形状、stride、groups、activation必须与图一致；缺少、额外、未知或不匹配绑定拒绝。
- arena长度、每个数组的偏移和范围检查；signed18 multiplier与shift 0..47检查。
- 输入RGB减128后的实数尺度规定为1/128；逐边输入/输出尺度必须一致。当前后端没有通用边界重定标器，不放宽容差来接受不同尺度。
- 残差两输入尺度必须相同，最终S8→RGB输入尺度必须为1/128。原三个残差块的边界尺度相同，因此删除中间块后仍可执行该整数合同。
- 每层生成的命令数必须恰好等于计划声明的128-bit读取数量；参数偏移随新计划的 `parameter_block` 生成。
- `export_new` 拒绝覆盖任何已有目标目录；`verify` 直接比较配套文件内容与重新编译结果，不使用校验和。

量化尺度相同只说明数值接口可接。删块改变了实际网络输出，单元测试也确认32×32输出与原网络不同；不意味着视觉效果仍可接受。所有新包明确记录 `quality_validated=false`、`topology_retraining_performed=false`。

## 4. 两个图的实际配套差异

| 项目 | 原图 | 删除res1的变体 |
| --- | ---: | ---: |
| 计划项 | 22 | 18 |
| 参数绑定层 | 16 | 13 |
| 实际计算写回层 | 19 | 15 |
| 参数镜像字节 | 180,224 | 147,456 |
| 活跃参数128-bit字 | 2,333 | 1,781 |
| 活跃参数字节 | 37,328 | 28,496 |
| RGB生产项 | 20 | 16 |
| 最终终止项 | 21 | 17 |

变体的 `res2.expand1x1` 从原第10项移动到第6项，相应参数移动到 `6×8192`；视图变为10/13/17。并非仍从旧第10项参数槽取数。工作区仍为三个8MiB槽，内部仍是P2C8，行计算与双页写回模块未替换。

Golden直接按逻辑DAG的输入边运行，不从编译后的mode/slot表决定数学运算。RAM期望生产者由逻辑边及视图根解析得到，不读取DUT的译码表，也不使用编译器提供的 `physical_inputs` 代替独立依赖检查。正确输出只存在于checker，不能成为DUT中间读响应。

## 5. 验证结果

总门禁：`logs/r2_c17_gate_20260913_a.log`；收口时再次检查当前配套文件及全部证据也通过，记录为 `logs/r2_c17_gate_20260913_b.log`。

| 层级 | 实际覆盖 |
| --- | --- |
| Python包/算法 | 10项测试；独立解码每个有效命令恢复权重/偏置/量化；原22项DAG与旧整数网络在3尺寸逐层一致；变体与独立两残差块顺序算法逐层一致 |
| 变体矩阵 | 4×4、12×12、32×32、640×12，各反压0/1：18次正常/恢复帧、24次故障；核对2,126,768个有效标量及146,756个正常写回字 |
| 原图兼容 | 12×12、32×32，各反压0/1：10次正常/恢复帧、24次故障；所有周期、访存量及汇总字段与当前C16证据一致 |
| 变体延迟模型 | 12×12，反压0/1，每两拍一次128-bit聚合读写服务、命令延迟20拍；6次正常帧、24次故障 |
| 变体复位 | 两种反压×6个阶段、写节流开启；12次完整golden重启，仍要求系统级复位合同 |
| 中间RAM负对照 | 两类实际数据/生产者破坏×两种反压，共4次检出 |
| 配套负对照 | 18项图混入旧22项计划，或混入旧22项参数，各两种反压，共4次检出 |
| xsim | 18项图、12×12、反压1、同等延迟模型；3次正常/恢复帧及12次故障，与Icarus对应周期和访存量一致 |
| 证据负对照 | 门禁拒绝7种损坏证据；与实际RAM/配套负对照分开计数 |

配套错误由**仿真检查器**通过未初始化参数读取或第6层实际数值不匹配检出。这不是FPGA已经具有运行时模型身份检查、错误权重认证或版本协商；真实软件仍须保证计划比特流与所上传参数配套。

原始运行：

- `logs/r2_plan_package_unit_20260913_a.log`
- `logs/r2_bound_{variant,baseline}_matrix_20260913_a.log`
- `logs/r2_bound_variant_{shared,reset,handoff}_20260913_a.log`
- `logs/r2_bound_package_negative_20260913_a.log`
- `logs/r2_bound_graph_xsim_runs/c17_bound_xsim_12x12_20260913_a/`

另有4×4原图/变体的8次起步帧 `r2_bound_plan_smoke_20260913_a.log`，不重复算入上面的矩阵覆盖。

## 6. 易灵思实现与性能边界

`c17_bound_plan96_i3_20260913_a` 已 map+PNR 完成，282.544秒。Ti60F225 I3、150MHz约束：

- 38,660 / 60,800 XLR；160 / 256 RAM；112 / 160 DSP。
- 最终setup +0.737ns、hold +0.026ns。
- 计划表、计算引擎和双页写回层次保留；计算引擎128 RAM/108 DSP，写回32 RAM/0 DSP。

这是18项计划的**CNN行传输核心**，没有实际AXI/video/host/CPU/PHY/CDC/IO。不能拿160 RAM替换C15联合核心的172 RAM，或据此声称整板资源已闭合。

变体640×12无额外反压为177,913拍，原22项同条件为206,079拍；前者少一个残差块、工作量不同，不能把差值称为同一模型的架构吞吐提升，更不能外推原生FPS。目前原生15.3145fps证据仍来自各自已完成的C12/C13六帧有限行为模型，不来自本变体。

## 7. 复现和清理

从工程根目录运行；现有目录只能使用 `--verify`：

```powershell
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/model/r2_plan_package.py --profile drop_res1 --output case1/model/r2_drop_res1_bound_plan --verify
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/golden/test_r2_plan_package.py
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/golden/run_r2_bound_plan_probe.py --profiles drop_res1 --shapes 12x12 --stalls 0,1 --memory-div 2 --latency 20
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/golden/check_r2_bound_plan_evidence.py
```

新xsim 19.563秒完成，实测worker Job=false；其私有工程及Efinity的C盘私有目录已清理。Icarus临时计划包、向量和可执行文件也已清理，无波形。16:00快照 `logs/r2_c17_partial_cleanup_20260913.json`：C17 xsim/EDA分别只保留38,397/100,621 B文本；两个 `model/*_bound_plan/` 合计398,109 B，是有意保留的配套设计产物，不是仿真临时目录。C14原生也已完成清理，仍运行的C15不要删除或重启。

## 8. 下一步

1. 以原22项配套包为主集成对象，将同一个计划执行器接入独立RGBX/AXI/host候选，保留C15默认和旧模块。18项图继续作为结构变更验证用例，不擅自替代比赛模型。
2. 验证完整系统中的参数上传、帧所有权、CPU竞争、错误排空和连续原生吞吐，并做该联合候选的Efinity资源/时序。
3. 对真实Sapphire/BSP、缓存与CDC、企业视频平台作后续对接；模型质量与板测仍需另行闭合。

本阶段是编译期计划/参数/实际RTL执行链的闭合，不是整个架构重构目标或比赛系统全部完成。

同期收口：C14原生六帧已独立通过，最坏完整负载间隔15.3145fps，且六次均选择当时最新完成帧，第4次采集完成到CNN启动年龄57.81→24.48ms。新证据 `r2_c14_native_gate_20260913_b.log`，详见[新鲜度报告](R2_FRESH_INPUT_SCHEDULING_20260913.md)。该系统仍使用原22项路径，不是C17变体的FPS。
