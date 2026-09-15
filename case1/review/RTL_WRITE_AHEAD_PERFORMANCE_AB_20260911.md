# 真实采集/CNN 并发负载下的写数据调度对照

日期：2026-09-11。本轮不改生产 RTL 或默认参数，补齐性能选择所需的同负载证据。

## 1. 固定条件

彩色 RAW10、12×10 ISP 输出、8×8 Resize/训练参数 22-stage CNN。
第一帧计算期间实际采集第二帧，第一帧显示交付后通过 APB 停止连续任务。
真实共享 fabric 深度 4，AW bypass 开启，fatal ticket 开启；DDR BFM 的 B 延迟
均为 32..34 core cycles，AW/W/AR/R 的既有间歇背压保持不变。

第一组 A/B 唯一功能差异是 `FABRIC_WRITE_W_AHEAD_OF_B`。
新 runner 开关 `-SerializeWriteData` 仅用于这个串行 W 对照，仍允许多个 AW
排队；它不是切回整个旧串行 fabric。该开关要求 ConcurrentCapture，并禁止
组合 InflightWriteAbort，后者要求前一笔 B 退休前已有两笔 W 完成。

新增 `C1_NUM_WRITE_MODE ahead/serial`。SV 和 golden 都检查模式对应的 W-ahead
计数；模式非法、重复、与计数不一致均拒绝。旧日志无模式标志时沿用此前规则。

## 2. 写路径 A/B 实测

| 指标 | W 等待前笔 B | W 可提前发送 |
|---|---:|---:|
| 计算作业 core cycles | 87,876 | 87,565 |
| bridge busy | 86,898 | 86,587 |
| feed（实际接受 operand） | 896 | 896 |
| input_wait（ready=1、valid=0） | 48,039 | 47,707 |
| engine_hold（valid=1、ready=0） | 12,294 | 12,317 |
| neither（valid=0、ready=0） | 25,669 | 25,667 |
| 逻辑 tensor 读/写请求 | 3,620 / 836 | 3,620 / 836 |
| 物理 AW/W/B | 864 / 912 / 864 | 864 / 912 / 864 |
| outstanding 峰值 | 2 | 2 |
| W-ahead beats | 0 | 32 |
| 计算期间采集 AW | 10 | 10 |
| 显示 swap 时间戳 | 1,732,508 | 1,732,508 |
| 新显示预取完成时间戳 | 2,030,510 | 2,030,510 |

计算周期减少 **311（约 0.354%）**，显示交付时刻不变。W-ahead 确实生效，
也没有改变工作量，但不是本例的主要加速来源。不能把峰值 outstanding=2 或
W-ahead=32 本身当成显著吞吐收益。

上述握手桶是 adapter/engine 边界观测，不是 DSP 利用率计数；input_wait
不能全部归因于外部 DDR。显示受实际 raster/帧边界影响，整机 R stall 包含
显示等待，不能直接拿它当 CNN 的 DDR 阻塞周期。

两边第一帧的 64 个输入、836 C8、64 个物理 DDR 输出和 120/64 显示像素
均逐项通过 golden，全部写事务退休。ahead 的检查器反例为 31 个，serial
为 32 个，均全部拒绝；额外一个反例确保串行模式标志不能丢失后静默通过。

运行记录：

- `review_wdata_ahead_ab_20260911`
- `review_wdata_serial_ab_20260911`

## 3. 在相同负载上增加 burst 缓存补给

第三个运行 `review_wdata_ahead_burst_ab_20260911` 保持 W-ahead 开启，唯一新增
功能开关为 `-TensorBurstRefill`，使用项目已有的读侧实现，不新增生产 RTL。

| 指标 | 普通补给＋W-ahead | burst 补给＋W-ahead |
|---|---:|---:|
| 计算作业 core cycles | 87,565 | 73,448 |
| bridge busy | 86,587 | 72,469 |
| feed | 896 | 896 |
| input_wait | 47,707 | 34,783 |
| engine_hold | 12,317 | 13,077 |
| neither | 25,667 | 23,713 |
| 逻辑 tensor 读/写 | 3,620 / 836 | 3,620 / 836 |
| 物理 AXI AR/R | 1,124 / 2,228 | 754 / 2,024 |
| 物理 AW/W/B | 864 / 912 / 864 | 864 / 912 / 864 |
| 逻辑请求背压周期 | 128 | 1,916 |
| 结果接口背压周期 | 11,732 | 10,538 |

计算周期减少 **14,117（16.1217%）**，物理 AR 减少 **32.9181%**，而逻辑
工作量与写事务量不变。请求背压计数虽然增加，总周期仍明显降低，说明不能
单凭某个局部背压计数选择方案。全部 CNN/DDR/显示 golden 与 31 个检查器反例
通过；capture AW 重叠=10、peak=2、W-ahead=33，显示 swap/新预取完成时间戳
仍为 1,732,508 / 2,030,510，不宣称端到端显示帧率提升。

## 4. 后续优先级

不因 0.354% 的小图结果就默认启用队列/W-ahead，也不删除已验证的并发能力；
摄像头/CPU/预览加入后的竞争可能不同。本例已验证 burst 缓存补给比仅解耦
W/B 更值得优先推进；下一步应扩展其连续帧、取消/错误组合与原生尺寸证据，
再处理单 writer 结果提交及计算流水瓶颈，不能继续仅凭 AW outstanding 峰值
决定优化优先级。尚未将第三预览缓冲接入生产 SoC，不能用本例替代该集成。
原生 15 fps、长时间连续流、完整 Efinity 资源与时序仍不能由本实验推断。

## 5. 复现与保留文件

三次运行分别耗时 92.092、91.027、83.915 秒（主机墙钟，不是 FPGA 推理时间）。
三个 xsim 临时目录均已清理，只保留合计 169051 bytes 精简日志，约 165.1 KiB。
继续使用脱离 Codex Windows Job 的隐藏 worker，不生成波形。

```powershell
# 三次共同参数；每次用独立 RunId。
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -RunId <unique-id> -TrainedArtifact -NumericalTrace -ColorFixture -SourceGeometry -QueuedWriteFabric -ConcurrentCapture -RegisterFatalTicket
# 串行 W 对照：另加 -SerializeWriteData。
# burst 读补给对照：另加 -TensorBurstRefill，不加 SerializeWriteData。
& <python> case1/golden/check_portable_soc_numerical_trace.py <run-log-dir> --require-video --require-concurrent-capture
& <python> case1/golden/test_portable_soc_numerical_trace.py <run-log-dir>
```

本轮只改 testbench、runner 和数值检查器。旧无模式头日志的 golden 复验通过，
日志精简内存测试通过；未重跑完整 Icarus 或综合，不把上一轮 141 配置冒作本轮
新结果。生产 RTL 仍为上一轮通过全量回归的版本，默认优化开关未变。
