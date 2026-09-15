# 正常长行补给：16/32 请求窗口对照

日期：2026-09-11。本轮补齐上一轮小图未能使用超过 16 请求窗口的证据，
不改生产 RTL 或默认参数。

## 负载与固定条件

使用真实 `c1_cache_refill_scheduler` 和 `c1_tensor_mem_axi128_read_burst_client`，
连续完成两条各 **1920 个 64-bit word** 的读取。第一条基址 `0x0FF0`，第二条
`0x5000`，覆盖多处 4 KiB 边界；BFM 依据地址生成确定的完整 64-bit 数据，
高位标识上下 64-bit lane。AR、R 和输出侧施加相同的确定性背压。

两次对照固定请求 FIFO=32、逻辑响应 FIFO=128、物理 burst 上限=16 beats、
reader 最大 outstanding=4；唯一变化是逻辑调度窗口 16/32。
未把 reader outstanding 或响应 FIFO 深度随调度窗口一起扩大。

这是独立补给组件的合成长行负载，不是摄像头、缓存行、CNN 或共享 DDR
fabric 的整机测试。1920 words 也不表示当前模型每一层都需要这么长的缓存行。

## 最终结果

| 指标 | 16 窗口 | 32 窗口 |
|---|---:|---:|
| 正常完成命令 | 2 | 2 |
| 逻辑请求/响应/输出 word | 3840 / 3840 / 3840 | 3840 / 3840 / 3840 |
| 物理 AR | 241 | 121 |
| 物理 R beats | 1920 | 1920 |
| 实测最大 burst | 8 beats | 16 beats |
| 实测最大逻辑 outstanding | 16 | 32 |
| 测试 core cycles | 9644 | 8724 |

测试周期减少 **920（9.5396%）**，AR 减少 **120（49.7925%）**，实际数据
传输量完全相同。窗口 16 的信用限制使连续补给只能积累约 8 个双 lane beat；
窗口 32 在本负载中实际组成了 16-beat burst，而非只修改参数值。
短行/小图此前没有收益，与这里的长行收益并不矛盾。

所有输出均检查完整 64-bit 值、row、index、epoch、error、last；全部请求
响应退休，调度器/reader quiescent。BFM 检查 AXI 属性、队列不溢出和不跨
4 KiB 的单个 burst。最终对照使用 `!==` 检查值/元数据，X/Z 不会被当作相等。

最终运行：

- `review_longrows_window16_final_20260911`：10.329 s，complete/exit=0。
- `review_longrows_window32_final_20260911`：10.326 s，complete/exit=0。
- 原短行配置 `review_refill_short_compat_20260911`：25 words，窗口 2，
  13 AR/13 beats，156 cycles，完整 64-bit 检查通过。

主机运行秒数不是 FPGA 推理时延。上述周期是从测试复位后统计至两条命令排空，
包含共同的启动/控制开销，不能直接换算为整机 15 fps。

## 测试基础设施改进

- 旧 testbench 的逻辑窗口、reader outstanding、burst 长度、FIFO 和两条
  word 数可分别配置，默认仍为历史短行配置。
- BFM 拼接中的算术明确转换为 32 bit，消除不定位宽表达式。
- 原本只核对低 32-bit 地址，现核对完整 64-bit 数据，包括 lane 高位标签，
  并将 word/epoch/error/last 比较改为未知值敏感检查。
- 新增实际 burst 最大长度和完整配置记录，不用名义参数替代实际覆盖。
- detached runner 增加 `-LongRows -SchedulerWindow 16/32`，xelab 赋值参数
  保留 Windows bat 必需的引号；较大窗口要求 LongRows，避免误跑短行。

本轮先跑的两次较弱数据检查结果与最终结果相同，但以 `_final_` 两次为
全 64-bit 验证依据。未重跑全量 Icarus 或综合，生产 RTL 未改变，不把上一轮
141 配置冒作本轮新结果。

## 后续取舍

32 窗口现在有了正常长流收益与真实并发证据，但仍需当前模型的实际大图缓存/
共享 fabric 性能和物理资源代价验证，默认保持 16。此前紧凑 FIFO 的动态边界
是窗口 16，不因这里窗口扩大就自动沿用其容量结论。

源码还显示 scheduler 的 `launch_event` 要求 `!req_pending_q`，每次请求握手
后有意留一拍空隙。下一步可以研究受信用约束的请求同拍交接，但必须保留
VALID/载荷稳定性及取消时的已接受请求排空，不能直接删除 pending 阶段。
这里没有证明该改动的收益，也没有实现或默认启用它。

## 复现与临时文件

```powershell
& case1/scripts/run_cache_refill_scheduler_read_client_xsim_detached.ps1 -RunId <unique-id> -SchedulerWindow 16 -LongRows
# 同负载 32 窗口只改 SchedulerWindow。
```

五次 xsim 均使用 WMI 创建的独立隐藏 worker，脱离 Codex Windows Job。
五个临时目录均已不存在，只保留 **20990 bytes** 精简日志，约 20.5 KiB，
无波形。原生连续 CNN、预览缓冲集成、15 fps 和 Efinity 完整实现仍未完成。
