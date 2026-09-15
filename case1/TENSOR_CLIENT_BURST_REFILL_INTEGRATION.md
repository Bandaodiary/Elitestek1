# Tensor client-6 burst/refill 集成阶段说明

更新时间：2026-08-28

本文记录赛题一当前“板前可完成”的下一阶段：只改造 client-6 的 tensor
cache refill 侧，不改变默认 SoC 的兼容路径，也不把小规模仿真结果写成
640×480@15 fps 达标结论。

## 1. 当前架构

```text
logical tensor request
          |
          v
  c1_tensor_window_cache_burst_axi_client
       |                         |
       | cacheable 3×3 read      | write / ordinary read / fallback
       v                         v
  C8 line cache             legacy 64-bit bridge
       |                         |
       +------ registered owner-+
                       |
                 one ID-less AXI4-128 slot
```

cacheable read 在 stage geometry 校验完成后进入三行 C8 cache；一次行 miss
由 exact-count shell 转成连续 row command，再由 128-bit burst reader 完成
pack2 和多 outstanding 的 AXI 服务。写请求、非 cacheable 读、配置拒绝和
运行期 cache error 仍走既有 one-beat compatibility bridge。owner 寄存器保证
两个子路径不会同时驱动同一条 ID-less AXI slot，响应仍按本地 logical request
顺序返回。

这不是完整的 cross-request MLP：当前 adapter 一次只呈现一个 logical request，
共享 fabric 也仍是 serial ID-less owner。因此本阶段的确定性收益是“每次 row
refill 的 AXI beat 数和 owner-switch 次数下降”，不是把七客户端 fabric 变成
带 AXI ID 的乱序 DDR 控制器。

## 2. 已闭合的维护边界

本阶段专门覆盖了容易形成死锁的边界，而不只测试正常 cache hit：

| 场景 | 约束与处理 |
|---|---|
| miss 尚未被 line cache 接收 | wrapper 先预约 `OWNER_BURST`，保持上游 `VALID`；若 fence 到达，仍保留 tap 并在 child 排空后桥接重放 |
| `REFILL_REQ` 已可见但 exact reader 尚未接收 command | shell 在 fence 同周期把可见 command capture 到 `cmd_hold`，旧 epoch 被拒绝并产生 exact-count poison suffix，避免停在 `ST_REFILL_REQ` |
| pending tap 处于 abort/flush | `s_req_ready` 与 `tap_valid` 同时禁止，避免上游看到虚假的 READY 后撤掉请求；响应侧仍可排空 |
| front request 在 maintenance 边沿尚未被 owner 接收 | `front_drain_q` 保留该请求，child quiescent 后只通过 legacy bridge 接收一次 |
| bridge response 已到但本地 response 被 back-pressure | `abort_done/flush_done` 等待 local response 被消费，不提前宣告 fence 完成 |
| 预期取消的 refill | `CANCEL_IS_PROTOCOL_ERROR=0`（默认）把取消作为 refill-data error，不把阶段永久毒化；结构性 sideband/LAST 错误仍保持 protocol fault |

`ready/valid` 的前提是标准协议：上游在 `VALID && !READY` 时必须保持请求及
sideband。wrapper 的 pending-owner 逻辑不依赖上游撤回请求；若上游不遵守该
协议，不能由本模块恢复丢失的 logical request。

## 3. 参数和启用方式

默认 SoC 保持：

```text
ENABLE_TENSOR_BURST_REFILL = 0
```

只有实验构建显式设为 1 才实例化新 client。取消策略也已显式参数化：

```text
TENSOR_BURST_CANCEL_IS_PROTOCOL_ERROR = 0
```

需要严格沿用历史 sticky protocol-error 语义时才设为 1。读侧的主要可调参数
仍位于 `c1_tensor_window_cache_burst_axi_client`：

```text
BURST_BEATS                  = 16
BURST_READER_MAX_OUTSTANDING = 4
BURST_CMD_FIFO_DEPTH         = 2
BURST_REQ_FIFO_DEPTH         = 32
BURST_RSP_FIFO_DEPTH         = 2 * BURST_BEATS * BURST_READER_MAX_OUTSTANDING
BURST_REFILL_SKID_DEPTH      = 2
```

