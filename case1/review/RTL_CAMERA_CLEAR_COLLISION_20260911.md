# 摄像头新错误与清错同拍的优先级修复

日期：2026-09-11。

## 问题与复现

`c1_r1_capture_frontend.sv` 的 camera_overflow 原先先判断
`camera_rst || camera_clear_error`，再判断 camera_overflow_event。
因此清错同拍发生的新错误会被覆盖。

对 free-running sample strobe，FIFO 满时每个样本都会产生丢样事件；连续
事件通常会在下一拍重新置位，但同拍清除仍造成短暂错误消失。对 pausable
ready/valid 源，阻塞期间 payload 改变可能只产生一拍事件，因为比较基准
随后更新；若恰好遇到清错，该错误可以永久漏报。

新增 BACKPRESSURE_CASE=5 复现了后一种情况：先填满 FIFO，合法保持源，
再将 RAW payload 从 0x123 改为 0x124，同时断言 camera_clear_error。
修复前定向运行失败：`fresh camera fault lost to simultaneous clear case=5`，
参数 CAMERA_HALF=3；没有依赖超时或间接状态推测。

## RTL 修复

优先级调整为：

1. camera_rst 清除；
2. camera_overflow_event 置位；
3. camera_clear_error 清除旧错误；
4. 其他周期保持。

清错只能清除旧错误，不能吞掉同拍新错误。复位行为不变；保持协议监视器
本身不变，跨时钟清错 CDC 和 core 域去重语义也没有改变。

## 新增验证

BACKPRESSURE_CASE=5 检查 pausable 源的一次 payload 错误；case=6 检查
free-running 源的丢样事件。各用 CAMERA_HALF=3/7，共 **4 配置通过**：

- 同拍新错误必须置位 camera_overflow。
- 经同步后，core 端必须报告 capture_error / code 0x01。
- 停止新错误，之后的清错必须成功，不能因改成错误优先而无法清除旧状态。
- 随后按现有契约清除 core 错误，确认两域均无残留错误；过程不使用复位。

最终全量 Icarus **529 配置通过**，退出码 0。命令：
`case1/scripts/run_iverilog_review_fixes.ps1 -Python <本地含 NumPy 的 Python>`。
相对最近全量 521 配置，包含上一轮未全量复测的控制器 4 配置，以及本轮
清错碰撞 4 配置。未启用波形，脚本自动清理临时镜像和生成向量。

## 边界

这是 sticky level 的语义修复，不是精确错误事件计数器。若 core 已经处理过
某个高电平，而该电平因不断出现的新错误持续不降，本轮不承诺逐次重新报告。
持续无法接收的 free-running 源在清错时保持错误是预期行为，不能通过清错
掩盖仍在发生的数据丢失。

本轮未改 RAW 重同步和 AXI 取消状态机，未运行 Vivado/Efinity 或板测；此前
完整 SoC 的 RAW 错误 xsim 结果不能冒称为本轮修改后重新运行的结果。
