# Stage 8–21 production-bank handoff preflight

更新日期：2026-08-29。

## 目的与边界

本文件记录赛题一 8×8 trained-artifact 缩放路径中，stage 8 至 stage 21 的
production parameter-bank / tensor-bank 交接证据。每个 `-FullStageN` 都自动
执行 stage 0…N 的前置阶段，然后在 N 的完整 2×2 结果交接处停止；这是一组
**有界 handoff gate**，不是 native 640×480 长帧或 15 fps 性能测试。

测试台使用真实 22-stage descriptor、真实 1,056×128-bit parameter arena、
三组 8 MiB 外部 tensor-bank 地址合同和 Python 生成的 8×8 vectors。BFM 对每个
读请求检查 producer bank、线性 record 顺序、精确地址、数据、x/y/group-last
以及 SOF/EOL/EOF；对每个写请求检查目标 bank、唯一 bitmap、record offset 和
响应顺序。stage 21 直接把 bank-1 的 RGB 结果送入 final adapter，不再向
tensor bank 写回，因此它以 64 个 final RGB beat 正常结束，不使用 abort。

## 层间几何、bank 路由和计数

| stage | descriptor / 运算 | 输入 → 输出形状 | 读序/写回 | producer → consumer bank | 本阶段 reads / writes | 累计 operands / results |
|---:|---|---|---|---|---:|---:|
| 8 | `res1.project1x1` | 2×2, C48→C24 (6→3 groups) | 1×1 center | bank1 → bank0 | 24 / 12 | 156 / 176 |
| 9 | `res1.add_relu` | 2×2, C24 | primary + residual | bank0 + bank2 → bank1 | 12 + 12 / 12 | 168 / 188 |
| 10 | `res2.expand1x1` | 2×2, C24→C48 (3→6 groups) | 1×1 center | bank1 → bank2 | 12 / 24 | 180 / 212 |
| 11 | `res2.depthwise3x3` | 2×2, C48, 6 groups | 3×3 `SAME_REPLICATE` | bank2 → bank0 | 216 / 24 | 204 / 236 |
| 12 | `res2.project1x1` | 2×2, C48→C24 | 1×1 center | bank0 → bank2 | 24 / 12 | 228 / 248 |
| 13 | `res2.add_relu` | 2×2, C24 | primary + residual | bank2 + bank1 → bank0 | 12 + 12 / 12 | 240 / 260 |
| 14 | `decoder1.upsample2` | 2×2→4×4, C24 | source floor(output/2) | bank0 → bank1 | 48 / 48 | 288 / 308 |
| 15 | `decoder1.depthwise3x3` | 4×4, C24, 3 groups | 3×3 `SAME_REPLICATE` | bank1 → bank0 | 432 / 48 | 336 / 356 |
| 16 | `decoder1.pointwise1x1` | 4×4, C24→C16 (3→2 groups) | 1×1 center | bank0 → bank1 | 48 / 32 | 384 / 388 |
| 17 | `decoder2.upsample2` | 4×4→8×8, C16 | source floor(output/2) | bank1 → bank0 | 128 / 128 | 512 / 516 |
| 18 | `decoder2.depthwise3x3` | 8×8, C16, 2 groups | 3×3 `SAME_REPLICATE` | bank0 → bank1 | 1,152 / 128 | 640 / 644 |
| 19 | `decoder2.pointwise1x1` | 8×8, C16→C8 (2→1 group) | 1×1 center | bank1 → bank0 | 128 / 64 | 768 / 708 |
| 20 | `output.conv3x3` | 8×8, C8→C3 | 3×3 `SAME_REPLICATE` | bank0 → bank1 | 576 / 64 | 832 / 772 |
| 21 | `output.s8_to_rgb` | 8×8, C3→RGB | 1×1 center / final stream | bank1 → final adapter | 64 / 0 | 896 / 836 + 64 RGB |

