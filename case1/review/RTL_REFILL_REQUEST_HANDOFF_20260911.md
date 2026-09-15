# 补给请求连续交接优化与验证

日期：2026-09-11。范围：厂商无关 RTL 的读补给调度；不覆盖板级集成或物理时序签核。

## 实际修改

`rtl/dma/c1_cache_refill_scheduler.sv` 新增默认关闭的 `ALLOW_REQ_HANDOFF`。
原模式每次请求握手后，pending 寄存槽留空一拍；新模式允许当前请求握手时
同时把下一请求写入该槽。VALID、地址和元数据仍从寄存器输出，不改为组合透传。

安全条件：

- 只在非末字、无维护/取消/延迟栅栏且命令有效时交接。
- 使用边沿前信用计数，要求 `meta_count < MAX_OUTSTANDING - 1`；不借用
  同拍响应释放的信用，不引入响应消费者 READY 到补给信用决策的组合路径。
- 握手请求的旧载荷写入 metadata FIFO，新载荷进入 pending 寄存器；地址
  加 stride，index 加一，重新计算 last，避免非阻塞赋值覆盖或错配。
- `MAX_OUTSTANDING=1` 时不能交接；保留停顿载荷稳定、旧 epoch 排空等断言，
  并新增 `meta_count + pending <= MAX_OUTSTANDING` 信用预留断言。

参数沿以下真实层级传递，均默认关闭：

| 文件/模块 | 参数 |
|---|---|
| `c1_r1_portable_soc` | `TENSOR_BURST_SCHED_REQ_HANDOFF` |
| `c1_tensor_window_cache_burst_axi_client` | `BURST_ALLOW_SCHED_REQ_HANDOFF` |
| `c1_window_line_cache_c8_exact_burst_shell` | `ALLOW_SCHED_REQ_HANDOFF` |
| `c1_cache_refill_scheduler_read_client_exact` | `ALLOW_SCHED_REQ_HANDOFF` |
| `c1_cache_refill_scheduler_read_client` | `ALLOW_SCHED_REQ_HANDOFF` |
| `c1_cache_refill_scheduler` | `ALLOW_REQ_HANDOFF` |

只有启用 tensor burst refill 的路径使用它。没有覆盖企业 IP、改变默认窗口或
缩小默认 FIFO。本轮也没有进一步增加 MAC 并行度。

## 性能结果与边界

长行负载沿用上一轮两条 1920 个 64-bit word，固定相同 FIFO、reader
outstanding、burst 上限及确定性背压。唯一新增开关是请求交接。

| 测试 | 原 cycles | 交接 cycles | 周期减少 | AR / R beats（两版相同） |
|---|---:|---:|---:|---:|
| 独立长行，窗口 16 | 9644 | 7227 | 25.06% | 241 / 1920 |
| 独立长行，窗口 32 | 8724 | 6173 | 29.24% | 121 / 1920 |
| 整机正常小图计算 | 73448 | 73249 | 0.271% | 不以独立长行计数替代整机 |
| 整机读取消后的恢复计算 | 73440 | 73202 | 0.324% | 恢复测试，不代表稳态帧率 |

长行每次核对完整 3840 个 64-bit word 及 row/index/epoch/error/last，全部
请求响应退休，调度器和 reader quiescent。最终运行包含新增信用预留断言：

- `review_handoff_long16_final_20260911`
- `review_handoff_long32_final_20260911`

对应基线为 `review_longrows_window16_final_20260911` 和
`review_longrows_window32_final_20260911`，详见
[长行基线记录](RTL_REFILL_LONG_ROWS_AB_20260911.md)。

整机仍是 12×10 输入缩放到 8×8 的真实 22-stage CNN，双采集与计算重叠、
queued write、fatal ticket 和 tensor burst refill 开启。两个运行：

- `review_soc_handoff_normal_20260911`：完整正常帧。
- `review_soc_handoff_cancel_20260911`：4 个读 beat 在途，阻塞 64 cycles，
  ABORT 后拒绝 START，排空后无复位恢复；3 次采集，只发布 1 次成功 DONE。

两者 Python golden 均通过：64 个计算输入、836 个 C8 中间结果、64 个 DDR
输出像素、120 个原始显示像素、64 个处理后显示像素。正常/恢复的校验器
破坏性负例分别通过 37/31 项；检查的是日志篡改拒绝，不是新增 RTL 故障数量。
正常帧 AW/W/B=864/912/864，恢复运行总量=938/1006/938；W-ahead 计数为 33。
显示换帧/新帧完成时间仍为 1732508/2030510 cycles，没有显示帧率收益证据。

## 信用与取消回归

扩展原 `tb_c1_cache_refill_scheduler.sv` 和独立 runner，增加窗口 1/2/3
及交接开关。保留 pending 停顿跨 ABORT、旧响应排空、新 epoch 命令、
held-high flush 单次推进及 orphan response 测试，新增实际交接覆盖计数。

| 运行后缀（均为 `review_handoff_..._20260911`） | 窗口 | 开关 | 实际交接 |
|---|---:|---:|---:|
| `credit1` | 1 | 开 | 0 |
| `credit2` | 2 | 开 | 1 |
| `credit3` | 3 | 开 | 2 |
| `default_retry` | 2 | 关 | 0 |

四组均 complete/exit=0；检查了最大信用、取消后无旧 epoch 泄漏和恢复输出。
首次 `default` 虽有仿真 PASS 文本，但 runner 报“流不可读”，状态 failed，
不计成功；不改 RTL 重跑 `default_retry` 后正常完成。

此外，本轮重新运行：

- `run_iverilog_review_fixes.ps1`：141 配置全部通过。
- `run_iverilog_rtl_compile.ps1 -QueuedWriteFabric`：131 sources，0 errors，
  608 条工具诊断仍存在，不宣称 warning-free。
- `test_portable_soc_compact_log.ps1`：通过，数值重复项保留以供检查器拒绝。

## 复现开关与后续工作

```powershell
# 三个 runner 均自行启动独立隐藏 worker；不要手工调用 -Worker。
& case1/scripts/run_cache_refill_scheduler_xsim_detached.ps1 -RunId <unique-id> -SchedulerWindow 3 -RequestHandoff
& case1/scripts/run_cache_refill_scheduler_read_client_xsim_detached.ps1 -RunId <unique-id> -SchedulerWindow 16 -LongRows -RequestHandoff
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -RunId <unique-id> -TrainedArtifact -NumericalTrace -ColorFixture -SourceGeometry -QueuedWriteFabric -ConcurrentCapture -RegisterFatalTicket -TensorBurstRefill -RefillRequestHandoff
# 最后一项增加 -InflightReadAbort 即读取消恢复场景。
```

新增的是 leaf READY 到 pending 更新使能/地址选择的路径；保留寄存边界不等于
已经证明物理时序无代价。默认开关保持 0，需再做 Efinity 完整映射/PNR、
实际大图 CNN/shared DDR 负载与资源比较，才考虑默认启用。当前仍未证明
15 fps、板级 DDR/MIPI/HDMI 或完整 Sapphire 集成，也未完成第三预览缓冲
的整机所有权与显示切换接线。

本轮共 11 个 xsim 运行（含早期长行两次及一次 runner 失败），逐个核查
状态记录中的临时目录，均已不存在。保留精简日志合计 144130 bytes，
约 140.8 KiB；没有保留波形或大型临时仿真工程。未修改 case2。
