# 描述符校验与 tensor 地址路径：640×480 proxy 对比

更新时间：2026-08-25。

## 目的

完整 `c1_r1_portable_soc` 的 FIFO128 proxy 把 core 时钟最差路径定位为
描述符/ tensor-adapter 地址组合锥。当前最终源码基线的 strict 结果为
`-53.327 ns`；此前 `-53.944 ns` 是流水化改动前的历史快照。本页记录一个保持
默认正确性契约的可选 relaxed build、一次没有收益的窄地址算术实验、两级
地址流水化，以及一个可选的 compute-start/config 寄存器边界，避免把“删掉
检查”或“增加寄存器”误写成系统时序已经闭合。

## 配置与实测

代理器件为 `xc7a200tsbg484-1`，native 参数 `640×480`，core/pixel/camera
时钟约束为 10/14/20 ns；结果不是 Ti60/Efinity 签核。

| 变体 | `STRICT_DESCRIPTOR_VALIDATION` | `FAST_TENSOR_ADDRESS_ARITH` | `PIPELINED_TENSOR_ADDRESS` | Total LUT | FF | DSP | core 最差路径 |
|---|---:|---:|---:|---:|---:|---:|---:|
| strict FIFO128（最终源码） | 1 | 0 | 0 | 45,298 | 28,123 | 99 | direct **-53.327 ns** |
| relaxed（最终源码） | 0 | 0 | 0 | 44,713 | 28,061 | 93 | direct **-15.659 ns**；Q→D **-13.455 ns** |
| relaxed + fast-address（最终源码实验） | 0 | 1 | 0 | 45,506 | 28,073 | 93 | direct **-16.647 ns**；Q→D **-14.216 ns** |
| relaxed + one-boundary address（历史中间态） | 0 | 0 | 1 | 44,598 | 28,055 | 91 | **-5.390 ns** |
| relaxed + pixel/final two-stage address | 0 | 0 | 1 | 44,641 | 28,069 | 84 | direct max **-4.972 ns**；Q→D data **-4.772 ns** |
| relaxed + pixel/final + compute-start boundary | 0 | 0 | 1 | 44,670 | 28,141 | 84 | direct max **-4.950 ns**；Q→D data **-4.601 ns** |
| relaxed + pixel/final + compute-start + **full product→pair→quad→dot tree** | 0 | 0 | 1 | **44,594** | **31,396** | 84 | direct max **-4.950 ns**；Q→D data **-4.701 ns** |
| full-tree + registered descriptor replay（实验） | 0 | 0 | 1 | **47,114** | **41,837** | 84 | direct max **-4.824 ns**；Q→D data **-4.701 ns** |
| full-tree + **capture-time 5-bit descriptor prevalidation**（实验） | 0 | 0 | 1 | **44,660** | **31,374** | 84 | direct max **-4.824 ns**；Q→D data **-4.701 ns** |
| full-tree + prevalidation + **abort fanout replication**（历史非配对负优化预警） | 0 | 0 | 1 | **44,727** | **31,380** | 84 | direct max **-5.557 ns**；Q→D data **-5.434 ns** |
| 当前源码同条件 + **table response FIFO** | 0 | 0 | 1 | **46,174** | **37,790** | 84 | direct max **-4.824 ns**；Q→D data **-4.701 ns**；相对 FIFO=0 为 -6 LUT/+128 FF |
| 当前源码同条件 + **unified output FIFO（组合 error gate，历史）** | 0 | 0 | 1 | **46,319** | **37,659** | 84 | direct max **-6.098 ns**；Q→D data **-6.098 ns**；data delay 15.947 ns、route 12.172 ns，较 FIFO=0 负优化 |
| 当前源码同条件 + **unified output FIFO（bridge-local error gate=0）** | 0 | 0 | 1 | **46,390** | **37,656** | 84 | direct max **-4.831 ns**；Q→D data **-4.702 ns**；data delay 14.449/14.551 ns、route约 11.058/11.030 ns，相对 FIFO=0 无 timing 收益 |
| 当前源码同条件 + **unified output skid（1-entry，bridge-local error gate=0）** | 0 | 0 | 1 | **46,243** | **37,766** | 84 | direct max **-5.415 ns**；Q→D data **-5.415 ns**；data delay **15.264 ns**、route **11.613 ns**，相对无边界负优化 |

