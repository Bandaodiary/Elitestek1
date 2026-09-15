# 15 fps 吞吐优化阶段（2026-08-27）

本阶段把“AXI packing/burst、缓存、fabric 多 outstanding、并行 MAC”从
周期模型推进到可独立复用的 RTL seam。默认 `c1_r1_portable_soc` 没有被改接，
所以这些结果是板卡前的可验证增量，不应写成已经达到 640×480@15 fps。

## 已落地的 RTL seam

| 方向 | 文件 | 当前能力 | 状态 |
|---|---|---|---|
| 读 pack/burst leaf | `rtl/dma/c1_tensor_mem_axi128_read_burst_client.sv` | 64-bit logical read FIFO→AXI128；相邻 half pack、burst、4 KiB 分割、多个 descriptor、按序响应；misaligned 不发非法 AXI | 独立 xsim PASS：`req=19 ar=6 beats=10 packed=7` |
| 3-row cache + burst | `rtl/dma/c1_window_line_cache_c8_burst_shell.sv` | 全 group C8 行 refill 接读 leaf；cache hit 不访问外部内存 | xsim PASS：`taps=6 refills=5 words=80 bursts=10 beats=40 max_outstanding=2` |
| refill tail flush（可选） | 同上，`REFILL_TAIL_FLUSH=1` | 已知完整 row 的最后 request drain 后提前关闭 descriptor；保持 pack2/AXI 顺序，默认关闭 | baseline/fast xsim：`closes=10`；`flush_closes=5`；`close_cycle_sum 1329→1319`；BFM 总 cycles 均 303 |
| 读 response FIFO pop/refill（可选） | `rtl/dma/c1_tensor_mem_axi128_read_burst_client.sv`，参数 `ALLOW_RSP_POP_REFILL` | 满 response FIFO 时，把同周期本地 rsp pop 释放的槽用于下一 R beat；逻辑 FIFO 的双 lane beat 仍只在“已非满”时接收 | 默认关闭；Python FIFO 模型在 depth=2 连续 packed R 下 `25→18` cycles，需在 Efinity 检查新增 `rsp_ready→RREADY` 路径 |
| 读 fabric queue | `rtl/dma/c1_axi_n_read_burst_arbiter_128.sv` | 多客户端 AR descriptor FIFO，ID-less R 按 AR 顺序路由；early/missing/orphan RLAST sticky 诊断；计数显式扩展避免回绕 | xsim PASS：正常 `max_inflight=4`，malformed early/missing flags 均置位 |
| 读集成 wrapper | `rtl/dma/c1_tensor_mem_axi128_read_fabric_2c.sv` | 两个 leaf 连接 fabric queue，保留每客户端逻辑顺序与 aggregate counters | 端到端 xsim PASS：`req=16 ar=6 beats=8 packed=6 max_inflight=5` |
| 写 pack/burst leaf | `rtl/dma/c1_tensor_mem_axi128_write_burst_client.sv` | 64-bit logical write FIFO→AW/W/B；pack2、burst、4 KiB/非连续分割、partial strobe、misaligned local error；同 lane 不同 payload 不合并 | xsim PASS：`req=21 aw=10 beats=13 packed=7 errors=2 b_stall=1`；当前明确单 outstanding |
| burst-level 写 MLP seam | `rtl/dma/c1_axi128_write_mlp.sv` | 接收已 pack 的 128-bit descriptor+payload；最多 4 个 descriptor，AW 可提前发，W/B 按序；early/late LAST、flush、orphan/early B 诊断 | xsim PASS：`desc=6 aw=3 w=12 b=3 max_out=3 aw/w/b_stall=18/5/49 errors=4`；proxy PASS |
| logical 写 MLP adapter | `rtl/dma/c1_tensor_mem_axi128_write_mlp_adapter.sv` | 64-bit descriptor/stream 校验、pack2、4 KiB/连续地址检查，完整 descriptor 送入 burst-level MLP，并按序展开 logical response | xsim PASS（小配置 `MAX_BEATS=4`）：`desc=5 req=26 rsp=26 aw=4 beats=12 packed=13 errors=2 max_out=4`；proxy `MAX_BEATS=16` PASS |
| 写 fabric queue | `rtl/dma/c1_axi_n_write_burst_arbiter_128.sv` | 多 writer AW descriptor 排队/提前发 AW；W 严格按 descriptor 顺序，B 按序退休；无 AXI ID 也能隐藏 AW/B 延迟 | xsim PASS：`aw=6 beats=12 b=6 max_outstanding=3`，并覆盖 AW/W/B stall/hold |
| 双 lane 写 fabric | `rtl/dma/c1_tensor_mem_axi128_write_parallel_fabric.sv` | 两个独立写 leaf + ID-less AW/W/B fabric；连续 block 分发、pack2、全局 tag FIFO 恢复逻辑响应顺序；可观测真实 descriptor MLP | xsim PASS：`req=16 aw=4 beats=8 packed=8 errors=4 max_outstanding=2`；可选 seam，未改 legacy top |
| 四 lane 写 fabric A/B | 同上 | 四个单 outstanding leaf 横向扩展；block 轮转、全局 tag FIFO 保序，用于估计 lane scaling 上限 | xsim PASS：`req=32 aw=8 beats=16 packed=16 errors=4 max_outstanding=4`；proxy PASS |
| adapter→两客户端写 fabric | `rtl/dma/c1_tensor_mem_axi128_write_mlp_fabric_2c.sv` | logical adapter 作为 client-0，与 raw AXI128 peer 共享 ID-less AW/W/B fabric；AW 可跨 client 预排，W/B 仍按序 | xsim PASS：`aw=4 w=7 b=4 adapter_rsp=8 peer_b=2 max_inflight=4 packed=4`；proxy PASS |
| 并行 MAC bank | `rtl/cnn/c1_dot8x8_requant_bank.sv` | `LANES` 个独立 8×8 INT8 dot+requant 核锁步广播输入；输出组并行，不改变单 lane 默认合同 | xsim PASS；Artix proxy LANES=1/2/4 为 `8144/16576/33148 LUT`、`16/32/64 DSP` |
| inter-pixel MAC ping-pong | `rtl/cnn/c1_dot8x8_requant_pingpong.sv` | 两个或更多 bank 轮转接收完整事务；上一像素等待 requant 时下一像素可供数；tag FIFO 保持结果顺序 | 2 bank xsim：6 事务、`max_inflight=2`；4 bank xsim：12 事务、`max_inflight=4`，均在第二事务前 8 cycles 进入重叠 |
| DW 权重 tile cache（可选） | `rtl/cnn/c1_r1_microstyle_engine.sv` (`CACHE_DW_WEIGHT_TILES=1`) | 每个 DW output group 首次从线性 bank 读取 9 拍，后续像素从 tap-bank tile RAM 一拍装载；默认参数为 0 | 同一 engine TB xsim：关闭 `first_run_cycles=30570`，开启 `28553`；22 stages/836 outputs/bit-exact PASS；模型 native 估算 39,571,200→30,048,184 cycles；最新 cache+MAC overlap proxy `36413 LUT/14889 FF/2 BRAM/35 DSP/WNS -4.959 ns`，timing 未闭合 |
| Conv/1x1 MAC prefetch overlap（可选） | `rtl/cnn/c1_r1_microstyle_engine.sv` (`MAC_PREFETCH_OVERLAP=1`) | 首拍保持注册 prefetch，后续 accepted beat 同边沿装载下一 activation/weight tile，稳态由 II=2 降至 II=1；默认参数为 0 | engine xsim：关闭/开启 `30570/29192` cycles；与 DW cache 联合 `27174`；native 模型 `39,571,200→31,238,400` cycles；未替换默认 SoC |

