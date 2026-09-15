# Stage-0→Stage-1 tensor handoff preflight

更新日期：2026-08-29。

## 目的

本专项补上“真实参数 Bank 已加载”与“中间 tensor 写回后由下一层重新读入”
同时出现的组合边界。它不是另一个 22-stage 全链路回归，而是一个有界的
stage-1 交接门：使用生产参数 Bank、完整的 22 个 descriptor 和 8×8 缩放拓扑，
让 stage 0 完整产生 4×4×2 个输出 group。默认模式让 stage 1 的第一个输出像素
完成两个输入 group 的 3×3 window 读取和三个输出 group 写回；`C1_STAGE1_FULL`
模式则完成 stage 1 的整个 2×2 输出（12 个 group），两种模式随后都通过共享
abort 安全停止。

这样可以在没有 Ti60 板卡的情况下确认以下关键事实：

1. parameter loader 已把 1,056 个 128-bit word 原子提交到 production
   `c1_r1_parameter_bank`，并向 engine 暴露 generation=1 的 active bank；
2. stage 0 的 32 个中间输出确实写入 bank-1，且 stage-1 读取发生在写入完成
   之后，而不是误读空/旧数据；
3. adapter 的 stage/channel/group 元数据、地址序列、engine operand/output
   顺序与 Python 生成的 8×8 向量一致，且输出的 x/y/group-last/SOF/EOL/EOF
   边界按缩放几何逐项检查；
4. 在 stage-1 首像素完成后，abort 会等待/排空已经接受的 pending response，
   不依赖长帧或板上 DDR 的不确定延迟。

## 缩放拓扑与停止点

| 项目 | stage 0 | stage 1（本专项） |
|---|---:|---:|
| 输入/输出空间 | 8×8 → 4×4 | 4×4 → 2×2 |
| 输入/输出通道 | C3 → C12 | C12 → C24 |
| 输入/输出 group | 1 → 2 | 2 → 3 |
| 完整输出 group 数 | 32 | 12（`C1_STAGE1_FULL`） |
| 默认最小门 | 64 个源像素写入后，stage-0 窗口读 | 首像素：2 group × 9 tap = 18，写 3 |
| 完整 stage-1 门 | 同上 | 4 像素：8 group × 9 tap = 72，写 12 |
| 停止条件 | stage-0 写回 EOF | 默认首像素或完整 2×2 写回后 abort |

测试台仍装载完整 `engine_vectors.mem`（896 条 operand、836 条 output），因此
不会改变 descriptor/向量文件的 ABI；`C1_STAGE1_HANDOFF` 只改变 scoreboard 的
有界上限和 BFM 的停止点，`C1_STAGE1_FULL` 再把上限提升到 stage 1 的 2×2
输出。生产参数侧由 `C1_USE_PARAMETER_BANK` 打开，避免把 direct
one-outstanding parameter BFM 的结果误认为 dual-bank production seam。
两个宏只存在于测试台/runner，未增加生产 RTL 的寄存器、BRAM、DSP 或 AXI
端口；因此本专项不会改变已有的综合资源预算。

## 复现

### Icarus（板前快速门）

从 `case1` 目录可直接运行一次性脚本；默认是首像素门，加
`-FullStage1` 是完整 2×2 stage-1 门：

```powershell
& .\scripts\run_iverilog_stage1_handoff.ps1
& .\scripts\run_iverilog_stage1_handoff.ps1 -FullStage1
```

脚本会把 vectors 和 vvp snapshot 放入 `%TEMP%` 并在 `finally` 删除。若需手工
检查编译源列表，也可运行同一个 SystemVerilog 测试台：