另做了一个保持默认分支关闭的 `PIPELINED_DOT_TREE=1` 实验。这里的实现名虽然
沿用参数名，但当前版本只在 **final dot-sum → accumulator/overflow 边界** 插入
一组弹性寄存器，乘法和 8→4→2→1 reduction tree 仍在同一组合段；因此不能把它
表述成“内部 dot tree 已分段”。在 pixel/final + start-config 基线上，640×480
proxy 资源为 `44,691 LUT / 28,606 FF / 84 DSP`（LUTRAM 5,948，RAMB36/18
为 20/9），普通最差路径仍为 `-4.950 ns`；Q→D 专用报告的最差路径变为
camera FIFO→engine state `-4.752 ns`，没有改善 `-4.601 ns` 的基线，故不纳入
默认架构。该分支只保留为后续真正按 product→pair→quad→dot 分级流水化的
功能/资源参考。

随后完成了真正的 `PIPELINED_DOT_TREE_FULL=1` 实验：8 个 dot lane 均采用
`product → pair → quad → dot-sum → accumulator/overflow` 四级弹性寄存器，
不是把 final dot-sum 单独延后一拍。640×480 full-tree proxy 为
`44,594 LUT / 31,396 FF / 84 DSP`（LUTRAM 5,948，RAMB36/18 为 20/9）；
相对 start-config 基线少 76 LUT、增加 3,255 FF，相对 final-dot-sum 边界少
97 LUT、增加 2,790 FF。普通最差路径仍为 `-4.950 ns`，Q→D 专用最差为
`-4.701 ns`（camera FIFO→engine/tree ready/control 链），因此完整算术树的
寄存器化没有闭合系统 100 MHz，也没有消除共享控制/回压路径。该版本保持填充后
II=1，但结果相对最后输入 beat 约增加四个算术级的 latency；它只应作为有明确
latency/budget 合同的候选开关，默认仍关闭。

为直接针对 `replay_index → descriptor_cache → descriptor validation` 的最差路径，
又加入了默认关闭的 `PIPELINED_DESCRIPTOR_REPLAY=1`。它在 wrapper 中缓存一个
512-bit descriptor 并在填充后每拍发出一条 descriptor；8×8 full-tree 集成回归
保持 `done=1 swaps=1 drops=0` 和原 AXI 计数，说明没有引入 per-stage bubble。
但 Vivado proxy 只把 direct 最差改善 `0.126 ns`（`-4.950→-4.824 ns`），Q→D
仍为 `-4.701 ns`，同时资源增加 `2,520 LUT / 10,441 FF`，LUTRAM 由 5,948
降为 5,636。该结果表明宽 descriptor 的寄存器/高扇出复制代价大于收益，故不纳入
默认或 full-tree 推荐组合；若要继续处理该路径，应在 decoder 内部分级校验字段，
而不是直接寄存完整 512-bit 总线。

随后实现了 `PREVALIDATE_DESCRIPTOR_REPLAY=1` 作为低资源对照：wrapper 在
capture 阶段调用与 decoder ABI 相同的校验函数，只为每个 stage 缓存 5-bit
error code；replay 时 decoder 使用该窄结果，不复制 512-bit descriptor。8×8
portable-SoC 回归保持 `done=1 swaps=1 drops=0 descriptors=22` 和
`AW/W/B=852/868/852`、`AR/R=1119/2199`。640×480 full-tree proxy 的资源为
`44,660 LUT / 31,374 FF / 84 DSP`，相对 full-tree 仅 `+66 LUT / -22 FF`，
却同样把 direct 最差路径从 `-4.950 ns` 推到 `-4.824 ns`；Q→D 仍为
`-4.701 ns`。因此它证明“窄结果缓存”比完整 replay register 更划算，但并未
闭合 100 MHz；该开关仍默认关闭，待 cache 完整性/错误语义在板上确认后再评估。