## 端到端读集成的意义

`c1_tensor_mem_axi128_read_fabric_2c` 的测试不是单纯的 AR 计数：两个 logical
producer 同时提交，BFM 延迟首个 R，随后检查每个客户端的 payload/error/order。
16 个 logical request 形成 6 个 AR、8 个 R beat，并观察到 5 个在途描述符。这
证明 leaf 的 packing 元数据可以穿过 fabric queue；它仍然只覆盖小型地址流，不能
替代 native 640×480 的 DDR/QoS 测试。

## 资源与时序代理（Artix-7 xc7a200tsbg484-1，100 MHz）

| 结构 | 参数 | LUT | FF | BRAM tile | DSP | WNS |
|---|---|---:|---:|---:|---:|---:|
| 写 fabric queue | 3 clients / FIFO 4 | 370 | 478 | 0 | 0 | +3.787 ns |
| 双 lane 写 fabric（优化后） | 2 lanes / block 16 / tag 64 / fabric FIFO 4 | 4,308 | 10,091 | 0 | 0 | **+1.203 ns** |
| 四 lane 写 fabric A/B | 4 lanes / block 16 / tag 128 / fabric FIFO 6 | 9,858 | 20,168 | 0 | 0 | **+2.166 ns** |
| logical 写 MLP adapter（可选） | `MAX_OUTSTANDING=4` / `MAX_BEATS=16` / response FIFO 4 | 15,961 | 27,771 | 0* | 0 | **+2.551 ns** |
| adapter→两客户端写 fabric（可选） | 2 clients / adapter MLP4 / fabric FIFO 6 | 16,291 | 28,296 | 0* | 0 | **+2.197 ns** |
| 两 leaf + 读 fabric（优化后） | leaf burst 4、fabric FIFO 8 | 31,905 | 10,075 | 0（分布式 RAM/LUTRAM） | 0 | **+1.928 ns** |
| 双 bank × 双 lane MAC ping-pong（当前脚本） | 2 banks / 2 lanes per bank / full tree | 31,165 | 22,833 | 0 | 64 | **+1.247 ns** |
| 四 bank × 双 lane MAC ping-pong（可选扩展） | 4 banks / 2 lanes per bank / full tree | 59,912 | 45,674 | 0 | 128 | **+0.337 ns** |

`0*` 表示 Vivado Artix-7 proxy 未把该可变深度数组稳定推成片上块 RAM；
payload/tile/response 存储的最终 EBR 数量必须在 Efinity/Ti60 上复测，不能按
这里的 0 计入“免费存储”。双 bank output-restart proxy 的同脚本对照为
`31163 LUT/22833 FF/64 DSP/WNS +1.247 ns`；历史 `31162/+1.938 ns`
是不同源码/综合快照，不与当前 A/B 混算。DW tile cache 的当前 tap-bank 重构已通过 xsim，
但 full-top proxy 仍需以最新综合结果为准。

读 leaf 的响应记录又增加了一个**可选 beat-record FIFO**。为避免把参数差异
混入结论，我用同一组 `REQ_FIFO_DEPTH=16 / BURST_BEATS=16 /
MAX_OUTSTANDING=4 / RSP_FIFO_DEPTH=64` 做了 Artix-7 proxy 对照：

| 读 leaf FIFO 布局 | LUT | FF | BRAM tile | DSP | WNS |
|---|---:|---:|---:|---:|---:|
| logical-entry（默认） | 12,045 | 5,378 | 0 | 0 | +1.046 ns |
| beat-record（可选） | **1,714** | **1,182** | 0 | 0 | **+1.380 ns** |

把模式继续转发到两客户端 read fabric 后，板卡前集成 seam 也通过 xsim：
`req=16 ar=6 beats=8 packed=6 max_inflight=5`，跨客户端逻辑顺序保持不变。
同一 Artix proxy（2 clients / fabric FIFO 8 / leaf burst 4 / leaf MAX4）中，
beat 采用 `leaf RSP16`、logical 对照采用 `leaf RSP64`，结果分别为
`2194 LUT/1630 FF/0 BRAM/0 DSP/WNS +1.815 ns` 与
`31905 LUT/10075 FF/WNS +1.928 ns`。其中一部分收益来自按 beat 记录数缩小
FIFO 深度，另一部分来自 beat layout 的单写入 bookkeeping；仍未在默认 SoC
打开，Ti60 的 EBR/同步读映射需要重新测量。

beat-record 每槽保存一个完整 AXI128 beat 和 lane 元数据，随后在本地接口上
拆成一或两个 64-bit 响应；因此不改变 AXI beat 数、DDR payload 或本地逻辑
响应数，只减少双写入、指针和 occupancy 逻辑。它对满 FIFO 采用保守容量判断，
可能多一个 refill bubble，不能单独把共享 CNN 从约 6 fps 提升到 15 fps。
当前集成 wrapper 仍默认 `RSP_FIFO_BEAT_MODE=0`；在 Efinity/Ti60 上确认 EBR
推断、读写端口冲突和长帧压力后，再逐 leaf 打开该选项。

