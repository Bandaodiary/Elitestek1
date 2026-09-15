# 独立原图几何贯通显示布局层

## 本次实现

`c1_r1_display_subsystem.sv` 追加默认关闭的 `SEPARATE_ORIGINAL_GEOMETRY` 参数及原图宽高输入。原图几何在接受 START 时锁存，经两级寄存器传入像素域，并连接上一阶段的独立几何 prefetch pair。

四种显示模式不改变原有布局：处理图单显、原图单显、左右分屏及默认黑屏。原图和处理图分别按各自宽高限制读取和黑色补边。未显示的一侧仍须排空，所以隐藏原图的 drain window 也改用原图尺寸；处理图继续使用处理图尺寸。否则原图更高/更宽时，隐藏侧可能永久占有行缓存。

`c1_r1_portable_soc.sv` 将控制器新增的 `display_original_width/height` 接入显示层，并为该实例启用独立几何。控制配置/采集/boardless 的完整 SoC 工作模式仍为同尺寸；这里是恢复元数据完整传递，不是放宽 SoC 的输入尺寸准入。

## 验证范围

扩展 `tb_c1_display_geometry.sv`：

- 原图 12×4、4×12、12×1，处理图均为 8×8，各覆盖四种显示模式；
- 分别核对每一路所有请求的有效性、源坐标及数量，隐藏画面同样必须完整消费；
- 对同步响应、黑色补边和时序对齐进行检查；START 后修改软件输入，验证原图和处理图快照均保持；
- 保留原有同尺寸 8×8、640×480，以及小容量 STORE_WIDTH=8 测试。

三种配置全部通过：异尺寸配置 261,120 次采样，旧普通配置 174,080 次，小容量配置 87,040 次。此测试强制 raster 和行缓存响应，是布局边界测试，不能独立证明真实 DDR/CDC 全链路。上一阶段真实双 DMA/双时钟缓存异尺寸测试仍保留在默认回归中。

全量 Icarus 回归完成，`C1_REVIEW_FIXES_REGRESSION_PASS configurations=122`（包含预期失败检查）。补充请求坐标断言后，三种布局配置再次全部通过。

完整 SoC 接线改变后，执行安全脱离 Windows Job 的 xsim：

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -RunId review_display_geometry_wiring_20260910 -TrainedArtifact -Frame8x8 -NumericalTrace -ColorFixture
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe case1/golden/check_portable_soc_numerical_trace.py case1/logs/portable_soc_cache_ddr_bfm_runs/review_display_geometry_wiring_20260910 --require-video
```

运行终态 complete，58.004 秒。Python 核对彩色 RGGB 源的 64 个输入、真实 CNN 的 22 stage / 836 个 C8 结果、64 个最终 DDR 像素，以及原图/处理图各 64 个显示响应像素，全部通过。该测试保持原有同尺寸 8×8，是整机兼容性证据，不是整机异尺寸证明。临时 xsim 目录已确认删除，仅保留精简日志。

完整 Icarus SoC 编译/展开通过，128 源文件、0 errors、602 条工具诊断。本次未进行综合或布局布线，没有新增性能、资源、板级 CDC 或 15 fps 结论。

## 仍未完成的能力

每侧依旧是固定 640×480 显示区域。两幅图可分别更小并补黑，但超出区域的尺寸继续由 prefetch 拒绝，避免悄悄裁剪导致未消费行/列挂住整个任务。支持大分辨率原图需要明确的缩放预览数据路径或完整消费方案，不能仅解除容量校验。

下一步仍须贯通控制器/软件 CSR 的独立输入尺寸、采集尺寸与 Resize 参数，并完成真正异尺寸的 SoC CNN/DDR/显示验证。本文件不替代这些任务。
