# RTL 时序下一步审计（2026-08-28）

本页只记录当前源码与已有 Vivado Artix-7 proxy 报告中的可复核证据，
不把 proxy 数字当作 Ti60/Efinity 签核，也不改变默认参数。

## 当前最差路径归因

最近一次同条件 full-top tensor-burst beat proxy 为
`baseline_helper_all_v1`（器件 `xc7a200tsbg484-1`、640×480、100 MHz）：

| 配置 | LUT | FF | BRAM tile | DSP | WNS | TNS |
|---|---:|---:|---:|---:|---:|---:|
| fixed descriptor-size baseline | 47,512 | 34,821 | 32 | 85 | -1.079 ns | -20.120 ns |
| registered preclamp | 47,443 | 34,784 | 32 | 81 | -1.079 ns | -15.868 ns |
| pixel-count split | 47,542 | 34,818 | 32 | 83 | -1.217 ns | -18.572 ns |
| iterative pixel-count | 47,611 | 34,917 | 32 | 82 | -1.206 ns | -23.233 ns |

baseline 的 `get_timing_paths` 首条路径是：

```text
u_tensor_adapter/descriptor_pending_q_reg[95]/C
  -> u_tensor_adapter/descriptor_size_pixel_count_narrow_q_reg[31]/D
slack=-1.079 ns, logic_levels=9
```

也就是说，当前首违例是严格描述符校验中的 16×16 `W*H` 像素计数，
而不是 abort/ready。打开 `PIPELINED_DESCRIPTOR_PIXEL_COUNT` 后，该乘法
路径确实被移出 top-20，但最差路径迁移为 cache `height_q` 到
`u_tensor_adapter/state_q[*]/CE` 的高扇出控制网（WNS -1.217 ns）；
迭代 shift/add 版本同样迁移到该控制网（WNS -1.206 ns），并增加 99 LUT、
96 FF。两项均默认关闭，不能作为时序修复。

`PRECLAMPED_TAP_COORDS=1` 是目前唯一有明确资源收缩且 WNS 不恶化的候选：
它减少 69 LUT、37 FF、4 DSP，TNS 改善 4.252 ns，但 WNS 仍为 -1.079 ns。
它属于 sideband/cache 语义优化，不应宣传为 100 MHz 闭合。

历史 full-tree/decoderpipe 组合中也出现过 camera FIFO→abort/ready→engine
state、以及 dot weight→overflow 路径；这些路径随可选参数组合变化，不能与本次
descriptor-size baseline 混为一谈。`REPLICATE_ABORT_CONTROL` 的历史非配对实验
还曾恶化约 0.7 ns，因此不再盲目复制或裸寄存 abort。

## 本轮低风险验证

`golden/test_descriptor_format.py` 现在增加了固定 8 MiB bank 阈值的边界检查，
逐一覆盖 8/16/24/32/40/48 bytes-per-group 的 `limit` 与 `limit+1`，并检查
代表性内部点和非法 group。运行结果：

```text
C1_DESCRIPTOR_SIZE_LIMITS_PASS groups=6 boundary_checks=36
C1_DESCRIPTOR_FORMAT_PASS words=16 bytes=64
```

该检查只验证 `FIXED_DESCRIPTOR_SIZE_LIMITS` 的数学等价性，不改变 RTL。

## 下一步建议（按风险排序）

1. **先保持默认配置不变**，用上述边界测试作为 fixed-limit 选项的必要门；
   不再叠加 `PIPELINED_DESCRIPTOR_PIXEL_COUNT`/iterative 版本，除非目标器件
   的报告显示乘法而非控制网是首违例。
2. 若必须处理 descriptor-size 路径，做一个独立、默认关闭的**一拍乘法器
   边界 A/B**（输入寄存器→产品寄存器），只比较 `u_tensor_adapter` 层级的
   WNS/LUT/DSP 和 22-stage 配置握手；不要直接延迟公共 ready/abort。通过后再
   接入 full-top，并确认每 descriptor 增加的配置拍数不会影响启动 watchdog。
3. 对 abort/ready 只采用带完整 payload 的局部 skid/elastic 边界；必须同时覆盖
   stall、flush、abort-at-request、abort-at-response 和下一帧重启。裸延迟 abort
   或把路径标成 false-path 均不满足现有 AXI drain 合同。
4. 地址流水 (`PIPELINED_TENSOR_ADDRESS`) 已把主要 `y*width`/group/byte 地址
   乘法移出 top-20；后续时序工作应转向真实 burst/cache client 的 owner/epoch
   与响应 FIFO，而不是继续加深 adapter 地址状态。
5. 最终判断必须在 Ti60/Efinity 上重复：当前 Vivado proxy 只用于排序候选，
   不能替代 EBR/DSP/LE 映射、DDR PHY 和板级 QoS/15 fps 验证。

本页未启动 native full xsim，也没有保留新的 Vivado/xsim runRoot。
