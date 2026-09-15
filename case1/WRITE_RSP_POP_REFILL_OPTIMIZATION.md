# 写响应 FIFO pop/refill（可选）

`c1_axi128_write_mlp` 增加 `ALLOW_RSP_POP_REFILL` 参数，默认 `0`。开启后，响应 FIFO 已满且本地 `rsp_ready` 同拍消费队头时，新的 AXI `B` 或本地错误退休可以立即占用释放的槽位；`rsp_count_q` 仍按 push/pop 同拍净变化更新。

## 小型 xsim A/B

使用脱离当前 Windows Job 的现有 AXI BFM（响应 FIFO 深度 2、AW/W/B 有停顿、包含 SLVERR/帧错误）：

| 模式 | full pop+push | desc/aw/w/b | B stall |
|---|---:|---|---:|
| 默认 | 0 | 6 / 3 / 12 / 3 | 49 |
| 可选 | 1 | 6 / 3 / 12 / 3 | 48 |

adapter 的默认与可选路径也分别通过，计数和错误顺序不变。2-client fabric 已转发该参数并完成可选编译/回归；其当前 BFM 只有两个 adapter descriptor，backend 响应 FIFO 未达到满 pop+push 条件，因此该层 marker 的 `full_pop_push=0` 是测试激励限制，不是功能失败。

独立的小周期模型（`model/write_rsp_pop_refill_model.py`）也覆盖了深度 2、
连续 12 个 descriptor response 的满槽场景：

```text
WRITE_RSP_POP_REFILL_MODEL_PASS depth=2 responses=12
  baseline_cycles=20 refill_cycles=20 saved_stalls=1
  baseline_stalls=6 refill_stalls=5 full_pop_push=10
```

该模型特意把公共响应消费者设为长延迟，因此总 drain cycle 可能不变；可量化
收益是 AXI `BREADY` 侧少一个 producer stall，而不是 payload 带宽增加。

## 集成边界

- 该选项只消除响应 FIFO 满时的一个等待周期，不减少 AXI payload beat/descriptor 数，也不是 15 fps 的主要收益来源。
- 它引入 `rsp_ready -> BREADY` 组合路径；默认关闭。板上启用前应做目标器件时序和 EBR 同址读写（READ_FIRST/WRITE_FIRST）确认。
