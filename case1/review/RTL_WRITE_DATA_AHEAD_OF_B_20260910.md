# 多 writer 的 W/B 解耦优化

日期：2026-09-10。

## 源码确认的问题

`c1_axi_n_write_burst_arbiter_128` 已支持多个 AW 描述符排队，但旧 W 选择器
使用 B 退休队首 `head_q`，且直到 B 接受才推进。因此它隐藏了后续地址
发出的延迟，却不能在首个 B 等待期间发送第二个 writer 的 W。
这不是 AXI 正确性错误，而是面向预览/处理结果并行写入的吞吐限制。

## RTL 改动

增加默认关闭的参数 `W_AHEAD_OF_B`：

- 独立 `w_issue_q` 指向最早尚未完成 W 的描述符。
- `w_pending_count_q` 跟踪已接受但尚未完成 W 的条目；支持 enqueue 与
  WLAST 同拍，不以指针相等判断空/满，避免满队列绕回的歧义。
- 开启时，在实际终止 W 握手后推进 W 游标，标记对应槽的 W 完成；
  下一个描述符随即可以发送 W，不等待前一个 B。
- AW 顺序、W burst 顺序和 B 退休顺序均保持一致；不同 burst 的 W beat
  不交织。槽位直到 B 接受才释放，响应路由仍使用 B 队首。
- W 不依赖 downstream AWREADY；已接受的上游描述符足以固定 W 归属，
  保持对“从端等待 WVALID 才给 AWREADY”的合法背压兼容性。
- 参数为零时仍使用旧 B 队首选择 W，不改变整机默认行为。

本轮没有新增另一套仲裁器。生产 SoC 尚未传递/开启此参数，也未将预览
writer 实际加入共享总线；这是已经验证的可选实现，而非整机吞吐结论。
单个 `c1_axi_xrgb_frame_writer` 仍是缓存一段 burst、等待其 B 后再采集下一段，
本次优化并未让单 writer 具备多个 outstanding；收益来自多个 writer 间的重叠。

## 验证

### 多主机描述符测试

将原有三主机 BFM 的 W 核对游标与 B 退休游标分离。旧模型本身假定 W
必须等待 B，不能用于验证本次优化；新版仍按独立记录的描述符顺序检查
WDATA/WSTRB/WLAST 与 BRESP 归属，并保留背压稳定性与计数守恒检查。

五个配置通过：默认、仅 AW bypass、W ahead、W ahead + AW bypass，
以及 W ahead 的深度 3 非二次幂队列。每配置六笔事务、十二个 W beat，
包含错误 BRESP 透传与 AW/W/B 背压。开启的三个配置各有八个 beat 在
旧 B 队首尚未退休时发送；关闭的两个配置均为零。深度 3/4 均覆盖游标回绕。

### 两个真实帧 writer

新增 `tb_c1_two_frame_writers_w_ahead`，实际实例化两个
`c1_axi_xrgb_frame_writer` 和深度 2 的共享仲裁器。预览 DMA 和输出 DMA
使用的正是这个 writer，但测试不包含上层 preview fork 或 CNN。

每配置四个连续无复位任务：正常、上游 AW 已入队但下游 AW 被阻塞时取消、
只给 writer 0 返回错误 BRESP、正常恢复。共逐像素检查 64 个真实打包
XRGB 输出，并确认两路 done 各恰好一次、各自 B 归属和 FIFO 最后为空。

在 B 关闭的 12 拍观察窗口中：

| 配置 | B 返回前完成的 W beat | 两 writer 是否仍忙 |
| --- | ---: | --- |
| 旧模式 | 2（第一笔） | 是 |
| W ahead | 4（两笔） | 是 |
| W ahead + AW bypass | 4（两笔） | 是 |

取消用例还在下游 AW 全部受阻时先接受 W，然后才接受 AW/B；期间不允许
提前释放事务。错误用例确认仅错误响应所属 writer 的 error 置位，下一任务恢复。
三个配置全部通过。首次编译遇到测试中生成索引 `id` 的解析冲突，已使用
独立 genvar 和局部常量索引修正；不是生产 RTL 失败。

定向结果标志：

```text
C1_WRITE_W_AHEAD_PASS enabled=1 depth=4 ahead_beats=8
C1_WRITE_W_AHEAD_PASS enabled=1 depth=3 ahead_beats=8
C1_TWO_WRITERS_W_AHEAD_PASS enabled=1 bypass=0 runs=4 ahead_cases=4 aw_stalled_w=1 pixels=64 no_reset=1
C1_TWO_WRITERS_W_AHEAD_PASS enabled=1 bypass=1 runs=4 ahead_cases=4 aw_stalled_w=1 pixels=64 no_reset=1
C1_TWO_WRITERS_W_AHEAD_PASS enabled=0 bypass=0 runs=4 ahead_cases=0 aw_stalled_w=1 pixels=64 no_reset=1
```

SoC 编译检查为 131 个源文件、0 errors、603 条工具诊断。未运行 xsim、
Efinity 综合或 PNR，不推断新的资源占用、Fmax 或 fps。
完整 Icarus 回归最终输出 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=134`。
runner 不生成波形，临时镜像及生成向量已清理。

## 后续门槛

先完成第三帧槽预检/所有权，再把预览与输出 writer 接到该仲裁器，连同
联合生命周期模块接入 boardless。启用 W ahead 前还需验证整机故障广播、
fence/quiescent、真实 DDR 延迟与目标大分辨率，并补充新模式下更全面的
畸形协议诊断测试。本轮不是 AXI 任意故障恢复或 15 fps 签核。
