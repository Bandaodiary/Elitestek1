# portable SoC 640×480：display FIFO 系统级 Vivado proxy

更新时间：2026-08-25。

## 目的

在已知竞赛目标为 Ti60F225I3、但尚无本次板卡 revision/DDR 控制器/pin 约束且尚未进行 Efinity 原生 P&R 的阶段，先把完整的
`c1_r1_portable_soc`（capture、22-stage engine、tensor adapter、七客户端
AXI、display、APB/CDC）按 native `640×480` 参数做 Xilinx 结构 proxy。
同一次 detached Vivado batch 分别综合：

| 变体 | 参数 |
|---|---|
| bypass | `ENABLE_DISPLAY_RESPONSE_FIFO=0`、`DISPLAY_RESPONSE_FIFO_DEPTH=64` |
| fifo128 | `ENABLE_DISPLAY_RESPONSE_FIFO=1`、`DISPLAY_RESPONSE_FIFO_DEPTH=128` |

代理器件为 `xc7a200tsbg484-1`；core/pixel/camera 时钟约束分别为 10/14/20 ns，
三个时钟组按显式 CDC synchronizer 设为 asynchronous。该流程只反映 Xilinx
综合器的逻辑映射，不是 Ti60 资源、布局布线或 15 fps 签核。

## 当前 run

`portable_soc_fifo_proxy_post_pipeline_default_20260825` 由 WMI detached worker 启动，bypass 与
fifo128 两个变体均完成，Vivado stderr 为空，最终 marker 为
`C1_PORTABLE_SOC_FIFO_PROXY_SYNTH_PASS variants=2 frame=640x480`。

报告目录：

`case1/sim/portable_soc_fifo_proxy_run_portable_soc_fifo_proxy_post_pipeline_default_20260825/reports/`

旧 `portable_soc_fifo_proxy_final_20260825` 报告仍保留，作为地址流水化前的
历史快照，不作为当前源码资源基线。

## 系统级资源对比

| 指标 | bypass | fifo128 | 增量 |
|---|---:|---:|---:|
| Total LUTs | 44,792 | 45,298 | +506（+1.13%） |
| Logic LUTs | 39,148 | 39,350 | +202 |
| LUTRAMs | 5,644 | 5,948 | +304 |
| FFs | 28,082 | 28,123 | +41 |
| RAMB36 | 20 | 20 | 0 |
| RAMB18 | 9 | 9 | 0 |
| DSP blocks | 99 | 99 | 0 |

fifo128 两个层级各约 255–260 LUT、22 FF、152 LUTRAM。与 display-only
proxy 的结果一致，59-bit×128×2 token 存储被 Vivado 映射为 LUTRAM；在此
完整 SoC 中，FIFO 增量只占总 LUT 约 1.1%，但 Efinity 可能将同一结构映射到
不同数量的 LUTRAM/EBR。

## 时序解读

| 时钟域 | bypass WNS | fifo128 WNS | 说明 |
|---|---:|---:|---|
| camera_clk 50 MHz | +14.919 ns | +14.919 ns | 无变化 |
| core_clk 100 MHz | **-53.327 ns** | **-53.327 ns** | 顶层主瓶颈，不是 FIFO 引入 |
| pixel_clk 71.43 MHz | +4.786 ns | +4.786 ns | 无变化 |

core_clk 的负 WNS 在两个变体完全相同，说明当前系统级关键路径来自
correctness-first CNN/tensor/控制组合逻辑，而不是 display response FIFO。
因此 FIFO 可以作为 QoS 修复保留，但不能把它解释成实时路径已经闭合；在
真实板卡前必须对 engine lane、tensor 地址/窗口调度、共享仲裁和控制路径做
流水化、并行化或时钟域拆分。

descriptor/tensor 控制路径的后续隔离实验见
`PORTABLE_SOC_DESCRIPTOR_TIMING_PROXY.md`：在 relaxed + pixel/final 地址流水化
上增加可选 `PIPELINED_START_CONFIG=1` 后，640×480 proxy 为
`44,670 LUT / 28,141 FF / 84 DSP`，Q→D 最差 `-4.601 ns`，相对同一源码的
`44,641 / 28,069 / 84` 增加 29 LUT、72 FF。该改善不改变本页 FIFO128 的
`-53.327 ns` 系统级 strict 基线，也不构成 Ti60/Efinity 或 15 fps 结论。

## 复现

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\case1\scripts\run_portable_soc_fifo_proxy_synth_detached.ps1 `
  -RunId portable_soc_fifo_proxy_post_pipeline_default_20260825
```

Tcl 源码为 `case1/scripts/synth_portable_soc_fifo_proxy.tcl`。runner 使用
WMI 创建 detached worker，符合本项目“不把 Vivado 绑定到当前 Windows Job”
约束。

## 与功能证据的关系

这次 proxy synthesis 与下列 boardless xsim 证据互补：

- `native_display_fifo_final_20260825`：640×480 display pair 两路逐像素、
  `underflow=0/0`；
- `portable_fifo_native_elab_final_20260825`：完整七客户端 native FIFO
  顶层 xvlog/xelab 通过；
- `portable_display_fifo_twoframe_monitor2_64x48_20260825`：小帧两帧
  ownership/QoS 与 aggregate monitor 通过。

但尚未完成 native portable-SoC full xsim 的 CNN/tensor 长帧、FIFO occupancy、
display underflow、frame deadline 和真实帧率验收；这些仍是下一阶段的硬门。