同一个参数也已沿 `c1_window_line_cache_c8_burst_shell` 转发到 burst reader；
cache refill/tap 回归在 `RSP_FIFO_BEAT_MODE=1`、`RSP_DEPTH=12` 下通过
`taps=6 refills=5 words=80 bursts=10 beats=40 max_outstanding=2`。这只证明
cache 的逻辑 64-bit 供数接口可透明消费 beat-record 响应，不代表行 cache 在
Ti60 上已完成 EBR 映射或 native 长帧性能闭环。

双 lane 写 fabric 的第一版 proxy 曾为 `4,374 LUT/10,091 FF`、WNS
`-0.160 ns`；关键路径是 tag FIFO head 经 `rsp_pop`、空槽计数和 `BREADY`
返回 leaf FSM。将写 leaf 的响应空间改为只看 occupancy（满 FIFO 时允许一个
保守气泡）后，资源降至 `4,308 LUT/10,091 FF`、WNS/TNS `+1.203/0 ns`。

读 leaf 同样取消 `rsp_pop` 对 AXI `RREADY` 的组合反馈，并按当前 beat 需要
的 0/1/2 个响应槽使用静态阈值。两 leaf + fabric proxy 从 `32,784 LUT /
10,078 FF / +0.214 ns` 改善为 `31,905 LUT / 10,075 FF / +1.928 ns`；读、写
两条反压路径均在 100 MHz Artix-7 综合代理闭合。两个结果仍是可选 seam，未
接入默认 SoC，也不是 Ti60/Efinity 签核。

为给最终的 Efinity 长帧/QoS 试验保留一个可控的吞吐旋钮，读 leaf 新增
`ALLOW_RSP_POP_REFILL`（默认 `0`）。打开后，response FIFO 在同一时钟内可先
向本地消费者退休一个逻辑响应、再接收下一 AXI R；但 logical-entry 模式中，满
FIFO 即使退休一个槽也**不会**错误接收一个双 lane R beat。参数已沿 two-client
read fabric 与 window-cache burst shell 转发。该模式会把 `rsp_ready` 组合地带入
`RREADY`，所以不能以 Python 的 depth=2 微模型 (`25→18` cycles) 外推到 15 fps，
更不能替换目前的时序优先默认值。板前检查方法和小 TB 在
`model/read_rsp_pop_refill_model.py`、
`sim/tb_c1_tensor_mem_axi128_read_burst_client.sv`（宏
`C1_RSP_POP_REFILL_TB`）中；上板/综合时应只对 Ti60 关闭 timing margin 的 leaf
逐一打开。

读集成 proxy 的 LUT 主要来自两个 leaf 的 request/response metadata 与
`RSP_FIFO_DEPTH=64` 的组合读口；Vivado 没有把它们推成 BRAM。上板前应在
Efinity 中做一版同步读/显式 EBR wrapper 对比，否则不能把这个 proxy 的 0 BRAM
理解为 Ti60 的最终映射。写 fabric queue 本身很小，但它只解决 descriptor/AW
等待，不会消除 tensor payload 的总字节数；双 lane wrapper 也仍受单个 leaf
连续 W/B 顺序约束。

Ping-pong MAC proxy 使用两个 `LANES=2`、full product/pair/quad/dot-tree
bank，因此 DSP/寄存器约为单 bank 的两倍；可选四 bank 点把资源提高到
`59,912 LUT/45,674 FF/128 DSP`，WNS 只剩 `+0.337 ns`。两种 xsim 的
8-cycle overlap 只证明事务级 inter-pixel 隐藏了 bank latency，并不等于整网
stage 间流水。输入仍按“START 后连续 IN_LAST”完整送入一个 bank，权重/窗口
带宽由上游 scheduler 承担；若供数不能达到该节拍，复制的 DSP 会被反压闲置。

## 15 fps 数量级结论

冻结的 640×480/22-stage 图在理想三行 cache + pack2 下为：

- 读 `2,409,600` AXI beat/frame，写 `2,006,400` beat/frame；合计
  `70,656,000 B/frame`，写通道仍约 `45.43%`；
- 在响应延迟 4 cycle、burst address 1 cycle 的整数模型中，真正的 fabric
  outstanding=1/2/4/8/16/32 对应 memory-only `9,638,400 / 4,819,200 /
  2,560,200 / 2,560,200 / 2,560,200 / 2,560,200` cycles；outstanding=2
  已越过 15 fps 的**memory-only**门槛，outstanding=4 后受 payload issue
  上限限制；
- 共享 FSM 即使 dot II=1、DW prefetch=1、两组并行也只有约 6.04 fps；
  `c1_dot8x8_requant_bank` 的 lane 复制只有在 inter-pixel/inter-stage
  streaming scheduler 同时改造时才有意义。模型中的 dedicated 80-lane
  lower bound 为 16.95 fps，但只剩约 0.10 M cycle 的保守余量。

这些数字来自 `model/throughput_sweep.py`，是结构下界/假设扫描，不是 DDR 实测。
`model/fabric_outstanding_sweep` 明确只有在 fabric 真有 descriptor queue 时才会
兑现；把 leaf 的 `MAX_OUTSTANDING` 单独调大不会改变旧串行仲裁器的 effective=1。

## 仍未解决的关键问题

1. **默认 SoC 尚未接入这些 seam。** logical 写 MLP adapter 已经把 64-bit
   pack2 接到 burst-level backend；新的两客户端 wrapper 也把 adapter 暴露为
   fabric client，但仍需把真实 tensor/cache client 的 flush、abort、
   generation/ownership 语义接入，并先做小帧 gate 再扩到 native 长帧。
2. **逻辑写端的 MLP 仍是可选路径。** `c1_axi128_write_mlp` backend 在
   burst-level 接口上允许最多 4 个 descriptor 的 AW ahead/W-B ordered，
   adapter xsim 实测 `max_outstanding=4`。它目前只在板卡前 seam 中运行，尚未
   接到默认 SoC 的七客户端 QoS，也没有 generation/abort drain 的完整合同，
   因而不能把该 seam 当成整帧 DDR 写 MLP 已交付。
3. **ID-less ordering 是硬合同。** 读/写 arbiter 都假设下游响应按 AW/AR 顺序；
   若 Ti60 DDR 控制器允许乱序，必须引入 AXI ID 与 reorder/retirement 表，并重新
   验证 malformed response containment。
