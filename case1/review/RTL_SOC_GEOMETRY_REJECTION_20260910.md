# 整机几何错误拒绝与无复位恢复

## 新增验证

安全 xsim runner 增加 `-RejectGeometry`，要求 `-SourceGeometry`，排除 DisplayFaultRecovery；因此测试总是使用真实 12×10 源/8×8 目标、trained CNN 和完整数值 trace。

在任何摄像头帧发送之前，通过真实 APB 逐次写入并 START 六种配置：

1. 源尺寸整字为零，继承目标 8×8，与固定采集输出 12×10 不符；
2. 源高度非零、宽度零；
3. 源宽度非零、高度零；
4. 源宽度不匹配；
5. 源高度不匹配；
6. 源尺寸正确，但纵向步长为负。

每个案例要求：恰好一次错误事件，CSR 错误码 0x12，STATUS 回到非 busy 且置 error；64 拍观察窗口内不允许 AXI AR/AW/W VALID、参数加载启动、采集 writer 启动、boardless 启动或 done。另检查 AXI 接受计数不增加。通过 IRQ_STATUS W1C 清除错误并核对，不复位系统。

完成六例后，用正确源尺寸和中心对齐 Resize 配置运行真实摄像头→CNN→DDR→显示任务。错误计数与显式预期累计值比较，不清零或覆盖历史错误；后续任何额外错误仍使测试失败。

分别运行直接故障广播和 `REGISTER_FATAL_TICKET=1`，覆盖此前寄存故障通知可能让参数加载先启动的风险。未修改生产 RTL。

## 测试监视器适配

首次两个运行在第一例被旧全局 monitor 终止：它将预期配置错误当作任意计算故障。随后仅在负例活动窗口、fatal_code=0x12 且 fatal_address=DESC_BASE 时允许该控制错误。CNN 和 boardless 计算错误仍无条件失败；错误次数、CSR、无外部请求与恢复检查均保留。该修订不是全局关闭故障监测。

## 边界

最终两个运行 complete（81.209 秒、81.054 秒），均包含 `C1_NUM_GEOMETRY_REJECT_PASS cases=6 no_axi=1 no_reset=1`。随后 12×10→8×8 的 64 CNN 输入、22 stage/836 C8 输出、64 DDR 像素、120 原图显示和 64 处理图显示像素全部通过 Python `--require-video` 核对。因此证明负例后的真实任务恢复，而非仅回到 idle。

四次尝试（包含最初 monitor 适配前的失败）均已清理临时 xsim 工程，仅保留精简日志，无波形。未改生产 RTL、未重跑全量 Icarus或综合；上一阶段 123 配置仍是历史证据。

负例期间没有送摄像头数据，故本测试不声称验证相机正在输入时的非法配置/丢帧时序，也不测试已接受 DDR burst 中途取消。该类协议场景由已有回归覆盖或需另外增加。此处重点是整机 APB 配置准入和无需硬复位的恢复。

复现：

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -RunId review_geometry_reject_direct2_20260910 -TrainedArtifact -Frame8x8 -NumericalTrace -ColorFixture -SourceGeometry -RejectGeometry
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -RunId review_geometry_reject_ticket2_20260910 -TrainedArtifact -Frame8x8 -NumericalTrace -ColorFixture -SourceGeometry -RejectGeometry -RegisterFatalTicket
```
