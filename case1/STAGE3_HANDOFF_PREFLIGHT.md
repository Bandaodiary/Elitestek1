# Stage-0→Stage-1→Stage-2→Stage-3 tensor handoff preflight

更新日期：2026-08-29。

## 目的

本专项在 stage-2 full gate 之后继续推进一个有限边界：使用真实 production
parameter bank、完整 22 个 descriptor 和同一份 8×8 缩放向量，让 stage 0、1、2、3
连续运行到 stage 3 EOF，然后在最后一个 tensor 写响应仍处于可控延迟时安全
abort。它不是 22-stage 全网回归，也不启动 native 640×480 长帧。

stage 3 对应 descriptor `res0.depthwise3x3`，输入和输出空间均为 2×2，通道均为
C48（6 个 C8 group）。它使用 stride-1、SAME_REPLICATE 的 3×3 depthwise window：
每个输出像素/输入 group 发出 9 次 tap read，因此边界像素会产生重复的物理地址，
这些请求不能被错误合并或去重。

本门新增确认：

1. stage 2 的 24 个 bank1 输出确实被独立 provenance bitmap 标记；
2. stage 3 的 216 次读取严格按像素→输入 group→tap 顺序发生，并且每个地址都
   对应已写入的 stage-2 bank1 word；
3. stage 3 的 24 个 bank2 输出与 `expected_outputs.mem[68..91]` 完全一致；
4. stage 3 输出的 x/y、group-last、SOF/EOL/EOF 与 2×2×6 几何一致；
5. 最后一个 stage-3 写请求的 response 固定延迟 3 个周期，abort 仍能排空
   pending response。

## 几何、bank 与计数

| 阶段 | 几何 | 输入/输出 group | 输入 bank → 输出 bank | 读取/写入 |
|---|---|---:|---|---:|
| stage 0 | 8×8 → 4×4，3×3 stride-2 | 1 → 2 | bank0 → bank1 | 144 / 32 |
| stage 1 | 4×4 → 2×2，3×3 stride-2 | 2 → 3 | bank1 → bank0 | 72 / 12 |
| stage 2 | 2×2 → 2×2，1×1 | 3 → 6 | bank0 → bank1 | 12 / 24 |
| stage 3 (`res0.depthwise3x3`) | 2×2 → 2×2，3×3 stride-1 | 6 → 6 | bank1 → bank2 | 216 / 24 |

stage-3 full gate 的固定 scoreboard 上限为：

```text
operands=60  results=92  source_writes=64  stage_done=4
```

其中 operand 数为 `16 + 8 + 12 + 24`，result 数为 `32 + 12 + 24 + 24`。
向量文件仍装载完整 896 条 operand/836 条 expected record；`C1_STAGE3_FULL` 只
定义在 testbench 和 runner 中，不增加生产 RTL 的寄存器、RAM、DSP 或 AXI 端口。

## 复现

### Icarus（快速门）

```powershell
& .\scripts\run_iverilog_stage1_handoff.ps1 -FullStage3
```

脚本将 vectors 与 vvp snapshot 放在 `%TEMP%` 的一次性目录，并在 `finally` 中
删除；不会在 `case1/sim` 保存仿真树或波形。当前通过 marker 为：

```text
C1_R1_STAGE3_FULL_8X8_PASS frame=8x8 stages=22 operands=60 results=92 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage2_reads=12 stage2_inputs=12 stage2_pixels=4 stage2_writes=24 stage2_outputs=24 stage3_reads=216 stage3_inputs=24 stage3_pixels=4 stage3_writes=24 stage3_outputs=24 stage_done=4 abort=1 abort_response_delay=3 first_group=19090000110c0021 last_group=0300300f00040000 boundary=SCALED_STAGE0_STAGE1_STAGE2_COMPLETE_PLUS_STAGE3_FULL_2X2_HANDOFF
```

### Vivado/xsim（脱离式 worker）

```powershell
& .\scripts\run_r1_stage1_handoff_xsim_detached.ps1 `
  -RunId stage3_full_metadata_final_20260829 -FullStage3
```

前台只创建 WMI/Breakaway worker，避免 Vivado/xsim 绑定在当前 Codex Windows
job；worker 结束后删除私有 `case1/sim/xsim_*` 工作树。本次运行的
`xvlog/xelab/xsim` exit code 均为 0，stderr 均为空，marker 唯一，runRoot 已删除；
仅保留 7 个紧凑日志文件（约 6.4 KiB）。

## 证据边界与后续门

本门闭合的是 8×8 缩放拓扑中 stage 0→1→2→3 的 production-bank 数据 provenance、
depthwise SAME_REPLICATE 地址、算术结果、元数据和 abort-drain。它本身不证明
stage 4–21、完整 22-stage production-bank 全链、native 640×480、AXI burst/
multi-outstanding、共享七客户端 QoS、100 MHz 时序或 15 fps。随后 stage 4–6
有界门已在 [`STAGE4_6_HANDOFF_PREFLIGHT.md`](STAGE4_6_HANDOFF_PREFLIGHT.md)
中完成，stage 7 `res1.depthwise3x3` 已在
[`STAGE7_HANDOFF_PREFLIGHT.md`](STAGE7_HANDOFF_PREFLIGHT.md) 中完成；后续
stage 8 仍应保持有界计数、超时和 detached runner 自动清理。