4. **cache 只减少 3×3 tap read，不减少 residual/read-modify/write。** 行 refill
   的地址流、行容量、BRAM/EBR 映射和跨 layer flush 仍要在完整 tensor client 中
   验证。
5. **并行 MAC 不是简单复制。** 当前 bank 锁步要求同一窗口、同一 `in_last` 和
   同一 backpressure；新增 ping-pong 只在事务级交替 bank，仍需把相邻 output
   group 的权重带宽、输出 FIFO、stage boundary 和 frame markers 一并扩宽。

## 复现入口（均为 detached worker）

```powershell
& .\scripts\run_tensor_mem_axi128_read_burst_client_xsim_detached.ps1
& .\scripts\run_window_line_cache_c8_burst_shell_xsim_detached.ps1
& .\scripts\run_axi_n_read_burst_arbiter_xsim_detached.ps1
& .\scripts\run_tensor_mem_axi128_read_fabric_2c_xsim_detached.ps1
& .\scripts\run_tensor_mem_axi128_write_burst_client_xsim_detached.ps1
& .\scripts\run_axi_n_write_burst_arbiter_xsim_detached.ps1
& .\scripts\run_axi_n_write_burst_arbiter_orphan_xsim_detached.ps1
& .\scripts\run_tensor_mem_axi128_write_parallel_fabric_xsim_detached.ps1
& .\scripts\run_axi128_write_mlp_xsim_detached.ps1
& .\scripts\run_tensor_mem_axi128_write_mlp_adapter_xsim_detached.ps1
& .\scripts\run_tensor_mem_axi128_write_mlp_fabric_2c_xsim_detached.ps1
& .\scripts\run_dot8x8_requant_pingpong_xsim_detached.ps1
& .\scripts\run_dot8x8_requant_pingpong_banks4_xsim_detached.ps1
& .\scripts\run_dot8x8_bank_xsim_detached.ps1
```

综合代理入口：

```powershell
& .\scripts\run_axi_n_write_burst_arbiter_proxy_synth_detached.ps1
& .\scripts\run_tensor_mem_axi128_read_fabric_proxy_synth_detached.ps1
& .\scripts\run_tensor_mem_axi128_write_parallel_fabric_proxy_synth_detached.ps1
& .\scripts\run_dot8x8_requant_pingpong_proxy_synth_detached.ps1
& .\scripts\run_dot8x8_requant_pingpong_banks4_proxy_synth_detached.ps1
& .\scripts\run_tensor_mem_axi128_read_burst_client_beatfifo_xsim_detached.ps1
& .\scripts\run_tensor_mem_axi128_read_burst_client_beatfifo_malformed_xsim_detached.ps1
& .\scripts\run_tensor_mem_axi128_read_burst_client_beatfifo_proxy_synth_detached.ps1
& .\scripts\run_tensor_mem_axi128_read_burst_client_logical_proxy_synth_detached.ps1
& .\scripts\run_tensor_mem_axi128_read_fabric_2c_beatfifo_xsim_detached.ps1
& .\scripts\run_tensor_mem_axi128_read_fabric_2c_beatfifo_proxy_synth_detached.ps1
& .\scripts\run_axi128_write_mlp_proxy_synth_detached.ps1
& .\scripts\run_tensor_mem_axi128_write_mlp_adapter_proxy_synth_detached.ps1
& .\scripts\run_tensor_mem_axi128_write_mlp_fabric_2c_proxy_synth_detached.ps1
```

所有 runner 使用 WMI 创建隐藏 worker、`-nolog/-nojournal`，并在 `finally` 删除
私有 runRoot；日志目录只保留小型 status/summary/stdout/stderr。

## 2026-08-27：面向 15 fps 的 AXI/cache/MAC 收口

本阶段把“能减少真实等待”的选项与“只改变存储布局/地址压力”的选项分开：

- 读侧增加了 `BURST_BEATS=16/MAX_OUTSTANDING=4` 的长突发 profile，并补齐
  了独立的 `BURST_BEATS=32` A/B。紧凑 RTL stream（189 logical requests、
  94 packed AXI beats）在 16/32 下分别为 `ar=9/7`，两者均
  `beats=94/packed=94/max_outstanding=3/page_split=1/cycles=397`；因此
  32-beat 只减少 AR descriptor，不减少 payload，且该 397-cycle BFM 结果
  不能解释成帧率。缓存 shell 在 64×2-group 行压力下仍为
  `640 logical words/20 bursts/320 beats/max_outstanding=4`，证明参数能在
  四个 descriptor 同时在途时工作。模型中 1280-word 行的 4/16/32-beat
  descriptor 数为 `160/40/20`。
- 读 response FIFO 的 `ALLOW_RSP_POP_REFILL`、写 MLP 的同名选项以及
  arbiter 的 `EMPTY_AW_BYPASS` 均保持默认关闭。前者/后者只在满槽或空队列
  边界消除一个 bubble，并引入 ready→AXI 组合路径；写 MLP leaf A/B 的
  `B stall=49→48`，AW bypass 的首拍延迟 `1→0`，steady-state beat/descriptor
  计数不变。
- 三行 C8 cache 已经把 3×3 tap 外部请求降到完整行 refill；本阶段只验证了
  长突发与四 outstanding 的压力，不宣称 cache 能覆盖 residual/RMW 或跨层
  flush。当前 cache shell 仍一次处理一个 row miss，真正的行预取/compute
  overlap 要等 tap scheduler 与 DDR client 合同确定后再做。
- 长 profile 还完成了四选项组合 smoke（`LongBurst + BeatFifo + TailFlush +
  ReqPopRefill`）：`640 words/20 bursts/320 beats/max_outstanding=4`，5 次
  known-tail flush，最终 `cycles=1883`。这证明参数/协议可组合，但 BFM 延迟主导
  了总周期，不能把周期不变解释成端到端吞吐提升。
- 并行 MAC 方面，二-bank ping-pong 的可选首拍 skid 将小 TB `cycles=40→38`；
  四-bank×双 lane 仍是 `128 DSP/WNS +0.337 ns` 的上限压力测试。DW tile
  cache + MAC overlap 虽把 native 共享-FSM proxy 推到约 `4.605 fps`，full-top
  Artix proxy 仍为 `WNS -4.959 ns`，因此不打开默认配置。

