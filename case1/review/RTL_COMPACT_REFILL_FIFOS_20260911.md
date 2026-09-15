# Burst 补给队列容量收紧

日期：2026-09-11。目标是减少可选 burst 补给路径的存储需求，保留数值、周期
和取消契约；不是增加一个未经测量的 ready 组合捷径。

## 结构依据

`c1_cache_refill_scheduler` 为每个已接受、尚未响应的逻辑请求保留 metadata。
当前 SoC 的 burst client 使用 `SCHED_MAX_OUTSTANDING=16`。后端默认请求
FIFO 为 32 项、逻辑响应 FIFO 为 128 项。请求队列中的地址和响应队列中的
结果，是调度器未完成逻辑请求的不同子集，队列深度明显大于当前调度窗口。

本轮在实际 SoC testbench 逐拍检查：

```text
req_used + rsp_used <= meta_used <= 16
```

并记录三个占用峰值。beat 模式下响应记录数不大于所代表的逻辑响应数。
该关系是结构分析加本次动态断言证据，不是形式验证或所有错误排列的证明。

这也解释了为什么没有直接启用既有 `ALLOW_REQ/RSP_POP_REFILL`：它们针对
队列满时的同拍取出/补入，而本负载的请求/响应队列峰值只有 1/2；新增
ready 组合路径没有相应收益证据。

## 生产接线与配置

- `c1_r1_portable_soc` 末尾追加 `TENSOR_BURST_REQ_FIFO_DEPTH=32`，向真实
  burst client 透传请求深度。默认不变，端口不变，不影响旧位置参数顺序。
- 响应深度使用原有 `TENSOR_BURST_RSP_FIFO_DEPTH` 参数。
- runner 新增 `-CompactRefillFifos`：要求 numerical burst refill，设置请求
  16 项、逻辑响应 16 项，禁止与 beat 模式组合。
- beat 模式原有 `RSP_FIFO_DEPTH >= BURST_BEATS * MAX_OUTSTANDING` 检查
  保留，没有因为本次结构分析就删除通用 reader 的安全限制。

有效逻辑数组容量（不含指针/计数器、描述符、缓存行和未选中数组）：

| 队列 | 原配置 | 紧凑配置 | 减少位数 |
|---|---:|---:|---:|
| 请求地址，32 bit/项 | 32 项 | 16 项 | 512 |
| 逻辑响应，64-bit 数据＋1-bit error | 128 项 | 16 项 | 7,280 |
| 合计 | 9,344 bit | 1,552 bit | **7,792 bit** |

这是逻辑数组位数，不是已实现 FPGA BRAM/LE 节省；块 RAM 粒度和综合映射
可能改变实际收益。没有改为仅够当前小图峰值的 2 项，而保留调度窗口 16 项。

## 验证

- 正常真实双采集/CNN：`review_compact_refill_normal_20260911`。
  计算周期 **73,448**，与上一轮 32/128 burst 配置完全相同；AW/W/B 为
  864/912/864，peak=2、W-ahead=33。36 个检查器反例全部拒绝。
- 真实 client-6 四拍读在途取消：`review_compact_refill_cancel_20260911`。
  64 周期不提前退休/重启，排空后无复位恢复；恢复计算周期 **73,440**，
  与先前非紧凑取消配置一致；AW/W/B=938/1006/938。30 个检查器反例全部拒绝。
- 两次均有实际 `req_depth=16 rsp_depth=16 beat_mode=0` 证据，峰值为
  `req_peak=1 rsp_peak=2 meta_peak=16`，逐拍占用守恒检查通过。
- 两次恢复/正常交付帧的 64 输入、836 C8、64 物理 DDR 输出和 120/64 显示
  像素均逐项匹配 golden，不只检查性能计数。
- 新增 `--require-compact-refill`：要求实际配置和非零占用证据，拒绝缺失、
  重复、超界、错误深度或未被执行的配置。旧无容量记录的日志仍兼容。
- 完整队列 SoC 131 源文件 Icarus 编译通过，0 errors、608 diagnostics。
  日志精简内存测试通过；最新生产接线的全量 Icarus **141 配置通过**。

两次 xsim 临时目录均已清理，仅保留合计 **112390 bytes** 精简日志，约
109.8 KiB。继续使用脱离 Codex Windows Job 的隐藏 worker，不生成波形。

## 复现

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -RunId <unique-id> -TrainedArtifact -NumericalTrace -ColorFixture -SourceGeometry -QueuedWriteFabric -ConcurrentCapture -RegisterFatalTicket -TensorBurstRefill -CompactRefillFifos
# 读取消/恢复另加 -InflightReadAbort。
& <python> case1/golden/check_portable_soc_numerical_trace.py <run-log-dir> --require-video --require-queued-write --require-compact-refill
& <python> case1/golden/test_portable_soc_numerical_trace.py <run-log-dir>
```

默认生产配置仍为 32/128；只有明确选用候选才收紧。尚未增加原生长流、
Efinity 资源/时序或 15 fps 结论；第三预览缓冲集成也未完成。
