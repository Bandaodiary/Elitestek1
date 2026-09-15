# Stage-0→Stage-6 tensor-bank handoff preflight

更新日期：2026-08-29。

## 目的

本专项把已经闭合的 8×8 production-parameter-bank handoff 从
`res0.depthwise3x3`（stage 3）继续推进到第一个残差块的尾部和下一个扩展层：

```text
stage 4  res0.project1x1  （C48 → C24）
stage 5  res0.add_relu     （C24 + skip C24 → C24）
stage 6  res1.expand1x1   （C24 → C48）
```

这是一个板卡前、有限 2×2 的数据 provenance/算术/协议门，不是 native
640×480 长帧，也不是完整 22-stage 生产性能回归。每个较高 stage 的开关都会
自动包含较低 stage 的完整前置 handoff；测试台在末个写响应上施加固定 3 周期
延迟，再检查 abort/drain。

本阶段没有改动 `rtl/cnn` 的生产 datapath；新增计数器、producer bitmap 和
stage marker 全部位于仿真 testbench/runner，因此不会直接增加 Ti60 的 LE、FF、
EBR 或 DSP。它验证的是现有通用 descriptor/adapter/engine 对这三种 opcode 的
可用性，后续若要把同一边界接入 native/15 fps，仍需单独评估真实缓存和 AXI 资源。

## 几何、opcode、bank 与向量偏移

| 阶段 | descriptor / opcode | 几何与 C8 group | 输入 → 输出 bank | operand records | expected outputs | 向量区间 |
|---|---|---|---|---:|---:|---|
| stage 0 | `encoder1.conv3x3_s2` / 1 | 8×8→4×4，1→2 | bank0→bank1 | 16 | 32 | records 0–15，expected 0–31 |
| stage 1 | `encoder2.conv3x3_s2` / 1 | 4×4→2×2，2→3 | bank1→bank0 | 8 | 12 | records 16–23，expected 32–43 |
| stage 2 | `res0.expand1x1` / 2 | 2×2→2×2，3→6 | bank0→bank1 | 12 | 24 | records 24–35，expected 44–67 |
| stage 3 | `res0.depthwise3x3` / 3 | 2×2→2×2，6→6 | bank1→bank2 | 24 | 24 | records 36–59，expected 68–91 |
| stage 4 | `res0.project1x1` / 2 | 2×2→2×2，6→3 | bank2→bank1 | 24 | 12 | records 60–83，expected 92–103 |
| stage 5 | `res0.add_relu` / 5 | 2×2→2×2，3→3 | bank1 + residual bank0→bank2 | 12 | 12 | records 84–95，expected 104–115 |
| stage 6 | `res1.expand1x1` / 2 | 2×2→2×2，3→6 | bank2→bank0 | 12 | 24 | records 96–107，expected 116–139 |

`record_offset/count`、`expected_offset/count` 以
`vectors/microstyle_engine_bitexact_8x8/engine_vector_manifest.json` 为唯一对照；
testbench 只冻结本次有限 gate 的边界常量并由 marker/count 检查守住它们。1×1
opcode 仍使用自描述的完整 3×3 record，但 adapter 只发
center tap（tap 4）请求；因此 stage 4/6 每个 operand record 对应一次 tensor
read。stage 5 每个 record 对应一次 primary read 和一次 residual read，故其
memory read 总数为 24（primary=12、residual=12）。

## 访问计数与边界

完整 `-FullStage6` 门的固定上限如下：

```text
operands=108  results=140  source_writes=64  stage_done=7
stage0_reads=144 stage0_writes=32
stage1_reads=72  stage1_writes=12
stage2_reads=12  stage2_writes=24
stage3_reads=216 stage3_writes=24
stage4_reads=24  stage4_writes=12
stage5_primary_reads=12 stage5_residual_reads=12 stage5_writes=12
stage6_reads=12  stage6_writes=24
```

若 testbench 只保留一个 `stage5_read_count`，应明确将它定义为
`primary + residual = 24`，不能误报为 manifest 的 12 条 operand records。
累计 stage 0–6 的 tensor reads（不含 64 次 source frame writes）为 504，写回
group 数为 140。

所有 tensor beat 的物理地址契约为：

