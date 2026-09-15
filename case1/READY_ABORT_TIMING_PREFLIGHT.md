# ready/abort 控制路径时序前置分析

更新时间：2026-08-25。

本文记录 full product→pair→quad→dot tree 与 5-bit descriptor prevalidation 打开后的
640×480 Vivado proxy 关键路径，并规定下一轮控制路径流水化的边界。该分析不改变默认
RTL 行为；`PIPELINED_*` 与 `PREVALIDATE_DESCRIPTOR_REPLAY` 仍全部默认关闭。

## 观测到的路径

报告目录：

`case1/sim/portable_soc_descriptor_relaxed_run_prevalidate_treefull_proxy_final_20260825/reports/`

最差 Q→D 路径为：

```text
camera FIFO rd_bin Q
  → table-reader error_event
  → CSR request_seen/abort_seen
  → parameter_abort_request
  → tensor_adapter compute_abort
  → CNN adapter_result_ready / product_valid
  → full-tree requant_in_ready / stage ready
  → DW/parameter scheduler/descriptor decoder
  → microstyle engine state_q D
```

量化结果：

| 项目 | 数值 |
|---|---:|
| data path delay | 14.550 ns |
| Q→D WNS（10 ns core clock） | -4.701 ns |
| logic levels | 21 |
| logic / route | 3.527 / 11.023 ns |
| 关键网扇出 | `parameter_abort_request` 约 158，`compute_abort` 约 95 |

同一个错误/取消广播还形成了 boardless DMA、dispatcher、job-controller 和
compute-shell 的多个负 slack 路径（约 -4.18 ns 至 -3.04 ns）。因此这不是单一
MAC 加法器的慢路径，而是一个低频 error/abort 事件经过高扇出控制网后，反向穿过
elastic ready 链的路径。

## 为什么暂不直接寄存 ready/abort

当前协议明确要求：

1. AXI AR 已握手后不得撤销，必须由 `c1_axi_read_abort_fence` 排空 R beat；
2. capture/table、input/output DMA、tensor cache 和 CNN 必须在 abort 后保持
   `busy`，直到各自 `abort_done/quiescent` 收口；
3. full-tree 的 `ready` 是 elastic pipeline 的反压信号，裸插一个寄存器会改变
   `valid/ready` 的相位，容易造成重复消费或丢失最后一个 group；
4. `manager_abort` 同时用于 soc-control 自身状态清零和下游模块取消。只延迟下游
   端而不延迟控制状态，会产生一个周期的状态不一致；整体延迟则必须重新证明
   start/abort、AXI drain 和 display ownership 合同。

所以，当前结果不能用“把 abort 延迟一拍”作为无条件修复，也不能把这条路径直接
标成 false path。

## 推荐的下一轮实验顺序

### A. 无行为变化的控制网复制实验

增加一个默认关闭的 `REPLICATE_ABORT_CONTROL` synthesis generic，在
`c1_r1_soc_control` 内将 `manager_abort` 分成受 `max_fanout` 约束的局部复制树。
该实验只改变网表复制，不改变 abort 的时钟周期和 AXI drain 语义。验收：

- 8×8 单帧、两帧和 abort/error directed regression 全部通过；
- `system_busy`、`abort_done`、`quiescent` 计数与 baseline 一致；
- proxy 的 error-path WNS 至少改善，且 LUT/FF 增量可解释；
- 若 Vivado 不复制或 route 仍占主导，撤销该方向。

### B. 局部 elastic/skid 边界

若 A 无效，只在 decoder→engine 或 dot MAC output 处加入带 payload 的
`valid/data/ready` skid/elastic 边界，并把 abort 定义为清空 valid，而不是单独
延迟 ready。必须新增 bubble、backpressure、abort-at-each-stage 定向向量，再跑
8×8/16×8 两帧和 native 640×480 elaboration。

### C. 受控多周期约束（最后考虑）

只有在系统规格明确允许错误恢复延迟至少一拍时，才评估对 error/abort recovery
路径使用 multicycle constraint；必须同时设置 hold 约束并保留 AXI/CDC/功能回归。
该约束不能用于正常像素/参数/ready 数据路径，也不能代替 Efinity/Ti60 签核。

## 复制树实验结果

`REPLICATE_ABORT_CONTROL=1` 只复制组合 `manager_abort` 广播树，不插入寄存器。
8×8 回归 `abortrep_8x8_postpatch_20260825` 保持
`done=1/swaps=1/drops=0/descriptors=22` 及原 AXI 计数；但历史 direct 对照下的
640×480 proxy `abortrep_treefull_proxy2_20260825` 为 `44,727 LUT / 31,380 FF /
84 DSP`，普通 direct WNS `-5.557 ns`，Q→D WNS `-5.434 ns`。相对
`prevalidate_treefull_proxy_final_20260825` 的 `44,660/31,374`、direct
`-4.824 ns`、Q→D `-4.701 ns`，观察到约 `0.733 ns` 的差异，且 `compute_abort`
下游扇出仍未切开。注意：这两份报告由不同时间点的 RTL/脚本生成，历史 direct
报告没有显式传入 `REPLICATE_ABORT_CONTROL`，当前源码的 generate 分支也在其后
调整过；因此它们不是严格的同源码 `generic=0/1` 配对，差异只能作为负向预警，
不能单独归因于 `max_fanout`。在允许重新综合时，必须先用当前源码成功生成
`REPLICATE_ABORT_CONTROL=0` 基线，再与 `=1` 比较。当前参数仍保持默认关闭，A
实验不再扩大。

## 当前结论

