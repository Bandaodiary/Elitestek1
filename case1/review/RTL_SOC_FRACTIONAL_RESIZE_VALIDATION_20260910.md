# 整机非单位 Resize 数值验证

## 测试配置

安全 xsim runner 新增 `-ResizeFixture`，要求 `-NumericalTrace`（其进一步限制为单帧 8×8 真实训练 artifact）。该开关通过 worker 参数与编译宏传递，沿用脱离 Windows Job 和临时工程自动清理机制，不改变生产 RTL。

testbench 在 START 之前通过真实 APB 配置：

- x_step=-1.25，x_phase0=7.5，采样 x 从 7.5 下降至 -1.25，覆盖左右边界裁剪；
- y_step=0.75，y_phase0=-0.25，覆盖上边界、分数插值和行复用；
- 输入输出仍均为 8×8，源图为既有彩色 RGGB → ISP 采集结果。

这是有意选择的反向/分数映射压力测试，不是等比例缩小图像；负横向步长已由现有两行 Resize 支持。该配置也会先产出所需输出、再排空未采样的源尾部，覆盖此前尾部完成时序修复。

原有忙时写影子参数测试保留，但活动快照检查改用本次配置常量。影子随后恢复单位参数，不影响已经接受的任务。默认无开关仍显式写单位映射，用于兼容性复测。

## 独立参考与检查器改进

`check_portable_soc_numerical_trace.py` 先独立构造 ISP 后的原始 RGB，再调用既有标量整数 `explicit_phase_rgb` 建立 Resize 参考（Q0.12 权重，横向两行分别舍入后再纵向舍入）。逐像素检查 CNN 输入后，对真实训练网络全部 22 层、最终物理 DDR 提交和两路显示响应核对。

关键区分：原图显示应匹配 **Resize 前的采集 RGB**，而非 CNN 输入。此前单位映射下二者一致，本轮拆分了这两个参考。处理图显示继续匹配最终网络输出。

新日志使用唯一 `C1_NUM_RESIZE reverse_fractional` 标记；未知或重复标记拒绝，旧无标记日志按单位映射解释。检查器反例新增缺失/未知/重复 Resize 标记，以及用 Resize 后首像素替换原图显示首像素，确保两种图像不能混淆。反例只在内存中修改日志，不落地伪造证据。

本轮只改仿真与检查工具，没有修改生产 RTL；不是新的资源、时序或吞吐签核。独立源尺寸 CSR、真实异尺寸采集和大图预览仍待贯通。

## 实测结果

`review_resize_fractional_20260910` xsim complete，83.241 秒。golden 核对通过：64 个 CNN 输入、22 stage / 836 个 C8 输出、64 个最终 DDR 像素和原图/处理图各 64 显示像素。检查器 19 个反例全部拒绝，包括新增四个 Resize/原图区分反例。

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -RunId review_resize_fractional_20260910 -TrainedArtifact -Frame8x8 -NumericalTrace -ColorFixture -ResizeFixture
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe case1/golden/test_portable_soc_numerical_trace.py case1/logs/portable_soc_cache_ddr_bfm_runs/review_resize_fractional_20260910
```

旧 `review_resize_csr_snapshot_20260910` 日志也通过新版检查器的基线与原有 15 个反例检查。未重跑全量 Icarus，上一阶段 123 配置的结论保持为历史证据。

当前 testbench 的单位映射兼容性复测 `review_resize_unit_compat_20260910` complete，79.246 秒，同样通过 CNN/DDR/两路显示 golden（`--require-video`）。两次运行的临时目录均已删除，仅保留精简日志合计 107,781 bytes，无波形。
