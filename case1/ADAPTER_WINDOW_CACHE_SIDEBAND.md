# MicroStyle tensor adapter 的 window-cache sideband

`rtl/cnn/c1_r1_microstyle_tensor_adapter.sv` 提供一个默认关闭的可选接口，
用于把现有逐 C8-word 请求接到 `c1_tensor_window_cache_seam`。缓存本体仍在
adapter 外部；portable SoC 的外部端口、原 64-bit memory bridge 和 engine
ABI 不变，但其内部新增 `ENABLE_TENSOR_WINDOW_CACHE` 可选 generate。

## 兼容模式

- `ENABLE_WINDOW_CACHE_SIDEBAND=0`（默认）：`ST_STAGE_LOAD` 与原实现一样
  直接进入 `ST_OPERAND_BEGIN`，`cache_stage_start_valid` 恒为 0，不等待
  `cache_stage_start_ready`。旧状态的枚举值也保持不变。
- `ENABLE_WINDOW_CACHE_SIDEBAND=1`：每次 `ST_STAGE_LOAD` 锁存 descriptor 和
  bank 选择后，进入独立 `ST_CACHE_CONFIG`。adapter 保持 stage payload，
  直到 `cache_stage_start_valid && cache_stage_start_ready`，随后才发出该层
  第一个 operand read。

stage payload 为：

```text
cache_stage_enable     = opcode is Conv3x3 or DWConv3x3
cache_stage_base_addr  = tensor_base + input_bank * TENSOR_BANK_BYTES
cache_stage_width      = descriptor input width
cache_stage_height     = descriptor input height
cache_stage_groups     = ceil(input channels / 8)
```

即使某层不可缓存也会在启用模式下发送一条 stage 配置，其中
`cache_stage_enable=0`，让下游 seam 明确切换到安全旁路状态。

## 每个 memory request 的 metadata

原 `mem_req_*` payload 增加：

- `mem_req_cacheable`；
- signed 17-bit `mem_req_cache_x/y`；
- `mem_req_cache_group`。

只有 Conv3x3/DWConv3x3 的九个 input tap read 标为 cacheable。source tensor
写、中间 tensor 写、Conv1x1、upsample、residual read 均为 0。
`cache_x/y` 是卷积窗口的未钳位坐标（边界可为 -1），而 `mem_req_addr` 仍
指向 SAME_REPLICATE 钳位后的物理 C8 word。group 与当前 input group 一致。
seam 接受请求时自行钳位并保存内部索引，同时核对物理地址；这与 adapter
保留未钳位 signed 坐标的语义并不冲突。

### 可选的已寄存物理坐标

为评估 cache 侧边界比较的时序代价，顶层新增
`PRECLAMPED_TAP_COORDS`（默认 `0`，不改变上述兼容语义）。显式设为 `1` 时，
adapter 在现有 request-Q 边界把 Conv3x3/DWConv3x3 的 tap 坐标按同一份
`tap_source_x/y_fn` 计算并寄存为**已钳位物理坐标**，再沿 burst/exact-shell
接口传播；因此 cache 侧可以省掉重复的 width/height 比较。该模式只对通过
descriptor/shape 校验的窗口请求生效，非法或非窗口请求仍走原有保护路径，且
不增加 ready→state 的组合回路。仿真在 opt-in 时会断言握手请求确实满足
`0 <= x < width`、`0 <= y < height`，以防把未钳位 signed sideband 误接入。

板前验证 `preclamped_registered_tap_8x8_twoframe_v1` 已通过两帧生命周期、
ownership、AXI 背压和 APB QoS 检查，并与 fixed baseline 保持完全相同的
`AW/W/B=1704/1736/1704`、`AR/R=1451/2970` 及 `drain_cycles=3464876`。
这只证明功能/流量等价，不是时序或 15 fps 签核。早期
`preclamped_tap_8x8_twoframe_v1` 曾直接对 signed logical 坐标做 sign-only
clamp，虽通过生命周期 marker 却产生 `AR/R=1463/3042`（client-6
`1280/1672`），因语义/流量不一致已拒绝，不得作为优化结果引用。

metadata 与地址、write/data/strobe 一起由 request 寄存器保持。仿真断言会
检查 stalled request 不得撤回且全部 payload 不变、非 3x3 请求不得误标
cacheable、read/write strobe 与 8-byte 对齐合同，以及 stalled stage 配置不会
在非 abort 条件下改变或撤回。

## 接入映射

adapter 的 `cache_stage_*` 可直接映射到 cache seam 的 `stage_start_*`；
adapter 的 `mem_req_cache*` 映射到 seam 的 `s_req_cache*`。启用参数前必须
实际连接 `cache_stage_start_ready`，否则 adapter 会有意停在
`ST_CACHE_CONFIG`。全局 abort 可以取消尚未握手的 stage 配置；已经呈现的
memory request 仍遵守原有 drain 语义。

## 已验证基线

当前默认关闭模式 run `1f59974a3dd14fe5afa8c94e8f3c668c` 使用原
self-checking adapter TB 完成 detached xvlog、xelab 和 xsim 回归；原
22-stage 请求/响应、随机回压、abort drain 和错误路径保持通过。启用模式
run `a3fcee365dde4361a3a1bb31bbd64287` 由
`sim/tb_c1_r1_microstyle_tensor_adapter_cache_sideband.sv` 在不复制或
改变旧 stimulus 的前提下复用该 TB，并令每个 stage handshake stall 两个
周期。专项回归覆盖 22 条配置、44 个配置 stall、1512 个 cacheable 3x3
read、266 个 bypass read，以及 signed tap 坐标到钳位物理地址的逐请求核对。
运行命令为：

```powershell
& .\scripts\run_r1_microstyle_tensor_adapter_xsim_detached.ps1 -CacheSideband
```

sideband 与 optional-top 结构接线已经完成。补入 `tensor_cache_busy` 的软件
quiescence fence 后，默认/缓存启用顶层 smoke 为
`7e76332ea7044371af9efcf39809258a`/`30658446f3d4442fb7f7a442bd5f9fe2`；
后者检查 seam 展开、CSR、idle/error/quiescent、cache busy→`system_busy`
fence 与无虚假 AXI。完整 22-stage 动态流量又分别通过 64-bit seam BFM
`9212d5a042ae4d9895a3162869e3815f` 和真实 bridge+AXI128 BFM
`be4977424d9d484e80340f970d9904d0`，覆盖 stage/hit/miss/refill、旁路、错误、
abort 和 AXI 五通道背压；当前源码顶层 shape-scaled gate 矩阵
`c1_8x8_gate_20260825`（8×8 单帧）、`c1_16x8_two_gate_20260825`（16×8 两帧）、
`c1_64x48_single_gate_20260825`（64×48 单帧）和
`c1_64x48_two_gate_20260825`（64×48 两帧）均覆盖 cache client-6→七客户端仲裁→DDR
以及 capture/display 争用；两帧均确认 `swaps=2 drops=0`。64×48 两帧又完成
`done=2 descriptors=44 stage_mask=1fffff display_done=1`、
`AW/W/B=80448/83328/80448`、`AR/R=96793/102295`；gate 同时验证 display
prefetch quiescence gate，避免共享 ID-less AXI 读响应被 display reader 反压时饿死
foreground CNN。该 gate 不冻结 raster，当前 TB 尚未把 `display_underflow_event`
纳入 PASS；上板前仍需 display FIFO/独立读端口或 AXI ID/QoS 方案。尚未覆盖
burst/multi-outstanding、native frame 和长帧 QoS；顶层 `flush_req` 当前暂绑 0。
