# 缺失 EOF 的整机等待与恢复验证

日期：2026-09-11。

本轮扩充真实 portable SoC DDR BFM，新增 `-RawMissingEof`，必须与
`-RawRasterFault` 及其原有前置参数配合。第一帧进入 CNN 后，第二帧保留
正确坐标但不发送 EOF；中途暂停保证故障前捕获和 CNN 两个实际 writer
均已存在提交的 AXI 写事务。随后恢复 RAW 输入，让末尾 token 被 guard
判为缺失 EOF，真实控制器自动报告 0x45 并取消，不发软件 abort 代替故障。

## 验证条件

- 冻结 B 响应 64 个 core 周期，保留完整输入区域有效位与基地址快照，
  禁止新的捕获/计算启动，忙期间 START 被拒绝。
- 放开 B，等待所有已提交写事务响应完成、capture writer 不再 busy。
- 此时仍不提供新 SOF/EOF，继续等待 64 个 core 周期：系统 busy、capture
  cleanup 和物理占用必须保留，不能将总线排空误当成帧边界恢复。
- 送入一完整维护帧提供 SOF/EOF 边界；它不是新接纳的捕获任务。
- 系统退出清理后，无 reset 重新启动第三次正式捕获，执行 CNN 和显示，
  使用 Python integer golden 检查结果。

日志验证器新增 `--require-missing-eof-recovery`，强制边界等待与最终恢复
记录唯一、内容正确且顺序正确，并继续要求 RAW 错误、多 writer 排空、
queued write、视频和数值验证。新增 5 个负测试（缺失等待、缺失恢复、
倒序、重复等待、总线未排空），连同原 8 个 RAW 负测试均通过。

## 运行

在原 detached xsim RAW 故障命令末尾增加 `-RawMissingEof`。本次使用
`-RegisterFatalTicket`，运行名 `raw_missing_eof_20260911`。通过 WMI 启动，
不绑定当前会话 Windows Job；仿真工作目录由既有 runner 自动清理。
运行 complete、退出码 0，耗时约 90.0 秒。Python golden 通过：64 CNN 输入、
22 阶段/836 C8 结果、64 DDR 像素、120 原图及 64 风格显示像素。故障排空
AW=B=20；最终 AW=B=874、W beats=924、峰值 outstanding=2。错误一次，
capture starts=3，成功 DONE=1。已确认本次临时工作目录不存在。

## 边界

这是“完整像素数但缺少终止标记，随后传感器恢复”的场景，不是永久停止
或帧中途停止的超时解决方案。未新增超时机制、未更改生产 RTL、未默认开启
CHECK_RAW_RASTER。没有覆盖持续坏帧、B 错误与 EOF 错误叠加、原有显示帧
仍在使用时的故障、长帧实时性能或实际 PHY。维护帧被主动丢弃符合关闭
接纳期间的契约，不应将该帧计算为额外一次 capture start。
