# 并行 MAC bank 结果退休同拍重启（可选）

## 目的与边界

`c1_dot8x8_requant_core` 原有合同是：`busy` 直到 `out_valid && out_ready`
之后才清零，下一次 `START` 至少晚一拍。新增末尾参数
`ALLOW_OUTPUT_RESTART`（默认 `0`），允许当前结果在退休的同一边沿接受下一
个 `START`：

```systemverilog
start_ready = !busy || (ALLOW_OUTPUT_RESTART && out_valid && out_ready);
```

新配置只用于下一事务；旧结果仍由旧的 requant pipeline 在该边沿采样。参数已
从 core 转发到 `c1_dot8x8_requant_bank` 和
`c1_dot8x8_requant_pingpong`，不改变默认单 bank/二 bank 的接口位宽、lane
锁步或 tag FIFO 顺序。

该优化隐藏的是**事务边界 bubble**，不是把一个 8×8 dot tree 变成更宽的
算术阵列，也不减少权重/窗口带宽。它还会形成 `out_ready → start_ready`
组合路径，故只作为板前 A/B seam。

## 小型 xsim A/B

runner 使用 WMI detached worker，测试包含周期性 output backpressure、6 个有序
事务和二 bank×二 lane full product/pair/quad/dot tree：

```powershell
.\case1\scripts\run_dot8x8_requant_pingpong_xsim_detached.ps1
.\case1\scripts\run_dot8x8_requant_pingpong_xsim_detached.ps1 -OutputRestart
.\case1\scripts\run_dot8x8_requant_pingpong_xsim_detached.ps1 -FirstBeat -OutputRestart
.\case1\scripts\run_dot8x8_requant_pingpong_banks4_xsim_detached.ps1 -OutputRestart
```

精确 marker：

```text
C1_DOT8X8_REQUANT_PINGPONG_PASS first_beat=0 output_restart=0 banks=2 lanes=2 transactions=6 max_inflight=2 same_bank_restart=0 first_overlap=8 cycles=40
C1_DOT8X8_REQUANT_PINGPONG_PASS first_beat=0 output_restart=1 banks=2 lanes=2 transactions=6 max_inflight=3 same_bank_restart=4 first_overlap=8 cycles=37
C1_DOT8X8_REQUANT_PINGPONG_PASS first_beat=1 output_restart=1 banks=2 lanes=2 transactions=6 max_inflight=3 same_bank_restart=4 first_overlap=9 cycles=37
C1_DOT8X8_REQUANT_PINGPONG_PASS first_beat=0 output_restart=0 banks=4 lanes=2 transactions=12 max_inflight=4 same_bank_restart=0 first_overlap=8 cycles=47
C1_DOT8X8_REQUANT_PINGPONG_PASS first_beat=0 output_restart=1 banks=4 lanes=2 transactions=12 max_inflight=5 same_bank_restart=1 first_overlap=8 cycles=45
```

数据、metadata、输出顺序和 overflow 检查均通过。独立事件模型
`model/mac_output_restart_model.py` 对相同的二 bank/六事务/周期性 backpressure
合同给出 `22→20` cycles、4 次 same-edge reuse；该模型只验证 ownership/退休
规则，不冒充 native CNN 帧率模型。

## 资源/时序判断

该开关不复制 DSP，理论上只增加一个 ready mux；但它把 output backpressure
带回 bank start 选择，可能恶化长距离组合路径。为避免把不同 Vivado 综合快照
混在一起，最新同一参数化脚本的二 bank full-tree proxy A/B 为：

```text
default : 31165 LUT / 22833 FF / 64 DSP / WNS +1.247 ns
optional: 31163 LUT / 22833 FF / 64 DSP / WNS +1.247 ns
```

这只是当前 Artix-7 未布局布线 proxy；更早的默认快照
`31162 LUT/WNS +1.938 ns` 属于不同源码/综合运行，不能用来推导开关的净时序
收益。四 bank 上限压力测试仍为 `+0.337 ns`。本阶段未把 optional path 写入
默认 SoC，也未把 15 fps 结论建立在 3-cycle 小 TB 收益上。

## 集成顺序

1. 先在二 bank、`LANES=2` 的真实 output-group scheduler 中确认每个 bank 的
   `out_ready` 与 tag head 同步；
2. 再在 Ti60/Efinity 做 `ALLOW_OUTPUT_RESTART=1` 的局部时序对照，特别检查
   bank-select、tag FIFO 和 output FIFO 的组合路径；
3. 只有在供数、权重带宽和 stage boundary 已能持续填满 bank 时才启用。若
   `start_ready` margin 下降，关闭参数不会影响默认协议。