综合结论仍是：理想 cache+pack2 流量约 `70,656,000 B/frame`，真实 fabric
outstanding=2 才有机会越过 memory-only 门槛；共享单 FSM 即使 II=1/双组并行
仍只有约 `6.04 fps`，而 dedicated 80-lane 下界 `16.9542 fps` 余量很小。
所以本轮优化完成的是可验证的 AXI packing/burst/queue seams，不是 native
640×480@15 fps signoff；所有新开关都须在 Ti60/Efinity 做 EBR、QoS 和时序
复测后再接入默认 SoC。

## 2026-08-27：本阶段新增的边界优化

在上述长 burst/cache profile 之后，又完成了两个只影响边界气泡的低风险 seam，
以及一个可复现的 MAC 事件模型：

| seam | 板前 A/B 结果 | 15 fps 解释 | 默认策略 |
|---|---|---|---|
| `ALLOW_REQ_POP_REFILL`（读 request FIFO） | depth-4 满槽替换 `full_to_accept=5→4`，`same_cycle=0→1`；`req/ar/beats/max_req=12/12/12/4` 不变 | 只消除 producer 反压的一拍，不减少 AXI payload | 关闭，待目标器件检查地址 RAM→ready 路径 |
| `EMPTY_AR_BYPASS`（读 arbiter） | 首个空队列 AR latency `1→0`，stalled 下游 `hold_capture=1`；正常/畸形 R `16/10` beat、`max_inflight=4`、错误标志均不变 | 只改善每次完全空闲后的启动，不改变 steady-state 带宽 | 关闭，避免 source→AR 组合路径 |
| `ALLOW_OUTPUT_RESTART`（并行 MAC bank） | 二 bank×二 lane `40→37` cycles、同 bank restart `0→4`；四 bank×二 lane `47→45`、`0→1`；数据/顺序 PASS | 隐藏事务退休边界；不复制 DSP，不能外推整网 fps | 关闭，待 `out_ready→start_ready` 时序和供数验证 |

`ALLOW_REQ_POP_REFILL` 已沿 read fabric/cache shell 转发；`EMPTY_AR_BYPASS` 已沿
two-client read fabric 转发；MAC 参数已从 core→bank→ping-pong 贯通。三者均是
末尾 named parameter，默认值保持兼容。详细 marker、runner 和风险记录分别见
[`READ_REQ_POP_REFILL_OPTIMIZATION.md`](READ_REQ_POP_REFILL_OPTIMIZATION.md)、
[`READ_AR_EMPTY_BYPASS_OPTIMIZATION.md`](READ_AR_EMPTY_BYPASS_OPTIMIZATION.md) 和
[`MAC_OUTPUT_RESTART_OPTIMIZATION.md`](MAC_OUTPUT_RESTART_OPTIMIZATION.md)。

独立模型 `model/mac_output_restart_model.py` 输出
`MAC_OUTPUT_RESTART_MODEL_PASS baseline_cycles=22 optional_cycles=20
saved_cycles=2 same_edge_restarts=4`，它只验证 bank ownership/ordered retirement
合同。由于 native frame 仍由共享 FSM、DDR/EBR、显示/采集 QoS 共同决定，本阶段
不把这些小测试的 1-cycle 或 3-cycle 收益叠加到 15 fps 声明中。

### 写侧 request FIFO 边界（2026-08-27）

为覆盖 AXI packing/burst 之外的生产端反压，又在
`c1_tensor_mem_axi128_write_burst_client` 增加默认关闭的
`ALLOW_REQ_POP_REFILL`，并透传到可选两路 write fabric。depth=4 的 detached
xsim A/B 保持 `req/aw/beats=12/12/12`、`max_req=4`：

| 模式 | full→replacement accept | same-cycle pop+push |
|---|---:|---:|
| default (`0`) | `6` cycles | `0` |
| optional (`1`) | `5` cycles | `1` |

现有 21-request 默认 leaf 回归仍为 `aw=10/beats=13/packed=7/errors=2`。
独立模型输出 `baseline_stalls=10→refill_stalls=9`，说明收益只是一拍生产端
气泡；它不减少 DDR payload、也不增加 AXI outstanding，不能单独换算为 15 fps。
由于可选路径把 builder 状态带入 `req_ready`，在 Ti60/Efinity 上仍应检查同步
request RAM→ready 时序和 abort/flush 边界，故默认保持关闭。详见
[`WRITE_REQ_POP_REFILL_OPTIMIZATION.md`](WRITE_REQ_POP_REFILL_OPTIMIZATION.md)。

## 2026-08-27：并行 MAC 满 TAG FIFO pop/push

进一步针对并行 MAC 的 admission/backpressure 边界，`c1_dot8x8_requant_pingpong`
新增默认关闭的 `ALLOW_TAG_POP_PUSH`。当有序 tag FIFO 已满、队首结果在本周期
`out_fire`，且 bank 通过 `ALLOW_OUTPUT_RESTART` 可同边沿复用时，允许新的
`START` 写入将被退休的 FIFO 槽；`start_fire` 与 `out_fire` 同时发生时计数
保持不变。该逻辑不改变乘法器/累加器数量，默认参数常量折叠后保持旧路径。

专用 xsim 将 FIFO 深度压到 bank 数，以确保边界真正触发：

| 配置 | 结果 marker 摘要 | 周期 |
|---|---|---:|
| 2 bank×2 lane，`TagPopPush`，无 output restart | `max_inflight=2`, `full_tag_pop_push=0` | 52 |
| 2 bank×2 lane，`TagPopPush+OutputRestart` | `max_inflight=3`, `same_bank_restart=6`, `full_tag_pop_push=6` | 48 |
| 4 bank×2 lane，`TagPopPush`，无 output restart | `max_inflight=4`, `full_tag_pop_push=0` | 59 |
| 4 bank×2 lane，`TagPopPush+OutputRestart` | `max_inflight=5`, `same_bank_restart=2`, `full_tag_pop_push=2` | 57 |

