# Ping-pong MAC：满 TAG FIFO 同周期 pop/push 优化

## 目的

`c1_dot8x8_requant_pingpong` 用有序 bank-id FIFO 保证并行 MAC bank 的
结果按输入事务顺序输出。当 FIFO 深度恰好等于物理 bank 数时，旧逻辑在
`tag_count_q == TAG_FIFO_DEPTH` 时禁止新的 `START`，即使本周期队首结果
已经 `out_valid && out_ready`。这会在 bank 已支持
`ALLOW_OUTPUT_RESTART` 时留下一个无效的启动气泡。

本阶段加入参数 `ALLOW_TAG_POP_PUSH`（默认 `1'b0`）：

```text
tag_space_available = (tag_count < TAG_FIFO_DEPTH)
                    || (ALLOW_TAG_POP_PUSH && out_fire)
```

只有在显式打开该参数时，满 FIFO 才允许同周期 `START` 与队首输出退休。
原有 `case ({start_fire,out_fire})` 计数逻辑保留，因此同时发生时 FIFO
计数不变；队首/队尾指针各自前进一格，顺序不变。推荐与
`ALLOW_OUTPUT_RESTART=1` 成对启用，否则正在退休的 bank 通常仍不能被
重新分配，优化不会产生收益。

## RTL 验证（boardless xsim）

测试宏 `C1_PINGPONG_TAG_POP_PUSH_TB` 将 `TAG_FIFO_DEPTH` 压到 `BANKS`
（2-bank 场景），并发送 8 个一组事务；脚本开关为
`-TagPopPush`。输出周期性施加 backpressure，覆盖 FIFO 满、队首退休、
同 bank 重启和有序数据检查。

| 配置 | marker 关键字段 | 周期 |
|---|---|---:|
| `-TagPopPush`（基线，output restart=0） | `max_inflight=2`, `same_bank_restart=0`, `full_tag_pop_push=0` | 52 |
| `-TagPopPush -OutputRestart` | `max_inflight=3`, `same_bank_restart=6`, `full_tag_pop_push=6` | 48 |

两次均输出 `C1_DOT8X8_REQUANT_PINGPONG_PASS`，数据/坐标顺序和溢出断言
均通过。相同新 RTL 的默认 smoke 仍为
`tag_pop_push=0 ... max_inflight=2 ... cycles=40`，证明默认路径未改变。

## Python 事件模型

`model/mac_tag_pop_push_model.py` 只抽象 bank 所有权、输出 ready 模式和
FIFO 计数，不假设具体 FPGA 资源。默认满 FIFO 参数的模型结果为：

```text
MAC_TAG_POP_PUSH_MODEL_PASS baseline_cycles=35 optional_cycles=31
saved_cycles=4 full_pop_push=6 max_tag=2
MAC_TAG_POP_PUSH_TEST_PASS
```

绝对周期取决于抽象的计算延迟和启动间隔；这里关注的是同一模型下的
4-cycle 相对收益、`max_tag <= depth` 和退休顺序不变。模型回归已加入
`run_python_regression.ps1`（当前命令数 21，另含 write-request pop/refill
模型）。

## 小型 Artix proxy（非板卡签核）

为检查新增控制锥的结构代价，使用同一 Vivado 2023.1 script、同一
`xc7a200tsbg484-1`、2-bank×2-lane、full product→pair→quad→dot tree，且两次
均固定 `ALLOW_OUTPUT_RESTART=1/TAG_FIFO_DEPTH=8`，只切换
`ALLOW_TAG_POP_PUSH`：

| 配置 | LUT | FF | BRAM | DSP | WNS |
|---|---:|---:|---:|---:|---:|
| tag pop/push=0 | 31,163 | 22,833 | 0 | 64 | +1.247 ns |
| tag pop/push=1 | 31,159 | 22,833 | 0 | 64 | +1.845 ns |

两次均为 proxy PASS、TNS=0；tag 开启版本仅少 4 LUT，寄存器/DSP 不变。WNS
差异来自小型综合运行的优化启发式，不能解释为该一位控制一定改善时序；
需在 Ti60/Efinity 做重复综合、布局布线和真实 FIFO 深度/约束验证。对应
run id 为 `tagpop_proxy_base_20260827` 与 `tagpop_proxy_opt_20260827`，runner
开关为 `-OutputRestart` 与 `-OutputRestart -TagPopPush`。

## 适用边界与资源影响

* 这是 admission/backpressure 优化，不增加乘法器或累加器；新增逻辑是
  一个比较器、`out_fire` 与参数常量的与或组合。默认关闭时应被综合常量
  折叠。
* FIFO 深度大于 bank 数时，当前锁序输出策略通常不会达到满深度；该选项
  对这种配置应保持无效/零收益。
* 该选项不能替代 AXI 带宽、缓存命中率或 MAC 阵列规模评估。它只去除
  “所有 bank 占满且队首结果正好可退休”这一窄窗口的启动气泡，不能单独
  证明整帧达到 15 fps。
* 上板前仍需在易灵思目标器件上确认 `ALLOW_OUTPUT_RESTART` 的时序闭合，
  并测量真实 DDR/片上 RAM backpressure；上述 Vivado proxy 结果不等同于
  Ti60/Efinity sign-off。
