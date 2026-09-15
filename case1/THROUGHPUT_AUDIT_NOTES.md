# 吞吐模型与 AXI 边界审计（2026-08-27）

本轮只记录模型边界，不改变 `model/throughput_sweep.py` 的既有结果。

## 4 KiB 与行尾

- `throughput_sweep.py::_burst_count()` 当前按 `ceil(beats / burst_beats)` 计数，等价于“起始地址已对齐、请求连续、不会在一条逻辑流中跨 4 KiB”的下界假设。
- RTL 读写 burst client 以及 XRGB reader/writer 都会在 4 KiB 边界提前结束 burst；读 cache shell 还按行提交 refill，因此行尾不能与下一行自动合并。`BURST_BEATS=16` 时，若行字数为奇数，每行至少有一个单 lane 尾 beat；若行首地址或行步长使 4 KiB 切分点落在 burst 中间，实际 descriptor 数还会增加。
- 640×480 的主要缓存行宽（`width × C8_groups`）通常为偶数，故当前 `pack2_ideal` 对该冻结尺寸接近可达；这不是任意宽度/任意 stage base 的保证。模型中的 `read_bursts=150600`、`write_bursts=125400` 应解读为理想连续流的 proxy，而非板上 AXI AR/AW 计数承诺。

## 写入端打包边界

`c1_axi_xrgb_frame_writer` 的 RGB 输入路径可在一个 AXI128 beat 中承载 4 个 RGB24 像素；吞吐 sweep 将 source write 与 C8 tensor write 统一抽象为 64-bit logical word，再按 pack2 计数，因而对 source ingress 是保守估计。后续若需要精确带宽预算，应拆分 `source_pack_factor`、tensor pack2 以及末尾 strobe/行跨页项。

## 使用建议

在拿到板卡或确定每个 tensor bank 的 16-byte 对齐基址后，再用实际 descriptor 地址序列逐行统计 `AR/AW`。在此之前，不用这些 burst 数推导“已达到 15 fps”；当前结论仍以 AXI payload beat 下界和独立 compute bound 为准。

## 写侧 request FIFO 边界

`c1_tensor_mem_axi128_write_burst_client` 仍是单 AXI burst outstanding 原型；真正的
多 outstanding 由 `c1_axi128_write_mlp`/parallel fabric 提供。本阶段新增的
`ALLOW_REQ_POP_REFILL` 只在 request FIFO 满且 builder 消费 head 的同一周期接受
替换请求，detached xsim 为 `full_to_accept=6→5`，而 `req/aw/beats=12/12/12`
和 `max_req=4` 不变。它不减少 AXI payload，也不改变 burst/响应顺序；默认关闭，
目标器件上须单独检查同步 request RAM 到 `req_ready` 的组合路径。完整证据见
`WRITE_REQ_POP_REFILL_OPTIMIZATION.md`。
