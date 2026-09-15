# exact-burst 下层重复维护请求验证

本轮不修改生产 RTL，扩展 `tb_c1_window_line_cache_c8_exact_burst_shell.sv`
及其 detached runner，检查直接转发请求的下层接口，而非上层保持请求的
汇合接口。

## 验证场景

真实缓存产生待接纳 AR/已接受逻辑读取后，关闭 AR 服务，发出第一个维护
脉冲。保持 12 周期并逐周期检查父层 pending、未完成；再发第二个脉冲，
随后允许 AXI 排空。检查取消数据的实际接收/丢弃/合成补齐计数、单次维护
完成、重试像素内容及最终 quiescent。

默认运行 flush；新增 `-RepeatAbort` 验证相同停顿场景下的 abort。
runner 强制检查对应模式唯一的 `C1_EXACT_SHELL_REPEATED_MAINTENANCE_PASS`，
避免仅靠通用 PASS 判断模式覆盖。

## 重要契约差异

flush 保留配置，可直接重试等待中的 tap；abort 使 `config_valid` 失效，
调用方必须重新启动 group 配置。初次 abort 测试沿用了 flush 的直接重试
假设，出现超时；源代码确认这是测试契约错误，不应改变 RTL 以迎合测试。
修正后检查 abort 后 12 周期无配置、无 tap 接纳/新增输出，再重新配置，
验证重试数据正确。

最终两项 detached xsim 均 complete、退出码 0，约 10.26 秒：

- `exact_repeat_abort_final_20260911`。
- `exact_repeat_flush_final_20260911`。

每项两次请求合并为一次完成，实际数据及取消计数校验通过。包含前期实验
在内的六个临时仿真目录均已确认清理。未重跑全量（最近 597）或 Efinity。

## 尚未证明的范围

本轮证明的是第二次请求在 AR 停顿且维护未完成期间到达；尚未覆盖两子层
确认到达不同步时的所有相位、完成同周期新请求、abort/flush 混合请求。
不得将本测试解释为全层级任意重复时序证明。普通非 burst cache seam 的
单独维护状态机仍需按其自身契约审查。
