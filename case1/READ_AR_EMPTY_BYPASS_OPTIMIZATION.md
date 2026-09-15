# 读 AR 空队列直通（可选）

## 目的

`c1_axi_n_read_burst_arbiter_128` 原本采用“先把 client AR 写入 pending
FIFO，再从 FIFO 发出”的保守时序。因而 fabric 完全空闲时，首个 AR 至少多
一拍。新增末尾参数 `EMPTY_AR_BYPASS`（默认 `0`）：当 pending/response 两个
descriptor ring 都为空且存在仲裁 grant 时，直接把被选 client 的 AR payload
送到下游。

- 下游 `m_arready=1`：同拍完成 client→downstream 的 AR handshake，并用 live
  `s_ar*` 写入 response owner/length metadata；
- 下游暂不 ready：新增的一项一-entry hold register 先锁存完整 `s_ar*`，待
  `m_arready` 后再发出；不会依赖 pending descriptor RAM 的异步读；
- bypass 只在两个 ring 同时为空时有效，不改变后续 ID-less AR/R 顺序、4 KiB
  规则或 malformed-R 诊断。

参数已沿 `c1_tensor_mem_axi128_read_fabric_2c` 增加
`EMPTY_AR_BYPASS` 末尾参数；legacy SoC 不改默认值。

## 无板卡 A/B 证据

runner：

```powershell
.\case1\scripts\run_axi_n_read_burst_arbiter_xsim_detached.ps1
.\case1\scripts\run_axi_n_read_burst_arbiter_xsim_detached.ps1 -EmptyArBypass
```

两次均由 WMI detached worker 完成，私有 xsim 目录在 worker 退出时删除。测试
激励把首个正常 AR 的 `m_arready` 设为 1，因此 `0` 延迟结论限定在下游首拍可
接受的情形；若首拍被 DDR/QoS 拒绝，优化只能保证不增加额外的空队列周期。
正常/畸形 R 流的计数与错误 containment 一致，只有首个空队列 AR latency 改变：

```text
C1_AXI_N_READ_BURST_ARBITER_PASS empty_ar_bypass=0 first_ar_latency=1 hold_capture=0 normal_beats=16 malformed_beats=10 max_inflight=4 ar_total=4 early=1 missing=1
C1_AXI_N_READ_BURST_ARBITER_PASS empty_ar_bypass=1 first_ar_latency=0 hold_capture=1 normal_beats=16 malformed_beats=10 max_inflight=4 ar_total=4 early=1 missing=1
```

two-client fabric 的可选编译/回归也通过：

```text
C1_TENSOR_MEM_AXI128_READ_FABRIC_PASS req=16 ar=6 beats=8 packed=6 max_inflight=5 req_pop_refill=0 empty_ar_bypass=1
```

`model/read_ar_bypass_model.py` 的二态检查也通过：首拍下游 ready 时
`ready=1→0`，首拍被阻塞时两种配置均为 1；因此这里的收益上限是每次完全空闲
启动最多一拍，而不是持续 AXI 带宽提升。

## 代价与启用条件

该选项把 client `s_ar*` 直接带到 downstream `m_ar*` 的组合 mux，并把 live
`s_arlen` 带入 response metadata；此外增加一项小 hold register 和选择逻辑。
它可能增加 `ARVALID/ARREADY` 的源到端路径，因此默认关闭；只有 Efinity/Ti60
时序显示首拍 bubble 确实影响 frame deadline 时才评估打开。它不减少 payload
beat，也不能替代真正的 descriptor multi-outstanding。

建议在板前阶段把它与 `MAX_OUTSTANDING=4` 长 burst、请求 FIFO
pop/refill 一起做小帧 A/B；若 AR 通道已经被 DDR 控制器持续占满，首拍一拍收益
对 15 fps 几乎不可见，应优先保证 response FIFO/EBR 和 QoS margin。
