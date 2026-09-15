# 多描述符写状态与 QoS 可移植性

日期：2026-09-10。

## 实际接线调查

当前 `c1_r1_portable_soc.u_memory_fabric` 实例化的是
`c1_axi_n_serial_arbiter_128`，并非上一轮优化的多描述符写仲裁器。
所以不存在可直接贯通 `W_AHEAD_OF_B` 的参数链。此次没有替换整机仲裁，
先补齐替换所需的状态接口以及 QoS 组合验证。

## 新增状态接口

在 `c1_axi_n_write_burst_arbiter_128` 末尾追加只读输出，不改变握手路径：

| 输出 | 精确定义 |
| --- | --- |
| write_busy | 已接受但尚未 B 退休的描述符数非零 |
| write_quiescent | write_busy 的反值 |
| write_owner | 最早尚未 B 退休的描述符所属客户端；空闲时为零 |
| write_data_busy | 已接受但尚未完成 W 的描述符数非零 |
| write_data_owner | 最早尚未完成 W 的描述符所属客户端；无待传输数据时为零 |

开启 W ahead 后，W 队首可以与 B 队首不同；全部 W 已发完也不代表写通道
空闲。关闭 W ahead 时，write_data_owner 仍表示待传输数据的最早拥有者，
但它可能因旧模式等待 B 而暂时不能发送，不应解释为当拍 WVALID 的 owner。

这些状态只描述已经接受的描述符，不禁止上游继续呈现请求，也不能单独
作为全局维护 fence。全局 fence 必须先关闭新请求准入，再联合客户端及
仲裁器状态确认退休；不能在输入 VALID 尚可能被接受时仅观察 quiescent。

QoS 的 write_owner_hold 在此连接方式下表示“最早 B 未退休项的占用时间”，
不再是串行模式下唯一活跃 writer 的占用时间，也不是实际 W 带宽份额。
逐客户端 AW/W/B 接受计数仍来自真实握手，不受 owner 解释变化影响。

## 修复实际暴露的可移植性问题

把真实 `c1_axi_shared_qos_monitor` 加入测试后，Icarus 报错：函数参数只能
为 input，不能展开原来的 `sat_inc(value, output overflowed)`。
这是工具支持限制，不是该 SystemVerilog 写法本身非法。默认 SoC 关闭 QoS，
因此以前的默认编译没有覆盖此问题。

现将函数改为返回打包的 `{overflow, saturated_value}`，调用处解包给原来的
计数值和溢出标志。计数宽度不变；最大值时保持饱和并报告溢出，其余值递增。
原有 bump_counter / bump_wait_counter / bump_owner_hold 的控制语义保持不变。

## 验证证据

扩展两个真实 XRGB writer 的测试，加入真实 QoS monitor：

- 逐拍对照独立 BFM 的 accepted / W-complete / B-retired 计数，检查五个状态输出。
- 旧模式、W ahead、W ahead + AW bypass 三配置均通过。
- 各配置连续四个无复位任务，包含下游 AW 受阻时取消、B 延迟、错误响应和恢复。
- 每个 writer 每任务 AW=1、W=2、B=1；错误响应仅送给对应 writer。
- 全部 W 完成而 B 被延迟时，write_data_busy 可以清零，但 write_busy 必须保持。
- 最终两个 B 队首 owner 占用时间之和等于总 write_busy_cycles；QoS 协议异常为零。

实际输出（三配置相同的状态/QoS计数）：

```text
C1_WRITE_STATUS_QOS_PASS frames=4 busy_cycles=82 protocol_errors=0
```

82 周期只是这个人为背压测试的观测结果，不是性能对比或帧率测量。

原有 `tb_c1_axi_shared_qos_monitor` 新增至默认回归并通过，覆盖握手计数、
等待/背压、owner 计时、显示欠载、deadline 和 clear_stats。
另直接检查饱和函数在 0、最大值前一项、最大值的三个边界：

```text
C1_QOS_SAT_INCREMENT_PASS boundaries=3
C1_AXI_SHARED_QOS_MONITOR_PASS aw0_wait=3 ar1_wait=2 b0_stall=2 r1_stall=4 read_hold=4 write_hold=3 underflow=1 deadline_miss=1
```

三点边界是函数级检查，不应扩展解释为所有计数器长时间溢出的系统测试。
首次新增测试另遇到数组声明顺序问题，已把引用移到声明后；生产修复仍只
涉及状态输出与 QoS 函数返回形式。

SoC 默认编译为 131 源文件、0 errors、603 条工具诊断。未运行 xsim、
Efinity 综合或 PNR，没有新的板级资源或时序结论。
完整 Icarus 回归通过 **135 配置**。全量启动后补加饱和函数三点边界，
最终定向重测通过，期间生产 RTL 未变化。runner 无波形，临时镜像与向量已清理。

## 下一接线门

保留当前读仲裁路径，增加可选多描述符写分支；将状态/故障诊断明确接入
顶层，并注明 QoS owner 统计含义变化。还需真实整机故障广播、全局 fence
和 buffer 生命周期验证，不能仅凭当前局部 quiescent 即宣布替换完成。
