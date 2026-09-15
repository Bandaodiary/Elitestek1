# 静默排空缺失 EOF 后的 SOF 恢复

日期：2026-09-11。

## 问题和修复

维护模式 discard_idle 丢弃未进入 ISP 的帧时，原 ST_DRAIN_RAW 只认 EOF。
如果该帧截断，维护结束后即使下一帧完整到达，也会被当作旧帧尾部全部丢弃。
中断前新增测试明确复现 `maintenance missing EOF consumed next clean frame`。

在 `CHECK_RAW_RASTER=1` 时，新增 silent_drain_seen_q，记录本次静默排空
已经消费过数据。若后续 FIFO 头为 SOF 且 x=y=0，则停止弹出该 token，
经 ST_RECOVER 结束旧帧清理。首个被主动丢弃帧的 SOF 不会触发提前退出。
已进入 ISP 的取消排空仍由现有 guard/flush 机制处理，不走这一静默分支。

该边界同时在 abort_frame 保持期间识别；ST_RECOVER 保持至 abort 释放，
不会吞掉已保留的首 token。如果 discard_idle 仍保持，回到 IDLE 后会按
维护契约主动丢弃下一整帧，而不是把“保留边界”误当成强制启动。
默认 CHECK_RAW_RASTER=0 的行为不变。

## 测试

6×7 RAW 图像先输入 20-token 前缀并截断，不发送 EOF。
两种摄像头半周期 3/7 ns，各覆盖三种情形，共 6 个新增配置：

- 维护结束：保留下一完整帧 SOF，显式启动后验证 20 个 RGB 及帧标记。
- abort 持续：下一 SOF 到达后继续保持 12 个 core 周期，确认 cleanup 保持、
  FIFO 不弹出 SOF；释放 abort 后恢复正常输出。
- 维护持续：下一完整帧应按请求全部丢弃；停止维护后第三帧正常处理。

所有恢复均不 reset、不重写 ISP/Gamma，检查静默维护没有误报完成、丢帧或
abort 计数。恢复工作后重新运行全量 Icarus **535 配置通过**，退出码 0；
相对最近确认的 529 配置新增 6 配置。命令：
`case1/scripts/run_iverilog_review_fixes.ps1 -Python <含 NumPy 的本地 Python>`。

## 边界

这不是永久停流超时机制：没有后续 EOF 或 SOF 时仍保持清理状态。
该测试针对真实前端、异步 FIFO、ISP，不包括共享 DDR 和 SoC 自动维护控制。
本轮未重跑 Vivado/Efinity，也不增加任何板级时序、资源或吞吐结论。
上次回归在会话中断后句柄丢失且无存活 Icarus 进程，最终结果不可验证；
恢复工作后重新执行当前版本回归，不将中断运行计为通过。

清理检查：结束后无存活 vvp/iverilog。TEMP 仍有较早的一个 c1_review 编译
镜像（451501 字节）及一个向量目录（13 文件、414965 字节），合计 866466
字节，疑为中断运行残留；本轮未将其冒称为已经清理，也未扩大删除范围。