四组均检查 signed-8 饱和后的 payload、坐标顺序、FIFO 深度和 overflow；默认
smoke 仍为 `tag_pop_push=0 ... cycles=40`。对应事件模型
`model/mac_tag_pop_push_model.py` 在相同抽象参数下得到 `35→31` cycles、
`full_pop_push=6`、`max_tag=2`，用于验证计数/顺序不变量，不作为 native 帧
周期预测。详细设计约束、run id 和复现命令见
[`MAC_TAG_POP_PUSH_OPTIMIZATION.md`](MAC_TAG_POP_PUSH_OPTIMIZATION.md)，汇总数据
已写入 `model/axi_burst_proxy_summary.json`。

同一 2-bank×2-lane Artix-7 proxy（两次均 `ALLOW_OUTPUT_RESTART=1`）只切换
`ALLOW_TAG_POP_PUSH` 时，资源为 `31163 LUT/22833 FF/64 DSP/WNS +1.247 ns`
与 `31159 LUT/22833 FF/64 DSP/WNS +1.845 ns`，TNS 均为 0。该小综合的 WNS
差异属于工具优化启发式，不作为时序改善结论；需 Ti60/Efinity 重复综合和
布局布线确认。

该 seam 的收益只存在于 FIFO 满且队首恰好可退休的窄窗口；它不能替代 AXI
packing/burst、cache 命中、fabric outstanding 或 MAC 阵列宽度，不能将上述
2/4-bank 小 TB 周期外推为 15 fps。上板前仍须在 Ti60/Efinity 检查
`out_ready→start_ready` 组合路径、EBR/QoS backpressure 和真实帧级 tag 深度。

## 2026-08-27：读 response FIFO 与 cache 长 burst 组合收口

`c1_window_line_cache_c8_burst_shell` 现可显式转发
`ALLOW_RSP_POP_REFILL`，runner 增加 `-RspPopRefill`。在
`LongBurst + BeatFifo + TailFlush + ReqPopRefill + RspPopRefill` 组合下，独立
detached xsim 通过：

`taps=6/refills=5/words=640/bursts=20/beats=320/max_outstanding=4/`
`tail_flush=5/rsp_pop_refill=1/req_pop_refill=1/cycles=1883`。

这个结果的用途是验证选项传播、AXI beat-record 格式、cache 行 refill、四个
descriptor 在途和 tail/flush 组合可以共同 elaboration/运行；BFM 的响应间隔主导
总周期，因而不把 `1883` 与未开启选项的同周期数解释成性能收益。读 leaf 的
专用 `ALLOW_RSP_POP_REFILL` A/B 仍负责覆盖“response FIFO 满且本地 pop 同拍接收
R beat”的窄路径（`READ_RSP_POP_REFILL_TEST_PASS`）；cache 组合 smoke 不伪造该
事件。该开关默认关闭，待 Ti60/Efinity 确认 `rsp_ready→RREADY` 时序和 EBR 同址
读写语义后再考虑接入默认 SoC。

### BURST_BEATS=16/32 读 leaf A/B（2026-08-27）

新增 `sim/tb_c1_tensor_mem_axi128_read_burst_profile.sv` 与 detached runner
`scripts/run_tensor_mem_axi128_read_burst_profile_xsim_detached.ps1`。profile
固定 `REQ_FIFO_DEPTH=32/MAX_OUTSTANDING=4`，并使用 189 个逻辑请求覆盖：

- 64 个连续 AXI beat（直接区分 16-beat 与 32-beat burst）；
- `0x2f00` 起始、跨 `0x3000` 的 4-KiB split；
- 非连续 descriptor、一个 misaligned local-error 和同 lane duplicate；
- AXI `ARSIZE=4/INCR`、R beat 顺序、pack2 lane 顺序及 outstanding 检查。

实际 detached xsim marker：

```text
C1_TENSOR_MEM_AXI128_READ_BURST_PROFILE_PASS burst_beats=16 req=189 ar=9 beats=94 packed=94 full_bursts=5 short_bursts=4 max_outstanding=3 page_split=1 cycles=397
C1_TENSOR_MEM_AXI128_READ_BURST_PROFILE_PASS burst_beats=32 req=189 ar=7 beats=94 packed=94 full_bursts=2 short_bursts=5 max_outstanding=3 page_split=1 cycles=397
```

两种参数的 payload、错误计数与逻辑响应顺序完全一致；32-beat 只减少了
`AR` descriptor。`cycles=397` 由紧凑请求生成器和确定性 BFM 间隔主导，不能
外推 native 640×480@15 fps。对应 1280-word 行模型仍为
`640 beats/40 bursts (16)/20 bursts (32)`。32-beat profile 仅作为板前几何和
协议证据，默认 SoC 不切换；上板前必须在 Efinity/Ti60 检查 EBR 深度、控制器
最大 burst、读 turnaround、QoS 以及更长 descriptor 占用时间。

### 最大行 1280-word / BURST_BEATS=32 cache-shell 门控（2026-08-27）

新增 runner 开关 `-MaxRow`，将 cache shell 配置为 `W=640/H=1/G=2`，即冻结
native 模型的最大 `width*groups=1280`。该 profile 使用 32-beat、四个
outstanding 和 16-entry BFM descriptor queue，检查连续 AR 地址、4-KiB 不跨界、
两次页边界分割、pack2、缓存命中以及整行计数：

```text
C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_MAXROW_PASS taps=8 refills=1 words=1280 bursts=20 beats=640 packed=640 ar=20 ar_beats=640 page_splits=2 max_outstanding=4 tail_flush=0 cycles=1636
```

这是最大行的 boardless geometry/order gate；`1636` 周期由确定性 BFM 和请求
生成器主导，不能外推 640×480@15 fps。默认 shell、portable SoC 接线和所有
可选参数仍保持不变。复现命令与详细边界见
[`READ_LONG_BURST_PROFILE.md`](READ_LONG_BURST_PROFILE.md)。

将 `-BeatFifo -TailFlush -ReqPopRefill -RspPopRefill` 叠加到同一 `-MaxRow`
profile 后仍保持 `bursts/beats/packed/max_outstanding=20/640/640/4`，并观测到
`tail_flush=1/cycles=1636`。这证明可选记录布局和维护边界在最大行上可以组合，
但不改变“需要 EBR/Efinity 与 native QoS 复核”的结论。

### 真实 tensor client 接入审计与 native shape 门控（2026-08-27）

