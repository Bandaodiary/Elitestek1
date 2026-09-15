# 双成功帧显示读回与合成器验证

日期：2026-09-11。扩展双帧数值跟踪，不修改生产 RTL。

## 新增覆盖

沿用两幅不同亮度的 8×8 灰度输入、真实 ISP/CNN、物理 DDR 模型与槽 0→1 两次成功换帧。

- 每帧分别记录原图、处理图各 64 个显示读回像素，共 256 个 RGB 像素。
- 随显示请求采样已提交显示帧号和坐标，在响应时使用该标签；不使用可能已进入下一任务的 CNN 作业号。
- 按真实响应有效信号取数，检查两路请求选择与响应经过合成器后的对齐；对比点是 OSD 之前的 `compositor_rgb`。
- 两帧各支路完整取样后才允许 `C1_NUM_TWO_VIDEO_PASS`。重复刷新不额外导出，但首个完整样本必须逐坐标通过，缺像素/跨刷新拼接导致坐标重复不能蒙混过关。
- 每个视频记录必须对应已经成功完成的帧；原有 128 输入、1672 个逐层结果、128 个 DDR 像素检查仍保留。

Python 校验器新增 `--require-video`。默认兼容历史仅 DDR 日志；一旦出现视频记录，即自动要求两帧两路完整证据。显式要求视频时，删除所有视频记录及其标记也不能退化成旧范围的 PASS。

参考原图由独立 RAW10 公式得到，处理图由独立整数 CNN 得到，不以读回数据生成期望结果。原无视频日志仍通过原数值检查与 19 项负向检查。

## 执行

独立 WMI worker：`review_two_frame_video_raster_20260911`。

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 `
  -RunId review_two_frame_video_raster_20260911 -TwoFrame -TwoFrameTrace `
  -TrainedArtifact -TensorBurstRefill -RegisterFatalTicket
```

```powershell
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' `
  case1/golden/check_portable_soc_two_frame_trace.py `
  case1/logs/portable_soc_cache_ddr_bfm_runs/review_two_frame_video_raster_20260911 `
  --require-video --self-test
```

首轮 `review_two_frame_video_20260911` 在第二次换槽后仅等待 100000 个 core 周期，报告 raw=64/0、styled=64/0，未通过。不能把此运行记为双帧视频成功。

源代码显示，`request_enable_frame_q` 仅在 pixel-domain `timing_frame_start` 更新；控制域通过 CDC 收到该边界、完成槽提交后，像素域可能已错过同一帧的开放机会。固定测试时序为 1650×750、pixel 周期 14 ns、core 周期 10 ns，一帧需要 1732500 个 core 周期。原等待不足一帧。

复验将上界设为两个完整光栅周期（3465000 core cycles），增加边界 enable/hold 与最终等待周期记录。是按明确时序契约修正测试窗口，不放宽像素数值、数量或坐标检查。

最终 `review_two_frame_video_raster_20260911` complete / exit 0，218.323 s。独立 golden 通过：128 输入、1672 个逐层 C8 结果、128 DDR 像素，以及两帧共 128 原图显示像素、128 处理图显示像素；32 项负向检查通过，包含删除全部视频证据、逐路缺失/重复、未知像素及第二帧混入旧帧像素。

实际边界记录：t=51975105000 时 frame=0、hold=1、enable_sync=0；下一光栅 t=69300105000 时 frame=1、hold=0、enable_sync=1。最终采完两路像素需额外等待 2026320 个 core 周期，小于 3465000 上界，证明是按帧边界恢复而非永久停滞。这是测试时钟下的显示调度延迟，不是目标板 15 fps 的测量。

两个运行目录完成后均检查不存在，仿真临时产物已清理；仅保留有界文本日志与状态。生产 RTL 未改，没有新增物理综合或全量 RTL 回归的结论。

## 边界

这是板无关显示读端与 OSD 前合成器的逐像素验证，不是物理 HDMI、OSD 字符像素或 FPGA IO 时序验证。本模式尚未启用 Resize 预览第八客户端，也不是原生尺寸 15 fps 的性能证明。生产 RTL 未改变，本轮不宣称新的综合或资源结果。
