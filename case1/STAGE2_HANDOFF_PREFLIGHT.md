# Stage-0→Stage-1→Stage-2 tensor handoff preflight

更新日期：2026-08-29。

## 目的

本专项在 `STAGE1_HANDOFF_PREFLIGHT.md` 的基础上再推进一个有限边界：使用真实
production parameter bank、完整 22 个 descriptor 和同一份 8×8 缩放向量，让
stage 0、stage 1 和 stage 2 连续运行到 stage 2 EOF，然后在最后一个 tensor
写响应仍处于可控延迟时安全 abort。它不是 22-stage 全网回归，也不启动 native
640×480 长帧。

stage 2 对应 descriptor `res0.expand1x1`，是一个 1×1 pointwise expansion：
输入为 C24（3 个 C8 group），输出为 C48（6 个 C8 group），空间尺寸保持 2×2。
由于 1×1 opcode 只需要 center tap，adapter 对每个输出像素/输入 group 只发起
一次 tensor read，而不是 3×3 的九次读取。

该门新增的验证点是：

1. stage 1 的 12 个输出 group 确实写入 bank0，并由独立 provenance bitmap 标记；
2. stage 2 的 12 个输入 read 只能消费这些 stage-1 写入的 bank0 word，地址按
   2×2×3 的 raster/group 顺序逐项检查；
3. stage 2 的 24 个 bank1 output group 与向量 `expected_outputs.mem[44..67]`
   完全一致；
4. 三个 stage 的 output metadata（stage/x/y/group/group-last/SOF/EOL/EOF）和
   stage_done 计数均与缩放几何一致；
5. 最后一个 stage-2 写请求的 response 固定延迟 3 个周期，确认 abort drain
   不会丢掉已经接受的 pending response。

## 几何、bank 与计数

| 阶段 | 几何 | 输入/输出 group | 输入 bank → 输出 bank | 读取/写入 |
|---|---|---:|---|---:|
| stage 0 | 8×8 → 4×4，3×3 stride-2 | 1 → 2 | bank0 → bank1 | 144 / 32 |
| stage 1 | 4×4 → 2×2，3×3 stride-2 | 2 → 3 | bank1 → bank0 | 72 / 12 |
| stage 2 (`res0.expand1x1`) | 2×2 → 2×2，1×1 | 3 → 6 | bank0 → bank1 | 12 / 24 |

因此 stage-2 full gate 的固定 scoreboard 上限为：

```text
operands=36  results=68  source_writes=64  stage_done=3
```

其中 operand 数是 `16 + 8 + 12`，result 数是 `32 + 12 + 24`。向量文件仍然
装载完整的 896 条 operand/836 条 expected record；测试台只把动态停止点限制在
stage 2 EOF，不改变 descriptor 或向量 ABI。`C1_STAGE2_FULL` 只定义在 testbench
和 runner 中，不增加生产 RTL 的寄存器、RAM、DSP 或 AXI 端口。

## 复现

### Icarus（快速门）

```powershell
& .\scripts\run_iverilog_stage1_handoff.ps1 -FullStage2
```

脚本将 vectors 与 vvp snapshot 放在 `%TEMP%` 的一次性目录，并在 `finally` 中
删除；不会在 `case1/sim` 保存仿真树或波形。当前通过 marker 为：

```text
C1_R1_STAGE2_FULL_8X8_PASS frame=8x8 stages=22 operands=36 results=68 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage2_reads=12 stage2_inputs=12 stage2_pixels=4 stage2_writes=24 stage2_outputs=24 stage_done=3 abort=1 abort_response_delay=3 first_group=0c00000631000031 last_group=00010000210a0000 boundary=SCALED_STAGE0_STAGE1_COMPLETE_PLUS_STAGE2_FULL_2X2_HANDOFF
```

### Vivado/xsim（脱离式 worker）

前台命令只创建 WMI/Breakaway worker，避免把 Vivado/xsim 绑定在当前 Codex
Windows job；worker 结束后删除私有 `case1/sim/xsim_*` 工作树：

```powershell
& .\scripts\run_r1_stage1_handoff_xsim_detached.ps1 `
  -RunId stage2_full_metadata_final_20260829 -FullStage2
```

本次 `stage2_full_metadata_final_20260829` 已通过，`xvlog/xelab/xsim` exit code
均为 0，stderr 均为空，marker 唯一，runRoot 已删除；只保留 7 个紧凑日志文件，
总量约 6.3 KiB。相同源码的 stage-1 首像素、stage-1 完整 2×2 和默认 22-stage
全链 probe 也已在本阶段回归通过。

## 证据边界与后续门

本门闭合的是 8×8 缩放拓扑中 stage 0→1→2 的 production-bank 数据 provenance、
1×1 center-tap 地址、算术结果、元数据和 abort-drain。它不证明 stage 3–21、
完整 22-stage production-bank 全链、native 640×480、AXI burst/multi-outstanding、
共享七客户端 QoS、100 MHz 时序或 15 fps。下一步若继续推进，应优先用同样的
有界方式验证 stage 3（depthwise 3×3，bank1→bank2）；该门已记录在
`STAGE3_HANDOFF_PREFLIGHT.md`。只有这些边界稳定后，再评估是否值得启动完整
8×8 production-bank 回归。
