# Native 640×480 首层有限窗口预检

更新时间：2026-08-28。

## 目的与边界

`tb_c1_r1_native_first_window_preflight.sv` 把真实 native 640×480、22-stage
descriptor 接入生产 `c1_r1_microstyle_tensor_adapter`，先按正常握手写入完整
RGB 源帧，再只消费首层第一个输出像素。一个小型合成 engine 接收首个 3×3
window 并返回首层的两个 output group；测试在第二个输出 word 的响应仍按合同
排空后发出 abort。它验证的是 native 数据面入口，而不是完整 CNN：

- bank-0 源 tensor 的 307,200 个连续 64-bit 写地址、对齐和容量；
- 首层 stride-2 + SAME_REPLICATE 的 9 个 tap 地址与源数据（左/上边界含重复）；
- 首层两个 output-group 的 bank-1 地址、标记和单 outstanding response 合同；
- abort 在已接受写事务之后的 drain/回 idle 行为。

测试不会启动后续 21 层、不会生成波形，也不会声称 native 逐像素 Golden、
15 fps、共享七客户端 QoS 或 Ti60/Efinity timing signoff。

## 复现

推荐 detached runner；它在 WMI 受限时使用 `CREATE_BREAKAWAY_FROM_JOB` fallback，
将 descriptor 副本放入私有 runRoot，并在 `finally` 删除完整 Vivado/xsim 树：

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\case1\scripts\run_r1_native_first_window_preflight_xsim_detached.ps1 `
  -RunId native_first_window_full_20260828
```

只做结构门：

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\case1\scripts\run_r1_native_first_window_preflight_xsim_detached.ps1 `
  -RunId native_first_window_elab_20260828 -CompileOnly
```

同一有限窗口也可打开 adapter 的两个可选流水寄存器，做功能 A/B（这不是时序签核，
只是确认增加一拍/多拍后 native 地址与握手合同仍保持不变）：

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\case1\scripts\run_r1_native_first_window_preflight_xsim_detached.ps1 `
  -RunId native_first_window_pipe_full_20260828 `
  -PipelinedAddress -PipelinedPixelIndex
```

## 结果

Icarus 14.0 与 detached Vivado/xsim 默认配置均通过；额外的地址/像素索引流水化
配置也通过同一个 gate：

```text
C1_R1_NATIVE_FIRST_WINDOW_PREFLIGHT_PASS frame=640x480 stages=22 source_writes=307200 first_window_reads=9 engine_inputs=1 output_writes=2 abort=1 base=00100000 boundary=NATIVE_SOURCE_INGEST_PLUS_FIRST_STAGE_WINDOW_ONLY
```

流水化 A/B 的 xsim 摘要为：

```text
C1_R1_NATIVE_FIRST_WINDOW_PREFLIGHT_PASS frame=640x480 stages=22 pipeline=1 pixel_pipeline=1 source_writes=307200 first_window_reads=9 engine_inputs=1 output_writes=2 abort=1 base=00100000 boundary=NATIVE_SOURCE_INGEST_PLUS_FIRST_STAGE_WINDOW_ONLY
```

`pipeline=1`/`pixel_pipeline=1` 是编译宏开关，默认仍为 0；本结果只说明寄存器化
路径在首窗口的功能/协议兼容性，不能推导 WNS、Fmax 或 15 fps 提升。

本次 xsim worker 约 11 s；完整 runRoot 已清理，未留下 `xsim/xelab/xvlog/vivado`
进程。该门的下一步是把同样的有限窗口接到真实 engine/parameter bank，或在
确定可控的周期/流量预算后再设计更大 ROI；不应直接把它扩展成无界 native 全网
仿真。
