# 整机永久停流与显式恢复验证

## 场景与改动

本轮不改生产 RTL，扩展真实 portable SoC DDR BFM 测试、detached 启动器及
Python 数值验证器。新增 `-ExplicitCaptureRecovery`，必须同时启用
`-RawIdleTimeout` 及其要求的在途写取消/并行捕获/训练权重/数值追踪配置。

第二次捕获在 RAW 帧中途停止，硬件 watchdog 达到 4096 周期后报告 0x46。
数据源直接终止旧帧：不补尾部、不补 EOF、不提供维护帧。此时真实捕获和
计算写事务重叠，两个已接纳的写事务 B 响应保持 64 周期不返回。测试通过
顶层 request/ready 接口请求恢复，并提供明确的停止确认。

检查项：

- B 阻塞期间保持 BUSY、输入物理区域快照和取消占用，START 返回错误。
- 即使外部源已确认停止，也不得在 B 排空前复位任一 FIFO 时钟域。
- 释放 B 后完成恢复；随后无需全局 reset 即可接纳第三次捕获。
- 恢复请求持续为高直到新任务完成，双域恢复只能完成一次。
- 对新任务的 22 阶段 CNN、836 个 C8 结果、64 个实际 DDR 像素，以及
  原图/处理图显示输出执行既有整数 golden 对比。

## 证据维护

首次运行 `explicit_recovery_soc_20260911` RTL 仿真通过，但日志裁剪遗漏
中间 `C1_SOC_EXPLICIT_RECOVERY_DRAIN_PASS`；严格 Python 检查拒绝通过。
已修复精简日志的保留规则，保留恢复标记且不去除重复项，另行重跑。
不得将首次仿真通过等同于完整 golden 证据通过。

新增 8 个显式恢复证据负测试，与原 RAW/EOF/timeout 的 17 个负测试一起
通过；不写测试夹具文件。检查缺失标记、错误顺序、重复完成、单个在途写、
未确认源停止、重复复位等无效证据。

## 最终结果

重跑 `explicit_recovery_soc_v2_20260911` 完成，耗时 92.996 秒，退出码 0。
以 `--require-explicit-recovery` 执行 Python 检查通过：源停止/一次恢复、
64 周期写阻塞、AW=B=874、W=924、在途峰值 2，22 阶段/836 C8/64 DDR
像素和 120+64 显示像素均符合整数 golden。两次运行的临时仿真工程均已
确认不存在；仅保留精简日志。运行方式为既有 WMI detached worker。

本轮生产 RTL 未改，未重跑全量 Icarus（最近 596 配置），未跑 Efinity。

复现：运行 `scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1`，
参数为 `-NumericalTrace -TrainedArtifact -TensorBurstRefill -RegisterFatalTicket
-SourceGeometry -QueuedWriteFabric -ConcurrentCapture -InflightWriteAbort
-RawRasterFault -RawIdleTimeout -ExplicitCaptureRecovery`，指定新的 RunId。
然后对相应日志目录运行 `golden/check_portable_soc_numerical_trace.py`
并传入 `--require-explicit-recovery`。

## 范围限制

测试是小帧、灰阶斜坡、寄存 fatal ticket、排队 AXI 写的整机验证，不是全
参数组合或板级证明。尚无 APB 恢复命令/摄像头停止控制的实际接线，未测试
本场景中摄像头时钟停止；后者只有既有前端/恢复模块的定向证据。当前版本
仍默认关闭显式恢复功能。无需因此替换现有 CNN 数据通路。
