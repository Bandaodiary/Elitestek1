# 输出溢出与 RAW EOF 同拍专项验证

日期：2026-09-11。验证上一轮 `RTL_CAPTURE_ABORT_EOF_20260911.md` 中同步修正、当时未单独覆盖的输出溢出入口。

## 方法

扩展 `tb_c1_r1_capture_frontend` 的 `RECOVERY_CASE=4`，使用真实相机异步 FIFO 和 ISP 光栅输入。启动 6×7 RAW 帧，阻塞 RGB 消费端，等待真实 `raw_fire && fifo_eof`，并确认此时仍为 `ST_STREAM`。

只在该接受沿，将 ISP/输出 FIFO 接口的 `output_fifo_in_valid` 强制为 1、`output_fifo_in_ready` 强制为 0，下一下降沿释放。这是接口故障注入，不改变内部状态或伪造 RAW EOF；不能把它解释成测得合法 headroom 配置下的自然 FIFO 容量溢出。

检查错误码 `0x03`、进入 cleanup，随后等待实际 ISP 退休。要求该坏帧 42 个 RAW token 全部接受，零 RGB 消费、零 ingress done、零 abort/drop 事件，错误 sticky 保留到显式清除。再清错并运行两帧渐变图像，不复位任何域；按既有解析期望逐像素比对 40 个 RGB 及帧标志。

## 结果

FIFO 深度 16/32 × 相机半周期 3/7 ns 四组通过，每组同时要求 `C1_CAPTURE_OVERFLOW_EOF_PASS` 与后续 `C1_CAPTURE_PAUSABLE_FRAMES_PASS`，避免仅错误报告成功而恢复失败仍算通过。

整个捕获定向入口 **28 配置通过**，包括已有源协议、活动期取消、EOF/abort、未知值负测试及合法背压整帧测试。此次只改测试和回归入口，生产 RTL 未变，没有重新运行完整回归；最近全量仍是 **458 配置通过**。

## 保留限制

- 不证明所有 FIFO 深度/headroom 参数均能防止自然溢出，也不进行资源、时序或吞吐估计。
- 坏帧输出在注入前已经被 sink 阻塞，不能撤回此前被其他消费者接受的数据。
- 不包含 DDR writer 的已发出事务排空，或缺失 EOF 时的恢复策略。
- 未启动 xsim、综合或板测，不产生波形；临时编译文件和向量由脚本清理。
