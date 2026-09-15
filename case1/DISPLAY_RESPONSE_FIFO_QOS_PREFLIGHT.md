# Display response FIFO / QoS boardless preflight

更新时间：2026-08-25。

## 目的

portable SoC 的默认双路 display reader 通过无 ID 的串行 AXI read arbiter
返回数据。旧路径要求 line-store 立即接收每个 R beat；当 pixel/control 域
暂时保持 line-store 时，一个 display reader 会长时间拉低 `RREADY`，把
read owner 锁在该 client 上。`PORTABLE_SOC_AXI_CLIENT_MONITOR.md` 记录的
基线是 styled-display client-5 的 `max AR wait=1,243,738` cycles，以及
original-display client-4 的 `R` response hold `1,243,662` cycles。

本预检加入一个可选、默认关闭的 display response FIFO：

```text
AXI XRGB reader → 59-bit token FIFO → dual-clock line store
```

token 为 `{eof,eol,sof,y,x,rgb}`。FIFO 分支默认在测试台使用 depth=128，
每个 reader 保留 64 个 token 的入站空间（最大 16-beat AXI burst × 4
pixels/beat）。reader 只在 `ST_PREPARE` 阶段等待 credit；一旦进入 `ST_AR`，
reader 自己保持 `ARVALID` 和 payload 直到握手。display prefetch pair 内还
有仿真期稳定性检查，防止 FIFO 门控撤回 stalled `ARVALID`。

顶层参数如下，默认值保持历史 wire-level bypass：

```systemverilog
.ENABLE_DISPLAY_RESPONSE_FIFO(0),
.DISPLAY_RESPONSE_FIFO_DEPTH(64)
```

测试台通过 `-DisplayResponseFifo` 把它切换为 `ENABLE=1, DEPTH=128`。

## 已验证运行

所有运行均由 WMI 隐藏 worker 启动，xvlog/xelab/xsim stderr 为空，且仿真
结束后没有残留 Vivado/xsim 进程。

