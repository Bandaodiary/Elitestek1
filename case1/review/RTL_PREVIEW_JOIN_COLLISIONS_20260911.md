# 计算/预览联合完成的同拍冲突验证

日期：2026-09-11。本轮检查 `c1_r1_runtime_join` 的终止优先级，扩展验证，
未改生产 RTL。

## 被验证的真实组合

沿用 `tb_c1_r1_preview_job_join.sv`：真实 job controller、runtime join、
preview DMA、fork 和 XRGB writer；计算完成/错误与无关预检客户端仍为
行为模型，不是完整 CNN SoC。真实 AXI writer 接收 B 错误并产生预览错误。

原有七任务覆盖两参与者准入、两种完成顺序、等待 B 时 watchdog、软件取消、
预览错误、计算错误和无复位重启；本轮增加以下三任务。

| 碰撞 | 实际同时观察的条件 | 要求 |
|---|---|---|
| 计算 DONE + 预览错误 | compute_done=1、preview_error=1 | 不出 engine_done，上报 0x63/0x1000 |
| 双方首次错误 | compute_error=1、preview_error=1 | 不出 engine_done，按左侧优先上报 0x91/0xABC0 |
| 取消 + 计算最终 DONE | cancel=1、compute_done=1、双方 idle，预览先前已完成 | 不出 engine_done，最终只报 aborted |

不仅检查最后的 job 结果，还在采样边沿计数对应碰撞。实测三个覆盖计数
均为 **1**。保留末端检查：终止时双方 busy 均为零、B 已退休、错误码和
地址准确、每任务只通知一次、CNN 输入和实际 XRGB 写数据正确。

## 结果

定向回归 exit=0：

`C1_PREVIEW_JOIN_COLLISION_PASS done_fault=1 both_fault=1 cancel_done=1`

`C1_PREVIEW_JOB_JOIN_PASS jobs=10 success=3 error=5 abort=2 watchdog=1 late_B=5 no_reset=1 pixels=80 ready_barrier=16`

runner 现在同时要求通用结果和专属碰撞标志，缺少实际碰撞覆盖不能过关。

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_r1_preview_job_join -Python <python.exe>
```

本轮只重新运行这一个配置，未重跑全量，也未进行 Efinity/Vivado 综合或
整机数值仿真。Icarus 临时编译文件/向量由 runner 清理，无波形。

## 结论边界

当前联合完成的上述优先级正确，没有证据要求改写生产逻辑。测试没有证明
所有异步时钟组合（模块本身要求同一时钟域），也不覆盖不同周期先后错误
的全部排列。第三路预览的 frame ownership、真实共享 DDR 接线和显示选择
仍待整机集成，不能用这个行为计算模型替代完整 CNN 运行验证。