```text
local_word = ((y * width + x) * groups) + group
byte_addr  = BASE_ADDR + bank * 8MiB + 8 * local_word
```

具体边界地址顺序为：

- stage 4 从 bank2 的 `((y*2+x)*6)+g` 读取，向 bank1 的
  `((y*2+x)*3)+g_out` 写入；
- stage 5 从 bank1 和 residual bank0 各按 `((y*2+x)*3)+g` 读取，向 bank2
  的同一 3-group 布局写入；
- stage 6 从 bank2 的 3-group 布局读取，向 bank0 的
  `((y*2+x)*6)+g_out` 写入。

由于三个 bank 的低地址窗口会反复覆盖，BFM 必须为不同生产阶段保存独立
provenance bitmap：stage3→stage4（bank2）、stage4→stage5 primary（bank1）、
stage1→stage5 residual（bank0）、stage5→stage6（bank2），以及后续
stage6→stage7（bank0）。不能用“该地址曾经写过”替代“由正确前一阶段写过”。

## Runner 用法

Icarus 快速门：

```powershell
& .\scripts\run_iverilog_stage1_handoff.ps1 -FullStage4
& .\scripts\run_iverilog_stage1_handoff.ps1 -FullStage5
& .\scripts\run_iverilog_stage1_handoff.ps1 -FullStage6
```

Vivado/xsim 脱离式门：

```powershell
& .\scripts\run_r1_stage1_handoff_xsim_detached.ps1 `
  -RunId stage4_full_metadata_final_20260829 -FullStage4
& .\scripts\run_r1_stage1_handoff_xsim_detached.ps1 `
  -RunId stage5_full_metadata_final_20260829 -FullStage5
& .\scripts\run_r1_stage1_handoff_xsim_detached.ps1 `
  -RunId stage6_full_metadata_final_20260829 -FullStage6
```

当多个 `-FullStageN` 同时给出时，runner 只转发最高编号的一个宏；例如
`-FullStage6 -FullStage4` 等价于 `-FullStage6`。testbench 宏再递归启用
stage 1–5 前置条件。xsim 使用 WMI/Breakaway worker，不绑定当前 Codex
Windows job。

本轮实际 marker 分别为：

```text
C1_R1_STAGE4_FULL_8X8_PASS
C1_R1_STAGE5_FULL_8X8_PASS
C1_R1_STAGE6_FULL_8X8_PASS
```

marker 只有在 operand window/residual、真实 parameter bank 算术、bank 地址与
provenance、输出 group 以及 x/y/group-last/SOF/EOL/EOF 全部通过后才应打印。

三个 detached xsim run（`stage4_full_metadata_final_20260829`、
`stage5_full_metadata_final_20260829`、`stage6_full_metadata_final_20260829`）的
xvlog/xelab/xsim exit code 均为 0，stderr 均为空，marker 各唯一；Icarus 三个
同宏命令也通过。stage 4/5/6 的累计 `operands/results` 分别为 `84/104`、
`96/116`、`108/140`，stage 5 的 primary/residual reads 为 `12/12`，
`stage_done` 分别为 `5/6/7`。

## 存储卫生

Icarus vectors/vvp 位于 `%TEMP%` 的一次性目录；xsim 的 xvlog/xelab/xsim
工作树位于 `case1/sim/xsim_r1_stage1_handoff_<RunId>` 私有目录。两个 runner
都在 `finally` 删除临时树，只保留 `case1/logs/stage1_handoff_runs/<RunId>/`
下的紧凑 stdout/stderr/status 文件。不要启用波形，也不要把临时 `xsim.dir`、
`.Xil` 或逐像素 stdout 复制回仓库。

## 证据边界与后续

本门已通过，说明 8×8 缩放图中 stage 0→6 的有限 production-bank
交接和 residual-bank 选择正确；stage 7 已在独立
`STAGE7_HANDOFF_PREFLIGHT.md` 中继续闭合。本文仍不证明 stage 8–21、完整
native CNN、AXI burst/multi-outstanding、15 fps、Efinity 综合布局布线或 Ti60
板级 MIPI/DDR/HDMI。后续 stage 8 仍应沿同样方法保持有界计数、超时、独立
provenance 与 detached runner 清理。
