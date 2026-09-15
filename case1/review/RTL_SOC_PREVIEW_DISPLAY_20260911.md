# 最外层 SoC 预览显示接线与数值验证

## 静态构建选择

`c1_r1_portable_soc.DISPLAY_RESIZED_PREVIEW` 默认 0，保持原图/风格图显示。
设为 1 时，第一显示支路改为 Resize 预览，第二支路仍为风格化输出。
该开关自动令 `PREVIEW_CAPTURE_ACTIVE=1`，启用第八 AXI writer 与 boardless
联合退休；不能仅打开显示而遗漏预览生产者。两块预览区仍须显式配置，
缺省重叠地址会被已有准入保护拒绝，不会开始未分配的预览写入。

预览任务准入快照 → boardless 成功完成 → controller pending → prefetch
request → current 的路径沿用上一轮接口；本轮公开 top 选择并连接至
控制器参数。不增加新的时钟域、不绕过旧帧读排空/换帧约束、不新增 APB
寄存器。它是构建参数，不是运行时可随意切换的显示源 CSR。

## 真实 SoC 验证

新增 runner `-PreviewDisplay`，目前要求 `-PreviewCapture` 且排除取消/
故障测试开关，以便先完成正常显示证据。测试使用彩色 RAW10 12×10 输入，
Resize 至 8×8、真实训练参数的 22-stage MicroStyle、queued writes、
tensor burst refill 和 registered fatal ticket。

运行 `review_soc_preview_display_20260911`：complete / exit 0，78.958 s。

- 64 个 CNN 输入和 22 层 836 个 C8 结果通过整数 golden。
- 64 个预览 DDR 像素与 64 个风格图 DDR 像素通过独立 golden。
- 实际显示响应：64 个预览像素 + 64 个风格图像素通过；原相同 fixture
  的原图模式应显示 120 个原图像素，而本构建不是该模式。
- 共享 AXI 累计 862 AW / 898 W / 862 B，峰值 outstanding=2，W-ahead=8。
- 数值检查器 52 项负向变异通过，新增显示模式标记缺失/重复/非法值、
  预览显示错误地使用原图像素等检查。

日志沿用既有第一显示接口的 `C1_NUM_VIDEO_RAW` 名称，但新增唯一的
`C1_NUM_FIRST_DISPLAY preview` 明确其语义。Python 据此使用独立 Resize
参考图，不能默认把这些数据当作 RAW。`--require-preview-display` 要求
显式标记，并隐含要求完整视频和预览 DDR 核对，避免缺失轨迹也通过。

```powershell
& <python.exe> case1/golden/check_portable_soc_numerical_trace.py `
  case1/logs/portable_soc_cache_ddr_bfm_runs/review_soc_preview_display_20260911 `
  --require-preview-display --require-video --require-queued-write
```

## 结构检查与边界

10 组 SoC smoke/协议错误配置通过，包括不显式打开 capture、仅打开
preview display 的合法/非法分区两组；验证生产者自动开启和既有分区保护。
133 个源文件的默认 queued-write SoC 编译通过，0 errors / 608 工具诊断。
全量 Icarus 162 配置通过；旧原图显示模式的取消恢复日志仍通过 58 项
负向检查，验证器保持兼容。xsim 在 Windows Job 外运行，无波形，临时
目录已自动删除，仅保留 56,055 字节小日志。

这证明单成功帧的预览/风格图视频数据路径，不证明连续双槽、该显示模式
下错误恢复或换帧竞争，也不证明原生尺寸 15 fps、Efinity 物理实现或板卡。
后续优先补齐双槽连续完成与切换期间的帧对应关系。
