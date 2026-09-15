# 重复 flush/abort 定向验证

本轮不修改生产 RTL，补齐上轮对称 flush 修正的验证，并刷新统一回归。

## 测试加强

`tb_c1_tensor_window_cache_burst_axi_client.sv` 在本地写响应被背压期间，
分别发出两个 abort 或两个 flush，间隔至少 40 周期。第二次请求前明确
断言父层仍 pending、子缓存确认已经收到，防止测试未进入真正故障窗口。
响应释放后必须只完成一次，且最终 quiescent。

默认配置和 `PackedWrites + BeatFifo` 配置均通过 detached xsim：

- `repeated_flush_default_v3_20260911`，11.244 秒，退出码 0。
- `repeated_flush_packed_v3_20260911`，11.245 秒，退出码 0。

每项均出现 flush=0 与 flush=1 的 `C1_TENSOR_CACHE_REPEATED_MAINTENANCE_PASS`，
验证两个请求合并为一个完成。

首轮测试取完成计数基准时，前一个 task 的完成尚未被计数器采入，导致
基准错误。修复测试采样时序后 v2 通过；v3 再增加上述父/子状态断言并通过。
该问题属于 testbench，不是新增硬件故障。六次运行的临时目录均已确认
不存在，保留精简状态/日志。

## 全量结果

统一 Icarus 回归 **597 配置通过，退出码 0**，包含 APB 恢复事件优先级
和 SoC 竞争检查，生产代码包含此前缓存重复取消修复。597 中含要求精确
诊断及非零退出的预期失败测试，不代表 597 个板级场景。缓存专用 xsim
测试独立于该列表，不能计入其配置数；本轮未跑 Efinity。

## 下层审查边界

`c1_window_line_cache_c8_exact_burst_shell` 直接把 abort/flush 输入连接
给两个子层；上轮修复的 burst client 则用 pending 把子请求保持为高。
两者并非相同握手契约，不能仅凭相似的 seen 寄存器清零代码直接套补丁。
普通 `c1_tensor_window_cache_seam` 又使用单独维护状态机和脉冲请求。
本轮仅完成这部分结构核对，尚未证明所有层级/任意重复时序都正确，不宣称
已完成全层级取消审计。下一步应为下层独立接口补针对性重复请求测试。