随后对 full-tree + prevalidation 组合加入默认关闭的 `REPLICATE_ABORT_CONTROL=1`。
该开关只在组合 `manager_abort` 广播树上施加 `max_fanout=16`，不插入寄存器，
也不改变 AXI drain 周期。8×8 当前源码回归 `abortrep_8x8_postpatch_20260825`
仍得到 `done=1/swaps=1/drops=0/descriptors=22`、`AW/W/B=852/868/852`、
`AR/R=1119/2199`。但历史、非同源码配对的 640×480 proxy
`abortrep_treefull_proxy2_20260825` 资源为 `44,727 LUT / 31,380 FF / 84 DSP`，
普通最差 WNS `-5.557 ns`、Q→D `-5.434 ns`；相对 prevalidation baseline
`44,660/31,374`、`-4.824/-4.701 ns` 恶化约 `0.733 ns`，并增加 67 LUT/6 FF。
报告出现 `_rep` 单元，但尚未有独立 high-fanout 报告证明物理复制；route delay
增至约 11.79 ns，且下游 `compute_abort` 扇出仍未切开。因此该实验仅作为“协议不变
但布局负优化”的预警，`REPLICATE_ABORT_CONTROL` 保持默认关闭，不再沿该方向扩大。

随后对当前源码做了真正同条件的 table response FIFO 配对：单项 payload 已寄存、
`in_ready=!full`、abort 清空且不依赖下游 ready。8×8 full-xsim PASS；640×480
proxy 资源为 `46,174 LUT / 37,790 FF / 84 DSP`，direct/Q→D 仍为
`-4.824/-4.701 ns`，所以该 FIFO 作为协议隔离开关保留，不作为 timing fix。

最后将完整 103-bit 结果 payload 的 depth-2 unified FIFO 以
`ENABLE_UNIFIED_OUTPUT_FIFO` 可选方式接入 bridge。组合 error gate 版本把
`compute_abort→FIFO occupancy→cnn_result_ready` 重新串回最差路径，proxy 为
`46,319 LUT / 37,659 FF`、Q→D `-6.098 ns`。随后 bridge-local error gate=0
只在 error 边沿同步清空 FIFO，并在 adapter 侧阻止错误后的握手；8×8 单帧/两帧、
640×480 native elaboration 和独立同步 error-gate unit 均通过，严格同条件最终
proxy 为 `46,390 LUT / 37,656 FF / 5,716 LUTRAM / 84 DSP`，direct/Q→D
`-4.831/-4.702 ns`。它恢复了路径但没有 timing 收益，仍默认关闭，第一次遗漏
descriptor-replay 的 run 不作为配对证据。

最终源码下 relaxed-only 的层级资源为 `u_tensor_adapter=2,146 LUT /
3,312 FF / 16 DSP`；fast-address 变成 `2,947 LUT / 3,333 FF / 16 DSP`。
后者的 shift/add 分支被 Xilinx proxy 映射成更大的选择/进位网络；top-level
相对最终 relaxed 基线增加 793 LUT，且 Q→D 最差为 `-14.216 ns`，因此默认不
启用。one-boundary
历史中间态的 adapter 为 `2,028 LUT / 3,307 FF / 14 DSP`；pixel/final 两级
为 `2,084 LUT / 3,329 FF / 7 DSP`。后者在 top-20 timing report 中已经不再出现
`tensor_addr/request_addr` 路径，说明地址乘法链确实被寄存器切开；Q→D 专用
报告的最差数据路径为 capture camera FIFO 到 resize request（`-4.772 ns`），
其次是 dot weight tile 到 accumulator overflow（`-4.601 ns`）。普通
`report_timing` 的 `-4.972 ns` 是同一高扇出控制/复位相关族中的最差报告值，
不应单独当作 tensor 数据路径。再打开 `PIPELINED_START_CONFIG=1` 后，top
资源为 `44,670 LUT / 28,141 FF / 84 DSP`，相对 pixel/final 增加 29 LUT、72 FF；
camera-FIFO→resize 路径不再是 Q→D 首位，新的最差为 dot weight tile→accumulator
overflow `-4.601 ns`，普通 max report 为 `-4.950 ns`。这是约 0.171 ns 的数据
路径改善，不是 100 MHz 闭合。整体仍未达到 100 MHz。

