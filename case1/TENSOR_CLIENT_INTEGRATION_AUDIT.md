# Tensor client → burst/MLP 接入审计（板前阶段）

日期：2026-08-28（含 2026-08-27 历史快照）。本文冻结当前源码的接入边界，目的不是宣布已经完成
native 15 fps，而是避免把已验证的性能 seam 直接接到一个尚未具备相同
协议语义的上游接口。

## 1. 当前真实数据路径

```text
c1_r1_microstyle_tensor_adapter
  └─ 64-bit mem_req/mem_rsp（一次只保留一个 logical transaction）
       └─ c1_tensor_window_cache_axi_client
            ├─ ENABLE_CACHE=0：c1_tensor_mem_axi128_bridge（AR/AW LEN=0）
            ├─ ENABLE_CACHE=1：三行 cache seam → 同一单拍 bridge（legacy）
            └─ optional exact shell：真实三行 cache → exact scheduler/AXI128
```

`c1_window_line_cache_c8_burst_shell` 是旧的只读、独立板前 seam：它把
整行 refill 转成 `c1_tensor_mem_axi128_read_burst_client`，可做 pack2、
4-KiB 分割和多个 AR descriptor；它没有接管普通 tensor 写、bypass read、
stage generation 或全局 abort。

当前已完成的 boardless 接线是
`c1_window_line_cache_c8_exact_burst_shell`：它在同一 stage-base/row 映射
下加入 epoch command hold、exact-count completion adapter、取消排水和
registered sideband skid。它仍是 optional read-only shell，不等于默认 SoC
已经启用。

`c1_tensor_mem_axi128_write_mlp_adapter` 的输入也不是 `mem_req/mem_rsp`，
而是“descriptor command + 声明长度的 logical payload stream”，随后才生成
128-bit payload descriptor。它需要帧边界和按 descriptor 的响应 tag，不能由
现有单拍接口无损推断。

## 2. 为什么本阶段不直接替换

| 风险 | 具体原因 | 直接替换的后果 |
|---|---|---|
| 读端没有供数窗口 | adapter 在收到一个 `mem_rsp` 前不会产生下一个确定请求；cache refill 也按一词请求/响应 | burst client 的 request FIFO、多个 outstanding 和 pack2 无法被填满，吞吐几乎不变，甚至改变 ready/valid 延迟 |
| 读写共享顺序 | 现有 bridge 是一个方向互斥的单 outstanding owner；burst read 与 MLP write 各自有独立退休状态 | 若只替换其中一侧，可能让旧响应匹配到新 owner，或在 ID-less fabric 上交叉污染顺序 |
| 写帧边界缺失 | MLP adapter 需要 `cmd_logical_count`、`req_last/flush` 和 descriptor tag | 把每个 64-bit write 当成 descriptor 会失去 pack2、partial strobe、early/late LAST 诊断和 B 响应归属 |
| generation/abort 尚未贯通 | generation 在 adapter/system bridge；cache seam 没有 generation，top 的 `flush_req` 目前绑 0 | 运行中切帧或 abort 可能留下旧 refill/旧 B response，造成重复响应、陈旧 cache 行或永久 busy |
| AXI ownership 假设不同 | 当前七客户端总线为 ID-less、按 AR/AW 顺序退休；burst/MLP seam 允许多个 descriptor 在途 | 若控制器实际乱序，必须增加 ID/reorder/retirement 表；不能仅凭小 TB 的 `max_outstanding` 推断安全 |

因此当前默认 `c1_r1_portable_soc` 不改参数、不改 client-6 接线。已有
`ENABLE_TENSOR_WINDOW_CACHE` 仍是 correctness-first cache seam，而不是性能
模式开关。

## 3. 可接受的下一条接入合同

性能版应先新增一个明确的 transaction scheduler（不改变旧 ABI），至少具备：

1. 读请求 FIFO：保存物理地址、cacheable/x/y/group sideband、stage generation
   和逻辑序号；只有在拥有足够 response credit 时才向 read burst client 发请求。
2. 写 descriptor FIFO：从连续的 64-bit stream 形成 128-bit beat，显式保存
   logical count、`req_last`/`flush`、byte strobe、generation 和逻辑响应 tag。
3. 统一 owner/epoch 表：每个在途 read descriptor、write descriptor、cache
   refill 行都能映射回同一 epoch；abort 只停止新 admission，先 drain 已接受
   的 AR/R、AW/W/B，再清 tags/config。
