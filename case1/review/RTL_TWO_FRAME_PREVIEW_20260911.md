# 双成功帧 Resize 预览验证

日期：2026-09-11

## 结论

真实 portable SoC 在不复位的两次成功任务中，已验证第八 AXI 客户端的预览写回、双槽配对、写响应退休以及预览/风格图显示读回。生产 RTL 本轮没有新增修改；本轮完善 testbench、运行参数约束和独立数值检查器，验证已有修复后的链路。

## 覆盖范围

- 两幅不同灰度 RAW10 图像，第二幅 tone 增加 32；有效源图 12×10，经显式相位 Resize 到 8×8。
- Resize 横/纵步长为 `0x18000` / `0x14000`，初相位为 `0x4000` / `0x2000`。
- 真实训练参数、22 层 CNN、tensor burst refill、寄存故障广播和 queued AXI 写仲裁。
- 预览槽依次为 `0x01000000`、`0x01000100`，stride 为 32 字节，与处理图输出槽 0、1 配对。
- 每帧预览写回检查 8 AW、16 W、8 B；完成通知前所有 B 响应已退休。检查实际内存字节写使能和写后像素，不仅比较提交给 writer 的输入。
- 显示依据实际显示帧 ID 对照 golden，并检查 OSD 前合成器与读回响应对齐。日志中的 `VIDEO_RAW` 在本模式指 Resize 预览支路，不是未缩放原图。

## 结果与证据

运行目录：`case1/logs/portable_soc_cache_ddr_bfm_runs/review_two_frame_preview_20260911`。

| 检查 | 结果 |
| --- | --- |
| xsim | complete，exit 0，251.041 秒 |
| 两帧 CNN 输入 | 128 个，与独立源图 golden 匹配 |
| 两帧 C8 层结果 | 1672 个，与整数推理 golden 匹配 |
| 处理图物理 DDR | 128 像素匹配 |
| 预览物理 DDR | 128 像素匹配 |
| 预览/风格图显示 | 分别 128 像素匹配 |
| 预览退休 | 两帧各 8 AW / 16 W / 8 B |
| shared queued writer | AW/B 各 1724，W 1796，最大 outstanding 2，W-ahead 16 beats |
| 检查器反例 | 44 项全部被拒绝 |
| 旧原图双帧显示回归 | 数值通过，32 项反例通过 |

反例覆盖缺失、重复、未知值、错误数值、旧帧像素替代、缺失预览模式或退休证据等。golden 从独立源图生成 Resize 和 CNN 结果，不使用 RTL CNN 输入作为算法参考。

## 修改文件

- `case1/sim/tb_c1_r1_portable_soc_cache_ddr_bfm.sv`：预览计数按任务重置，保留两槽物理写入证据；新增两帧预览快照、槽位及退休检查。
- `case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1`：允许受限的双成功帧 source-geometry / queued-write / preview-display 组合；拒绝与该验证语义不兼容的取消、错误注入等模式。
- `case1/golden/check_portable_soc_two_frame_trace.py`：新增显式相位 Resize golden、预览模式及逐帧退休解析、必需证据开关和反例。

## 复现

从项目根目录运行已有 detached 脚本，RunId 必须使用新的唯一值：

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 `
  -RunId <new-run-id> -TwoFrame -TwoFrameTrace -TrainedArtifact `
  -TensorBurstRefill -RegisterFatalTicket -SourceGeometry `
  -QueuedWriteFabric -PreviewCapture -PreviewDisplay
```

等待状态 complete / exit 0 后，用有 NumPy 的 Python 执行：

```powershell
python case1/golden/check_portable_soc_two_frame_trace.py `
  case1/logs/portable_soc_cache_ddr_bfm_runs/<new-run-id> `
  --require-video --require-preview --self-test
```

本次通过 WMI 脱离 Codex Windows Job 启动，无波形输出。已确认本次 `case1/sim/portable_soc_cache_ddr_bfm_run_review_two_frame_preview_20260911` 不存在；仅保留 7 个文本文件，合计 114587 字节。

## 尚未证明的事项

这是 8×8 输出规模、串行两任务、不同灰度图像的功能验证，不是原生分辨率 15 fps 的吞吐证明；本轮未重新运行全部 186 配置回归，也未做物理综合或时序签核。仍需补充已有成功显示画面时的整机故障保留验证，以及实际 Efinity DDR/MIPI/HDMI IP、跨时钟约束和板卡联调。OSD 最终像素和物理 HDMI 不在本次检查范围内。