报告目录：

- strict/FIFO128：
  `case1/sim/portable_soc_fifo_proxy_run_portable_soc_fifo_proxy_post_pipeline_default_20260825/reports/`
- relaxed-only final-source：
  `case1/sim/portable_soc_descriptor_relaxed_run_portable_soc_descriptor_relaxed_post_pipeline2_20260825/reports/`
- relaxed+fast-address final-source experiment：
  `case1/sim/portable_soc_descriptor_relaxed_run_portable_soc_descriptor_relaxed_fast_post_pipeline2_20260825/reports/`
- relaxed + one-boundary address：
  `case1/sim/portable_soc_descriptor_relaxed_run_portable_soc_descriptor_relaxed_pipelined_proxy_20260825/reports/`
- relaxed + pixel/final two-stage address：
  `case1/sim/portable_soc_descriptor_relaxed_run_portable_soc_descriptor_relaxed_pipelined2_proxy_20260825/reports/`
- relaxed + pixel/final + compute-start boundary：
  `case1/sim/portable_soc_descriptor_relaxed_run_portable_soc_descriptor_relaxed_pipelined2_startcfg_proxy_20260825/reports/`
- relaxed + pixel/final + compute-start + final-dot-sum boundary：
  `case1/sim/portable_soc_descriptor_relaxed_run_portable_soc_descriptor_relaxed_pipelined2_startcfg_dottree_proxy_20260825/reports/`
- relaxed + pixel/final + compute-start + full product/pair/quad/dot tree：
  `case1/sim/portable_soc_descriptor_relaxed_run_portable_soc_descriptor_relaxed_pipelined2_startcfg_treefull_proxy_20260825/reports/`
- full-tree + registered descriptor replay（负优化实验）：
  `case1/sim/portable_soc_descriptor_relaxed_run_portable_soc_descriptor_relaxed_pipelined2_startcfg_treefull_descr_replay_proxy_20260825/reports/`
- full-tree + capture-time 5-bit descriptor prevalidation：
  `case1/sim/portable_soc_descriptor_relaxed_run_prevalidate_treefull_proxy_final_20260825/reports/`
- Q→D data-only timing：同一 proxy 的 `relaxed_data_timing.rpt`（由
  `C1_DATA_TIMING_PINS from=28069 to=28071` 证明过滤集合非空；最终
  relaxed-only/fast-address 的 pin 集合分别为 `28061→28063` 与
  `28073→28075`）。

表中 strict/relaxed/fast 三行来自同一轮最终 RTL 源码；旧 canonical/debug
报告仍保留用于追溯，但不再作为当前资源基线：旧 relaxed `44,799/28,063`
与旧 strict `45,269/28,114` 只代表地址流水化加入前的快照。

relaxed netlist 的 `report_timing_summary` 在 Vivado 2023.1 会异常退出；
relaxed 结论采用同一约束下成功完成的 `report_timing -max_paths 20`，并在
日志中保留 source/destination、数据延迟和逻辑级数。这个工具限制不影响
xvlog/xelab/xsim 或 utilization 结果。

## 正确性门

relaxed 模式只移除综合时的 512-bit descriptor topology/size checker；默认
值仍为 strict=1。`ifndef SYNTHESIS` 下 relaxed 模式仍调用同一个
`descriptor_valid_fn`，非法软件 ABI 会 `$fatal`，不会静默产生错误 tensor
地址。以下 detached xsim 均通过且 stderr 为空：