4. 读写响应仲裁：在 ID-less fabric 上保持全局退休顺序；若下游允许乱序，
   先引入 AXI ID 与有限深度 reorder buffer，并用 early/late RLAST、orphan B
   和错误响应做负向回归。
5. 可观测计数器：logical req/rsp、packed beats、AR/AW、最大在途、cache hit/
   refill、generation discard、abort drain cycles；没有这些计数不能把小帧
   周期外推到 fps。

推荐分三步验收（前两步的 read-only 部分现已完成，第三步进行中）：

```text
read-only cache refill (MAX_OUTSTANDING=2)          [已完成]
        ↓
read + direct-bypass mux（shell 已完成，SoC 未接）  [部分完成]
        ↓
read/write epoch scheduler + native 640×480 长帧 QoS [下一阶段]
```

每一步都要先过 8×8、64×48，再过 native 640×480 compile/elaboration，最后
才在 Efinity/Ti60 检查 EBR、DDR controller burst 上限、WNS/TNS 和显示/采集
争用。若任一步不能证明 drain/ordering，就回退到旧 bridge，不把可选 seam
接入默认 top。

## 4. 本阶段已有证据与边界

- `BURST_BEATS=16/32` 紧凑 profile 均通过 pack2、4-KiB split、响应顺序、
  misaligned error 和多个 outstanding；32-beat 将该流的 AR 从 9 降到 7，
  payload 仍为 94 beats，397-cycle BFM 结果不代表 fps。
- 1280-word 行模型为 640 AXI beats，16/32-beat descriptor 数分别为 40/20；
  这只量化地址通道压力，不能替代真实 DDR service time。
- native 640×480 的 detached `xvlog`/`xelab` compile-only gate 已通过；
  runner 使用私有 `xvlog -f` source manifest，避免 Windows 命令行过长导致
  的假性“access denied”，并在成功/失败路径删除私有 runRoot。
- 所有上述 seam 的默认参数仍关闭；Python 21-command regression 继续作为
  算法/模型守门，不包含真实板卡 DDR 带宽承诺。

## 5. 上板前阻塞项

1. `c1_cache_refill_completion_adapter` 已完成 boardless exact-count
   bridge，并已接入独立的
   `c1_window_line_cache_c8_exact_burst_shell`，覆盖真实 row-specific
   base/stride=8 映射、epoch hold、flush/abort drain 和 synthetic suffix。
   尚未完成的是把这条 optional shell 接入默认 SoC 的统一 owner/epoch
   mux，并在共享读写流量下验证 request/response credit 与 burst scheduler；
2. 明确 generation、flush、abort drain 和 cache row invalidation 的统一时序；
3. 在 Efinity 复测 response/payload FIFO 的 EBR 推断和同步读延迟；
4. 用 native 长帧 BFM 记录 AR/AW/R/W/B 分布、QoS 等待和计算供数空洞；
5. 只有在共享 FSM 被 stage-overlap/并行 MAC 供数取代后，才用 6,666,667
   cycles/frame 的预算判断 15 fps。

adapter 的 terminal token（`cmd_done`/`abort_done`/`flush_done`）必须真实连线，
且 line-cache declared count 必须非零；synthetic suffix 仅为取消排水的
zero/error poison，不代表真实 tensor 数据。

## 6. 2026-08-28 owner/epoch fence 接口状态

新增 `rtl/dma/c1_axi_shared_owner_epoch_fence.sv` 作为共享 fabric 的控制
seam。它不替换现有 AXI arbiter，只提供 `read_admit/write_admit`、统一
`current_epoch`、abort/flush drain completion 和 sticky wiring-error 诊断：

* abort/flush 边沿同周期关闭新 admission，避免撤回尚未握手的 VALID；
* 只有 read/write 两方向同时 `quiescent && !busy` 才递增 epoch 并发 done；
* abort 清除 context，flush 保留 context；同时发生时只递增一次 epoch、
  但分别给出两个 completion token。

detached xsim marker：

```text
C1_AXI_SHARED_OWNER_EPOCH_FENCE_PASS abort=2 flush=2 epoch=3 fence_count=3 cycles=15
```

该控制 seam 的下一步是挂到七客户端 owner mux，并让真实 exact shell 的
`group_start`/维护请求使用同一 epoch；在此之前，默认
`c1_r1_portable_soc` 的 client-6 接线和 15-fps 结论保持不变。
