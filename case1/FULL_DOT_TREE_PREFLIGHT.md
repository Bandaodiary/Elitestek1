# `PIPELINED_DOT_TREE_FULL` 板前预检记录

更新时间：2026-08-25。

## 目的

`PIPELINED_DOT_TREE_FULL=1` 是赛题一 CNN engine 的可选算术流水化分支。它与
旧的 `PIPELINED_DOT_TREE=1` 不同：旧分支只在完整 dot-sum 到 accumulator/overflow
之间增加一组寄存器；本分支把 8-lane INT8 dot 的内部 reduction 真正拆成
`product → pair → quad → dot-sum → accumulator/overflow`。

默认值仍为 0。该实验用于在拿到 Ti60 以前验证 bit-exact、ready/valid、跨帧
ownership、cycle budget 和 Vivado 结构资源；它不代表 Efinity 布局布线或板上帧率。

## RTL 结构

实现文件为 `rtl/cnn/c1_s8_dot8_accum_treepipe.sv`，每个 dot lane 包含：

| 边界 | 数据宽度 | 作用 |
|---|---:|---|
| stage 0 | 8 个 signed 16-bit product | INT8×INT8，按 lane mask 置零 |
| stage 1 | 4 个 signed 17-bit pair sum | 两两相加 |
| stage 2 | 2 个 signed 18-bit quad sum | 四路归约为两路 |
| stage 3 | 1 个 signed 19-bit dot sum | 形成完整 dot-sum |
| final | signed 32-bit accumulator | 顺序累加、溢出标志、held output |

四级中间边界均为 elastic valid/ready 寄存器，并携带 `first/last`、bias、
`SOF/EOL/EOF`、`X/Y` 元数据。最后一级仍保持原有 sequence-order recurrence；
因此不会把不同 pixel/sequence 的 accumulator 状态混合。输出被 backpressure 时，
反压逐级传播；最后一个 beat 还保留旧合同：held result 未被消费时不接受新序列。

填充后目标 II 为 1。相对 legacy dot，最终结果通常晚约四个算术级；engine 本身
不依赖固定 latency，而依赖 ready/valid 和 `stage_done`，所以可以吸收这段延迟。

## 已完成的板前证据

| 层级 | 结果 |
|---|---|
| standalone dot/requant | 160 cases、781 groups、2 overflow cases；输入保持、输出保持、输出 stall、source gap 均 PASS |
| 22-stage engine | 836 outputs、312 MAC、248 DW、276 bypass、1,116 parameter reads；stage-18 非零 10,000-cycle budget 未触发 |
| portable SoC 8×8 | `done=1 swaps=1 drops=0 descriptors=22`；`AW/W/B=852/868/852`、`AR/R=1119/2199` |
| portable SoC 16×8 两帧 | `done=2 swaps=2 drops=0 descriptors=44`；`drain_cycles=1,438,892`；`AW/W/B=3376/3472/3376`、`AR/R=4194/5502` |
| portable SoC 64×48 单帧 | `done=1 swaps=1 drops=0 descriptors=22`；`drain_cycles=907,593`；`AW/W/B=40224/41664/40224`、`AR/R=48427/51643` |
| descriptor-replay 参数默认兼容复核 | `treefull_default_after_descriptor_param_8x8_20260825`；`PIPELINED_DESCRIPTOR_REPLAY=0` | 当前源码默认分支再次得到 `done=1 swaps=1 drops=0 descriptors=22`、`AW/W/B=852/868/852`、`AR/R=1119/2199`；stderr 为空 |
| capture-time descriptor prevalidation | `prevalidate_replay_8x8_final_20260825`；`ed8badbe0e6a4809964e361b79d6cb7a` | wrapper 为每个 stage 缓存 5-bit validator error；8×8 AXI/descriptor 计数不变，独立 external-validation decoder vector 回归 429/429 PASS |
| native 640×480 | FIFO、relaxed descriptor、tensor-address、start-config、full-tree 全开 xvlog/xelab PASS；未启动 native full-xsim |
| 640×480 Vivado proxy | full-tree `44,594 LUT / 31,396 FF / 84 DSP`；LUTRAM `5,948`，RAMB36/18 `20/9`；direct `-4.950 ns`，Q→D `-4.701 ns` |
| full-tree + capture-time prevalidation proxy | `prevalidate_treefull_proxy_final_20260825` | `44,660 LUT / 31,374 FF / 84 DSP`；LUTRAM `5,832`，RAMB36/18 `20/9`；direct `-4.824 ns`，Q→D `-4.701 ns` |
| full-tree + prevalidation + abort fanout replication（负优化预警） | `abortrep_8x8_postpatch_20260825`；`abortrep_treefull_proxy2_20260825` | 8×8 功能计数保持；历史/非同源 proxy 为 `44,727 LUT / 31,380 FF / 84 DSP`，direct `-5.557 ns`，Q→D `-5.434 ns`；不能作为严格因果对照，默认关闭 |
| 当前源码同条件 table response FIFO | `tablefifo_8x8_20260825`；`current_treefull_prevalidate_tablefifo_nohelper_20260825` | 8×8 full-xsim PASS；当前配对 proxy `46,174 LUT / 37,790 FF / 84 DSP`，与 FIFO=0 相比 `-6 LUT/+128 FF`，direct/Q→D 均无变化，默认关闭 |
| standalone unified output FIFO | `unified_output_fifo_latest_20260825` | depth=2、103-bit payload；随机背压、stall 保持、满载 bubble、abort/error flush/restart PASS |
| portable SoC unified output FIFO（可选集成） | `unified_fifo_errorgate0_gated_8x8_20260825`；`unified_fifo_errorgate0_gated_8x8_twoframe_20260825`；`unified_fifo_errorgate0_gated_native_elab_20260825`；`current_treefull_prevalidate_unifiedfifo_errorgate0_gated_nohelper_retry1_20260825` | 8×8 单帧/两帧 full-xsim、最终 640×480 xvlog/xelab 均 PASS；bridge-local error gate=0 的同条件 proxy `46,390 LUT / 37,656 FF / 84 DSP`、`5,716 LUTRAM`，direct `-4.831 ns`、Q→D `-4.702 ns`，相对无 FIFO无收益，默认关闭 |

