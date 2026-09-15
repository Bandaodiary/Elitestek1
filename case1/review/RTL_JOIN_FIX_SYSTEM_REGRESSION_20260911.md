# 确认汇合修复后的系统回归

本轮冻结生产 RTL，验证上一轮
`c1_window_line_cache_c8_exact_burst_shell.sv` 的新请求/旧子确认优先级修复。
不把修改前的通过结果当作本版本证据。

## 整机结果

`apb_recovery_join_regression_20260911`：WMI detached xsim 完成，退出码 0，
约 122.21 秒。随后执行 Python checker，要求同时满足
`--require-apb-recovery --require-late-source-ack`，全部通过：

- 只有 APB 发起恢复，硬件恢复请求为低；可读取诊断码 0x46，忙时重复命令
  被拒绝，完成状态可读取并清除。
- 两个在途写事务 B 阻塞 64 周期，DDR 排空后继续等待源确认 32 周期；
  此时维持物理占用，不以 AXI 空闲替代源停止确认。
- 无全局 reset 恢复新任务，64 个 CNN 输入、22 阶段、836 C8 结果、64 个
  DDR 像素和 120+64 显示像素符合整数 golden。
- AW=B=874，W=924，在途峰值 2。

本次临时整机目录已确认不存在，保留精简证据。37 个恢复日志负测试也已
重跑通过。该整机用例仍是小帧灰阶斜坡、寄存 fatal ticket、排队写和 burst
refill 的有限组合，不是所有模型/配置或板级验证。

## 全量 Icarus

`run_iverilog_review_fixes.ps1` 完整运行 **597 配置通过，退出码 0**。
包括预期失败且要求精确诊断的测试，不能解释为 597 项板级功能验证。
本轮生产源未改，因此全量和整机 golden 对应同一个当前 RTL 版本。
默认不生成波形，脚本 finally 清理本次唯一临时编译文件及生成向量。

## 后续边界

普通 `c1_tensor_window_cache_seam` 的维护由 `MAINT_IDLE/WAIT_ABORT/
WAIT_FLUSH` 串行状态机调度，且等前端、逻辑/下游所有者及 refill 排空后
才发子请求；不能机械应用 exact shell 的双子确认汇合补丁。该路径需另行
验证请求/完成同周期及混合请求。本轮不新增性能或资源达标声明，未跑
Efinity 或板卡测试。
