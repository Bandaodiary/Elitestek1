# Display response FIFO：Vivado proxy 综合结果

更新时间：2026-08-25。

## 目的与边界

这是板卡到手前的结构预算，不是易灵思/Efinity 签核。使用本机 Vivado
2023.1、`xc7a200tsbg484-1` 代理器件，把同一个
`c1_display_prefetch_pair` 分别综合为：

| 变体 | 参数 |
|---|---|
| bypass | `ENABLE_RESPONSE_FIFO=0`、`RESPONSE_FIFO_DEPTH=64` |
| fifo128 | `ENABLE_RESPONSE_FIFO=1`、`RESPONSE_FIFO_DEPTH=128` |

core clock 约束为 100 MHz（10 ns），pixel clock 约束为 71.43 MHz（14 ns）。
core/pixel 之间采用 `set_clock_groups -asynchronous`，因为 RTL 已有显式
toggle synchronizer；因此报告中的 WNS 是各时钟域内部的 proxy 指标，不是
跨 CDC 路径的板级时序承诺。

## 当前 run

`display_fifo_proxy_async_final2_20260825` 由 WMI 隐藏 worker 启动，Vivado
batch、两个变体均完成，stderr 为空，唯一最终 marker 为
`C1_DISPLAY_FIFO_PROXY_SYNTH_PASS variants=2`。报告位于：

`case1/sim/display_prefetch_fifo_proxy_run_display_fifo_proxy_async_final2_20260825/reports/`

### 资源对比（Vivado proxy）

| 指标 | bypass | fifo128 | 增量 |
|---|---:|---:|---:|
| Total LUTs | 2,600 | 3,094 | +494（+19.0%） |
| Logic LUTs | 1,320 | 1,510 | +190 |
| LUTRAMs | 1,280 | 1,584 | +304 |
| FFs | 1,141 | 1,185 | +44 |
| RAMB36 | 0 | 0 | 0 |
| RAMB18 | 0 | 0 | 0 |
| DSP blocks | 4 | 4 | 0 |

两个 FIFO 的逻辑层级各约 257/258 LUT、22 FF、152 LUTRAM。理论 token
存储下界仍为 `59 × 128 × 2 = 15,104 bit`；Vivado 将其推成 LUTRAM，且
控制/计数逻辑使 LUTRAM 数高于裸 bit 数换算。Efinity 可能选择不同的
LUTRAM/BRAM 映射，不能直接把这组数字当作 Ti60 资源占用。

### 时序对比（各域内部）

| 时钟域 | bypass WNS | fifo128 WNS | 变化 |
|---|---:|---:|---:|
| core_clk 100 MHz | +3.265 ns | +2.470 ns | -0.795 ns |
| pixel_clk 71.43 MHz | +8.470 ns | +8.470 ns | 0 |

两种变体的报告均为 0 个 setup failing endpoint。FIFO 的主要代价落在
core-domain reader/FIFO admission 路径，pixel-domain line-store 路径没有
变差；这与 xsim 中 FIFO 仅吸收 core→line-store token 的结构相符。

## 复现

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\case1\scripts\run_display_prefetch_fifo_proxy_synth_detached.ps1 `
  -RunId display_fifo_proxy_async_final2_20260825
```

Tcl 源码为 `case1/scripts/synth_display_prefetch_fifo_proxy.tcl`。runner 使用
WMI 创建 detached worker，避免 Vivado 绑定到当前 Codex Windows Job。

## 结论与下一步

在当前 proxy part 上，depth=128 双 FIFO 的资源代价是约 494 LUT、44 FF、
304 LUTRAM，core 100 MHz 仍有 +2.470 ns WNS；这足以支持“先保留 FIFO 作为
可选 QoS 路径、上板前再做 Efinity 映射”的工程决策。仍需：

1. 将 FIFO 分支接入 native portable-SoC 七客户端长帧，记录 occupancy、
   underflow 和 frame deadline；
2. 在易灵思工具链中复核 LUTRAM/EBR 映射、Ti60 总资源和真实时钟约束；
3. 结合真实 CNN/tensor 访存争用后再决定 FIFO 深度、AXI outstanding 和
   独立 display 端口方案。
