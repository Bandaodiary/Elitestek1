# 真实 portable SoC RAW 故障、共享写排空与数值恢复

日期：2026-09-11。

## 本轮推进

此前分别验证了真实 capture subsystem/AXI writer，以及带叶端忙信号模型的
真实控制器。本轮在已有 `tb_c1_r1_portable_soc_cache_ddr_bfm.sv` 中连接验证
完整 portable SoC：真实摄像头 RAW 输入、异步 FIFO、guard、ISP、捕获 writer、
控制器、帧管理、CNN、共享 AXI fabric、DDR 行存储模型和显示预取。

新增 runner 开关 `-RawRasterFault`，复用已有 concurrent capture/inflight write
测试流程。该模式要求 `-InflightWriteAbort -TrainedArtifact -NumericalTrace`，
间接保留其 SourceGeometry/QueuedWriteFabric/ConcurrentCapture 前置约束。
仅在测试配置中启用 `CHECK_RAW_RASTER=1` 与 pausable camera 契约。
生产 RTL 默认参数未修改。

## 故障场景

第一帧进入 CNN 计算后，第二帧输入有效前缀，在传感器帧中部暂停。等待捕获
与计算两个真实 writer 都有在途写事务，并冻结 DDR B 响应；确认至少两笔
AW 已接受且 W 数据已完成后，恢复摄像头输入，并将指定 token 的 x=0 改为 x=1。
这不是强制内部 error/busy 信号，也不是发软件 abort 代替 RAW 错误。

真实 guard 检测错误，控制器报告 0x45 后自行取消。测试继续保持 B 响应
64 个 core 周期，检查：

- system_busy/fabric_write_busy 保持，B 数量不变化；
- 全部 input_region_valid_q 和 input_region_base_q 与故障前快照完全相同；
- cancel hold 有效，不出现新捕获、计算启动或 manager grant；
- 稳定后的 AW 数不再增加；忙期间再次 START 被拒绝。

放开 B 后，要求全部 AW/W/B 退休、系统退出 busy、错误只报告一次且不发布
失败任务的 DONE。随后无 reset 启动第三次捕获，完成真实 CNN、DDR 写回和显示。

## 数值证据

寄存 fatal ticket 路径运行 `raw_raster_soc_v2_20260911` 已完成，退出码 0：

- 故障点 pending=2，B 冻结 64 周期；取消排空时 AW=B=20。
- 最终 captures=3、errors=1、done=1、reset=0。
- 最终 AW=B=874、W beats=924，峰值 outstanding=2，W 提前接受 beat 数=3。
- Python golden 核对 12×10 原图下采样至 8×8 的 64 个 CNN 输入。
- 全部 22 阶段、836 个 C8 结果、64 个物理 DDR 像素正确。
- 显示原图 120 像素、风格图 64 像素均通过 golden。

直接 fatal 路径 `raw_raster_soc_direct_20260911` 同样完成、退出码 0，且通过
同一 Python golden（同样 AW=B=874、W=924、22 阶段/836 结果/64 DDR 像素、
120+64 显示像素）。寄存/直接路径运行耗时分别约 90.0/86.9 秒。
三次运行（含首轮监视器终止）的临时仿真工作目录均已确认不存在。

首轮 `raw_raster_soc_20260911` 在预期错误出现时，被旧的“任何控制器 fatal
均失败”监视器终止。监视器现仅在指定 RAW 注入已释放、尚无错误报告、
capture code=0x05、fatal code=0x45/address=0 时允许这一预期错误，其他错误
仍立即失败。这是测试场景兼容修正，不是生产 RTL 故障修复。

## 可复用验证入口

使用已有 WMI detached runner，Vivado 不绑定当前 Codex Windows Job：

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 `
  -RunId <唯一运行名> -NumericalTrace -TrainedArtifact -TensorBurstRefill `
  -RegisterFatalTicket -SourceGeometry -QueuedWriteFabric -ConcurrentCapture `
  -InflightWriteAbort -RawRasterFault
```

省略 `-RegisterFatalTicket` 复测直接路径。待 status.json 为 complete 后，运行
`check_portable_soc_numerical_trace.py <运行日志目录> --require-raw-fault-recovery`。
新 golden gate 强制错误/排空/恢复记录唯一且顺序正确，pending≥2、AW=B，
并强制视频和 queued write 数值证据。8 个无落盘负测试覆盖缺失、重复、仅一个
writer、未退休、pending 不匹配、顺序错误、没有错误、使用 reset，均被拒绝。

## 保留的边界

这是小尺寸、灰度仿射图、单次中途坐标错误、正常 B 响应的整机证明，不等于
所有故障组合已覆盖。缺失 EOF、连续坏帧、永久停流、显示已有旧帧时的错误、
错误 B 与 RAW 错误叠加、长帧及实际时钟/DDR PHY 仍需验证。
CHECK_RAW_RASTER 继续默认关闭；本轮没有新的综合资源、时序或 15 fps 结论。
仿真工作目录自动清理，仅保留紧凑文本证据；本轮未重跑全量 Icarus。
