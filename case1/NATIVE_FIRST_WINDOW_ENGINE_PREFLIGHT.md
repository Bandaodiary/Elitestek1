# Native 640x480 首层真实算术有限窗口预检

更新时间：2026-08-29。

## 目的与边界

tb_c1_r1_native_first_window_engine_preflight.sv 在上一阶段
native_first_window_preflight 的基础上，把真实 native 640x480 descriptor、
生产 c1_r1_microstyle_tensor_adapter、c1_r1_microstyle_cnn_top 和
c1_r1_parameter_bank 串起来。参数 arena 先通过 dual-bank 的
load_start/load_valid/load_last 合同提交，确认 generation=1 后才启动
adapter/engine。源帧仍完整写入 bank-0；随后只执行 stage 0 首行的有限连续
输出像素。`WindowPixels` 当前支持 `{1,2,4,8,16}`，默认一个：

- stage 0 是 Conv3x3、stride 2、SAME_REPLICATE，输入 C3（1 个 C8 group），
  输出 C12（2 个 C8 group）；
- 每个输出像素检查 9 个 bank-0 tap 的地址/数据、adapter 到 engine 的窗口和
  坐标标记；总检查量按 `9×WindowPixels` 个 tap read、`WindowPixels` 个
  engine input 和 `2×WindowPixels` 个 output group 线性增加；
- 用真实参数 bank、scheduler、weight repack、8x8 dot/requant core 计算并检查
  两个输出 group 的 signed-INT8 golden；
- 检查 bank-1 中连续的 `2×WindowPixels` 个 output group word，随后发出一个完整周期的共享 abort，确认
  adapter、CNN top 和 parameter read 均回到 idle。

该 gate 不启动 stage 1-21，不代表 native 全帧逐像素 CNN、共享七客户端 QoS、
15 fps、Efinity 综合/P&R 或 Ti60 实板 signoff。仿真输入使用 centered signed-s8
确定性图案；输出 golden 为：

    group0 = 0e09000000320005
    group1 = 0000000000190006

## 复现

先用 Python/NumPy 重新生成并核对 RTL 中冻结的首行常量（默认四像素）：

    D:\miniconda\miniconda\envs\SWPC_ENV\python.exe .\case1\golden\test_native_stage0_window.py

需要覆盖 1/2/4/8/16 像素候选 gate 时，使用对应的 `--pixels` 值；例如 16 像素：

    D:\miniconda\miniconda\envs\SWPC_ENV\python.exe .\case1\golden\test_native_stage0_window.py --pixels 16

预期输出为 C1_NATIVE_STAGE0_WINDOW_GOLDEN_PASS；若替换训练工件或 signed-s8
输入图案，应先更新该检查与 TB 常量，再运行 RTL gate。

推荐 detached runner。它复制 descriptor/arena 到私有 runRoot，使用
C1_USE_PARAMETER_BANK 编译宏，关闭波形，并在 finally 删除完整 Vivado/xsim
工作树：

    powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\case1\scripts\run_r1_native_first_window_engine_preflight_xsim_detached.ps1 -RunId native_first_window_engine_default_postroi_20260828

只做 xvlog/xelab 结构门：

    powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\case1\scripts\run_r1_native_first_window_engine_preflight_xsim_detached.ps1 -RunId native_first_window_engine_elab_20260828 -CompileOnly

地址和像素索引流水化 A/B：

    powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\case1\scripts\run_r1_native_first_window_engine_preflight_xsim_detached.ps1 -RunId native_first_window_engine_pipe_full_20260828 -PipelinedAddress -PipelinedPixelIndex

有限四像素首行 gate（真实 parameter bank；同时打开两个地址流水寄存器）：

    powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\case1\scripts\run_r1_native_first_window_engine_preflight_xsim_detached.ps1 -RunId native_first_window_engine_roi4_full_20260828 -WindowPixels 4 -PipelinedAddress -PipelinedPixelIndex

## 本阶段扩展结果

