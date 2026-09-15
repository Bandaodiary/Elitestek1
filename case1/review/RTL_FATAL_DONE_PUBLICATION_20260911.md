# 致命错误与完成同拍：成功发布栅栏

## 问题与复现

上一轮修复了软件 ABORT 与 DONE 同拍的错误成功通知。本轮继续检查
`REGISTER_FATAL_TICKET=1` 时的一个时钟周期分类/广播间隔。

原实现中，`fatal_now` 已经为真，但 `manager_abort` 尚未到达；如果此时
`boardless_done=1`，控制器仍设置 `done_event`、`manager_nn_done` 和
`pending_pair_valid_q`。下一拍取消虽会清理帧状态，已经发给软件的成功通知
却无法收回。寄存故障广播应延迟取消路径，不能延迟“结果是否成功”的判断。

在 `tb_c1_r1_soc_control.sv` 加入参数错误与显示错误两类同拍碰撞测试后：

- 旧 RTL 的 direct 模式通过。
- 旧 RTL 的 ticket 模式在参数错误场景失败：
  `fatal and DONE collision published success kind=0 ticket=1`。

这些是控制器接口定向驱动，不是整机物理 DDR 故障注入。

## 生产修改

仅修改 `rtl/top/c1_r1_soc_control.sv`：

- 软件完成条件改为 `boardless_done && !manager_abort && !fatal_now`。
- NN 完成与待显示帧发布同样受 `!fatal_now` 限制；该时序块原本已有
  `manager_abort` 的外层优先清理分支。

取消广播、错误码/地址捕获及报告时序保持不变；未改变模块接口或默认参数。
新增组合依赖只用于成功发布条件，没有将 raw fatal 广播到所有子系统。
未进行新的综合或时序测量，因此不声称物理时序开销为零。

## 验证契约

每类错误在首次采样沿要求 DONE、NN 完成、pending pair 均不发布；错误脉冲
撤销后的四拍继续检查无延迟成功，错误仅报告一次，分别为 `0x23` 和 `0x70`。
同尺寸/异尺寸与 direct/ticket 四配置定向测试已通过，既有正常完成测试保留。

完整 SoC 的正常彩色 12×10→8×8 双采集重叠负载已复测通过，用于排除正常
数值/显示路径回归，不等于在整机中再次注入同拍错误：

- detached xsim：`review_fatal_done_ticket_20260911`，77.755 s，complete/exit=0。
- 64 个输入、22 stage/836 C8、64 DDR 输出、120/64 显示像素均逐项符合 golden。
- AW=864/W=912/B=864，全部退休；peak=2、W-ahead=32、计算期间采集 AW=10。
- 检查器 28 个变异反例全部拒绝；使用已修复的精简日志函数，重复证据不再被去重。
- 队列模式完整 SoC 的 131 源文件 Icarus 编译通过：0 errors、608 diagnostics，
  非“零警告”；精简日志函数的内存内测试亦通过。
- 本轮 xsim 临时目录已不存在，只保留 56292 bytes 精简日志；仍使用脱离 Codex
  Windows Job 的隐藏 worker，不生成波形。

最新生产 RTL 的全量 Icarus 回归完成：**141 个配置全部通过**。

## 未覆盖范围

不把这两类控制器碰撞推广为所有故障排列的穷尽证明；有在途事务时的 AXI
协议硬故障、第三预览缓冲接入、原生完整 CNN 和 15 fps 仍未完成。