审计确认 `c1_r1_microstyle_tensor_adapter` 与当前
`c1_tensor_window_cache_axi_client` 仍是一次一个 `mem_req/mem_rsp` 的逻辑
合同；cache refill 也逐 word 等待响应。因此把 read burst leaf 或 write MLP
直接替换到 client-6 不会自动产生有效的供数窗口，还会绕开写 descriptor 的
帧边界以及 generation/abort/flush drain。完整风险、推荐 scheduler 边界和
分阶段接入顺序见 [`TENSOR_CLIENT_INTEGRATION_AUDIT.md`](TENSOR_CLIENT_INTEGRATION_AUDIT.md)。

本阶段没有修改默认 top 或打开任何可选吞吐参数。另以 detached WMI worker
完成 native `640×480` compile-only gate；新的 runner 用私有 `xvlog -f` source
manifest，避免 117 个源文件拼接成长命令行而触发 `xvlog` 的误报，并在
success/failure 两条路径删除私有 runRoot。该 gate 只证明 RTL 可编译/展开，
不代表 native CNN、DDR QoS 或 15 fps。

### 只读 cache-refill scheduler 与 AXI128 leaf（2026-08-27）

为把“多 outstanding”从单个 read leaf 的局部参数提升为可验证的行级
协议，新增 `c1_cache_refill_scheduler`。它以 row command FIFO、logical-word
metadata credit、epoch/generation sideband 和 `leaf_req_flush` close pulse
管理现有 AXI128 read burst client；默认 SoC 接线不变。

这一阶段的关键顺序约束已经用小型 detached xsim 收口：

```text
FENCE_STALL_PASS       req=2 rsp=2 words=2 flush_done=2 epoch=2 cycles=31
DRAIN_PASS             req=2 rsp=2 drain=2 stale=2 max_outstanding=2 epoch=1 flush=1 cycles=23
READ_CLIENT_PASS       commands=2 words=25 req=25 rsp=25 ar=13 axi_beats=13 max_outstanding=2 flush=1 cycles=156
WRAPPER_PASS           words=3 bursts=1 beats=2 cycles=18
```

`deferred_start_q` 保证维护边沿不能撤回已呈现且尚未 ready 的 current word；
`EMIT_DRAIN_WORDS=1` 则把已接受的 stale response 放到独立 drain stream，并
由 drain sink 的 ready 决定排水速度。可复用 wrapper 将 scheduler 的
`SCHED_MAX_OUTSTANDING=16`（logical words）与 reader 的
`READER_MAX_OUTSTANDING=4`（AXI bursts）分开，避免把 burst descriptor credit
误当作 logical response credit。

需要特别保留的边界是：scheduler 只能为已经被 leaf 接受的请求生成 metadata
和 drain word。line-cache 的既有 ABI 要求一个 refill 的 declared word count
全部握手，因此 abort 时未发出的 suffix 需要 cancel-token/completion adapter；
这两句属于 2026-08-27 historical snapshot。2026-08-28 已由 optional
`c1_window_line_cache_c8_exact_burst_shell` 接到真实
`c1_window_line_cache_c8.refill_word_*` ABI，并通过 exact-shell boardless
回归；它仍未接到 default SoC，小 TB 周期也不能换算成 15 fps。

裸 scheduler proxy（Artix-7 `xc7a200tsbg484-1`，100 MHz）为 839 LUT、1647 FF、
0 BRAM、0 DSP、WNS +1.274 ns/TNS 0。它只说明控制面在板前可综合；真正的
Ti60/Efinity EBR、DDR QoS、读写 owner/epoch mux、native 长帧和帧 deadline
仍是后续门控。

### exact-count cancellation/completion bridge（2026-08-27）

为满足现有 line-cache “accepted refill 必须收满 declared count”的合同，
新增 `c1_cache_refill_completion_adapter` 及其
`c1_cache_refill_scheduler_read_client_exact` 组合。adapter 对已接受的旧
响应消费 scheduler drain stream，对尚未发出的 suffix 只生成 zero/error
poison；这解决的是取消时的协议收口，不增加有效 tensor 带宽，也不能把
poison 词计入 CNN 计算。

它还把 completion 定义为双条件：exact-count stream 和 scheduler 的
`cmd_done`/`abort_done`/`flush_done` terminal token 都到达后才释放下一条
命令。normal back-to-back gate 已覆盖最后一个词早于 `cmd_done` 的情况：

```text
C1_CACHE_REFILL_COMPLETION_ADAPTER_NORMAL_PASS normal=5 synthetic=2 done=4 error_done=2 req=5 rsp=5 cycles=46
C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_EXACT_PASS words=5 drained=2 synthetic=3 req=2 rsp=2 ar=1 beats=1 flush=1 cycles=25
```

exact composition 的 Artix-7 proxy 为 `35435 LUT / 11743 FF / 0 BRAM /
0 DSP / WNS +0.799 ns / TNS 0`（100 MHz，scheduler logical credit 16、
reader burst credit 4、16-beat、32-entry request FIFO）。该组合仍未接入
default SoC，不能从 `cycles=25` 或 proxy WNS 推导 15 fps；真实瓶颈仍是
read/write owner、DDR QoS、line-cache 行几何和并行 MAC 供数。adapter 的
ready 反压是组合路径，若 Ti60/Efinity 报告不收敛，再插入保留 normal/drain
mode 与 sideband 的一深度 skid。

line-cache 集成前必须保留三项约束：`word_count>=1`、三个 terminal token
均连线、synthetic suffix 只能触发 discard/error；随后才可做 native 长帧
abort/drain 和帧 deadline 测试。

### 真实 line-cache exact shell 与 registered refill FIFO（2026-08-28）

新增 `rtl/dma/c1_window_line_cache_c8_exact_burst_shell.sv`，把真实三行
`c1_window_line_cache_c8` 接到 exact scheduler/AXI128 read client。命令映射
为 `base=stage_base+row*(frame_width*frame_groups*8)`、`stride=8`；
`stage_base` 与 group geometry 在同一 `group_start` handshake 捕获，
abort/flush 的 cache/exact 两路 done 由 shell join 后对外报告。小型 detached
xsim 通过：

```text
C1_WINDOW_LINE_CACHE_C8_EXACT_BURST_SHELL_PASS responses=4 refills=3 words=24 ar=5 beats=10 flush=1 epoch=1 cancel_req=3 cancel_source=3 cancel_drain=3 cancel_synthetic=5 cancel_unified=8 cycles=143
```

