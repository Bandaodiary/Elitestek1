# 彩色双帧端到端验证

日期：2026-09-11。

## 检查发现与改进

原双成功帧用例采用灰度图，R/G/B 相等，不能证明真实 SoC 链路的颜色通道顺序。生产代码检查涉及 preview fork、preview DMA、runtime join 与顶层预览地址布局；本轮未发现新的确定性生产 RTL 缺陷，没有为增加修改量而改动生产逻辑。

新增彩色双成功帧验证：使用 RGGB Bayer 源，各通道分别在同一线性 RAW10 平面增加 96、40、0。第二帧再整体增加 tone=32。两帧不复位，源图有效尺寸 12×10，显式相位 Resize 为 8×8，使用真实训练参数运行 22 层 CNN。这样可以区分旧帧重放、RGB/BGR 接反和 C8/XRGB 字节布局错误。

## 修改

- `case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1`：允许 ColorFixture 与 TwoFrameTrace 组合，保留双成功帧模式的其它约束。
- `case1/sim/tb_c1_r1_portable_soc_cache_ddr_bfm.sv`：新增唯一彩色模式标记，复用已有真实 RGGB camera 源。
- `case1/golden/check_portable_soc_two_frame_trace.py`：从独立三通道源图计算 Resize 和整数 CNN；增加 `--require-color`；拒绝错误、重复及迟到模式标记；增加两帧 CNN 输入、预览 DDR、预览显示各自 R/B 互换反例。

本轮未修改生产 RTL。灰度日志不能满足 `--require-color`，已单独验证拒绝行为。

## 验证结果

运行 ID：`review_two_frame_color_preview_20260911`。

| 项目 | 实测结果 |
| --- | --- |
| xsim | complete / exit 0，322.218 秒墙钟耗时 |
| CNN 输入 | 两帧共 128 个，与独立源图匹配 |
| C8 层结果 | 两帧共 1672 个，与整数 golden 匹配 |
| 处理图/预览物理 DDR | 各 128 像素匹配 |
| 预览/风格图显示读回 | 各 128 像素匹配；OSD 前合成器对齐通过 |
| 每帧预览写退休 | 8 AW / 16 W / 8 B，完成前退休 |
| 日志反例 | 53 项全部拒绝，其中 6 项独立 R/B 互换 |
| 灰度预览双帧旧检查 | golden 通过，44 项反例通过 |
| 灰度原图双帧旧检查 | golden 通过，32 项反例通过 |
| Icarus 定向预览 DMA | 2 配置通过 |
| Icarus 全量回归 | 本轮重跑 186 配置全部通过 |

## 复现

从项目根目录执行，替换为未使用的 RunId：

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 `
  -RunId <new-run-id> -TwoFrame -TwoFrameTrace -TrainedArtifact `
  -TensorBurstRefill -RegisterFatalTicket -SourceGeometry `
  -QueuedWriteFabric -PreviewCapture -PreviewDisplay -ColorFixture
```

状态达到 complete / exit 0 后：

```powershell
python case1/golden/check_portable_soc_two_frame_trace.py `
  case1/logs/portable_soc_cache_ddr_bfm_runs/<new-run-id> `
  --require-video --require-preview --require-color --self-test
```

Python 需要 NumPy。全量回归命令为 `case1/scripts/run_iverilog_review_fixes.ps1 -Python <python-path>`。

## 产物与结论边界

xsim 使用已有 WMI 脱离 Windows Job 的启动方式，无波形；确认本次临时仿真目录不存在，仅保留 `case1/logs/portable_soc_cache_ddr_bfm_runs/review_two_frame_color_preview_20260911` 下 7 个文本文件，共 114636 字节。Icarus 使用已有 finally 清理逻辑。

本用例验证的是线性彩色平面和 8×8 输出，不是任意纹理、原生分辨率或所有运行参数的穷尽证明。墙钟仿真时间不是硬件帧率。原生分辨率 15 fps、已有成功画面时的整机故障保留、Efinity 物理时序与板卡链路验证仍未完成。