```powershell
D:\iverilog\bin\iverilog.exe -g2012 -s tb_c1_r1_microstyle_artifact_tensor_engine_8x8 `
  -o .stage1_handoff.vvp `
  -D C1_USE_PARAMETER_BANK -D C1_STAGE1_HANDOFF `
  rtl/common/c1_ram_sdp_read_first.sv `
  rtl/control/c1_descriptor_pkg.sv `
  rtl/control/c1_descriptor_decoder_pkg.sv `
  rtl/control/c1_layer_command_decoder.sv `
  rtl/cnn/c1_s8_dot8_accum.sv `
  rtl/cnn/c1_s8_dot8_accum_pipelined.sv `
  rtl/cnn/c1_s8_dot8_accum_treepipe.sv `
  rtl/cnn/c1_requant_bank8.sv `
  rtl/cnn/c1_dot8x8_requant_core.sv `
  rtl/cnn/c1_dwconv3x3_c8_requant_core.sv `
  rtl/cnn/c1_r1_c8_parameter_scheduler.sv `
  rtl/cnn/c1_r1_parameter_bank.sv `
  rtl/cnn/c1_r1_microstyle_engine.sv `
  rtl/cnn/c1_r1_microstyle_cnn_top.sv `
  rtl/cnn/c1_r1_microstyle_tensor_adapter.sv `
  sim/tb_c1_r1_microstyle_artifact_tensor_engine_8x8.sv
Set-Location vectors\microstyle_engine_bitexact_8x8
vvp ..\..\.stage1_handoff.vvp
Remove-Item ..\..\.stage1_handoff.vvp -Force
```

实际板前 smoke 输出：

```text
C1_R1_STAGE1_HANDOFF_8X8_PASS frame=8x8 stages=22 operands=18 results=35 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=18 stage1_inputs=2 stage1_pixels=1 stage1_writes=3 stage1_outputs=3 stage_done=1 abort=1 abort_response_delay=3 group0=0100050300000005 group1=0000010208020002 group2=0300000000010200 boundary=SCALED_STAGE0_COMPLETE_PLUS_STAGE1_FIRST_PIXEL_BANK_HANDOFF
```

将同一命令的宏再加上 `-D C1_STAGE1_FULL`，得到完整 stage-1 2×2 门：

```text
C1_R1_STAGE1_FULL_8X8_PASS frame=8x8 stages=22 operands=24 results=44 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage_done=2 abort=1 abort_response_delay=3 first_group=0100050300000005 last_group=0001010003030000 boundary=SCALED_STAGE0_COMPLETE_PLUS_STAGE1_FULL_2X2_HANDOFF
```

### Vivado/xsim（脱离式 worker）

前台只创建 WMI/Breakaway worker，仿真工作树放在一次性 `case1/sim` 子目录，
结束时删除；长期只保留紧凑的 status、stdout/stderr：

```powershell
& .\scripts\run_r1_stage1_handoff_xsim_detached.ps1 `
  -RunId stage1_handoff_metadata_final_20260829
```

该 run `stage1_handoff_metadata_final_20260829` 在 2026-08-29 通过，worker elapsed
约 9.2 s，`xvlog/xelab/xsim` 的
stderr 均为空，marker 与上面一致，仿真 runRoot 已清理，未留下 Vivado/xsim
进程或波形文件。

完整 stage-1 运行使用同一个 detached worker，只需增加开关：

```powershell
& .\scripts\run_r1_stage1_handoff_xsim_detached.ps1 `
  -RunId stage1_full_metadata_final_20260829 -FullStage1
```

`stage1_full_metadata_final_20260829` 同样通过，elapsed 约 9.2 s，stderr 为空，
私有 runRoot 自动删除。

## 证据边界与下一步

本门覆盖的是 8×8 缩放拓扑的 stage-0 全写回和 stage-1（默认首像素或完整 2×2）
交接；它不证明 stage 2–21、native 640×480 长帧、共享七客户端 DDR QoS、AXI
burst/multi-outstanding、100 MHz 时序或 15 fps。stage-2 完整 2×2 的后续门已
单独记录在 `STAGE2_HANDOFF_PREFLIGHT.md`；再往后应沿同一 production-bank 结构
验证 stage 3 的首像素/整层，并最终再决定是否启动完整 22-stage
production-bank 回归。任何 native 长帧都应继续使用有界计数/超时和自动清理的
detached runner。
