# Portable SoC 显式捕获恢复接口

## 本轮改动

`rtl/top/c1_r1_portable_soc.sv` 新增默认关闭的
`ENABLE_EXPLICIT_CAPTURE_RECOVERY`，将已有前端/子系统恢复握手接入真实
SoC 控制路径。保持默认配置兼容，不新增 APB 地址，不改模型运算。

- `capture_recovery_request && capture_recovery_ready` 接纳一次恢复请求，
  经现有全局 abort 路径取消捕获、参数读取、计算及显示预取。
- 恢复期间保持软件 BUSY；子系统关闭表请求接纳，控制器因此保持取消清理
  和物理输入缓冲区占用屏障。新 START 被 APB 拒绝。
- 等待读写 fabric 排空、所有客户端不再提出 AR/AW/W、计算适配器与缓存
  空闲、参数取消和显示 flush 完成。捕获子系统另行检查 writer 和表读取
  排空。不能仅以 fabric 暂时空闲判定安全。
- 源明确停止后才进行已有的双时钟 FIFO 复位握手；完成后释放 BUSY。
  请求持续为高不会反复触发，拉低后重新武装。

采用单次全局取消脉冲，而非在整个恢复期间持续 abort，避免重复触发显示
flush，使恢复条件无法收敛。

## 接口契约

新增输入/输出均属于 core 时钟域。板级异步停止确认必须经过适当 CDC；
`capture_source_quiescent` 是源停止的明确确认，不能用摄像头 valid 暂时
为低代替。调用方应保持源停止直到 `capture_recovery_done`，随后才恢复
数据源和发起新任务。两个时钟均须运行以完成同步 FIFO 复位；停钟时等待，
不伪造完成。ready 为低时的请求不排队。

SoC 接纳恢复时沿用现有全局取消的错误清除行为；不要把前端独立测试中
“局部复位保留错误”的结论直接套到 SoC 软件状态。需要保存诊断时，调用方
应在恢复前读取错误状态。配置修改仍应与恢复串行化。

## 已验证与边界

随后执行完整 `run_iverilog_review_fixes.ps1`：**596 配置通过，退出码 0**。
包括要求精确诊断且非零退出的非法参数负测试。使用 Icarus，不生成波形；
回归脚本在 finally 中清理本次临时编译文件及生成的向量。这不表示清理过
此前会话遗留的临时文件。全量输出为 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=596`。

`tb_c1_r1_portable_soc_smoke` 定向回归 **19 配置通过，退出码 0**。
新增 4 配置覆盖读写 fabric 的直连/排队配置与 fatal ticket 直连/寄存配置。
每个新增配置检查源确认前保持 12 周期、拒绝 START、完成后等待 24 周期
不重复恢复、BUSY/占用屏障释放及请求重新武装。

这是空闲 SoC 的控制握手测试，不是携带图像数据的整机在途恢复证明。
原子系统 60 配置已覆盖实际 writer 的 AW/W/B 阻塞与表 AR/R/响应背压，
但不能因此声称完整 SoC 的这些组合已经验证。

下一门槛：在 portable SoC 的实际 DDR BFM 场景下，注入停流及在途写响应
延迟，验证恢复期间物理区域快照不提前释放，并对恢复后的 CNN、DDR 和
显示结果进行 golden 对比。此后再设计 APB 软件命令及板级停止确认接线。
本轮不声称完成 Efinity 综合、时序或上板验证。
