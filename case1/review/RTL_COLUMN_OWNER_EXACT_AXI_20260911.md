# 列事务所有者与 exact AXI 补行链路验证

日期：2026-09-11。

## 发现并修复的 RTL 问题

`c1_column_transaction_owner.sv` 原先以 `m_rsp_error || maintenance` 形成旁路响应错误位和数据清零条件。如果后端成功响应刚刚呈现、尚未进入私有保持寄存器，此时上游提出维护，已可见的成功响应会被组合改写为零/错误。

真实 exact AXI 组合在取消 phase=3（保持成功响应）复现错误；首次独立握手模型只覆盖了响应已锁存之后的取消，因此未发现该边界。

修复后，后端接纳请求就拥有其取消语义：它负责返回成功或者取消错误，控制层不得再用自己的维护状态改写响应。控制层仍对未下发的本地拒绝返回零/错误，仍延迟下游维护直到请求被接纳，仍联合 ACK 和上游响应退休。新增独立测试在旁路响应出现后、下一采样边沿前直接改变维护输入，验证响应不变。

另修正组合测试的责任边界：有响应保持寄存器后，后端可以先排空并使配置失效，上游响应仍由所有者持有。因此不能要求后端 `config_valid` 一直有效；改为要求所有者持续 busy、非 quiescent、禁止配置且不得向上游报告维护完成。原 AXI 债务、数据/错误一致性及最终排空检查保留。

## 连接与验证

在 `tb_c1_column_cache_exact_axi.sv` 增加默认关闭的 OWNER 配置，连接生产所有者、生产列缓存、exact-count completion、scheduler 和 AXI128 reader；只有 AXI memory 为行为模型。

运行器 `run_window_line_cache_c8_exact_burst_shell_xsim_detached.ps1` 增加 `-ColumnOwner`，必须配合 `-ColumnCache`。运行器检查唯一 owner 配置标记及全部 12 个取消场景、2 个 RRESP 错误恢复标记，避免误跑默认配置仍记成功。

最终 xsim 成功运行（均状态 complete、退出码 0）：

| RunId | 配置 | 成功列/补行/声明字数 | AXI AR/beat |
| --- | --- | --- | --- |
| owner_exact_word_20260911_c | owner=1, word FIFO, skid=2 | 34/68/2244 | 307/1039 |
| owner_exact_beat_20260911_final | owner=1, beat FIFO, skid=3 | 34/68/2244 | 307/1037 |
| owner_exact_direct_20260911_final | owner=0, word FIFO, skid=2 | 34/68/2244 | 307/1037 |

计数范围以 testbench 原有统计定义为准，不能把包含取消流量的 AXI 差异当作吞吐提升。前两次探索运行 a/b 均失败，分别暴露测试所有权假设和上述 RTL 错误，不计为成功。

这三个成功运行的临时目录均已检查不存在。所有 xsim 均通过现有 WMI 隐藏 worker 脱离 Codex Windows job 启动；仅保留小型状态/摘要日志。没有综合或实现运行。

最终修复后的独立所有者测试 1 配置通过；`tb_c1_adapter_column_cache` 全部 11 个配置重跑通过，含两种复用设置的真实缓存请求阻塞/取消/重启。两项 Icarus 命令均退出码 0，合计 12 个定向配置；不计为完整套件验证。

## 剩余边界

- 这次完成真实只读 AXI 组合验证，但还没有把连接封装接入生产 SoC。
- adapter＋所有者＋列缓存回归与所有者＋列缓存＋AXI 回归仍是两个组合，不等价于整个链路的单次端到端验证。
- 新 OWNER 模式本轮没有验证 epoch 耗尽组合，不把旧模式的耗尽结论自动扩大到新组合。
- 没有完整套件、整机训练模型数值、15 fps 或 Efinity 物理资源的新结论。

## 后续：epoch 耗尽及受控恢复

新增 OWNER 模式的耗尽组合验证通过，关闭上节关于该组合未经验证的缺口。随后扩展 `epoch_exhaust_case`，不再仅以终止错误作为结束条件：

1. 2-bit epoch 饱和于 3，不允许回绕。三次错误列请求共排空 99 个声明字，不新增 AXI 请求，配置重写不能清除保护。
2. 复位前检查所有者 quiescent、无待返回列、AXI 队列为空且无活动 burst。
3. 同时复位所有者、缓存、exact reader 等整个测试事务域三个时钟周期；确认 epoch=0、配置无效、缓存及补行协议错误清除。
4. 改变行为内存数据代次、重新配置并读取完整三行列，独立期望值核验正确，并确认发起新的 AXI 读取、无残留债务。

最终三个运行均 complete/exit 0，且同时包含耗尽与恢复两个唯一标记：

- `owner_epoch_word_20260911_recovery`：OWNER=1，word FIFO，skid=2。
- `owner_epoch_beat_20260911_recovery`：OWNER=1，beat FIFO，skid=2。
- `owner_epoch_direct_20260911_recovery`：OWNER=0，word FIFO，skid=2，兼容性对照。

新增标记为 `C1_COLUMN_AXI_EPOCH_RECOVERY_PASS drained_reset=1 fresh_axi=1 golden_column=1`，运行器将其设为耗尽测试的必需证据。前两次 `_a` 运行只验证耗尽，不计入最终恢复覆盖。本次改动为 testbench 和运行器补强，无新增生产 RTL 电路。

该证据仅支持**排空后的整域复位恢复**，不支持带未完成 AXI 债务的热复位，也不等于生产 SoC 已有自动复位控制器或软件恢复流程。默认 8-bit epoch 的长期运行维护频率与恢复策略仍需在系统集成时明确。
