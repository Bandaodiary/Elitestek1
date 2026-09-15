# Native 640×480 trained-artifact staged preflight

更新日期：2026-08-28。

## 目的

`tb_c1_r1_native_artifact_preflight.sv` 是 native 长帧之前的一个有界门。它把
`vectors/microstyle_artifact/` 中真实的 22 个 descriptor 和 16,896 B parameter
arena 接入生产 RTL，但**不启动 CNN 数据平面**。测试覆盖：

1. 22 个 descriptor 的 decoder ready/valid 接收和字段投影；
2. 首层 `640×480`、层间输入/输出尺寸连续、末层 `640×480×3` 边界；
3. Conv/Depthwise/1×1/Upsample/Residual/RGB-output 的几何与参数偏移约束；
4. 真实 arena 经 `c1_axi_parameter_loader` 的 128-bit AXI 读突发（66 bursts/1056
   beats），包括 4 KiB 边界检查、AR/R 回压和参数 bank 回压；
5. `c1_r1_parameter_bank` 的原子提交、generation=1，以及首/中/尾字读回。

该测试的 PASS **不等价于** native 640×480 逐像素 CNN、portable SoC 全客户端
QoS 或 15 fps；它明确把下一阶段风险限定为真实 tensor 数据平面和时序/带宽。

## 复现

推荐使用 detached Vivado/xsim runner。WMI 被本机策略拒绝时，脚本自动切换到
`CREATE_BREAKAWAY_FROM_JOB` native fallback；工作目录和 vector 副本在 worker
结束时删除，不保存 `.wdb` 或大型 xsim 临时树。

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\case1\scripts\run_r1_native_artifact_preflight_xsim_detached.ps1 `
  -RunId native_artifact_preflight_full_20260828
```

只做 xvlog/xelab 结构门时加 `-CompileOnly`：

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\case1\scripts\run_r1_native_artifact_preflight_xsim_detached.ps1 `
  -RunId native_artifact_preflight_elab_20260828 -CompileOnly
```

## 结果

```text
C1_R1_NATIVE_ARTIFACT_PREFLIGHT_ELAB_PASS frame=640x480 stages=22 parameter_bytes=16896
C1_R1_NATIVE_ARTIFACT_PREFLIGHT_PASS frame=640x480 stages=22 descriptor_count=22 parameter_bytes=16896 parameter_words=1056 parameter_nonzero_words=1030 bursts=66 beats=1056 ar_stalls=23 r_stalls=242 generation=1 boundary=DESCRIPTOR_CONTINUITY_PLUS_PARAMETER_COMMIT_ONLY
```

Icarus 14.0 使用同一 TB 也通过；其 `sorry: constant selects ...` 仅是 Icarus 的
敏感列表提示，不是 RTL 错误。runner 的持久日志仅保留 xvlog/xelab/xsim 的短文本
输出，完整临时树在 `finally` 中清理。

## 下一步边界

下一步应把同一真实 descriptor/arena 接入 native `c1_r1_boardless_frame_system`
或 portable SoC 的 tensor adapter，先做首层/末层有限窗口和参数读回，再决定是否
进行 640×480 全帧。由于当前 adapter 是单 outstanding 64-bit correctness-first
路径，不应把本预检的 66 个参数突发误认为 CNN 端到端带宽或 15 fps 证据。