proxy 的最差 Q→D 仍位于 camera FIFO→engine/tree ready/control 链，说明仅切分
算术 reduction 不能消除 parameter-scheduler、abort 和 ready 高扇出。相对
`PIPELINED_START_CONFIG` 基线，full-tree 少 76 LUT 但增加 3,255 FF；因此目前
是“功能/结构候选”，不是默认开启项。

针对另一条 `replay_index → descriptor validation` 路径的
`PIPELINED_DESCRIPTOR_REPLAY=1` 也已做过 8×8 集成和 640×480 proxy：功能无
per-stage bubble，但资源升至 `47,114 LUT / 41,837 FF`，direct 只改善到
`-4.824 ns`，Q→D 仍 `-4.701 ns`，已判定为负优化并保持关闭。

`PREVALIDATE_DESCRIPTOR_REPLAY=1` 是同一路径的窄结果版本：capture 时只缓存
5-bit error code，replay 时不复制 512-bit descriptor。它以 `+66 LUT/-22 FF`
换得与 registered replay 相同的 `0.126 ns` direct 改善，且 8×8 功能和 external
validation vector 回归均通过；但 Q→D 仍为 `-4.701 ns`，并依赖 descriptor cache
在 capture 后保持完整，因此仍是默认关闭的板前候选，而不是时序签核方案。

### abort 广播复制实验（已停止）

为验证高扇出控制网能否在不改变协议的情况下改善 route，增加了默认关闭的
`REPLICATE_ABORT_CONTROL`。该开关只在 `manager_abort` 组合广播树上施加
`max_fanout=16`，没有引入时钟周期延迟；`abortrep_8x8_postpatch_20260825`
证明 AXI/descriptor/ownership 计数不变。但历史、非同源码配对的 640×480 proxy
`abortrep_treefull_proxy2_20260825` 显示资源增加 `+67 LUT/+6 FF`，普通 WNS
从 `-4.824` 恶化到 `-5.557 ns`，Q→D 从 `-4.701` 恶化到 `-5.434 ns`。
报告中出现了带 `_rep` 的网表对象，但尚未生成独立 high-fanout 证明，且下游
`compute_abort` 扇出仍未切开；因此只能作为负向预警，路线不采用，开关保持默认关闭。

### table response FIFO 实验（协议隔离，不是 timing fix）

