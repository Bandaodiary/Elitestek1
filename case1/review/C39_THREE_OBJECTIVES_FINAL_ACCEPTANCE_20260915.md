# C39 三个资源优化目标：最终验收与交付

日期：2026-09-15。结论：**按[原三个目标及验收要求](C39_THREE_OBJECTIVES_IMPLEMENTATION_20260915.md)完成本阶段，选择 C39 one-hot 组合作为后续开发入口，保留 C37 回退工程。** 未改算法、96 路乘积并行度、通道/行容量合同或 AXI 并发深度；没有通过放宽时序/吞吐门槛取得通过。

这里的完成指本阶段的 RTL 等价优化、官方 CPU 裁剪/公开平台合同、联合接口验证及真实资源/相关时序评估。**不等于完整赛题、真实 CPU 软件启动、板级外设或全系统物理签核已完成。**

## 1. 三个目标逐项验收

| 原要求 | 当前直接证据与结论 |
| --- | --- |
| 精简官方 CPU 平台：实际生成，同版本比较 | 官方 Sapphire 3.4.1 的 S0/S1/S2 均实际生成，企业原 3.3.0 保留。同一 C37、DDR、100MHz 边界，S0→S2 MAP 从40,102 LUT4/27,161 FF/187 RAM变为35,738/23,673/165，减少4,364 LUT4、3,488 FF、22 RAM；125 DSP不变。这是MAP差值，不是最终XLR差值。 |
| CPU 端口/BSP与联合总线合同 | 五个实际联合顶层公开平台检查通过，错误CPU/DDR时钟、校准绕过、150MHz冒用和压缩ISA五项负例均被拒绝；联合接口9项检查及BRESP、RID、校准门控三项真实连线故障负控通过。接口仿真使用行为CPU/DDR，不声称执行过受保护CPU。 |
| 等价量化舍入：数值、五级弹性、II=1、复位/回压 | 原始RTL补跑接受9,775项、退休9,762项（复位丢弃13项），4,702保持周期、7复位周期、244连续II=1检查、8 lane及48移位通过。guard、进位、弹性保持三种实际RTL故障均检出；四个真实编译来源表已保留。另有49位幅值全域、符号/ReLU、48移位的算术表达式ROBDD补证；它不是完整RTL形式证明。 |
| 量化同边界物理收益及整机回归 | 六有效lane同约束PNR：3,706→2,700 XLR，减少1,006（27.1%），均12 DSP；最终setup/hold均正。三模型及原生完整host通过。叶级节省不能再与整机节省相加；量化单独替换的host MAP曾回退，记录保留。 |
| 压缩搬运与窗口选择：无损且保留通用合同 | 操作数8编码、11,016次768位比较、5,632合法回环（含640次PW回绕）、三种真实RTL故障负控通过。PW双像素/通道回绕、RGB分组、DW72位、残差16位及保留编码的原默认行为均保留。 |
| 窗口逐拍等价、容量及回压 | 现有one-hot窗口重新实际编译/运行：512深度46配置/4,560请求，1024深度57配置/6,120请求；共103配置/10,680请求，与基准逐拍、独立golden一致，保持周期4,116+5,686。实际源表和编译容量已保留。双槽、同步读、II=2不变。 |
| 完整算子、24/48通道和512/1024容量合同 | 当前one-hot完整算子无/有回压两轮各187作业、167,635向量、六复位模式通过；有回压192,713保持周期。默认资源探针24通道/512容量；扩大配置的兼容验证不代表同样资源占用或板卡容量签核。 |
| 真实资源收益、相关时序及完整视频吞吐 | 纯host同边界PNR净少842 XLR；官方S2+one-hot+唯一DDR实际PNR完成，指定host映射后CDC通过。三模型短图矩阵、稳定模型640×480六帧系统回归通过，五个完成间隔不劣于C37。详见后两节。 |

可复查入口：

- CPU生成/比较及接口：[实施记录](C39_THREE_OBJECTIVES_IMPLEMENTATION_20260915.md)、[S0 MAP](../logs/efinity_resource_runs/c39_joint_s0_c37_map_20260915a/summary.json)、[S2 MAP](../logs/efinity_resource_runs/c39_joint_s2_c37_map_20260915a/summary.json)、[联合接口原始输出](../logs/c39_resource_queue_runs/c39_onehot_acceptance_20260915a/joint_seam.stdout.log)。
- 量化：[本次原始RTL输出](../logs/c39_datapath_runs/c39_requant_terminal_20260915a/stdout.log)、[终态](../logs/c39_datapath_runs/c39_requant_terminal_20260915a/status.json)、[表达式证明边界](C39_REQUANT_ARITHMETIC_EQUIVALENCE_20260915.md)、[基线PNR](../logs/efinity_resource_runs/c39_quant_baseline_pnr_20260915b/summary.json)、[窄舍入PNR](../logs/efinity_resource_runs/c39_quant_narrow_pnr_20260915a/summary.json)。
- 操作数/窗口：[解包短测](../logs/c39_onehot_probe_20260915a.log)、[完整算子终态](../logs/c39_datapath_runs/c39_onehot_fallback_20260915a/status.json)、[窗口原始输出](../logs/c39_datapath_runs/c39_onehot_window_terminal_20260915a/stdout.log)、[窗口终态](../logs/c39_datapath_runs/c39_onehot_window_terminal_20260915a/status.json)。