- `descriptor_relaxed_fifo_8x8_20260825`：relaxed + FIFO128；22 descriptors，
  `AW/W/B=852/868/852`、`AR/R=1119/2199`；
- `descriptor_relaxed_fast_fifo_8x8_20260825`：relaxed + FIFO128 +
  fast-address 实验，同一计数和 marker 通过。
- `descriptor_relaxed_pipelined2_fifo_8x8_20260825`：relaxed + FIFO128 +
  `PIPELINED_TENSOR_ADDRESS=1`，`done=1 swaps=1 drops=0`，
  `AW/W/B=852/868/852`、`AR/R=1119/2199`，stderr 为空。
- `descriptor_relaxed_pipelined2_twoframe_8x8_20260825`：同一 pipeline 的两帧
  ownership，`done=2 swaps=2 drops=0 descriptors=44`，stderr 为空。
- `descriptor_strict_pipelined2_compat_8x8_20260825`：默认 strict/bypass
  兼容回归 PASS，说明 `PIPELINED_TENSOR_ADDRESS=0` 未改变生产路径。
- `descriptor_pipelined2_compute_start_8x8_20260825`：relaxed + 地址流水化 +
  `PIPELINED_START_CONFIG=1` 单帧 PASS；
- `descriptor_pipelined2_startcfg_twoframe_8x8_20260825`：同一配置两帧
  `done=2 swaps=2 drops=0 descriptors=44` PASS；
- `descriptor_pipelined2_startcfg_strict_8x8_20260825`：strict + 地址流水化 +
  `PIPELINED_START_CONFIG=1` 兼容回归。
- `aba8388974174f209ea0c7c2cc2dcbf0`：最终 `PIPELINED_DOT_TREE=1` 的独立
  dot/requant 回归，`cases=160 groups=781 tail_masks=141 full_masks=19
  overflow_cases=2 input_hold=160 output_hold=635 output_stall=635`，stderr 为空。
- `8b6b7df80aa1482ead7c3cdea4269e55`：同一 final-dot-sum 边界的 22-stage
  engine 回归；`stages=22 outputs=836 mac=312 dw=248 bypass=276`，stderr 为空。
- `f00e07cb7e884af7960dfaae36696bfb` / `0475bd62524b40388af6fe685dfd2cc9`：legacy
  与 final-dot-sum 各自带 stage-18 `10,000` cycle budget 的 margin gate，均 PASS；
  这只验证小尺寸 budget 不被新增一拍耗尽，不外推 native deadline。
- `descriptor_pipelined2_startcfg_dottree_final_8x8_20260825`：同一 final-dot-sum
  边界流水接入完整 portable-SoC 8×8 链；该回归只在最终状态 complete 且 marker
  通过后计入，不能替代 native 长帧性能验证。
- `4998087102b6420ba49009b7216b3f96`：full-tree standalone dot/requant 随机回归
  PASS，`cases=160 groups=781 tail_masks=141 full_masks=19 overflow_cases=2`，
  覆盖输入保持、输出保持、输出 backpressure 与 source gap。
- `a3f71de333da470483f247902d497d52`：full-tree 22-stage engine 回归 PASS，
  `stages=22 outputs=836 mac=312 dw=248 bypass=276 param_reads=1116
  stalls=263 aborts=8 faults=6`；非零 `10,000`-cycle stage budget 仍未触发。
- `descriptor_pipelined2_startcfg_treefull_8x8_20260825`：full-tree 接入完整
  portable-SoC 8×8 链 PASS，`done=1 swaps=1 drops=0 descriptors=22`，
  `drain_cycles=1,947,286`，`AW/W/B=852/868/852`、`AR/R=1119/2199`；
  四级 latency 被 engine/bridge/ownership 正确吸收。
- `descriptor_pipelined2_startcfg_treefull_16x8_twoframe_20260825`：同一 full-tree
  配置扩展到 16×8 两帧并通过 ownership/drain，`done=2 swaps=2 drops=0
  descriptors=44`，`drain_cycles=1,438,892`，`AW/W/B=3376/3472/3376`、
  `AR/R=4194/5502`，stderr 为空；说明新增四级 latency 未破坏跨帧 swap。
