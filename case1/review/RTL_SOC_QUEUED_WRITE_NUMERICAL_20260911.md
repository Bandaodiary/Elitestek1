# 队列写模式的真实 CNN / DDR 数值验证

日期：2026-09-11。

## 本轮完成内容

启用完整 portable SoC 的深度 4 队列写、W ahead 和 AW bypass，使用原有
trained-artifact CNN 数值链：14×12 RAW10 摄像头样例，经有效裁剪输出
12×10 RGB，再按既有中心对齐相位缩放为 8×8，执行真实 22 stage CNN。
输入 stride=64，目标 stride=32。direct/registered fatal ticket 两种配置均通过。

本轮没有修改生产 RTL；修改了整机 BFM、detached runner 和 golden 检查器。

## 内存模型修正

旧 BFM 在前一笔 B 退休前不再接受 AW/W，本质上只支持一笔写事务。
新增 `QueuedWriteFabric` 模式：

- 八槽 AW 描述符队列，地址、长度各自保存到 B 退休；容量大于 fabric 深度四。
- 独立接受 AW、推进 W 和退休 B 的游标，按顺序关联物理写地址。
- AW/W 有独立周期背压，B 在对应 W 完成后延迟并保持至接受。
- W 仍通过原 `store_beat` 按真实 WSTRB 更新 DDR，未旁路实际写入。
- 检查 AW 对齐、size/burst、4 KiB 边界和每笔 WLAST。
- 保留旧模式不变；新模式仍维护原有结束排空观察量。

这使模型具备接收多笔写的能力，但模型容量不等于本轮实际达到的并发度。
多槽并发压力尚需另外的整机工作负载；本轮实际峰值只有一笔。

## 数值和退休证据

| 最终运行 | 用时（主机墙钟） | 状态 |
| --- | ---: | --- |
| review_queued_numeric_direct2_20260911 | 65.973 s | 完成，golden PASS |
| review_queued_numeric_ticket_20260911 | 67.829 s | 完成，golden PASS |

两种配置均逐项核对：

- 64 个 Resize/CNN 输入 token；
- 22 个 stage，共 836 个 C8 结果；
- 64 个最终实际 DDR XRGB 像素；
- 120 个原图显示读回像素与 64 个处理图显示读回像素；
- AW=854、W beat=882、B=854，所有写描述符最终退休。

两种配置的关键结果相同：

```text
C1_SOC_QUEUED_WRITE_TRACE_PASS aw=854 w=882 b=854 peak=1 ahead=0
C1_SOC_VIDEO_GOLDEN_PASS raw_pixels=120 styled_pixels=64
C1_SOC_NUMERICAL_GOLDEN_PASS fixture=color_rggb resize=downsample_12x10 inputs=64 stages=22 C8_results=836 DDR_pixels=64
```

其中 `peak=1, ahead=0` 是重要限制：本例没有形成写并发，也没有实际发挥
W ahead 优势。它证明新模式在真实计算/DDR/显示链中的数值兼容性，不能
证明此优化已提升整机吞吐。单 writer 的单 outstanding 和当前计算调度仍是限制。
墙钟运行时间不是硬件帧时间，不用于推算 fps。

首次 `review_queued_numeric_direct_20260911` 的数值也通过，但新增退休
标志最初放在未启用的错误恢复结束分支。已移到正常结束分支，并补跑
direct2；没有把缺少退休标志的首次记录冒充最终退休门通过。

## 检查器加强

runner 新增 `-QueuedWriteFabric`，当前限定和 `-NumericalTrace` 同用。
它将宏传到 worker/xvlog，最终必须找到队列写退休标志才报告成功。

golden 检查器新增 `--require-queued-write`：要求唯一、格式正确的退休标志，
AW/B 守恒、非零事务、W beat 数合法、峰值不超过所配置的四槽 fabric。
旧日志仍可沿原接口验证；该开关不会用标志替代数值比对。

反例检查增加缺失/重复标志、错误退休计数、超过容量四例。最终日志的
**23 个内存内变异反例均被拒绝**，包含原数值、显示和几何反例。
反例仅修改检查器读取的内存文本，不写磁盘，不更改实际仿真日志。

## 运行隔离与文件

沿用外部 WMI / breakaway worker 启动方式，没有将 xsim 放入 Codex 的
Windows Job。三个运行均已确认终止，三个对应临时工程目录均不存在。
三个运行日志目录合计 167,307 bytes（约 163 KiB），未保存波形或大型工程产物。

本轮未重跑 Icarus 全量、Efinity 综合或 PNR，也没有板测结论。
此前 141 配置回归仍为历史记录，不重新宣称为本轮执行结果。

## 下一阶段

需要构造确实有 capture/output/tensor 写并发的整机负载，测量 outstanding
峰值及 W-before-B 计数，并在实际在途写事务下验证取消/故障排空。不能仅
把当前单帧测试尺寸变大就假定出现并发。预览第三帧槽和帧所有权的实际
集成仍未完成；当前不改变队列写默认关闭状态，也不宣称达到 15 fps。
