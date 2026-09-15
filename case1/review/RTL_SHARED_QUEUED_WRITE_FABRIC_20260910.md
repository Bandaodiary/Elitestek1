# 共享 AXI fabric 的可选多描述符写分支

开始日期：2026-09-10；回归收口：2026-09-11。

## 实际 RTL 接线

`c1_axi_n_serial_arbiter_128` 现在可在 elaboration 时选择写通道实现，
不再仅有与多描述符写模块互不相连的独立例程。读通道保持原实现。

新增参数：

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| WRITE_FIFO_DEPTH | 0 | 0 为原串行写；2..255 实例化现有多描述符写仲裁器 |
| WRITE_W_AHEAD_OF_B | 0 | 将 W ahead 选项传给该写分支 |
| WRITE_EMPTY_AW_BYPASS | 0 | 将空队列 AW bypass 选项传给该写分支 |

不允许在深度为零时单独开启后两个选项，也不接受其他队列深度。
原串行写组合逻辑和状态机由静态 generate 保留；未启用时不经过额外运行时 mux。
读状态机、读 owner、读响应 skid 和读错误处理未修改。

写分支新增公开的 `write_protocol_error`、`write_data_busy` 和
`write_data_owner`。队列模式的 `write_busy/quiescent/write_owner` 接入真实
写仲裁器，owner 指向最早未退休的 B，而非唯一活跃 writer；W-pending owner
单独输出。原串行模式的协议诊断输出为零，未凭空增加未实现的诊断能力。
队列模式协议错误仍保持到全局复位，不能用取消自动清除。

## 验证范围

扩展 `tb_c1_two_frame_writers_w_ahead`，通过参数选择“独立写仲裁器”或
“真实共享 fabric 的新分支”，同一套独立 BFM 检查实际 writer 数据与响应。

三种共享配置通过：

1. 队列深度 2，W ahead 开启，读响应 direct。
2. 队列深度 2，W ahead + AW bypass，读响应 skid 开启。
3. 队列深度 2，W ahead 关闭，读响应 direct。

每种配置的四个连续任务均执行两个真实 XRGB writer；保留取消、AW 受阻时
W 先发、错误 BRESP 归属、无复位恢复以及逐像素检查。

另在每个任务的 B 全部受阻期间向 client 0 注入一个读事务：核对 AR
地址 0x9000、单 beat/128 位/INCR 属性、返回数据、RRESP、RLAST 和目标客户端；
要求读完成后 read_quiescent 恢复，write_busy 仍为一，B 计数仍为零。
每配置完成四个这样的并行读事务。真实 QoS 同时检查 AR/R 与 AW/W/B
逐客户端累计计数，protocol_error_count 为零。

关键输出：

```text
C1_SHARED_QUEUED_WRITE_PASS shared=1 read_skid=0 concurrent_reads=4
C1_SHARED_QUEUED_WRITE_PASS shared=1 read_skid=1 concurrent_reads=4
```

原独立写仲裁器的三个配置也继续通过。该验证是共享 fabric 层的真实组合，
不是整机 CNN、摄像头或显示回归。共享读测试只覆盖单拍正常响应；原读路径
更广的协议覆盖仍由既有回归承担，不能扩展为新分支所有异常组合已验证。

默认 SoC 编译/展开为 131 个源文件、0 errors、603 条工具诊断。
本轮无 Vivado/xsim、Efinity 综合、PNR 或板测，不增加资源/Fmax/fps 结论。
完整 Icarus 回归最终 **138 配置符合预期**，包含原默认分支回归及新增共享分支
组合测试。runner 不生成波形，临时镜像与生成向量已清理。

## 尚未完成的顶层配置

`c1_r1_portable_soc` 当前仍使用 WRITE_FIFO_DEPTH 的默认零值。因此新分支
已接入共享 fabric 模块，但尚未开放 SoC 顶层参数，也没有切换生产配置。
下一步须同时开放参数、路由协议错误诊断、明确故障后停止新请求及安全排空，
再做整机测试；不能把独立状态端口悬空后便认为全局 fault/fence 已接通。