`stage_done` 在完整 handoff 模式中分别为 `stage+1`；因此 stage 8…21 的
终点值为 9…22。stage 9 和 stage 13 的 residual 来源分别固定为 stage 5
的 bank2 与 stage 9 的 bank1，不能仅凭低地址命中推断来源；测试台使用独立
producer bitmap 把这两个语义锁住。

## 已执行的板前回归

### Icarus

在 `D:\iverilog` 的 Icarus 14.0 devel 上，`-FullStage8`…`-FullStage21`
逐一执行并通过。累计 marker 如下（所有 intermediate stage 均为
`abort=1, abort_response_delay=3`；stage 21 为自然完成 `abort=0`）：

```text
stage8  156/176  stage_done=9
stage9  168/188  stage_done=10
stage10 180/212  stage_done=11
stage11 204/236  stage_done=12
stage12 228/248  stage_done=13
stage13 240/260  stage_done=14
stage14 288/308  stage_done=15
stage15 336/356  stage_done=16
stage16 384/388  stage_done=17
stage17 512/516  stage_done=18
stage18 640/644  stage_done=19
stage19 768/708  stage_done=20
stage20 832/772  stage_done=21
stage21 896/836  final=64 stage_done=22
```

复现示例：

```powershell
Set-Location D:\contest\2026FPGA\yilingsi\case1
& .\scripts\run_iverilog_stage1_handoff.ps1 -FullStage14
& .\scripts\run_iverilog_stage1_handoff.ps1 -FullStage21
```

本轮 14 个终点的紧凑 marker 摘要保存在
`logs/stage1_handoff_runs/stage8_21_iverilog_regression_20260829.log`；runner
本身仍不把 vvp 或逐像素 stdout 写入项目目录。

### Vivado/xsim（脱离式 worker）

为控制会话和磁盘占用，使用 `run_r1_stage1_handoff_xsim_detached.ps1` 的
WMI/`CREATE_BREAKAWAY_FROM_JOB` worker。已完成两个代表性端点：

```text
C1_R1_STAGE14_FULL_8X8_PASS ... operands=288 results=308 final=0 stage_done=15 abort=1 boundary=PRODUCTION_BANK_HANDOFF
C1_R1_STAGE21_FULL_8X8_PASS ... operands=896 results=836 final=64 stage_done=22 abort=0 boundary=PRODUCTION_BANK_HANDOFF
```

对应 run ID 为 `stage14_full_handoff_20260829`、
`stage21_full_handoff_20260829`，以及收口复核的
`stage21_full_handoff_final_20260829`。xvlog/xelab/xsim 返回码均为 0，stderr 为空；
stage 21 的完整 handoff counts 还明确给出 `s18=1152/128`、`s20=576/64`、
`s21=64 final=64`，覆盖两个最容易因边界重复或 RGB 通道宽度出错的末端层。

## 存储与复现约束

- xsim runner 每次把 vectors、xvlog/xelab snapshot 和日志放到 disposable
  `runRoot`，在 `finally` 中删除；`case1/sim` 不保留 `.Xil`、波形或大 stdout。
- Icarus 的 `vvp` 和复制后的 vectors 放在 `%TEMP%` 一次性目录，结束后自动清理。
- 长帧、VCD/FST、GUI 波形和逐像素 stdout 不属于本 gate；需要调试时应显式
  另存小范围波形，并在确认后删除。
- `case1/sim/c1_pixel_pipeline_proxy.dcp`（若存在）是有意保留的综合代理快照，
  不属于 handoff 仿真临时文件。
- 当前证据只把 production-bank handoff 闭合到 22-stage 8×8 缩放链；仍待
  完成 native 640×480 全网、真实 DDR3/Efinity IP、共享 AXI burst/多 outstanding、
  时序收敛和 15 fps deadline/QoS 验证。

## 代码入口

- 测试台：`sim/tb_c1_r1_microstyle_artifact_tensor_engine_8x8.sv`
- Icarus runner：`scripts/run_iverilog_stage1_handoff.ps1`
- detached xsim runner：`scripts/run_r1_stage1_handoff_xsim_detached.ps1`
- 前一阶段记录：`STAGE7_HANDOFF_PREFLIGHT.md`