- `descriptor_pipelined2_startcfg_treefull_64x48_20260825`：64×48 单帧 full-tree
  链 PASS，`done=1 swaps=1 drops=0 descriptors=22`，`drain_cycles=907,593`，
  `AW/W/B=40224/41664/40224`、`AR/R=48427/51643`，stderr 为空；在更大
  shape 下 AXI 计数与 ownership 仍守恒。
- `descriptor_replay_treefull_8x8_20260825`：full-tree + registered descriptor
  replay 集成 PASS，`done=1 swaps=1 drops=0 descriptors=22`，AXI
  `AW/W/B=852/868/852`、`AR/R=1119/2199`，stderr 为空；仅作为功能/latency
  证据，不能抵消 proxy 的资源负优化。
- `prevalidate_replay_8x8_final_20260825`：capture-time 5-bit descriptor prevalidation
  接入 8×8 portable-SoC，`done=1 swaps=1 drops=0 descriptors=22`，AXI
  `AW/W/B=852/868/852`、`AR/R=1119/2199`，stderr 为空。
- `ed8badbe0e6a4809964e361b79d6cb7a`：decoder external-validation branch 重放
  全部 429 个 descriptor vector，PASS；预缓存错误码仍保持 directed error、随机
  bit-flip 分类和 held-output/abort 契约。
- `prevalidate_native_elab_640x480_20260825`：640×480、地址/启动/full-tree/
  prevalidation 全开时 xvlog/xelab PASS，stderr 为空。
- `prevalidate_treefull_proxy_final_20260825`：capture-time prevalidation 640×480
  proxy synthesis PASS；资源 `44,660/31,374/84`，direct `-4.824 ns`，Q→D
  `-4.701 ns`。
- `treefull_final_native_elab_20260825`：640×480、FIFO/relaxed descriptor/
  tensor-address/start-config/full-tree 全开时 xvlog/xelab PASS，stderr 为空；
  这是结构闭合证据，不是 native full-xsim、帧率或 Ti60 sign-off。

复现 relaxed-only canonical proxy：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\case1\scripts\run_portable_soc_descriptor_relaxed_proxy_detached.ps1 `
 -RunId portable_soc_descriptor_relaxed_proxy_canonical_20260825
```

复现 pixel/final 两级地址流水化 proxy：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\case1\scripts\run_portable_soc_descriptor_relaxed_proxy_detached.ps1 `
  -RunId portable_soc_descriptor_relaxed_pipelined2_data_proxy_recheck `
 -PipelinedAddress
```

复现 full-tree + capture-time descriptor prevalidation proxy：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\case1\scripts\run_portable_soc_descriptor_relaxed_proxy_detached.ps1 `
  -RunId prevalidate_treefull_proxy_recheck `
  -PipelinedAddress -PipelinedStartConfig -PipelinedDotTreeFull `
  -PrevalidateDescriptorReplay