## 2. 整机资源与时序

| 同边界纯host，标称150MHz | C37 | 当前C39 one-hot |
| --- | ---: | ---: |
| LUT4 / FF | 28,933 / 17,945 | 28,079 / 17,335 |
| 最终XLR | 41,318 | 40,476 |
| RAM / DSP | 117 / 121 | 117 / 121 |
| 最终setup / hold，ns | +0.267 / +0.026 | +0.606 / +0.026 |

整机净减少 **842 XLR，2.04%**，不是把各叶级收益线性叠加的估计。[实际C37结果](../logs/efinity_resource_runs/c37_resource24_pnr_20260915b/summary.json)、[实际C39结果](../logs/efinity_resource_runs/c39_host_onehot_pnr_20260915a/summary.json)。

真实 **S2 CPU + one-hot + 唯一DDR、100MHz联合探针**为 **51,900/60,800 XLR（85.36%）、165/256 RAM、125/160 DSP**；最终setup/hold为 **+0.293/+0.026ns**，核心同域setup +1.601ns。独立审计56同步FF、127+14跨域端点、32位标签及Gray skew 0.066/0.042ns通过。[联合派生复核](C39_ONEHOT_JOINT_RESOURCE_CDC_REVIEW_20260915.json)。

历史联合summary因顶层长名称截断，将FF漏为null、RAM误为0；没有覆盖原文件。实际保留根行及修正解析器确认35,368 LUT4/23,053 FF/165 RAM/125 DSP，以独立复核为准。旧native联合负时序、通用pack面积回退等失败记录均保留。工具完整`report_cdc`曾内部断言失败，指定host检查通过不能冒充全CPU/DDR/JTAG/复位CDC签核。

## 3. 实际六帧结果与吞吐边界

运行：`c39_onehot_stable_camera30_20260915b`。原运行自然结束，complete/0，独立终态检查通过；没有重新生成一个更容易通过的替代运行。前三模型队列的Starry/Mosaic四矩阵及小图原生时钟仿真也均完成并独立复查。

五个完成间隔（核心周期）：**6,316,040；6,343,354；6,433,652；6,398,800；6,358,814**。

- 最差间隔6,433,652，与C37基线相同；纯host标称150MHz换算的保守观测吞吐为 **23.314907 fps**，满足≥15fps且无最差间隔回退。
- 6个CNN帧、9次采集、14次显示、8,601,600个正确显示像素，underflow=0、display_misses=0。
- 最差已观测采集间隔对应约30.426556 fps；输入源没有通过降低采集频率来掩盖瓶颈。
- **不是板卡实测，不是100MHz官方CPU联合系统的实测帧率。** 不通过按时钟简单缩放来声称联合系统已达15fps。

证据：[原生原始输出](../logs/c39_onehot_trained_host_runs/c39_onehot_stable_camera30_20260915b/native_xsim.result.log)、[原生终态](../logs/c39_onehot_trained_host_runs/c39_onehot_stable_camera30_20260915b/status.json)、[三个模型队列](../logs/c39_model_queue_runs/c39_onehot_model_queue_20260915b/status.json)。独立命令：

```powershell
python -X utf8 -B case1/golden/check_c39_onehot_trained_pipeline.py --run c39_onehot_stable_camera30_20260915b --phase native
python -X utf8 -B case1/golden/c39_onehot_operator_preflight.py
python -X utf8 -B case1/golden/c39_joint_platform_selftest.py
python -X utf8 -B case1/golden/c39_joint_cdc_evidence.py --run c39_onehot_acceptance_20260915a_joint_s2_onehot_cdc
```

## 4. 后续开发入口与保留项

当前选用[one-hot纯host XML](../efinity/c1_ti60_c39_host_onehot.xml)及[真实S2联合XML](../efinity/c1_ti60_c39_joint_s2_onehot_cdc.xml)。准确选源见[六个替换文件与49源闭包说明](../rtl/c39/README.md)；不复制覆盖旧源，不通配导入所有版本。C37工程保留为回退。

S2软件使用当前[非压缩RV32IM入口](../software/c39_s2_probe/README.md)，六个当前驱动API均已实际构建/反汇编检查；[构建记录](../logs/c39_s2_driver_runs/c39_s2_driver_20260915a/summary.json)不代表CPU执行、PLIC或缓存运行验证。

仍属后续平台工作的事项：真实CPU启动/调试与应用运行、缓存一致性与DMA软件流程、官方CPU联合100MHz吞吐、完整摄像头/CSI/Debayer/HDMI和PLL/引脚集成、DDR PHY及板级验证。联合资源余量有限，不能直接把完整视频Demo再拼入。

额外`c39_window_factor`仍是未完成资源验证的实验，**没有选入当前已验收闭包，不作为本阶段必须完成项，也没有声称其收益**。

本轮模型、量化和窗口运行均无波形，原worker/子进程自然退出，已核实相应自有私有仿真目录消失。只保留小型原始日志、源码与结果；没有删除历史失败证据、企业源或生成的官方IP/BSP。