建议在 Efinity 前先保持上述保守配置；增大 burst 或 FIFO 会增加 EBR/布线和
共享 owner 持有时间，不能只依据 xsim 周期选择。

## 4. 板前验证证据

### 4.1 standalone contract BFM

独立 TB `tb_c1_tensor_window_cache_burst_axi_client.sv` 覆盖：

- 首次 miss 的 packed refill 和同一 row hit；
- legacy read、AW/W/B write 以及局部 response stall；
- AR blocked 的 flush-before-AR；
- AR blocked 的 abort-before-AR；
- 已发出部分 burst 后的 flush/abort；
- bridge response 已到但 local response 暂停；
- AR/R gap、AW stall、W stall 和 payload stability。

最终 detached xsim marker：

```text
C1_TENSOR_CACHE_BURST_AXI_CLIENT_PASS
burst_ar=4 single_ar=5 beats=13 aw/w/b=2/2/2
flush_done=2 abort_done=3 ar_stall=3 r_stall=0 r_gap=21
aw_stall=1 w_stall=2 cycles=265
```

该 TB 的工具运行通过 WMI detached worker 完成；worker 退出后私有 xsim
目录删除，只保留 status 和短 stdout/stderr。

取消策略参数透传后的 exact shell 原有回归也保持通过：

```text
C1_WINDOW_LINE_CACHE_C8_EXACT_BURST_SHELL_PASS responses=4 refills=3 words=24
ar=5 beats=10 flush=1 epoch=1 cancel_req=3 cancel_source=3
cancel_drain=3 cancel_synthetic=5 cancel_unified=8 cycles=143
```

### 4.2 portable SoC shape/elaboration

启用 `-SharedQosMonitor -TensorBurstRefill -DisplayResponseFifo` 的 64×48
顶层 compile-only gate 通过：

```text
C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS frame=64x48
```

同一参数组合的 640×480 compile-only gate 也已通过：

```text
C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS frame=640x480
```

这两项只证明源码可编译、参数可展开和 native 几何边界可接受；没有启动
640×480 长帧 xsim，也没有提供 Efinity 资源/时序或 15 fps 证据。

此前同一可选分支也完成了 8×8 两帧和 64×48 两帧 detached full BFM。64×48
两帧的代表性统计为：

```text
done=2 swaps=2 drops=0
AXI AW/W/B=80448/83328/80448
AXI AR/R=60165/84187
frame_count=2 last_frame_cycles=5086618
protocol=0 overflow=0
client-6 AW/W/B=80256/80256/80256 AR/R=59664/76800
```

与同条件 legacy cache client 的 `client-6 AR/R=96384/96384` 相比，当前
可选分支把 client-6 的 AR 数减少约 38.1%，R beat 数减少约 20.3%。但是
端到端 `drain_cycles` 和 `last_frame_cycles` 仍由共享 ID-less display/其它
客户端路径主导，不能据此声称 15 fps 已解决。

## 5. 资源和时序判断

目前没有易灵思/Efinity 原生综合结果，故不报虚假的 LUT/FF/EBR 数字。可用的
板前判断是：

1. C8 payload cache 本身已有独立 proxy 结果，最大行配置约占 7.5 个 BRAM
   tile；burst reader 另外需要 response FIFO、request/command FIFO 和少量
   计数器。实际 EBR 映射取决于易灵思 RAM 深度/宽度拼接，必须以目标器件综合
   为准。
2. 新 wrapper 没有新增 DSP；主要代价是 128-bit response FIFO、burst reader
   outstanding bookkeeping、owner/maintenance 控制和较宽 AXI mux。
3. `BURST_BEATS=16`、reader outstanding=4 是合理的首个资源/时序工作点；
   在共享 fabric 中继续增加 outstanding 可能只延长 client-6 owner hold，反而
   加剧 display HOL。
