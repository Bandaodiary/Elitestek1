# 请求交接与 exact 取消补齐的组合验证

日期：2026-09-11。本轮仅增强验证与 runner；未修改生产 RTL，未重新执行
全量 Icarus、综合或整机数值测试，不把上一轮结果冒作本轮新增结果。

## 发现与改进

原 `tb_c1_cache_refill_scheduler_read_client_exact.sv` 只验证真实排空数据的
低 32-bit 地址，高 32-bit 的上下 lane 标签损坏可能漏检；普通 `!=` 比较
对 X/Z 的检测也不充分。现改为完整 64-bit 预期值与 `!==` 比较，并对
row/index/epoch/error/last、合成零值后缀同样使用未知值敏感检查。

新增 `REQ_HANDOFF` 参数并传到真实 exact wrapper，新增内部实际交接次数
检查：启用且信用大于 1 必须真正交接；单信用或关闭时不得交接。
独立 detached runner 增加 `-RequestHandoff`，默认关闭、原默认窗口不变。

## 四组 xsim 结果

均为真实 scheduler → AXI read client → completion adapter 组合：先停止
AXI 服务，填满逻辑信用窗口，输出端保持不接收时发出 flush，随后释放
AXI 和输出。检查旧 epoch 真实前缀携带 error 排空，未发起后缀合成
zero/error，合计严格等于命令长度；最终全部退休、quiescent、epoch=1。
正常取消不应被当作结构协议故障，因此 protocol_error 必须保持为零。

| Run ID | 窗口/交接开关 | 输出=排空+合成 | 实际交接 | AR/R beats | cycles |
|---|---|---|---:|---|---:|
| `review_exact_handoff1_20260911` | 1 / 开 | 5=1+4 | 0 | 1/1 | 23 |
| `review_exact_handoff3_20260911` | 3 / 开 | 7=3+4 | 2 | 2/2 | 27 |
| `review_exact_handoff32_20260911` | 32 / 开 | 40=32+8 | 31 | 5/16 | 89 |
| `review_exact_full64_default_20260911` | 2 / 关 | 5=2+3 | 0 | 1/1 | 25 |

四组状态均 complete/exit=0，完整数据/元数据检查通过。窗口 3 覆盖
非二次幂信用指针；窗口 32 实际发生 31 次交接，不是只验证参数可编译。
不同窗口的已接受前缀不同，上述 cycles 不能作为公平性能对比。

## 复现与结论边界

```powershell
& case1/scripts/run_cache_refill_scheduler_read_client_exact_xsim_detached.ps1 -RunId <unique-id> -SchedulerWindow 32 -WordCount 40 -RequestHandoff
```

四组均由 WMI 独立隐藏 worker 启动，脱离 Codex Windows Job；逐个核验
status 中记录的临时目录均不存在，没有波形或大型临时工程残留。
精简证据位于 `case1/logs/xsim_runs/cache_refill_scheduler_read_client_exact/`
各 Run ID 子目录。

本轮证明的是指定负载下交接与 flush 的 exact-count 组合契约，并非所有
任意时刻取消的形式证明；整机无复位读取消恢复见上一轮
[请求交接记录](RTL_REFILL_REQUEST_HANDOFF_20260911.md)。没有新增生产缺陷
证据，所以未为“修复”而改写已通过的生产逻辑。实际大图吞吐、完整物理
实现、第三预览缓冲的整机接线仍未完成，整体目标保持开放。
