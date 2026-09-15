# 整机在途写取消、无复位恢复及 DONE 优先级修复

日期：2026-09-11。范围：厂商无关 RTL、控制器 Icarus 回归与 detached xsim。

## 1. 生产 RTL 缺陷与修复

`rtl/top/c1_r1_soc_control.sv` 原先直接将 `boardless_done` 转为软件
`done_event`。当软件 ABORT 与子系统 DONE 同拍时，另一个时序块优先处理
`manager_abort`，丢弃 pending pair 和 NN 完成事件，但软件仍得到成功通知。
这会出现“软件认为完成，系统却没有可交付结果帧”的不一致。

在 `tb_c1_r1_soc_control.sv` 增加同拍碰撞测试后，旧 RTL 确实失败：

```text
ABORT and child DONE collision published success
```

生产修复：仅在 `boardless_done && !manager_abort` 时发布 `done_event`。
它与 pending pair 的取消优先级一致，不增加端口、周期、存储或默认参数。
修复后控制器四种配置均通过；随后完整 Icarus **141 配置通过**。
原有正常 DONE 场景仍在回归中。本次定向碰撞覆盖软件 ABORT，不扩大为所有
异步错误与完成事件排列的穷尽证明。

## 2. 帧所有权与实际 AXI 在途取消

帧管理器的 ABORT 会将非显示帧的逻辑状态立即变为 FREE；这不代表物理
AXI 已排空。当前外围安全契约是：关闭准入，并由 writer、boardless、清理
状态与 fabric busy 阻止新的 START/帧分配，直到已接受事务全部退休。
不能把 `c1_frame_manager` 的 FREE 单独当作 DDR 缓冲可重用凭据。

新增 runner 参数 `-InflightWriteAbort`，依赖 `-ConcurrentCapture`，后者要求
`-QueuedWriteFabric -SourceGeometry -NumericalTrace -TrainedArtifact`。
测试不强制内部 AXI 信号、不复位清除欠账，使用真实 APB 和真实两个 writer：

1. 连续模式采集第一帧并开始 CNN，第二帧实际进入另一个受管输入槽。
2. 等物理 AXI 已接受至少两笔写请求，再暂停 BFM **尚未呈现的** B 响应；
   已呈现 BVALID 不撤回。等两笔 W 均完成，确认 capture/CNN/fabric 都 busy。
3. 发 APB ABORT；在 B 响应未退休时再发 START，必须得到 PSLVERR。
4. 保留响应并检查 64 个 core 周期：system/fabric busy 保持、无新 capture
   或 CNN grant/start、无假 DONE、B 不退休；稳定窗口也不产生额外 AW。
5. 释放 B；14 笔已接受写全部退休，系统排空，无错误、无 DONE。
6. 不复位，仅恢复下一次 START 的几何 CSR，再采集第三帧运行完整 CNN/显示。

## 3. 最新验证结果

两配置均使用本次 DONE 优先级修复后的生产 RTL：

- direct：`review_inflight_abort_direct4_20260911`，66.940 s，complete/exit=0。
- ticket：`review_inflight_abort_ticket4_20260911`，68.031 s，complete/exit=0。

共同结果：

```text
C1_SOC_INFLIGHT_WRITE_ABORT_PASS pending=2 held_cycles=64 captures=3 done=1 aw=868 b=868 reset=0
C1_SOC_QUEUED_WRITE_TRACE_PASS aw=868 w=918 b=868 peak=2 ahead=3
C1_SOC_VIDEO_GOLDEN_PASS raw_pixels=120 styled_pixels=64
C1_SOC_NUMERICAL_GOLDEN_PASS fixture=color_rggb resize=downsample_12x10 inputs=64 stages=22 C8_results=836 DDR_pixels=64
```

数值 trace 仅从恢复作业开始，不混入被取消作业。检查器逐项比较恢复帧的
64 个输入、836 个 C8 中间结果、物理 DDR 的 64 个输出、120/64 个显示像素；
两配置分别通过 23 个检查器变异反例。上述 AW/W/B 是取消前后累计值，
不是一帧独立的性能计数。

复现入口：

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -Python <python> -TestTop tb_c1_r1_soc_control
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -RunId <unique-id> -TrainedArtifact -NumericalTrace -ColorFixture -SourceGeometry -QueuedWriteFabric -ConcurrentCapture -InflightWriteAbort
# ticket 配置另加 -RegisterFatalTicket；等待对应 status.json 为 complete。
& <python> case1/golden/check_portable_soc_numerical_trace.py <run-log-dir> --require-video --require-queued-write
& <python> case1/golden/test_portable_soc_numerical_trace.py <run-log-dir>
& case1/scripts/test_portable_soc_compact_log.ps1
```

本模式不能加 `--require-concurrent-capture`：那个检查器标志要求两次采集且第一帧
正常完成，本模式则是两帧取消后第三帧恢复；取消门由专用 SV 断言及 runner 标志检查。

## 4. 验证基础设施修复及失败记录

- 初版 direct/ticket 将 B 暂停得过早，使 CNN 持有共享读路径，第二帧无法先读
  缓冲表。已定位并只停止这两个测试内核，由独立 runner 清理；没有停止其他任务。
  改为确认真实并发 AW 后才暂停 B，避免人为制造与目标场景不同的依赖阻塞。
- 第二版 direct2/ticket2 已通过 14 笔写排空，但旧性能观察器只认识 DONE/error，
  不认识软件 ABORT，因而在重启时报 overlapping jobs。观察器现增加独立 ABORT
  记录并结束取消区间，不将它伪装成成功任务。
- direct3/ticket3 生命周期通过；direct4/ticket4 进一步验证最新生产 RTL 和恢复帧
  的完整 golden，作为本轮最终证据。
- 日志精简原有全局 `Select-Object -Unique` 会删除相同的重复数值记录，削弱
  检查器发现重复输出的能力。现在按保留集合排除尾部重叠，不再全局去重。
  内存内测试确认重复数值仍保留两次、尾部不重复追加、早期取消证据保留、
  空日志处理正确，不读写测试临时文件。该日志修复在最终两次 xsim 启动后完成，
  由独立函数测试验证；不冒称这两份已生成日志使用了新精简函数。

## 5. 文件与结论边界

本轮八个 xsim 临时工程全部清理，仅留下合计 **276628 bytes** 的精简日志
（约 270.1 KiB，含四次失败与四次完成记录）。进程继续使用脱离 Codex Windows
Job 的隐藏 worker；不生成波形。未进行新的 Efinity map/PNR 或板测。

这次证明指定合法 AXI、双 writer、延迟 B 场景下的软件取消栅栏和无复位恢复。
并未验证在多笔在途事务中注入非法早到 B/WLAST 的整机恢复；协议硬故障仍按
共同复位契约处理。未验证长时间连续视频、原生完整 CNN、第三预览缓冲集成、
同负载性能收益或 15 fps。这些仍是后续工作，而非本轮成功条件的外推。
