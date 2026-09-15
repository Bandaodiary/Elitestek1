# 真实采集与 CNN 写并发验证

日期：2026-09-11。

## 测试的实际工作负载

上一轮单帧运行的写 outstanding 峰值为 1。本轮没有直接驱动内部 AXI 信号，
而是通过真实 APB 将任务设置为连续采集，发送两帧不同色调的摄像头数据：

1. 第一帧使用既有彩色 RAW10 样例，ISP 有效输出 12×10，Resize 至 8×8，
   运行真实 22-stage CNN。
2. 第一帧的 boardless/engine 进入运行后，送入 tone offset=0x055 的第二帧，
   经实际采集、ISP、帧槽分配和 XRGB writer 写入另一个输入缓冲。
3. 第一帧显示读回完成后，通过真实 APB ABORT 停止连续任务，等待队列排空，
   避免第二个 CNN 作业产生额外 token 混入单帧 golden。

开启深度 4/W ahead/AW bypass，使用上一轮八槽写 BFM；本模式将每笔 B 的
延迟设为 32..34 个 core 周期，而非原来的 3..5，以形成可重复的竞争窗口。
这不是真实 DDR 时序模型，也不是板卡带宽测量。

## 覆盖门槛与结果

新增 `-ConcurrentCapture` 开关，仅允许与 `-QueuedWriteFabric`、
`-SourceGeometry` 数值模式合用，不能叠加 RejectGeometry。
runner 必须找到并发覆盖标志才认为测试通过。

测试强制检查：采集 writer 启动两次；采集 AW 在第一帧计算期间被实际接受；
写峰值至少为 2；W-ahead beat 大于零；第一帧恰好完成一次；没有采集丢帧；
结束时 AW/W/B 队列全部退休。不是只检查一个总 PASS。

direct 与寄存故障广播 ticket 两配置均得到以下实际输出：

```text
C1_SOC_QUEUED_WRITE_TRACE_PASS aw=864 w=912 b=864 peak=2 ahead=32
C1_SOC_CONCURRENT_CAPTURE_TRACE_PASS captures=2 overlap_aw=10 peak=2 ahead=32
C1_SOC_VIDEO_GOLDEN_PASS raw_pixels=120 styled_pixels=64
C1_SOC_NUMERICAL_GOLDEN_PASS fixture=color_rggb resize=downsample_12x10 inputs=64 stages=22 C8_results=836 DDR_pixels=64
```

相对于上一轮，增加了第二帧采集的 10 笔 AW/B 和 30 个 W beat。
第一帧的 64 输入、836 C8 中间结果、64 个 DDR 输出、120/64 个显示像素
均仍逐项符合 golden。这证明并发采集没有破坏本例第一帧的数值与显示来源。
第二帧本身没有运行完整 CNN，也没有对其全部采集像素做独立 golden，不能扩大结论。

## 检查器

新增 `--require-concurrent-capture`，同时要求队列退休标志。检查并发标志的
唯一性、两次采集、非零重叠请求、峰值与 W-ahead 计数和队列标志一致。
新增缺失/重复标志、只有一帧、没有重叠、峰值不符五个反例；本例合计
**28 个内存内变异反例全部拒绝**。上一轮无并发标志的日志也重新通过旧接口验证。

## 运行与文件保留

- direct：`review_capture_overlap_direct_20260911`，75.945 s，完成且退出码 0。
- ticket：`review_capture_overlap_ticket_20260911`，76.895 s，完成且退出码 0。
- 两配置分别通过完整 golden 与全部 28 个检查器反例。
- 使用现有脱离 Codex Windows Job 的隐藏 worker，不生成波形。
- 两个 `case1/sim/portable_soc_cache_ddr_bfm_run_<run-id>` 临时工程均已不存在；
  每个运行只保留 56085 bytes 精简日志，合计 112170 bytes（约 109.5 KiB）。

## 结论边界

- 这次确实观察到了整机多 writer 并发：peak=2、ahead=32，而非仅启用参数。
- 第一帧计算、实际 DDR 存储及显示数值正确，但不是大分辨率/长时间连续流验证。
- ABORT 在第一帧显示完成后发出，没有证明“ABORT 到来时必有未退休写事务”。
  不能据此替代后续在途事务取消/协议故障的整机测试。
- 未进行 W ahead 关闭时的同负载帧周期对照，不宣称量化加速或 15 fps。
- 本轮只修改 testbench、runner 和检查器，未改生产 RTL，默认选项保持关闭。
- 不增加综合、PNR 或板级资源/时序结论；本轮未重跑全量 Icarus。

后续应补齐在已接受写事务中途触发取消/协议故障、确认不提前释放缓冲及完整排空；
并在相同真实工作负载下比较写模式和帧周期。预览第三帧槽集成仍未完成。