exact stream 与 cache 之间的默认 `REFILL_SKID_DEPTH=2` 是注册 FIFO，输入
ready 只看 occupancy，并保存 data/error/last/row/index/epoch；它切断了
cache→adapter→reader 的长反压路径。Artix-7 `xc7a200tsbg484-1`、100 MHz
proxy 的 A/B 为：

```text
without skid: 35543 LUT / 11923 FF / 7.5 BRAM / 0 DSP / WNS -1.622 ns / TNS -97.709 ns
skid depth 2: 35639 LUT / 11930 FF / 7.5 BRAM / 0 DSP / WNS +0.302 ns / TNS 0
```

这只是 read-only shell 的结构及时序证据，不是 Ti60/Efinity 或整网 15 fps
签核；7 个 cache BRAM 的可选输出寄存器仍需在目标器件重新评估。FIFO 只
改善收敛，不增加有效 tensor 带宽；行仍是串行 refill，真实 15 fps 还取决于
读写 owner/epoch mux、DDR QoS、并行 MAC 供数和帧 deadline。板级必须最终
服务已经接受的 AR/R 请求，长期封锁 AR 会让 drain 按协议反压。

## 2026-08-28：共享 owner/epoch fence 与真实 arbiter shell

新增 `c1_axi_shared_owner_epoch_fence` 作为共享 read/write 维护 authority，
并为 `c1_axi_n_serial_arbiter_128` 导出只读 owner/busy/quiescent 状态。它在
abort/flush 边沿阻止新的 idle owner，同时允许已选中的 stalled AR/AW/W/R/B
继续排空，待两方向完全 quiescent 后才递增 epoch、给出 completion token。
真实组合回归通过：

```text
C1_AXI_SHARED_OWNER_EPOCH_FENCE_ARBITER_PASS ar=1 r=1 aw=1 b=1 epoch=2 cycles=23
```

可选 `c1_axi_shared_owner_epoch_arbiter_128` shell 已将同一 gate 实际放入
RTL，2-client/no-skid 与 read-skid=1 均通过 focused xsim；默认 7-client、
`READ_RESPONSE_SKID=1` 的 Artix-7 100 MHz proxy 为
`1411 LUT / 407 FF / 0 BRAM / 0 DSP / WNS +2.144 ns / TNS 0`。现有
cache-enabled portable SoC wiring smoke 仍通过，新增 status 输出未破坏默认
arbiter 的 named instantiation，但 default SoC 尚未替换为该 shell。

因此这一步解决的是 owner/epoch 协议和可观测性，不是吞吐签核；下一步需把该
seam 与真实七客户端长帧 QoS、display underflow/deadline、burst credit 和
并行 MAC 供数联合回归。新增 runner 均以 detached WMI worker 运行，使用
response-file 编译并删除私有 xsim/Vivado runRoot，避免仿真临时文件持续增长。

## 2026-08-28：native QoS 观测与端到端 deadline 基线

新增的 `c1_axi_shared_qos_monitor` 是默认关闭的 observation-only RTL seam。
它记录每个 client 的 AW/AR 等待、W/R/B response stall、accepted beat、
arbiter owner hold，以及 display underflow、frame cycles 和 deadline miss；
`csr_clear_stats_pulse` 提供同步清零控制。为保持主频，统计宽度默认为 24 bit，
owner maximum 使用标量 `max+owner_id`，独立 Artix-7 100 MHz proxy 为
`2268 LUT / 4000 FF / WNS +1.465 ns / TNS 0`。32-bit 变体不能直接沿用这组
时序数字。

真实 8×8 native BFM 已启用该 monitor（runner 加 `-SharedQosMonitor`），功能
仍通过，同时得到 tagged two-frame 聚合读窗口：

```text
C1_R1_PORTABLE_SOC_SHARED_QOS_STATS frame_count=2 last_frame_cycles=3446518 deadline_miss=2 underflow=2 read_busy=5358372 write_busy=12955 r4_stall=5338987 r5_stall=2205 ar4_wait=2365 ar5_wait=5339177 protocol=0 overflow=0 event_start=2 event_prefetch_done=3 event_new_done=2 event_swap=2
```

计时起点是 accepted boardless start，终点是
`display_prefetch_new_done_event`；raw `display_prefetch_done` 会把 current-pair
后台刷新混入窗口。`display_swap_event` 只表示 VSYNC ownership commit，当前可
早于 tagged done。结果确认当前 ID-less default fabric 的主要风险是 client-4
的长 R hold 导致 client-5 AR 等待约 5.34 M cycles，并伴随两次 display
underflow；它是 QoS/调度定位结果，不是 640×480 或 15 fps 证明。aggregate
字段现在可由 APB `0x108..0x12c` 读取（live、非原子多寄存器读；per-client
细节仍为层次化诊断）。下一步应在 response-FIFO 与 owner/epoch shell 候选配置
上复用同一统计接口，再决定是否切换 payload mux。

2026-08-28 的同条件 A/B `native_qos_fifo_tagged_twoframe_v1` 打开
`C1_DISPLAY_RESPONSE_FIFO` 后，`r4/r5` stall 从约 `5.34 M` 降到 `27/27`，
`ar4/ar5` wait 为 `194/234`，`read_busy` 约 `17 k`；但
`last_frame_cycles=3446518`、deadline/underflow=`2/2` 不变。该结果把下一步
边界明确为 client-6 tensor/compute-start/共享调度的 cycle attribution；FIFO
保持默认关闭，不能单独宣称达到 15 fps。

随后同一配置在 64×48 两帧上完成 `native_qos_fifo_tagged_64x48_twoframe_v2`：
`done=2/swaps=2/drops=0`、`frame_count=2`，`last_frame_cycles=5086618`，
`r4/r5 stall=4305/3499`、`ar4/ar5 wait=941/1005`，`read_busy=626599`，
`AW/W/B=80448/83328/80448`、`AR/R=96884/103766`，APB aggregate readback
通过。原 v1 在 5 M-cycle 固定观察上限处超时；测试台现在仅对大 shape 使用
20 M-cycle boundary guard，第二个 tagged terminal 约 90.48 ms 到达。由于
该 shape 仍把 SoC 图像缩小而保留固定 720p 请求窗，`underflow=3` 是尺度回归
诊断；native 640×480 display-only FIFO 预检的 `underflow=0/0` 才适合画质/供数
判断。上述 guard 不是硬件 watchdog 或帧率优化。
