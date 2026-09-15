# 补给调度窗口 16/32：接线、性能边界与排空验证

## 生产修改

`c1_r1_portable_soc` 末尾新增 `TENSOR_BURST_SCHED_MAX_OUTSTANDING=16`，
沿 burst client → exact shell → exact composition → scheduler/reader composition
透传至真实 scheduler 的 `MAX_OUTSTANDING`。默认不变，原位置参数顺序不变。
请求 FIFO、响应 FIFO、物理 read burst 长度、reader outstanding 均不随之自动改变。

runner 新增 `-WideRefillWindow`，设置逻辑调度窗口 32，要求 numerical burst
refill，并与 CompactRefillFifos 互斥，以隔离窗口与容量变化。生产参数本身
仍独立，互斥是当前实验入口的限制，不是已经证明两种选项不兼容。

## 小图 A/B 结论：没有收益证据

真实彩色 12×10→8×8、两次采集与第一帧 CNN 重叠、ticket/队列写/W-ahead
均开启，FIFO 保持 32/128。32 窗口正常运行：

- `review_wide_refill_normal_20260911`，90.026 s，complete/exit=0。
- 计算 **73,448 cycles**，AR/R=754/2024，AW/W/B=864/912/864。
- 全部性能分桶与此前 16 窗口同负载结果一致；没有计算周期或事务量改善。
- 请求/响应队列峰值 1/2，metadata 峰值仍 **16**；不能声称此负载已使用
  32 个并发逻辑请求。参数链静态核验通过，不是漏接参数导致的假对照。
- 64 输入、22 stage/836 C8、64 DDR 输出、120/64 显示像素均通过 golden。
  检查器 37 个变异反例全部拒绝。

读在途取消运行 `review_wide_refill_cancel_20260911`（93.032 s）亦通过：
实际 client-6 四拍读待 R 时取消，64 周期保持栅栏，排空后无复位恢复。
恢复计算 **73,440 cycles**，与 16 窗口相同；完整 golden 和 31 个反例通过。
它同样没有达到 metadata>16，不冒称是 32 请求在途取消的整机证据。

因此不默认扩大窗口，不宣称加速，也不据此断言原生长行一定没有收益。
增加调度 metadata 会有存储及选择逻辑成本，本轮没有综合/时序结果。

## 实际超过 16 请求的独立排空门

为避免只检查参数数值，参数化旧的 `tb_c1_cache_refill_scheduler_read_client_exact`，
声明 40 个连续 64-bit words，地址跨 4 KiB；在物理 AXI 服务关闭时先接受完整
窗口，再 flush。随后释放 AXI 和下游，逐字检查已接受前缀的真实排空、未发出
后缀的零/错误合成、顺序/坐标/epoch/最后一字及全部退休。

最终 detached xsim 结果：

| 运行 | 已接受/真实排空 | 未发出/合成后缀 | 总 word | AR/R beats |
|---|---:|---:|---:|---:|
| `review_window16_drain3_20260911` | 16 | 24 | 40 | 3 / 8 |
| `review_window32_drain3_20260911` | 32 | 8 | 40 | 5 / 16 |

两者均 flush 完成、quiescent、无遗留请求，所有 poison word 检查通过。
这是 scheduler→reader→completion adapter 的独立组合，不包含实际 CNN/cache
及共享 fabric。真实传输前缀数量不同，不能用两次耗时或 AR 数直接比较性能。

恢复旧测试时的失败与处理均保留记录：

1. Icarus 报 BFM 拼接内算术位宽不定，改为明确 32-bit 尺寸转换，不改数据值。
2. 该独立组合在 Icarus 30 秒运行门超时；未确认具体调度原因，转现有 detached
   xsim runner，未将该测试纳入 Icarus 全量 PASS。原全量 141 配置仍通过。
3. 首轮 xelab 的 `参数=值` 被 Windows bat 拆开，现将每个赋值作为带引号参数。
4. 第二轮已正确得到 16/32 前缀与 24/8 后缀，但旧 testbench 仍要求正常 flush
   产生 sticky protocol_error。当前 exact wrapper 默认
   `CANCEL_IS_PROTOCOL_ERROR=0`，因此改为要求 protocol_error=0，同时继续
   要求 sticky 的 `done_error_seen=1` 和每个输出的 error=1，没有删除数据错误检查。

## 验证工具与文件

golden 新增独立窗口记录解析；有窗口标志时必须有容量证据，容量峰值按实际
窗口校验，不再硬编码 16。旧日志仍按历史默认 16 解释。非法/重复窗口、缺失
容量、超界峰值等反例已加入检查。runner 检查真实 32 窗口标志。
Icarus 编译失败时先输出最多 8 条实质错误，避免只显示最后一批综合警告。

最新生产接线的全量 Icarus **141 配置通过**；完整队列 SoC 的 131 源文件编译
0 errors、608 diagnostics。日志精简内存测试通过。

本轮 8 个 xsim 临时工程全部清理，包含 4 个失败记录在内的精简日志合计
**133822 bytes**，约 130.7 KiB。所有 xsim 均脱离 Codex Windows Job，不生成波形。

```powershell
# 整机正常/取消：在既有 numerical burst/queued/concurrent 参数上加
# -WideRefillWindow，取消另加 -InflightReadAbort。
& case1/scripts/run_cache_refill_scheduler_read_client_exact_xsim_detached.ps1 -RunId <unique-id> -SchedulerWindow 32 -WordCount 40
# 16 窗口对照只改 SchedulerWindow。该 runner 用 WMI 启动独立隐藏进程。
```

后续仍需足以使用 >16 逻辑请求的正常长行/原生负载性能对照。第三预览缓冲、
原生连续 CNN、15 fps 和完整 Efinity 资源/时序仍未完成；本轮不缩小这些目标。