4. shell 内的 shift/add row-base、命令 capture 和 ready/valid 边界已通过
   Vivado xvlog/xelab；这不等于 100 MHz Efinity timing closure。真正 signoff
   仍需 EBR inference、目标器件 placement、AXI/DDR controller latency 和
   native 640×480 traffic 一起测量。

### 5.1 full-top proxy 的资源闸门（2026-08-28）

为避免只用单体 wrapper 估算，已用 125 个 RTL 源文件对真实
`c1_r1_portable_soc` 做了 640×480、Artix-7 `xc7a200tsbg484-1` 的 detached
Vivado 综合。该 proxy 没有 P&R，也不是 Ti60/Efinity sign-off，但足以判断
optional client 是否会把 full top 推过资源红线：

| 配置 | LUT | FF | Block RAM tile | DSP | WNS/TNS (100 MHz) | 状态 |
|---|---:|---:|---:|---:|---:|---|
| burst + logical response FIFO(128) | 80,791 | 39,369 | 32 | 100 | −52.20 / −175,089 ns | timing failed，资源也超过 Ti60 LE |
| burst + beat-record FIFO(64) | 48,411 | 30,950 | 32 | 100 | −52.55 / −191,612 ns | timing failed，资源 proxy 低于 62,016 LE |
| 单 client wrapper logical（对照） | 35,718 | 10,806 | 7.5 | 0 | −0.319 / −0.598 ns | timing failed |
| 单 client wrapper beat（对照） | 2,852 | 2,394 | 7.5 | 0 | −0.159 / −73.1 ns | timing failed |

full-top logical/beat run 分别记录在
`logs/portable_soc_tensor_burst_proxy_runs/portable_soc_tensor_burst_logical_v4`
和 `.../portable_soc_tensor_burst_beat_v1`；worker 只留下 summary 与短报告，
综合树已清理。`fanout_limit=64` 的无功能 A/B 与 logical 单体完全相同，且
Vivado 2023.1 报告该开关 deprecated，不能当作 RTL 时序改善。

beat mode 的 full-top LUT 相当于 Ti60 62,016 LE 的约 78%（Xilinx Slice LUT
与 Efinix LE 不是一一对应，只作风险筛查），因此它目前是唯一值得带到 Efinity
做早期映射的资源候选；logical mode 可直接淘汰。full-top WNS 的主要来源
是综合阶段的长 core-clock 数据锥；未放置 clock 网络段本身只有亚纳秒量级，
不能解释 −52 ns。因此不能用这个负 WNS 直接推断板上最终频率，但也不能把它
写成“时序已通过”。`fanout_limit=64` 的无功能 A/B 未改变网表，且 Vivado
2023.1 已将该开关标为 deprecated；在真正 Efinity 约束前不再沿这条路径
盲目加扇出约束，下一项先做 descriptor 校验锥的受控对照并重新跑功能回归。

full-top beat mode 的 native BFM 也已通过：8×8 两帧和 64×48 两帧均为
`done=2/swaps=2/drops=0`、`protocol=0`，64×48 的
`AR/R=60165/84187`、`last_frame_cycles=5086618` 与 logical 分支相同。
这说明 beat mode 只改变 response FIFO 的存储布局，不改变当前 serial
ID-less fabric 的端到端瓶颈；它仍不是 15 fps signoff。

### 5.2 时序归因与 place/route sanity gate（2026-08-28）

随后对 beat full-top 运行了一次可选 `-PlaceRoute` sanity gate
（`portable_soc_tensor_burst_beat_place_v1`）。由于 boardless proxy 没有真实
封装管脚/时钟 LOC，Vivado 在 `place_design` 的 IO Clock Placer 阶段因顶层
AXI/clock I/O 未放置而退出；这次失败不能用来判断板上时序，也没有保留大工程树。
日志中还出现已有的组合环 DRC（`pipeline_busy_reg`），应在真正板级约束前单独
修复/确认，不能用 `ALLOW_COMBINATORIAL_LOOPS` 掩盖。

