# 64-bit → AXI128 写 burst client（boardless 原型）

文件：

- RTL：[rtl/dma/c1_tensor_mem_axi128_write_burst_client.sv](rtl/dma/c1_tensor_mem_axi128_write_burst_client.sv)
- 最小 BFM：[sim/tb_c1_tensor_mem_axi128_write_burst_client.sv](sim/tb_c1_tensor_mem_axi128_write_burst_client.sv)
- Detached runner：[scripts/run_tensor_mem_axi128_write_burst_client_xsim_detached.ps1](scripts/run_tensor_mem_axi128_write_burst_client_xsim_detached.ps1)

## 功能

输入是带 `addr/wdata/wstrb` 的 64-bit logical write FIFO。地址必须 8-byte 对齐；地址不对齐时不发 AXI，而是按原顺序产生一个 `rsp_error` 响应。连续的 16-byte beat 会被收集成一个 `AWLEN+1` 的 AXI INCR burst，且不会跨 4-KiB 边界。

一个 AXI beat 的低/高 64-bit lane 分别对应地址 `base+0`/`base+8`。`WSTRB` 的低/高 8 bit 同样映射到两个 lane。`rsp_rdata` 默认回送原 logical write data；本地对齐错误回送 0，BRESP 错误仍回送原数据并置 `rsp_error`。

该leaf限制为一个 AXI burst outstanding：完整burst建好后独立驱动AW/W，二者都完成后等待B；请求FIFO可在事务期间继续接收，W也允许先于AW完成。`MAX_OUTSTANDING`保留为接口参数，但必须为1。SoC的可选2/4事务实现使用独立`c1_tensor_mem_axi128_ordered_write_client`和MLP backend，不是把本leaf的参数直接改大。

该原型没有 abort/epoch 机制。系统应只在 AXI 空闲时复位；若在 AW/W 中途复位，外部从设备可能已经写入部分 beat，而本地响应会被清空，实际产品需要由上层 drain B 通道或增加事务 epoch/fence。

`ALLOW_SAME_LANE_DUP=0`（默认）时，同一 64-bit lane 的重复写会拆成两个 burst，保证两个不同 payload 都真正写入。开启为 1 时，仅当重复请求的 data 和 strobe 完全相同时才合并；不同 payload 仍拆分。相同 lane 的不同值不能在一个 128-bit W beat 中无损表示。

## 仿真覆盖

detached xsim BFM 覆盖 AW/W 独立 backpressure、BVALID 保持、部分 strobe、4-KiB 分割、不连续地址、后继 misaligned/local error、同 lane 不同/相同 payload duplicate，以及一个非 OKAY BRESP 的错误传播；并用 byte shadow memory 检查最终写入。典型结果：

```
C1_TENSOR_MEM_AXI128_WRITE_BURST_CLIENT_PASS req=21 aw=10 beats=13 packed=7 errors=2 b_stall=1
```

runner的worker在`finally`中删除私有xsim运行目录，只保留小型status/stdout/stderr日志。该leaf现经`c1_tensor_mem_axi128_packing_bridge`用于SoC可选packed写路径的默认单事务实现；没有因此完成板卡DDR验证。

## 15 fps 边界优化：request FIFO pop/refill

末尾 named parameter `ALLOW_REQ_POP_REFILL`（默认 `0`）可在 FIFO 已满且
builder 同拍消费 head 时接受替换请求，避免一个 producer ready bubble；同拍
push/pop 不改变 occupancy。它已透传到可选的
`c1_tensor_mem_axi128_write_parallel_fabric`，但仍未接入默认 SoC。

专用 A/B 与模型、启用条件见
[`WRITE_REQ_POP_REFILL_OPTIMIZATION.md`](WRITE_REQ_POP_REFILL_OPTIMIZATION.md)。
