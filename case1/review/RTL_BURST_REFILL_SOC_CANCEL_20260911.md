# Burst 缓存补给与整机取消/恢复组合

日期：2026-09-11。本轮延续同负载实测中 burst 补给约 16.12% 的计算周期收益，
补其整机取消与恢复门，不改变生产 RTL 或默认开关。

## 场景区分

### A. 开启 burst 补给后的双 writer 在途取消

复用已验证的真实摄像头采集/CNN 并发写负载，启用 `TensorBurstRefill`。
分别使用逻辑响应 FIFO 和 beat 响应 FIFO。两笔 AW/W 已接受、B 尚未退休时
发送真实 APB ABORT；在保留 B 的 64 周期内拒绝 START、不重新分配帧；排空
后不复位，再执行一帧完整 CNN/显示。

这一场景只能证明“开启 burst 补给后，双 writer 取消仍兼容”，不能证明
取消当时缓存读 burst 本身正在等待 R。

### B. 实际 tensor refill 读 burst 在途取消

新增 `-InflightReadAbort`，要求 `ConcurrentCapture + TensorBurstRefill`，
与 InflightWriteAbort/SerializeWriteData 互斥。共用取消后的排空/重启/golden
代码，但用独立触发条件与断言，不复用写取消标志冒充读覆盖：

1. 第一帧运行 CNN，第二帧经过实际采集进入另一受管输入槽。
2. 等物理读事务已接受，fabric owner=6、ARLEN>0、R index=0 且尚未呈现
   RVALID，确认这是 tensor cache refill，而非参数表或输入图像读取。
3. BFM 只延迟尚未呈现的 R 响应，不撤回 VALID、不改变 AR/数据/时钟/复位。
4. APB ABORT 后再次 START 必须 PSLVERR；64 周期检查 system/fabric read busy
   保持、原 R 事务仍活动、AR/R 计数不变、cache abort_done 不提前出现、
   capture/CNN 不重新获授、软件没有假 DONE。
5. 释放 R，等待系统及所有模型在途事务排空，再无复位重启。
6. 仅记录恢复作业的数值 trace：实际输入、全部 22 stage、物理 DDR 输出及
   两路显示；被取消作业的部分计算不混入 golden。

测试先确认有真实被接受的 burst，再使用有限响应延迟；不通过内部强制状态
来模拟取消成功，也不靠复位删除 AXI 欠账。

## 实测结果

四个运行均 complete/exit=0，保持 ticket 广播和深度 4 队列写：

| 运行 | FIFO 模式 | 主机耗时（秒） | 覆盖及累计写事务 |
|---|---|---:|---|
| `review_burst_cancel_logical_20260911` | logical | 104.129 | 两笔写待 B；AW/W/B=869/919/869 |
| `review_burst_cancel_beat_20260911` | beat | 102.001 | 两笔写待 B；AW/W/B=869/919/869 |
| `review_refill_cancel_logical_20260911` | logical | 84.888 | owner=6，4 beats 待 R；AW/W/B=938/1006/938 |
| `review_refill_cancel_beat_20260911` | beat | 85.919 | owner=6，4 beats 待 R；AW/W/B=938/1006/938 |

所有场景都检查 64 周期取消栅栏、三次采集、一次成功完成、无复位恢复。
每个恢复帧均有 64 输入、22 stage/836 C8、64 物理 DDR 输出及 120/64 显示
像素逐项匹配 golden；每配置 **25 个检查器变异反例全部拒绝**。
读场景的最终独立标志为：

```text
C1_SOC_INFLIGHT_READ_ABORT_PASS pending_beats=4 held_cycles=64 captures=3 done=1 owner=6 reset=0
```

四个临时工程目录全部不存在，仅保留合计 **222822 bytes** 精简日志，约
217.6 KiB。继续使用脱离 Codex Windows Job 的隐藏 worker，不生成波形。
本轮只改 testbench/runner/日志测试，未修改生产 RTL，未重跑全量 Icarus；
生产 RTL 最近的全量基线仍为前轮通过的 141 配置。

## 检查与复现

共同参数：

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -RunId <unique-id> -TrainedArtifact -NumericalTrace -ColorFixture -SourceGeometry -QueuedWriteFabric -ConcurrentCapture -RegisterFatalTicket -TensorBurstRefill -InflightReadAbort
# 写取消使用 -InflightWriteAbort 替代 -InflightReadAbort。
# 两种场景的 beat FIFO 对照均另外加 -TensorBurstBeatMode。
& <python> case1/golden/check_portable_soc_numerical_trace.py <run-log-dir> --require-video --require-queued-write
& <python> case1/golden/test_portable_soc_numerical_trace.py <run-log-dir>
```

这些恢复模式不要使用 `--require-concurrent-capture`：它要求两次采集且第一帧
成功完成，而此处是前两帧被取消/丢弃、第三帧恢复。取消覆盖由 SV 专属断言
与 runner 的唯一 PASS 标志检查。

runner 增加读取消阶段日志保留；内存内日志测试已验证早期读/写取消记录不被
80 行尾部截断、重复数值不被去重。该保留扩展在本轮读仿真启动后完成，不能
据此声称已生成的日志必含早期 DRAIN 标志；最终 READ_ABORT_PASS 自带覆盖值。

## 边界

上述只覆盖合法 AXI、指定小图和有界响应延迟。尚不覆盖真实 DDR PHY、在途
协议硬故障、所有 R beat 位置的取消、长时间连续视频或原生 15 fps。
未进行新的综合/PNR，不以 FIFO 功能等价推断 Ti60 的物理资源等价。