```

runner 通过 WMI 创建 detached worker，并预读 Vivado runtime Tcl；这满足本项目
不把长 Vivado/xsim 绑定在当前 Windows Job 的约束。个别早期 fast proxy run
曾出现 `unimacro_verilog.tcl`/`rt-undefined` helper 读取竞态，已单独记录，
不计入 RTL 资源结论。

## 工程结论

relaxed checker 是有效的诊断/性能候选：它把最终 strict 的 `-53.327 ns`
降到 `-15.659 ns`；随后 `PIPELINED_TENSOR_ADDRESS=1` 的 pixel/final 两级
状态又把 tensor 地址路径从 top-20 移出，Q→D 专用报告的系统最差为
`-4.772 ns`；再加 `PIPELINED_START_CONFIG=1` 后，Q→D 最差改善为
`-4.601 ns`，代价为 29 LUT/72 FF 和一拍 start-to-child latency。fast-address
最终源码实验仍为 `-16.647 ns`，不值得启用。
它仍不是 100 MHz 闭合，因为新增的两拍/请求会降低顺序 adapter 吞吐，且共享
fabric、DMA、resize 和 dot engine 还有更大的系统级周期问题。strict 默认必须保留，
`PIPELINED_START_CONFIG` 只建议作为与 pixel/final 地址流水化配套的实验开关，
默认仍关闭；在启用前仍要完成 native 640×480
bit-exact、deadline/underflow、AXI burst/multiple-outstanding 以及 Ti60/Efinity
映射验证。`PIPELINED_START_CONFIG=1` 的现有 PASS 只覆盖 portable bridge BFM
的 level-ready 启动、descriptor validation 和 frame ownership；不覆盖
`tb_c1_r1_compute_shell.sv` 所要求的 standalone external-CNN same-edge
`cnn_start_valid` ABI。外部 CNN 必须在 pending 期间保持可接受状态；当前实现没有
pending timeout，并且 watchdog/cycle budget 至少要为 launch 多留一拍。

`PIPELINED_DOT_TREE=1` 同样默认关闭：它保持 ready/valid 和 II=1（填充后），但
最终结果/overflow 相对最后一个输入 beat 多一拍。真正的
`PIPELINED_DOT_TREE_FULL=1` 已把完整上下文随 product→pair→quad→dot 各级寄存并
通过 standalone、engine、8×8 SoC 和 native elaboration；然而 full-tree proxy 的
Q→D 仍为 `-4.701 ns`、FF 增量约 3.3k，故当前结论仍是“功能/结构候选”，不是
默认开启理由。下一轮应优先切分 parameter-scheduler/ready-control 高扇出路径，
并以固定 latency、cycle budget、underflow/deadline 作为开关验收条件。

`PIPELINED_DESCRIPTOR_REPLAY=1` 的 8×8 功能回归通过，但 proxy 的
`47,114 LUT / 41,837 FF` 与 `-4.824 ns` direct path 明确是负优化；该开关保持
默认关闭。后续的 `PREVALIDATE_DESCRIPTOR_REPLAY=1` 用每 stage 五比特结果缓存，
在几乎不增加资源的情况下取得相同 `0.126 ns` direct 改善，因而是更合理的
descriptor-path 候选；但 Q→D 仍为 `-4.701 ns`，整体仍未达到 100 MHz，且它
依赖 capture 后 descriptor cache 不被破坏。当前建议仍保持默认 0，先切分
parameter-scheduler/ready-control 高扇出路径并完成板前 cache-integrity、错误注入
和 watchdog/cycle-budget 验证。

## `PIPELINED_START_CONFIG` 接口边界

该开关在 `c1_r1_compute_shell` 中不是“无语义变化”的内部 retiming：默认值 0
要求 source、ingress、egress 和 external CNN 在同一个 `start_valid && start_ready`
边沿启动；值 1 则在该边沿锁存 source/config，并把 `child_start/cnn_start_valid`
推迟至少一拍。因此 standalone compute-shell 原有的 same-edge external-CNN
start ABI 在值 1 时不再成立，`tb_c1_r1_compute_shell.sv` 的同边沿断言不能被
集成 SoC 小帧 PASS 替代。当前 strict 回归证明的是 descriptor/ownership 与
level-ready bridge 的组合兼容，不是任意外部 CNN 接口兼容。

optional launch 仍把 `cnn_start_ready` 纳入 `all_children_ready`，即
`cnn_start_valid` 受 READY 门控；pending 队列没有独立 timeout。若 external CNN
在原始 engine-start 边沿后撤 READY、只给一个短 READY 脉冲，或等待 VALID 才产生
READY，可能一直停在 pending，直到 abort/上层 watchdog。启用前必须约定 READY
保持到延迟 launch，或改为明确的独立 VALID/READY 缓冲协议；同时因为 controller
在原始 start 边沿已进入 RUN，固定 cycle budget 至少预留一拍启动余量，并单独
验证 pending 不会吞掉 frame deadline。基于此，proxy 的资源/时序改善不构成
默认开启理由。