`WindowPixels=8` 和 `WindowPixels=16` 已在同一 detached runner 中完成真实
parameter-bank + adapter + CNN-top gate（均为 `-PipelinedAddress
-PipelinedPixelIndex`）。8 像素覆盖 72 个 tap read、8 个 engine input 和
16 个 output group；16 像素覆盖 144/16/32，并在 x=0..15 的连续首行地址上逐项
比较两组 golden。两次均在 worker 结束时自动删除 xsim runRoot：

    C1_R1_NATIVE_FIRST_WINDOW_ENGINE_PREFLIGHT_PASS frame=640x480 stages=22 pipeline=1 pixel_pipeline=1 window_pixels=8 source_writes=307200 first_window_reads=72 engine_inputs=8 engine_outputs=16 output_writes=16 abort=1 group0=0e09000000320005 group1=0000000000190006 boundary=NATIVE_SOURCE_INGEST_PLUS_REAL_STAGE0_ARITHMETIC_ONLY
    C1_R1_NATIVE_FIRST_WINDOW_ENGINE_PREFLIGHT_PASS frame=640x480 stages=22 pipeline=1 pixel_pipeline=1 window_pixels=16 source_writes=307200 first_window_reads=144 engine_inputs=16 engine_outputs=32 output_writes=32 abort=1 group0=0e09000000320005 group1=0000000000190006 boundary=NATIVE_SOURCE_INGEST_PLUS_REAL_STAGE0_ARITHMETIC_ONLY

Icarus 14.0 的 Python golden guard 现已逐档通过 `WindowPixels=1/2/4/8/16`；
其中 16 像素 RTL 配置的 marker 计数与 xsim 相同。该扩展仍只
覆盖 stage 0；不能替代 stage 1–21、native 全网、burst/multi-outstanding、
15 fps 或 Ti60 实板验证。

## 结果

Icarus 14.0（真实 c1_r1_parameter_bank）和 detached Vivado/xsim 默认配置、
流水化 A/B 均通过。默认 post-ROI marker（WindowPixels=1）为：

    C1_R1_NATIVE_FIRST_WINDOW_ENGINE_PREFLIGHT_PASS frame=640x480 stages=22 pipeline=0 pixel_pipeline=0 window_pixels=1 source_writes=307200 first_window_reads=9 engine_inputs=1 engine_outputs=2 output_writes=2 abort=1 group0=0e09000000320005 group1=0000000000190006 boundary=NATIVE_SOURCE_INGEST_PLUS_REAL_STAGE0_ARITHMETIC_ONLY

四像素 detached xsim marker（native_first_window_engine_roi4_full_20260828）为：

    C1_R1_NATIVE_FIRST_WINDOW_ENGINE_PREFLIGHT_PASS frame=640x480 stages=22 pipeline=1 pixel_pipeline=1 window_pixels=4 source_writes=307200 first_window_reads=36 engine_inputs=4 engine_outputs=8 output_writes=8 abort=1 group0=0e09000000320005 group1=0000000000190006 boundary=NATIVE_SOURCE_INGEST_PLUS_REAL_STAGE0_ARITHMETIC_ONLY

四像素 gate 还逐项比较了 x=1..3 的 stage-0 两个 group golden，而 marker 中的
group0/group1 保留为首像素摘要。流水化 A/B 只改变 pipeline=1 和
pixel_pipeline=1，其余计数和 golden 保持一致。这证明真实参数 bank/engine 与
adapter 在连续首行像素上的地址、窗口、ready/valid/abort 合同兼容；不能从该
有限 gate 推出频率或吞吐提升。

四像素逐项常量（每行是一个 64-bit C8 group，低字节对应低通道）为：

    x=0  group0=0e09000000320005  group1=0000000000190006
    x=1  group0=19000000003a000f  group1=0000000000110000
    x=2  group0=250000070041001b  group1=0000000001070200
    x=3  group0=36000028003f0015  group1=000000001a001a00

本次 worker 仅保留 compact stdout/stderr/status，小于长帧波形规模；runRoot
自动清理，结束后无 vivado/xsim/xelab/xvlog 残留进程。