`c1_table_response_elastic_fifo` 是 table reader→soc-control 之间的单项已寄存
payload buffer，`in_ready=!full`，abort 清空且不依赖下游 ready。它已通过 8×8
compile/full-xsim（随机 response stall/gap），并完成当前源码 640×480 同条件 proxy。
配对结果为 `46,180/37,662` → `46,174/37,790` LUT/FF，BRAM/DSP 不变；最差
camera-FIFO→abort/ready 路径没有改变。因此暂不接入默认路径，只保留为板前协议
隔离与后续测量开关。

### unified output FIFO 系统集成实验（协议通过，QoR 中性但不改善）

`c1_r1_unified_output_fifo` 已在 `c1_r1_microstyle_system_bridge` 内以
`ENABLE_UNIFIED_OUTPUT_FIFO` 可选方式接线，携带完整结果 payload。组合 error gate
版本会把错误反馈重新接入 CNN ready，proxy 恶化到 `-6.098 ns`；最终 bridge-local
error gate=0 版本在错误边沿同步清空 FIFO、adapter 侧立即禁止错误后的握手，单帧、
两帧和 native-width elaboration 均通过。严格同条件最终 proxy 为
`46,390 LUT / 37,656 FF / 5,716 LUTRAM / 84 DSP`，direct/Q→D `-4.831/-4.702 ns`，
相对 FIFO=0 的 `46,180/37,662`、`-4.824/-4.701 ns` 只增加资源、没有 timing 收益。
因此它保留为协议隔离/板上观测候选，不作为默认数据通路或时序修复；启用前还需
真实 error/abort 生命周期回归。

### unified output skid 系统集成实验（协议通过，timing 负优化）

`c1_r1_unified_output_skid` 是同一 CNN result seam 的 1-entry、完整 103-bit
registered payload 边界。默认/同步 error gate standalone、8×8 单帧/两帧、
16×8 和 640×480 elaboration 均通过；但同条件 proxy 为 `46243 LUT/37766 FF /
5636 LUTRAM/84 DSP`，direct/Q→D `-5.415/-5.415 ns`，相对无边界的
`46180/37662`、`-4.824/-4.701 ns` 负优化。结论是协议边界可安全接入，但该位置
没有切开真正的高扇出控制路径，默认保持关闭。

## 复现入口

以下 runner 都通过 `Win32_Process.Create` 创建 detached worker，Vivado/xsim 不属于
当前 Codex shell 的 Windows Job：

```powershell
# standalone dot
powershell -NoProfile -ExecutionPolicy Bypass -File .\case1\scripts\run_dot8x8_core_xsim_detached.ps1 `
  -RunId dot8x8_treefull_recheck -PipelinedDotTreeFull

# 22-stage engine
powershell -NoProfile -ExecutionPolicy Bypass -File .\case1\scripts\run_r1_microstyle_engine_xsim_detached.ps1 `
  -RunId engine_treefull_recheck -PipelinedDotTreeFull -NonzeroCycleBudget

# portable SoC shape/ownership
powershell -NoProfile -ExecutionPolicy Bypass -File .\case1\scripts\run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 `
  -RunId soc_treefull_16x8_twoframe_recheck -Frame 16x8 -TwoFrame `
  -DisplayResponseFifo -RelaxedDescriptor -PipelinedAddress `
  -PipelinedStartConfig -PipelinedDotTreeFull
```

640×480 proxy report目录：

`sim/portable_soc_descriptor_relaxed_run_portable_soc_descriptor_relaxed_pipelined2_startcfg_treefull_proxy_20260825/reports/`

预校验 proxy 报告目录：

`sim/portable_soc_descriptor_relaxed_run_prevalidate_treefull_proxy_final_20260825/reports/`

## 尚未闭合的边界

1. `-4.950/-4.701 ns` 是 Artix-7 Vivado 综合代理，不是 Ti60/Efinity 时序；
2. 还没有 native 640×480 full-xsim CNN/QoS/deadline 结果；
3. full-tree 增加约四级 latency，启用时必须把 watchdog、stage budget、display
   underflow 和 frame deadline 一并纳入合同；
4. 下一优先级是 parameter-scheduler/ready-control/abort 高扇出路径，以及
   tensor burst/multiple-outstanding 和有效 MAC 并行度，而不是继续无条件增加
   arithmetic registers。
