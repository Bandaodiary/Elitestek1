# Read request FIFO pop/refill（可选）

## 目的

`c1_tensor_mem_axi128_read_burst_client` 的逻辑请求 FIFO 在满状态下，原
`req_ready = (req_count < REQ_FIFO_DEPTH)` 会把同一个时钟内的 builder
`req_pop` 和 producer `req_push` 分开处理，因而在 FIFO 满、已有请求被取走
时仍插入一个输入气泡。本阶段加入参数 `ALLOW_REQ_POP_REFILL`，默认值为
`0`，只在明确打开实验配置时改变 `req_ready`：

```systemverilog
req_ready = !rst && ((req_count_q < REQ_FIFO_DEPTH) ||
                     (ALLOW_REQ_POP_REFILL && req_pop));
```

`req_pop` 只由已注册 FIFO/builder 状态决定，不依赖 `req_ready` 或
`req_push`，因此该组合逻辑无环。满 FIFO 时 push 写入当前 tail（与 head
重合），同拍 pop 消费旧 head，计数保持满，FIFO 顺序不变。

同时修正 `perf_max_req_occupancy`：同拍 pop/push 的物理占用不增加，统计值
不会再错误地报告 `REQ_FIFO_DEPTH+1`。

## 无板卡 A/B 证据

专用测试平台
`sim/tb_c1_tensor_mem_axi128_read_burst_client_req_pop_refill.sv` 在描述符
槽耗尽时暂缓 AXI，填满深度 4 的请求 FIFO，再释放 AXI；所有请求均为非连续
地址，确保 builder 每次只消费一个逻辑请求。runner：

```text
scripts/run_tensor_mem_axi128_read_burst_client_xsim_detached.ps1
  -ReqPopRefillBaseline   # 保守基线
  -ReqPopRefill            # 可选模式
```

两次均通过 Vivado 2023.1 `xvlog/xelab/xsim`，且由 WMI detached worker
运行、结束时删除私有仿真目录：

```text
C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_REQ_POP_REFILL_PASS mode=0 full_cycle=13 first_post_full_cycle=18 full_to_accept=5 same_cycle=0 req=12 ar=12 beats=12 max_req=4
C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_REQ_POP_REFILL_PASS mode=1 full_cycle=13 first_post_full_cycle=17 full_to_accept=4 same_cycle=1 req=12 ar=12 beats=12 max_req=4
```

这表明 focused 场景的满 FIFO 首个替换请求延迟由 5 降至 4 个时钟，且请求
响应顺序、AXI burst/beat 数、最大占用均一致。默认 leaf 回归仍为：

```text
C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_PASS burst_beats=4 max_outstanding=3 req=19 ar=6 beats=10 packed=7
```

## 风险与集成建议

- 可选路径把 builder 的 `req_pop`（含请求头地址 RAM 的组合读取和相邻性判断）
  带到 `req_ready`，可能拉长 producer→ready 的组合路径；因此默认关闭。
- 该优化不减少 AXI payload beat，也不改变 burst/descriptor 顺序，只消除
  FIFO 满边界的一拍反压；只有上游能持续提供请求且 FIFO 经常满时才有收益。
- 若在 fabric/cache wrapper 中使用，应把参数以末尾 named parameter 转发，
  并在目标 Ti60/Efinity 综合后检查 ready 路径时序；若 timing margin 不足，
  保持 `0` 不影响现有集成。

本阶段已完成两级传播：

- `c1_tensor_mem_axi128_read_fabric_2c` 新增末尾参数
  `LEAF_ALLOW_REQ_POP_REFILL`，逐 leaf 转发到
  `ALLOW_REQ_POP_REFILL`；双客户端默认/可选回归均保持
  `req=16 ar=6 beats=8 packed=6 max_inflight=5`。
- `c1_window_line_cache_c8_burst_shell` 新增末尾参数
  `ALLOW_REQ_POP_REFILL`，转发至内部 reader。主 runner
  `scripts/run_window_line_cache_c8_burst_shell_xsim_detached.ps1` 增加
  `-ReqPopRefill`，可与 `-LongBurst` 组合；默认、小 profile、长 profile
  均完成 detached xsim 回归，数据/缓存计数一致：

```text
C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_PASS taps=6 refills=5 words=80 bursts=10 beats=40 max_outstanding=2 tail_flush=0 req_pop_refill=0 ... cycles=303
C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_PASS taps=6 refills=5 words=80 bursts=10 beats=40 max_outstanding=2 tail_flush=0 req_pop_refill=1 ... cycles=303
C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_PASS taps=6 refills=5 words=640 bursts=20 beats=320 max_outstanding=4 tail_flush=0 req_pop_refill=1 ... cycles=1883
```

四个选项同时打开（`-LongBurst -BeatFifo -TailFlush -ReqPopRefill`）也通过：

```text
C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_PASS taps=6 refills=5 words=640 bursts=20 beats=320 max_outstanding=4 tail_flush=5 req_pop_refill=1 flush_closes=5 closes=20 cycles=1883
```

该组合 smoke 的周期仍由 BFM 延迟主导；它证明参数可组合，不把周期不变误读成
额外吞吐收益。

cache shell 的小/长 smoke 中请求 FIFO 未持续处于“满且 builder pop”的
边界，因此周期数没有变化；该回归的作用是确认参数传播及默认兼容，而非
宣称端到端吞吐提升。