| run | 结果 | 关键证据 |
|---|---|---|
| `portable_display_fifo_reader_gate_elab_20260825` | 严格 PASS | 64×48 FIFO 分支 xvlog/xelab elaboration 通过 |
| `portable_display_fifo_reader_gate_full_64x48_20260825` | 严格 PASS | `c4/c5 max AR wait=76/83`；`r4/r5 hold=2/2`；`C1_R1_PORTABLE_SOC_AXI_CLIENT_MONITOR_PASS`；完整 BFM `AW/W/B=40224/41664/40224`、`AR/R=48427/51643`、`display_done=1` |
| `native_display_fifo_elab_20260825` | 严格 PASS | 640×480 FIFO 分支 elaboration 通过 |
| `native_display_fifo_full_20260825` | 严格 PASS | 真实 display pair 逐像素 RGB 比对：`responses=307200/307200`、`axi_ar=4800/4800`、`axi_r=76800/76800`、`underflow=0/0` |
| `portable_display_fifo_bypass_functional_8x8_20260825` | 严格 PASS | 默认 FIFO=0 的原有功能链 `done=1`, `display_done=1`, `AW/W/B=852/868/852`, `AR/R=1119/2199` |
| `portable_display_fifo_bypass_gate_8x8_20260825` | 诊断 FAIL（预期） | 默认旁路仍暴露 ID-less HOL：c5 `max AR wait=1,940,204`，c4 `R hold=1,940,197`；不是 FIFO 分支回归失败 |
| `display_fifo_twoframe_review_64x48_20260825` | 已定位并废弃 | 早期 FIFO gate 同时使用 `!hold_requests`，单帧 monitor PASS 但第二 pair `Fatal: second display pair did not swap count=1`；根因是把 pixel-domain hold 错误地施加到 core-domain AR admission |
| `portable_display_fifo_credit_only_twoframe_8x8_20260825` | 严格 PASS | 移除 `!hold_requests`、保留 credit-only pre-AR gate 后，`done=2 swaps=2 drops=0 display_done=1`，monitor PASS；`start_ready/done` 另外等待 FIFO/line-store drain |
| `portable_display_fifo_twoframe_monitor2_64x48_20260825` | 严格 PASS | 两帧汇总 monitor（`job_completions=2`）：c4/c5 `AR/R=100/1600`、max wait `89/83`、R hold `2/2`；BFM `done=2 swaps=2 drops=0`, `AW/W/B=80448/83328/80448`, `AR/R=96796/102358` |
| `portable_display_fifo_bypass_final_8x8_20260825` | 严格 PASS | 最新 reader API/drain-guard 后的默认 FIFO=0 兼容性回归：`done=1 swaps=1 drops=0 display_done=1`，`AW/W/B=852/868/852`、`AR/R=1119/2199`，xsim stderr 为空 |
| `native_display_fifo_final_20260825` | 严格 PASS | 最新 reader API/drain-guard 后的 640×480 FIFO pixel gate：`responses=307200/307200`、`axi_ar=4800/4800`、`axi_r=76800/76800`、`underflow=0/0`，xvlog/xelab/xsim stderr 为空 |
| `portable_fifo_native_elab_final_20260825` | 严格 PASS | 完整 portable SoC 七客户端顶层在 `640×480 + C1_DISPLAY_RESPONSE_FIFO` 参数下 xvlog/xelab 通过，elaboration stderr 为空；未启动长帧 xsim |
| `native_qos_fifo_tagged_twoframe_v1`（2026-08-28） | 严格 PASS | 8×8、`-DisplayResponseFifo -SharedQosMonitor -TwoFrame`：`done=2 swaps=2 drops=0`；tagged 事件 `start/new_done/swap=2/2/2`；`r4_stall=27`、`r5_stall=27`、`ar4_wait=194`、`ar5_wait=234`、`read_busy=17254`、`last_frame_cycles=3446518`、`underflow=2`、`deadline_miss=2`、`protocol=0`；APB `C1_QOS_APB_READBACK pass=1`。相对同源 bypass baseline 的百万级 display HOL 已基本消除，但总 frame cycles/deadline 未改善，瓶颈已转移到其他 client/调度路径 |
| `native_qos_fifo_tagged_64x48_twoframe_v1`（2026-08-28） | 诊断超时（不作 PASS） | 原 boundary guard 固定 5 M core cycles 时，事件为 `start/raw_done/new_done/swap=2/2/1/2`、`monitor_frame=1`；第二 pair 已完成 VSYNC swap，但像素域尚未完成最后 line-store drain。无 reader error/protocol error；该记录用于定位观察窗口问题，runRoot 已清理 |
| `native_qos_fifo_tagged_64x48_twoframe_v2`（2026-08-28） | 严格 PASS | 在测试台按形状将 QoS boundary guard 提升为 20 M core cycles（DUT 未变）后，`done=2 swaps=2 drops=0 descriptors=44`，tagged 事件 `start/raw_done/new_done/swap=2/3/2/2`、`monitor_frame=2 active=0`；`r4_stall=4305`、`r5_stall=3499`、`ar4_wait=941`、`ar5_wait=1005`、`read_busy=626599`、`last_frame_cycles=5086618`、`underflow=3`、`deadline_miss=2`、`protocol=0`；APB `C1_QOS_APB_READBACK pass=1`，AXI `AW/W/B=80448/83328/80448`、`AR/R=96884/103766`。第二 tagged completion 在约 90.48 ms 到达，证实 v1 是固定观察上限不足而非 FIFO 死锁 |

## 资源边界

FIFO 存储下界为 `59 × 128 × 2 = 15,104 bit`（约 1.85 KiB），depth=64
时为 7,552 bit；实际会按 Vivado/Efinity 的 LUTRAM/BRAM 推断方式变化。当前
没有把该原型宣称为 Ti60 LE/M10K 资源报告，也没有做 Efinity mapping、DDR
PHY、显示时钟或功耗签核。默认 bypass 不增加这两组 FIFO 的存储资源。

