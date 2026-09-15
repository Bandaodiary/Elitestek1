# Stage-0→Stage-7 tensor-bank handoff preflight

更新日期：2026-08-29。

## 目的

本阶段把 8×8 production-parameter-bank 的有限 handoff 从 stage 6
`res1.expand1x1` 推进到 stage 7 `res1.depthwise3x3`。它仍是板卡前的
2×2 bounded gate：完整 22-stage descriptor/parameter 配置保持不变，只让
stage 0–7 的有限数据流运行，然后在 stage-7 最后一个写响应后执行安全
abort/drain；不会启动 native 640×480 长帧或 15 fps 回归。

## 精确 ABI 与 bank 路由

唯一对照是
`vectors/microstyle_engine_bitexact_8x8/engine_vector_manifest.json`：

| 阶段 | descriptor / opcode | 几何与 C8 group | 输入 → 输出 bank | operand records | expected outputs |
|---|---|---|---|---:|---:|
| stage 6 | `res1.expand1x1` / 2 | 2×2→2×2，C24→C48，3→6 | bank2→bank0 | records 96–107（12） | expected 116–139（24） |
| stage 7 | `res1.depthwise3x3` / 3 | 2×2→2×2，C48→C48，6→6 | bank0→bank1 | records 108–131（24） | expected 140–163（24） |

stage 7 的每个 operand record 触发一个完整 3×3 SAME_REPLICATE 窗口，
访问顺序为 `output_pixel → input_group → tap`，共
`4 × 6 × 9 = 216` 个 64-bit tensor reads。边界 tap 保留重复的钳位地址，
不能把相同物理地址折叠成一次访问。每个输出像素写 6 个 C8 group，
共 24 writes。

2×2 局部地址按下式检查：

```text
tap = 0..8, dx = tap % 3, dy = tap / 3
sx = clamp(output_x + dx - 1, 0, 1)
sy = clamp(output_y + dy - 1, 0, 1)
local_word = ((sy * 2 + sx) * 6) + input_group
byte_addr  = BASE_ADDR + bank * 8MiB + (local_word << 3)
```

由于 bank0/1 的低地址窗口在前面阶段反复覆盖，BFM 使用独立 producer
bitmap：`bank0_stage6_written_q` 只允许 stage 7 消费 stage-6 结果，
`bank1_stage7_written_q` 记录本阶段写回，避免把旧 stage-0/2/4 内容误判为
合法输入。

## 完整 gate 计数

`-FullStage7` 的固定边界为：

```text
operands=132  results=164  source_writes=64  stage_done=8
stage0_reads=144 stage0_writes=32
stage1_reads=72  stage1_writes=12
stage2_reads=12  stage2_writes=24
stage3_reads=216 stage3_writes=24
stage4_reads=24  stage4_writes=12
stage5_primary_reads=12 stage5_residual_reads=12 stage5_writes=12
stage6_reads=12  stage6_writes=24
stage7_reads=216 stage7_writes=24
```

累计 tensor reads（不含 64 次 source-frame writes）为 720，累计 group
write-back 为 164。真实 parameter bank 仍由 1,056 个 128-bit words 原子
提交，算术结果、输出坐标以及 group-last/SOF/EOL/EOF 元数据逐项比较。

## 复现命令

Icarus 快速门：

```powershell
& .\scripts\run_iverilog_stage1_handoff.ps1 -FullStage7
```

detached Vivado/xsim 门：

```powershell
& .\scripts\run_r1_stage1_handoff_xsim_detached.ps1 `
  -RunId stage7_full_metadata_final_20260829 -FullStage7
```

两个 runner 都只转发最高编号的 stage 宏；`C1_STAGE7_FULL` 自动包含
stage 1–6 前置条件。xsim 由 WMI/Breakaway worker 启动，不绑定当前 Codex
Windows job，也不启用波形。

## 已取得证据

Icarus 与 detached Vivado/xsim 均通过，实际 marker 为：

```text
C1_R1_STAGE7_FULL_8X8_PASS frame=8x8 stages=22 operands=132 results=164 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage2_reads=12 stage2_inputs=12 stage2_pixels=4 stage2_writes=24 stage2_outputs=24 stage3_reads=216 stage3_inputs=24 stage3_pixels=4 stage3_writes=24 stage3_outputs=24 stage4_reads=24 stage4_inputs=24 stage4_pixels=4 stage4_writes=12 stage4_outputs=12 stage5_reads=24 stage5_main_reads=12 stage5_residual_reads=12 stage5_inputs=12 stage5_pixels=4 stage5_writes=12 stage5_outputs=12 stage6_reads=12 stage6_inputs=12 stage6_pixels=4 stage6_writes=24 stage6_outputs=24 stage7_reads=216 stage7_inputs=24 stage7_pixels=4 stage7_writes=24 stage7_outputs=24 stage_done=8 abort=1 abort_response_delay=3 first_group=0000080000000000 last_group=0300000001000000 boundary=SCALED_STAGE0_STAGE1_STAGE2_STAGE3_STAGE4_STAGE5_STAGE6_COMPLETE_PLUS_STAGE7_FULL_2X2_HANDOFF
```

xsim run `stage7_full_metadata_final_20260829` 的 xvlog/xelab/xsim exit code
均为 0，marker 唯一，stderr 为 0 bytes；`case1/sim` 下的私有 runRoot 已由
runner 删除，检查时没有残留 Vivado/xvlog/xelab/xsim/vvp 进程。随后
`-FullStage6`、`-FullStage3` 和默认首像素 Icarus 回归也保持 PASS。

## 证据边界

本门只闭合 stage 0→7 的 8×8 production-bank 地址、算术、SAME_REPLICATE
读序、bank provenance、输出元数据和 abort/drain。它不证明 stage 8–21、
完整 native 640×480 CNN、AXI burst/multi-outstanding、共享 DDR QoS、Efinity
布局布线、Ti60 板级 MIPI/DDR/HDMI 或 15 fps。下一停止点是 stage 8
`res1.project1x1`；仍应沿用有界计数、独立 provenance 和 detached 清理策略。

## 存储卫生

Icarus 的 vectors/vvp 位于 `%TEMP%` 一次性目录；xsim 工作树位于
`case1/sim/xsim_r1_stage1_handoff_<RunId>`，runner 在 `finally` 删除。长期
只保留 `case1/logs/stage1_handoff_runs/<RunId>/` 的紧凑 stdout/stderr/status，
不保存波形、`xsim.dir` 或逐像素临时输出。
