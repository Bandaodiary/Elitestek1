# 活动任务期间清统计的生命周期修复

日期：2026-09-11。生产修改限于 `c1_axi_shared_qos_monitor`，不改变计算、帧槽或 AXI 事务。

## 问题与复现

原 `rst || clear_stats` 分支同时清空历史计数和 `frame_active`。软件在活动任务中发出 clear-stats 后，该任务的正常 done 就变成“没有对应 start”的孤立终止，完整时长也丢失。

先添加真实时钟推进的定向测试，原代码失败：

```text
FATAL: clear_stats lost active frame ownership or elapsed time
```

## 新契约

- 复位仍清空所有状态。
- clear-stats 清零历史统计，不取消已接受的任务。活动帧继续计时，清零边沿也计入完整时长。
- clear 与 start 同拍：历史清零，同时开始跟踪新帧。
- clear 与 done 同拍：历史清零优先，本拍终止样本不计入清零后的统计，但正确关闭生命周期。下一次合法 start 不被误报重入。
- clear 与 abort 同拍：取消优先，活动计时清零；即便同时出现 start，也不启动新计时。
- 活动帧已经回绕或恰在 clear 边沿回绕：保留本帧回绕证据及对应 overflow 提示，后续不会漏判期限。其他历史诊断按 clear 清零。

实现复用原寄存器，仅在统计清零分支中保留必要的活动生命周期转换。没有新增端口或 CSR；运行时 clear 不再等价于 monitor 的全局 reset。需要清除活动计时的集成应使用已有 `frame_abort`，不是反复清统计。

## 验证

新增定向断言覆盖：活动帧连续两拍 clear、完整时长、clear/start、clear/done、后续合法启动、65535→0 回绕与 clear 同拍、clear/abort/start 优先级。未 force 内部计数器。原回绕与取消测试继续通过。

133 源文件 queued-write 顶层 Icarus 编译通过，0 errors / 608 工具诊断。全量 **186 配置通过**，退出码 0，最终标记 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=186`。本次唯一 VVP 与向量目录已由脚本清理，完成后检查均不存在。本轮未启动 Vivado/Efinity，不宣称物理时序或资源改善。

## 仍需推进

当前问题属于测量可靠性；修复不增加 CNN 吞吐。完整 SoC 两个不同成功帧的像素级 golden、已有画面故障恢复、原生尺寸吞吐与板级资源/时序仍未闭合。