综合 timing path 的归因结果相反：最差 endpoint 为
`u_tensor_adapter/descriptor_cache_reg[0][35]/CE`，logical/beat 分别约
110/112 个逻辑级（98/99 个 CARRY4），数据到达约 −64 ns；core clock 未放置
网络段仅约 0.439 ns，故不是 −52 ns 的主因。当前安全的下一项是只在 proxy
中打开 `STRICT_DESCRIPTOR_VALIDATION=0` 做对照（runner 的
`-RelaxedDescriptor`），验证是否移除 64-bit tensor-size/ABI 校验锥；正式
产品配置仍保持 strict=1，仿真中的 relaxed descriptor fatal guard 不变。

## 6. 拿到板卡后的最短路径

1. 先以 `ENABLE_TENSOR_BURST_REFILL=0` 下载默认兼容构建，确认相机、显示、
   DDR 和 APB 基线。
2. 只打开 burst client，保持 display FIFO 等其它 optional mode 不变，先用
   BRAM/DDR loopback 检查 ARLEN、4-KiB 边界、R-last、数据 lane 和 abort/flush。
3. 读取 QoS monitor 的 client-6 `AR/AW wait`、owner hold、R stall、underflow
   和 tagged frame deadline；比较 legacy 与 burst A/B，而不是只看总 fps。
4. 若 client-6 仍是瓶颈，再考虑 tile scheduler/真正的跨请求 outstanding；
   若 display 或 MAC starvation 主导，则不要继续扩大 burst FIFO。
5. 只有 native 640×480 长帧、真实 DDR controller 和 Efinity timing 均通过，
   才把该开关晋升为候选比赛配置。

## 7. 已知未完成项

- top-level optional branch 的 `flush_req` 当前仍绑为 0；板级 frame manager
  需要先定义 tagged flush/epoch 语义，再接入真实 flush 广播。
- 共享 fabric 仍是 ID-less serial owner，尚未获得跨 burst 的真实并行服务。
- wrapper 暂不把 `refill_done_error` 作为独立软件 CSR；结构性错误通过
  `cache_error/cache_error_code`，预期取消通过 exact shell 的 refill-done
  error 诊断观察。板前若需要可追踪性，应在稳定协议后再增加窄诊断寄存器。
- 未做完整 Efinity 综合、功耗、DDR PHY 校准或板上逻辑分析仪验证。

## 8. 2026-08-28 REGISTER_ABORT_RESET A/B 结果

native resize PASS；native 8×8/64×48 abortreg 均 PASS，`protocol=0`。proxy
baseline 为 `48192 LUT/31227 FF/32 BRAM/88 DSP`、WNS/TNS
`-5.900/-67577.578`；abortreg v2 为 `48211 LUT/31237 FF/32 BRAM/88 DSP`、
WNS/TNS `-5.416/-66644.070`，`timing_met=false`。当前剩余最差路径为 reset
相关的 descriptor decoder path。

## 9. 2026-08-28 PIPELINED_DECODER_VALIDATION

decoder pipeline 已在 engine→cnn_top→system_bridge→portable_soc 参数化，默认为 0。
MicroStyle engine xsim PASS marker：`C1_R1_MICROSTYLE_ENGINE_PASS ... outputs=836 ... first_run_cycles=30570`。
完整 8×8 两帧组合（burst+beat+address+adapter descriptor pipeline+narrow+abort reset+QoS+display FIFO+decoder pipeline）PASS：
`done=2/swaps=2/drops=0`、`protocol=0`、`last_frame_cycles=3446518`、
`r4/r5 stall=29/29`、`ar4/ar5 wait=202/244`。

proxy `tensor_burst_beat_pipelined_split_addr_abortreg_decoderpipe_v1` 为
`47493 LUT/31441 FF/32 BRAM/88 DSP`、WNS/TNS `-5.362/-66042.227 ns`，
`timing_met=false`；abortreg v2 对比为 `48211/31237/-5.416/-66644.070`。
配置阶段每 descriptor 固定增加两拍，运行期协议不变，仍非 timing signoff。