FIFO 解决的是“已接受 display burst 在 line-store 暂停期间的响应吸收”和
read-owner 长 hold；`hold_requests` 只冻结 pixel request，不阻塞 core-domain
新 pair 预取；`start_ready/done` 还要等 FIFO 与 line-store 完整 drain。它不改变 correctness-first tensor adapter 的单
outstanding 结构，也不证明 native CNN、15 fps、长期 frame deadline 或
板上 HDMI/MIPI 稳定性。

### 2026-08-28 native QoS A/B 结论

同一 BFM、同一 tagged frame boundary、其余吞吐开关全部关闭时，bypass
(`native_qos_8x8_tagged_twoframe_v7`) 的 `r4_stall≈5.34 M`、`ar5_wait≈5.34 M`，
而 FIFO (`native_qos_fifo_tagged_twoframe_v1`) 降为 `r4/r5=27/27`、
`ar4/ar5=194/234`，`read_busy` 从约 `5.36 M` 降到约 `17 k`。AXI 事务/生命周期
和 tagged terminal 守恒，且 APB aggregate 逐字段读回通过；但两者
`last_frame_cycles=3446518`、`deadline_miss=2`、`underflow=2` 相同。结论是 FIFO
确实修复 display response HOL/供数隔离，却不是端到端 15 fps 加速器；下一步
应对 client-6 tensor、compute-start/descriptor 和共享调度做同样的 cycle attribution。
APB 读窗口为 live、非原子多寄存器读，BFM 对单调 busy/owner 计数允许读期间继续
增加，软件若需严格一致性应在 idle 后读取或增加后续 freeze/latch 命令。

对 64×48 形状，首轮 5 M-cycle guard 在第二次 VSYNC swap 后提前结束；将该
测试台观察上限按形状提升到 20 M 后，第二个 tagged terminal 在约 90.48 ms
到达并严格 PASS。该调整只改变回归等待上限和超时诊断，不改变 prefetch/FIFO
RTL，也不应被解释为硬件 watchdog 或帧率改善。

Vivado proxy 已在 `display_fifo_proxy_async_final2_20260825` 完成 bypass/FIFO
双变体综合：fifo128 相对 bypass 为 `+494 LUT/+44 FF/+304 LUTRAM`，core 100 MHz
WNS 从 `+3.265 ns` 降到 `+2.470 ns`，pixel 71.43 MHz WNS 保持 `+8.470 ns`。
这是 Xilinx proxy part 的结构预算，完整表格和报告路径见
`DISPLAY_RESPONSE_FIFO_PROXY_SYNTH.md`；不能替代 Efinity/Ti60 mapping。
完整 portable SoC 的最终源码 native proxy 也已完成：fifo128 相对 bypass 为
`+506 LUT/+41 FF/+304 LUTRAM`，而 core WNS 在两种变体均为 `-53.327 ns`；
这表明当前主瓶颈是 CNN/tensor/控制关键路径，详见
`PORTABLE_SOC_FIFO_PROXY_SYNTH.md`。

## 复现

portable SoC 64×48 FIFO gate：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\case1\scripts\run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 `
  -Frame 64x48 -DisplayResponseFifo -ClientTrafficGate `
  -RunId portable_display_fifo_reader_gate_full_64x48_20260825
```

native 640×480 display FIFO pixel gate：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\case1\scripts\run_r1_native_display_prefetch_xsim_detached.ps1 `
  -ResponseFifo -RunId native_display_fifo_final_20260825
```

下一步是把相同的 monitor/underflow/deadline 条件带入 native portable-SoC
长帧，并在已安装的易灵思工具链中、使用确切板卡器件/DDR 约束后复核映射；在此之前不应
把 FIFO prototype 当作 Ti60 资源或 15-fps 完成结论。

64×48 的 v3 client-dump 进一步确认了瓶颈转移：display reader 的 `r_stall`
已经只有约 4.3k/3.5k cycles，而 tensor/cache client-6 承担了
`96384` 次读和 `80256` 次写，`owner_hold` 达到 `511230/618270` cycles。
因此 FIFO 阶段已完成其预期的 HOL 隔离；下一阶段应针对 client-6 的批量
发射、写回和可取消的 outstanding 事务设计独立 seam，而不是继续增加
display FIFO 深度。