full-tree 与 prevalidation 已把 descriptor/算术局部路径的主要问题暴露出来，但
系统 Q→D 仍由高扇出 abort/ready 控制链主导。复制树 A 已完成一次非配对的预警性
实验，尚不能作为 QoR 定论；下一步只做带完整 payload、occupancy 和 flush/abort
语义的局部 elastic/skid 边界，在得到同源码配对的资源和 timing 证据前，不启用任何
raw ready/abort 寄存器，也不修改默认配置。

## 当前源码配对基线与 table response FIFO

为避免把历史快照混作因果对照，已用当前源码、相同
`PIPELINED_ADDRESS=1 + PIPELINED_START_CONFIG=1 + PIPELINED_DOT_TREE_FULL=1 +
PIPELINED_DESCRIPTOR_REPLAY=1 + PREVALIDATE_DESCRIPTOR_REPLAY=1` 重新建立基线：

| 配置 | LUT | FF | RAMB36/RAMB18 | DSP | direct WNS / delay | Q→D WNS / delay |
|---|---:|---:|---:|---:|---:|---:|
| 当前源码，table response FIFO=0（`current_treefull_prevalidate_nofifo_nohelper_20260825`） | 46,180 | 37,662 | 20 / 9 | 84 | -4.824 ns / 14.442 ns | -4.701 ns / 14.550 ns |
| 当前源码，table response FIFO=1（`current_treefull_prevalidate_tablefifo_nohelper_20260825`） | 46,174 | 37,790 | 20 / 9 | 84 | -4.824 ns / 14.442 ns | -4.701 ns / 14.550 ns |
| 当前源码，unified output FIFO=1、组合 error gate 保持（历史实验） | 46,319 | 37,659 | 20 / 9 | 84 | -6.098 ns / 15.947 ns | -6.098 ns / 15.947 ns |
| 当前源码，unified output FIFO=1、bridge-local error gate=0（`current_treefull_prevalidate_unifiedfifo_errorgate0_gated_nohelper_retry1_20260825`） | 46,390 | 37,656 | 20 / 9 | 84 | -4.831 ns / 14.449 ns | -4.702 ns / 14.551 ns |

table FIFO 的 8×8 compile/full-xsim 已通过；640×480 proxy 也已通过。它增加
一次已寄存的 table payload 边界（约 +128 FF），但最差路径仍从 camera FIFO/abort
控制链进入 engine，因此没有改善这两个 WNS。`ENABLE_TABLE_RESPONSE_FIFO` 保持默认
关闭，作为协议隔离和后续板上观测的可选开关，不把它宣传为 timing fix。

随后把完整 103-bit CNN 结果 payload 接入 bridge 内的可选 depth-2
`c1_r1_unified_output_fifo`。8×8 单帧和两帧 full-xsim 均通过，最终 RTL 分别得到
`done=1/swaps=1/drops=0/descriptors=22` 与
`done=2/swaps=2/drops=0/descriptors=44`；640×480 native xvlog/xelab 也通过。
最初的组合 error gate 版本把 `compute_abort→FIFO occupancy→cnn_result_ready`
重新串回 Q→D，proxy 恶化到 `-6.098 ns`；随后 bridge-local error gate=0 只把
`error_flush` 改为同步清空，并在 adapter 侧阻止错误后的握手。严格同条件最终 proxy
为 `46,390 LUT / 37,656 FF / 5,716 LUTRAM / 84 DSP`，direct/Q→D 分别为
`-4.831/-4.702 ns`，已回到无 FIFO 基线附近，但没有产生正的 WNS 收益（资源约
`+210 LUT/+80 LUTRAM`）。因此该边界证明了协议和 timing-cut 方向可接入，却不应
成为默认 timing 修复；`ENABLE_UNIFIED_OUTPUT_FIFO` 仍保持默认关闭。第一次遗漏
descriptor-replay 的 unified proxy 不纳入比较。

独立 FIFO 的 `COMBINATIONAL_ERROR_GATE=0` 回归
`unified_output_fifo_registered_error_gate0_recheck_20260825` 也通过，确认队列在
error 边沿清空、旧 payload 不跨 epoch；该模式仍需板上真实错误/abort 生命周期回归
后才能考虑启用。

随后对同一 seam 做了更小的 1-entry `c1_r1_unified_output_skid` 实验。
默认 error gate 与同步 error gate standalone 均通过；8×8 单帧/两帧、16×8、
640×480 elaboration 也通过，说明完整 103-bit payload、stall、flush 和跨帧
ownership 合同没有被破坏。但严格同条件 proxy 为 `46243 LUT / 37766 FF /
5636 LUTRAM / 84 DSP`，direct/Q→D `-5.415/-5.415 ns`，data delay `15.264 ns`
（route `11.613 ns`，约 76.1%），较无边界 `46180/37662`、`-4.824/-4.701 ns`
均恶化。因此深度减小本身没有切开当前 camera FIFO→abort/ready→engine state
控制锥；`ENABLE_UNIFIED_OUTPUT_SKID` 保持默认关闭，只作为后续局部协议观测和
板前对照开关，不能宣称为 timing fix。

上述两次 proxy 通过 runner 的 `-DisableParallelHelper` 选项运行；该选项仅将
Vivado `synth.enableParallelHelperSpawn` 设为 `none`，绕过间歇性的 detached helper
Tcl 文件读取错误，仍由 WMI worker 脱离当前 Windows Job 启动，不改变 RTL 默认路径。

下一步不再继续叠加统一结果 FIFO/skid；应转向更靠近高扇出控制源的局部
table/abort/ready 分区，或先完成 native 长帧 QoS/underflow 证据。不对 raw
ready/abort 做裸寄存器延迟。
