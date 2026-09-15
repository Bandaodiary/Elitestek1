# 下一 tap 地址准备前移：整机吞吐收益确认

日期：2026-09-11。生产 RTL 已更新；`PREFETCH_NEXT_TAP_ADDRESS` 仍默认关闭。

## 1. 从上一轮证据出发

第一版只在请求握手后启动准备，在实际 cache 路径上 prepared=0，未减少整机周期。本轮没有改变 memory/cache 的服务延迟来制造命中，而是修改 adapter 的调度位置。

主要改动位于 `rtl/cnn/c1_r1_microstyle_tensor_adapter.sv`：

- 当前地址在 `ST_TENSOR_ADDR_FINAL` 锁存到 `request_addr_q` 时，就为下一 tap 装载坐标。请求与 cache sideband 的寄存器独立于地址计算临时寄存器。
- 在 `ST_READ_REQ` 的背压等待和 `ST_READ_RSP` 的响应等待期间都推进准备；请求握手不再清除其进度。
- phase 3 已具有寄存的 pixel-index，可在响应接收边界执行原有最终地址缩放并锁存请求地址；phase 4 则使用已经寄存的完整地址。不将行乘法与加法重新合并为一个无流水级的表达式。
- 快路径接到 tap k+1 时，同时准备 k+2，保证连续 tap 都可受益。当前 tap=7 时不再准备越界的 tap 9；当前 tap=8 继续按原流程结束窗口。
- 准备未完成仍走原地址状态。没有新增 speculative memory 请求，没有改变单 read outstanding、返回顺序和 abort 排空合同。

新增两个内部 task 用于复用准备/推进代码，仍在同一个时钟过程里更新寄存器，不是独立时钟域或新并发访存端口。综合后的算术共享、控制选择器开销及实际时序仍待测量。

## 2. 单元与取消边界

Icarus adapter **19 配置通过，退出码 0**。覆盖预计算开/关、两种地址流水线、随机/0/8 的 BFM 附加读延迟、结果写流水化组合，以及没有地址流水线时开关不生效的兼容路径。

前移后 phase 1 可以出现在请求尚未握手时，因此更新了定向测试：主动保持请求 ready=0，在 phase 1/3/4 注入 abort，三级模式额外覆盖 phase 2。检查请求不会撤回，随后放行请求，并继续压住响应至少 6 个检查周期，确认不能提前结束排空。另保留请求已接纳时的 abort 和读错误测试。不同场景间不做硬件 reset，实际重新提交任务。

两级流水线在零附加读延迟场景下已能全部命中；三级模式零附加读延迟仍有 664 命中/680 回退，故测试保留对该回退路径的覆盖门槛，而不是要求所有配置都必须回退。完整正常任务的窗口/残差/上采样与最终流检查保留。

## 3. 新版 RTL 的整机开关对照

两次运行均启用：三级地址流水线、DW 权重缓存、MAC 预取重叠、结果写流水化、tensor packing/end、queued write fabric、burst refill、真实参数、12×10→8×8 source geometry、并发采集及 RAW/APB 故障恢复。只有预计算开关不同。

| 成功任务指标 | 关闭 | 开启 |
|---|---:|---:|
| 周期 | 77681 | 69789 |
| 地址准备命中 / 回退 | 0 / 2688 | 2688 / 0 |
| ST_OPERAND_ADDR 周期 | 3584 | 896 |
| ST_TENSOR_ADDR_FINAL 周期 | 4456 | 1768 |
| adapter 输入等待 | 52524 | 44634 |
| 逻辑读 / 写 | 3620 / 836 | 3620 / 836 |
| engine feed | 896 | 896 |

成功任务减少 **7892 周期，约 10.16%**。命中数及地址状态计数共同证明优化确实被执行；其他状态的随机背压分布会随时序改变，不应把总周期差直接等同于全部省下的地址状态拍数。

两个运行名：

- `tap_prefetch_early_off_system_20260911`
- `tap_prefetch_early_on_system_20260911`

两者均为 complete、退出码 0。独立 Python golden 检查全部通过：22 阶段、836 C8、64 DDR 像素；原图显示 120 像素与风格显示 64 像素匹配。错误诊断、最终写响应保持 64 周期、DDR 已排空后源停止确认再延迟 32 周期、APB 恢复及无 reset 重启也通过。

整个测试的 AW/W/B 均为 628/770/628、写在途峰值 2。这是全测试计数，和上表成功任务计数口径不同。

仿真经原有 WMI/breakaway runner 独立启动；两个专属临时工程目录已清理，仅保留小型状态/trace。没有运行综合或修改企业原始工程。

## 4. 复现与适用范围

单元：

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_r1_microstyle_tensor_adapter -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
```

整机使用 `run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1`，共同参数为：

```text
-NumericalTrace -TrainedArtifact -TensorBurstRefill -RegisterFatalTicket
-SourceGeometry -QueuedWriteFabric -ConcurrentCapture -InflightWriteAbort
-RawRasterFault -RawIdleTimeout -ExplicitCaptureRecovery -RecoveryLateSourceAck
-ApbCaptureRecovery -CacheDwWeightTiles -MacPrefetchOverlap
-PipelinedResultWrites -TensorPackedWrites -TensorWriteEnd
-PipelinedAddress -PipelinedPixelIndex
```

开启组另加 `-PrefetchNextTapAddress`，每次使用新的 RunId。完成后用 `check_portable_soc_numerical_trace.py RUN目录 --require-apb-recovery --require-late-source-ack` 检查。

本收益是固定三级地址流水线配置内的对照，不证明比此前所有非流水化配置更快，也不证明目标频率提升、Ti60 时序收敛或原生 640×480 达到 15 fps。读请求数仍未下降，上层多 outstanding 和更广泛的数据复用仍是后续架构工作。还需补正常彩色连续帧验证及全量回归。
