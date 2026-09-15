# 捕获前端 RAW 格式错误与局部恢复

日期：2026-09-11。范围：工具无关 RTL；不是板级或全系统故障恢复签核。

## 本轮改进

此前 RAW 光栅校验器和 ISP 局部清理各自已有测试，但未接入捕获前端。
本轮在 `c1_r1_capture_frontend.sv` 接入两者，新增默认关闭的
`CHECK_RAW_RASTER` 参数，并将参数透传至 capture subsystem 和 portable SoC。
默认配置保留原有数据路径；需显式设为 1 才启用硬件校验与恢复。

启用后，前端在正常输入以及已进入 ISP 的取消排空过程中检查坐标、SOF、
EOL、EOF。坏 token 被本地消费但不送入 ISP；若是帧内突然出现坐标为
(0,0) 的 SOF，则不消费它，为下一次帧启动保留 FIFO 首项。

错误发生时：

1. 锁存 `capture_error=1`、`capture_error_code=8'h05`（RAW 光栅格式错误）。
2. 同拍清理 ISP 像素状态及 RGB FIFO，抑制该拍输出握手；不清空摄像头异步 FIFO。
3. 保留 ISP active 配置与 Gamma RAM，不需要全局 reset 或软件重新加载。
4. 进入 `ST_RESYNC`，残留 RAW 不再经过 ISP。到后续 EOF 或下一帧 SOF 边界后，
   经 `ST_RECOVER` 返回空闲；下一帧 SOF 保留至显式 `begin_frame`。
5. 错误 token 自带的 EOF 不作为恢复完成依据；持续 abort 不得跳过重同步，
   `clear_error` 也不能直接结束清理。

正常完整帧及合法取消仍沿用原有流程。前端 ABI 对格式错误使用统一 0x05，
未向软件导出独立 guard 内部的四种细分错误码。

## 验证

捕获前端定向回归 **58 配置通过**，其中新增 24 配置：

- 5 类错误 × 两种摄像头时钟半周期（3/7 ns）× 有无持续 abort，共 20 配置。
- 错误类型：错误坐标、错误 EOL、提前 EOF、缺失 EOF、20-token 前缀后直接开始下一帧。
- 错误帧期间保持 RGB 接收端背压；验证错误帧未完成、RGB 未交付、0x05 被报告。
- 干净帧预先排入摄像头 FIFO，确认首 SOF 未被吞掉。
- 无 reset、无配置/Gamma 重写，恢复帧的 20 个 RGB 输出逐像素核对解析预期值及 SOF/EOL/EOF。
- 另有 4 配置启用校验后复测正常双帧、帧内取消、EOF 同拍取消、源暂停后取消排空。
- 原有 34 配置保持通过，包括默认关闭校验时的预期失败诊断测试。

最终全量 Icarus 回归 **497 配置通过**，进程退出码 0；上一轮基线 473，新增 24。
回归命令：`case1/scripts/run_iverilog_review_fixes.ps1 -Python <本地含 NumPy 的 Python>`。
脚本在 finally 中清理本次临时编译镜像与生成向量；未启用波形。
Efinity XML 仅做语法解析；本轮未运行 Efinity 综合、布局布线、Vivado 或板测。
更新 Efinity portable SoC、通用 xsim worker 及捕获前端 detached xsim 源清单，加入 guard。

## 不能据此推导的结论

- 已发送到 DDR writer 的帧前缀无法撤回。局部 flush 不负责取消 AXI AW/W/B，
  不得直接释放已分配帧缓冲；必须依赖系统错误传播、writer 排空和所有权屏障。
- 本轮错误测试将 RGB sink 保持为背压状态，尚未证明“部分 RGB 已写入 DDR”后整机恢复。
- 输出 FIFO flush 是局部取消，可撤销尚未接受的输出；集成接收方必须将错误帧整体作废，
  不能当成普通无取消语义的 ready/valid 流继续拼接下一帧。
- `discard_idle` 是显式维护丢弃命令。若恢复后仍保持它，后续完整帧也可能按既有契约被丢弃；
  “保留下一帧 SOF”不覆盖软件/控制器主动要求持续丢弃的情况。
- 源永久停止且没有后续 EOF/SOF 时，保持 cleanup busy；尚未新增停流超时与强制重同步策略。
- 默认硬件配置仍不启用这一开关；新增比较器与故障到局部复位路径尚无目标 FPGA 时序/资源测量。

## 下一项集成门槛

在真实 capture subsystem/portable SoC 仿真中，让 writer 已接受部分数据，再注入
坏 RAW；对 AW/W/B 加背压，验证错误锁存、在途事务排空、缓冲区不提前释放、
下一帧重新分配与完整 RGB 数值。通过之后，才考虑在目标配置中默认启用校验。
