# C39 one-hot 操作数解包：已验收开发组合

独立候选，不覆盖 C37 或已测 native。仅替换 `c39_operand_unpack` 的组合选择网络：共享 PW/RGB/DW/residual 译码，各源先掩码再并行 OR。保留 PW 通道回绕判定、RGB 三通道分组、DW 72 位、残差 16 位和其他模式的默认广播行为。

- 不减少 96 路 MAC、存储容量、模式范围或流水级，不改权重、舍入和输出数值。
- 原生工程中的旧 `u_unpack` 实测为 1,025 LUT4；这是优化对象规模，不是承诺节省量。
- [源码及工程检查器](../../golden/c39_onehot_sources.py)验证完整 native 父版本和当前 49 源闭包。
- [验证入口](../../golden/run_c39_onehot_probe.py)：8 种编码、11,016 次 768 位比较；复用 5,632 组合法操作数回环，另做三种真实 RTL 故障注入。这里只验证组合功能，不替代整机回压、原生帧率或实际布线。
- [独立综合工程](../../efinity/c1_ti60_c39_host_onehot.xml)保留 native/C37 相同模型、探针边界及约束。

2026-09-15：源码生成一致性检查通过；实际 Icarus 的 11,016 次逐位比较、5,632 组合法操作数回环（640 次 PW 回绕）和三种真实 RTL 故障负控全部通过。私有目录自动清理，无波形。证据见[短测日志](../../logs/c39_onehot_probe_20260915a.log)。

`c39_host_onehot_pnr_20260915a` 已完成实际综合/布线并清理：28,079 LUT4 /17,335 FF，**40,476 XLR /117 RAM /121 DSP**。同边界C37为41,318 XLR，净少842（2.04%），比native少609；当前纯host约束下setup/hold为+0.606/+0.026ns。见[实际摘要](../../logs/efinity_resource_runs/c39_host_onehot_pnr_20260915a/summary.json)。

全算子双回压已实际通过：`c39_onehot_fallback_20260915a`两轮各187作业/167,635向量、六种复位，原进程退出及私有目录清理，独立终态门槛通过。联合接口9项和三种真实连线负控也通过（行为CPU/DDR）。

2026-09-15最终结果：三个模型及640×480六帧系统回归已完成，实际最差间隔6,433,652周期，标称150MHz下约23.315fps，与C37无回退。当前组合已选为后续开发入口，不覆盖C37；这不是板级或100MHz官方CPU联合吞吐签核。[最终验收](../../review/C39_THREE_OBJECTIVES_FINAL_ACCEPTANCE_20260915.md)。

20:37更新：带逐端点CDC的S2/DDR联合探针正实际PNR，三模型整机队列等待；保留每次编译的小型来源表，不保留大型vvp或仿真工程。见[验收运行链](../../review/C39_ONEHOT_ACCEPTANCE_20260915.md)。

20:53更新：上述联合PNR已完成/清理，51,900 XLR/165 RAM/125 DSP，最终setup/hold +0.293/+0.026ns；指定host映射后CDC独立检查通过。完整工具CDC分类失败，不是CPU/DDR PHY/JTAG/复位/板测签核。[独立复核](../../review/C39_ONEHOT_JOINT_RESOURCE_CDC_REVIEW_20260915.json)。修复历史报告顶层截断解析后，三模型b队列已通过前检并运行Starry host矩阵，尚无新帧率结果。
