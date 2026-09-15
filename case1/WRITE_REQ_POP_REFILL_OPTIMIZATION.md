# 写请求 FIFO 同拍 pop/refill（板前可验证 seam）

本阶段针对 15 fps 路径中的一个具体边界气泡：`c1_tensor_mem_axi128_write_burst_client`
在 request FIFO 已满、burst builder 同拍消费 FIFO head 时，旧的 `req_ready` 仍保持
为 0，导致生产端多等一拍。新增末尾 named parameter
`ALLOW_REQ_POP_REFILL`，仅在显式打开时把这一个槽位立即交给替换请求。

## RTL 合同

- 默认值为 `1'b0`，旧集成的 `req_ready` 时序和 packing 行为不变。
- 可选路径的条件为
  `req_count_q == REQ_FIFO_DEPTH && req_pop`；`req_pop` 只由已寄存的
  builder/FIFO 状态决定，不依赖 `req_valid/req_ready`，因此没有组合环。
- 同拍 push/pop 时 occupancy 保持不变，`perf_max_req_occupancy` 不会再报告
  虚假的 `DEPTH+1`。
- 地址连续性、pack2、4-KiB 边界、AXI W/B 顺序和错误响应合同均未改变。
- `c1_tensor_mem_axi128_write_parallel_fabric` 将参数透传到每个 write leaf；默认
  仍关闭。该 seam 还没有接入 legacy SoC。

## 独立验证

专用 TB 使用 `REQ_DEPTH=4/BURST_BEATS=2/MAX_OUTSTANDING=1`，先停住 AXI 使
request FIFO 填满，再释放一个单拍 descriptor。每个请求为非连续、8-byte 对齐地址，
因而可同时检查顺序、AW/W/B 数量和 occupancy。runner 使用 WMI detached worker，
退出时删除私有 xsim 目录：

```powershell
scripts/run_tensor_mem_axi128_write_burst_client_xsim_detached.ps1 -ReqPopRefillBaseline
scripts/run_tensor_mem_axi128_write_burst_client_xsim_detached.ps1 -ReqPopRefill
```

基线：

```text
C1_TENSOR_MEM_AXI128_WRITE_BURST_CLIENT_REQ_POP_REFILL_PASS mode=0 full_cycle=9 first_post_full_cycle=15 full_to_accept=6 same_cycle=0 req=12 aw=12 beats=12 max_req=4
```

可选：

```text
C1_TENSOR_MEM_AXI128_WRITE_BURST_CLIENT_REQ_POP_REFILL_PASS mode=1 full_cycle=9 first_post_full_cycle=14 full_to_accept=5 same_cycle=1 req=12 aw=12 beats=12 max_req=4
```

现有默认 leaf 回归仍为：

```text
C1_TENSOR_MEM_AXI128_WRITE_BURST_CLIENT_PASS req=21 aw=10 beats=13 packed=7 errors=2 b_stall=1
```

独立 Python 模型只抽象 FIFO 调度，不把边界收益外推为 DDR 或整帧 fps：

```text
WRITE_REQ_POP_REFILL_MODEL_PASS depth=4 requests=12 baseline_stalls=10 refill_stalls=9 baseline_full_to_accept=3 refill_full_to_accept=2 full_pop_push=8
```

## 启用前检查

该优化只减少生产端的一个 ready bubble，不减少 AXI payload bytes，也不增加 AXI
outstanding 数。目标器件上应分别检查 request RAM（尤其 EBR 同步读）到
`req_ready` 的组合路径、上游 VALID hold，以及与 abort/flush 的边界；在 Efinity/Ti60
实测前，建议保留默认关闭。
