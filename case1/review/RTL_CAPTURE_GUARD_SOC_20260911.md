# 加入捕获启动保护后的真实 SoC 彩色双帧复验

日期：2026-09-11。

## 目的

此前地址保护的拒绝、取消、发布与 VSYNC 竞争测试以控制器及行为客户端为主。本轮重新运行真实 portable SoC 数据链路，确认新增捕获预检等待不会破坏正常 camera 握手、CNN、DDR 写回和显示。生产 RTL、BFM 与 golden 本轮没有新增修改。

## 配置与证据

运行 ID：`capture_guard_soc_color_20260911`。启用 TwoFrame / TwoFrameTrace / TrainedArtifact / TensorBurstRefill / RegisterFatalTicket / SourceGeometry / QueuedWriteFabric / PreviewCapture / PreviewDisplay / ColorFixture。

真实 RGGB 彩色源有效尺寸 12×10，显式相位 Resize 到 8×8，第二帧 tone 增加 32；不复位连续完成两个任务，真实 22 层训练参数，两个预览/输出槽切换。

| 项目 | 结果 |
| --- | --- |
| xsim | complete / exit 0，228.563 秒墙钟耗时 |
| CNN 输入 | 两帧共 128 个，独立源图 golden 匹配 |
| C8 层结果 | 两帧共 1672 个，整数 golden 匹配 |
| 处理图 / 预览物理 DDR | 各 128 像素匹配 |
| 预览 / 风格图显示读回 | 各 128 像素匹配，OSD 前合成器对齐通过 |
| 每帧预览退休 | 8 AW / 16 W / 8 B |
| shared queued writer | AW/B 各 1724，W 1796，max outstanding=2，W-ahead=16 beats |
| 检查器反例 | 53 项全部拒绝，包括旧帧与 R/B 互换 |

## 复现

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 `
  -RunId <new-id> -TwoFrame -TwoFrameTrace -TrainedArtifact `
  -TensorBurstRefill -RegisterFatalTicket -SourceGeometry `
  -QueuedWriteFabric -PreviewCapture -PreviewDisplay -ColorFixture
python case1/golden/check_portable_soc_two_frame_trace.py `
  case1/logs/portable_soc_cache_ddr_bfm_runs/<new-id> `
  --require-video --require-preview --require-color --self-test
```

Python 检查须在状态 complete / exit 0 后执行，并需要 NumPy。

## 产物

WMI detached 启动，脱离 Codex Windows Job，不生成波形。已确认 `case1/sim/portable_soc_cache_ddr_bfm_run_capture_guard_soc_color_20260911` 不存在，仅保留日志目录中的 7 个文本文件，合计 114615 字节。

## 本轮架构检查所得

持续占用不能直接复用控制器 capture_writer 配置输出，因为取消会清零这些控制状态，而 writer 内部快照仍可驱动排空。也不能简单在 DMA busy=0 时释放区域：READY_NN 与 READY_DISPLAY 仍持有有效帧数据。已据此整理 [区域生命周期契约](RTL_REGION_LIFETIME_CONTRACT_20260911.md)，明确真实申请入口、短暂申请仲裁、所有权转移、取消排空和释放条件。

该契约尚未实现。本轮只证明正常合法地址布局下的真实小帧链路没有因新增启动保护产生回归；不是全局地址隔离、原生分辨率 15 fps、所有故障场景或物理板卡验证。仿真墙钟时间也不是 FPGA 帧率或优化收益。本轮没有重跑全量 Icarus；最近一次全量为上一轮 229 配置通过。
