# 地址准备前移后的完整回归与彩色双帧验证

日期：2026-09-11。此轮冻结生产 RTL，只执行验证并更新记录。

## 1. 当前完整 Icarus 套件

执行 `run_iverilog_review_fixes.ps1`，不传 TestTop，最终：

```text
C1_REVIEW_FIXES_REGRESSION_PASS configurations=639
```

进程退出码 0。639 是当前脚本定义的配置数，包含要求触发指定诊断的非法参数/故障配置，不表示全部可能参数组合已被穷举。新增的 IRQ 宽度、下一 tap 准备、请求未握手/已接纳时的取消和读错误检查均纳入本次完整运行；原有算术、流接口、DMA、缓存、CSR、CDC 和系统组合回归保留。

复现：

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
```

Icarus 运行不生成波形，脚本 finally 清理本轮临时 VVP/向量。检查同前缀残留仅发现当天 10:08/10:10 的既有目录/文件，早于本轮约 14:21 的启动时间；未删除这些不属于本轮的对象。

## 2. 正常彩色双帧整机

运行 `early_tap_color_twoframe_20260911`：complete，退出码 0，294.071 秒。启用真实参数、color fixture、burst refill、queued writes、DW 权重缓存、MAC 预取重叠、结果写流水化、tensor packing/end、三级地址流水线及下一 tap 准备。两幅正常任务串行提交，不能将此测试称为所有帧并行或持续满速视频验证。

独立 Python 检查结果：

```text
C1_TWO_FRAME_GOLDEN_PASS frames=2 inputs=128 C8_results=1672 DDR_pixels=128 independent_source=1
C1_TWO_FRAME_VIDEO_GOLDEN_PASS frames=2 raw_pixels=128 styled_pixels=128
C1_TWO_FRAME_COLOR_GOLDEN_PASS frames=2 independent_RGGB_planes=1
C1_TWO_FRAME_NEGATIVE_PASS cases=39
```

同时强制要求彩色输入和两路视频 trace。39 项负测试验证检查器拒绝预设的缺失/损坏证据，不是额外 39 次 RTL 故障注入。

| 成功任务 | 周期 | 地址准备命中 | 回退 | 逻辑读 / 写 |
|---|---:|---:|---:|---:|
| 第 1 帧 | 54099 | 2688 | 0 | 3620 / 836 |
| 第 2 帧 | 54056 | 2688 | 0 | 3620 / 836 |

两帧完整结果正确且均使用准备路径，没有在本场景发现前一帧的地址/窗口状态残留。这里没有关闭开关的同场景对照，因此不从本表计算新的优化百分比；上一轮 10.16% 仍只适用于其固定故障恢复对照配置。

复现整机启动参数：

```text
-TwoFrame -TwoFrameTrace -TrainedArtifact -ColorFixture -TensorBurstRefill
-RegisterFatalTicket -QueuedWriteFabric -CacheDwWeightTiles -MacPrefetchOverlap
-PipelinedResultWrites -TensorPackedWrites -TensorWriteEnd
-PipelinedAddress -PipelinedPixelIndex -PrefetchNextTapAddress
```

通过 `run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1`、使用新的 RunId 启动，保持 WMI/breakaway 独立进程方式。完成后执行：

```powershell
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/golden/check_portable_soc_two_frame_trace.py case1/logs/portable_soc_cache_ddr_bfm_runs/early_tap_color_twoframe_20260911 --require-video --require-color --self-test
```

确认 xsim 专属临时工程目录不存在，仅保留状态和有限 trace/摘要。

## 3. 仍未证明的事项

本轮补齐当前套件与正常彩色连续任务证据，但不证明原生 640×480/15 fps、无限连续流、实际器件资源或时序、厂商 IP 和物理 CDC 签核。优化继续默认关闭；上层读请求仍单 outstanding，读次数没有下降，后续架构工作应继续针对实际访存/计算等待推进。
