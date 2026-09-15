# Ti60F225 / Efinity 2026.1 隔离资源评估

检查日期：2026-08-29。所有 map/PNR 由
`case1/scripts/run_efinity_ti60_resource_map_detached.ps1` 在独立的
`CREATE_BREAKAWAY_FROM_JOB` worker 中执行。Efinity 的 `out/`、`work/`、VDB、
布局布线数据库和 bitstream 均位于 `%TEMP%`，worker 结束时删除；仓库只保留
每次运行的 status、summary 和少量尾日志。

## 结论

1. Ti60 的 160 个 DSP 是当前 CNN 计算结构的第一硬约束。一个真实的
   `c1_dot8x8_requant_core`（8 个 8-lane dot + requant）已经占用 **80/160 = 50%**
   的物理 DSP；DW 叶级 wrapper 占用 **28/160 = 17.5%**。因此不能把多个完整
   dot core 静态并列复制来追求吞吐，必须依靠时分复用、权重/窗口缓存和共享
   MAC 阵列。
2. 片上存储不是当前算术叶的主要瓶颈：dot/DW 叶没有被识别为 EBR；显式
   4-bank 代理使用 8/256 memory blocks（3.12%）。实际 24 MiB tensor arena
   仍必须放 DDR3，不能误认为能放入 Ti60 的片上 RAM。
3. dot core 与 DW wrapper 的 core-only PNR 时序均远高于 100 MHz 需求；但这
   是无板级 IO/PLL/DDR/MIPI/HDMI 的隔离结果，不能作为整板 sign-off。
 4. 默认 `PACKED_AFFINE_CACHE=0` 时，完整 `c1_r1_microstyle_engine` 和
    `c1_r1_microstyle_cnn_top` 在 Efinity 2026.1.132.3.9 的 map 前端触发
    `EXCEPTION_ACCESS_VIOLATION`（退出码 `0xc0000005`）。同一批 dot/DW
    子模块已独立通过 map/PNR，故目前不能把该崩溃解释为算法或资源超限；
    另一个**可选** packed-affine wrapper 已通过 channel16/fullchannel 的
    map+PNR，且 22-stage packed top candidate 也已通过 map+PNR；这些仍不是
    full board sign-off。

## 实测结果

| 设计/运行 | Flow | Efinity 结果 | 资源/时序摘要 |
|---|---|---|---|
| `c1_ti60_ebr_probe` | map | PASS | 同步 256×128 RAM 模板：模块行 FF=128、RAM=7、DSP=0。用于确认 EBR 推断模板可用。|
| `c1_r1_c8_parameter_scheduler` | map + PNR | PASS | 模块行 FF=293、ADD=201、LUT=613、逻辑 DSP=1（DSP48）；PNR 物理 DSP=1/160=0.62%、RAM=0；final period=4.222 ns（236.855 MHz），WNS=+5.778 ns，WHS=+0.104 ns。参数读取控制本身不是资源瓶颈。|
| `c1_layer_command_decoder` | map；PNR 探针 | map PASS，PNR 失败于 IO | map 只得到 2 个 DSP48 原语（宽比较/验证逻辑）；原始宽 descriptor 端口的 PNR 再次触发 `AutoPinIOResourceExhaustion`，说明需用官方 wrapper/peri 约束，不能把裸宽 IO 当板级设计。|
| `c1_ti60_resource_proxy`（异步数组旧版） | map | PASS（方向性） | FF=9,467、LUT=20,086、RAM=0、DSP=64；日志有“read port is not synchronous”并退化到 logic memory，不能作为最终结构。|
| `c1_ti60_resource_proxy`（同步 EBR bank 版） | map + PNR | PASS | 模块行 FF=509、LUT=181、ADD=2,083、RAM=8、DSP=64；PNR RAM 8/256=3.12%、DSP 64/160=40.0%；final period=4.091 ns（244.439 MHz），WNS=+5.909 ns，WHS=+0.091 ns。|
| `c1_dot8x8_requant_core` | map + PNR | PASS | primitive `EFX_DSP24=64`、`EFX_DSP48=16`，逻辑 DSP=80；PNR DSP=80/160=50.0%，RAM=0；final period=5.271 ns（189.717 MHz），WNS=+4.729 ns，WHS=+0.091 ns。顶层模块行被 Efinity 报告省略，不能从空行推算 LUT 总量；8 个 dot 实例各约 DSP=8、LUT=161–167、FF=51–74。|
| `c1_dwconv3x3_c8_requant_core`（原始宽 IO） | map | PASS | primitive `EFX_DSP24=72`、`EFX_DSP48=16`，逻辑 DSP=88、无 EBR。|
| 原始 DW core | map + PNR | 失败于 IO | `AutoPinIOResourceExhaustion`；原始宽 tensor/weight 端口没有板级 pin/periphery 约束。这是 wrapper/接口边界问题，不是算术资源结论。|
| `c1_ti60_dw_leaf_wrapper`（小 IO、内部激励） | map + PNR | PASS | 模块行 FF=1,451、LUT=1,252、ADD=634；逻辑 DSP=44（36×DSP24+8×DSP48），但 Ti60 可分形 DSP 的物理 PNR 计数为 28/160=17.5%；RAM=0；final period=3.682 ns（271.592 MHz），WNS=+6.318 ns，WHS=+0.090 ns。|
| `c1_r1_microstyle_engine` | map | **工具崩溃** | 与完整顶层相同的 `libefx.dll/libvfc_database.dll` 访问违例；无可信资源数字。|
| `c1_r1_microstyle_cnn_top` | map | **工具崩溃** | 同上；无可信资源数字。|

### 2026-08-29 前端尺寸阈值探针（仅作兼容性诊断）

为把 full-top 失败拆成可复现的小门，在同一个
`c1_ti60_engine_small_wrapper.sv` 中只改变参数，不改变生产顶层的协议接线。
结果如下；`MAX_CHANNELS=8` 时 `MAX_GROUPS=1`，进入 16 时变为第二个 C8 group。

| wrapper | 关键参数（`REQUIRED_STAGES / PARAM_ARENA_BYTES / MAX_CHANNELS / MAX_WEIGHT_BYTES / MAX_PACKED_WEIGHT_TILES`） | run | map 结果 |
|---|---|---|---|
| `c1_ti60_engine_small_wrapper` | `1 / 256 / 8 / 144 / 4` | `e038f1327bc44f1597dcfcceecffef8e`（重复确认 `3bb80e904ad94b4abe6eece6d628a378`） | PASS |
| `c1_ti60_engine_fullweight_wrapper` | `1 / 16896 / 8 / 2592 / 72` | `0915ea848f0e4bb3a2f0108476663c72` | PASS（历史探针） |
| `c1_ti60_engine_channel16_wrapper`（默认 unpacked affine） | `1 / 16896 / 16 / 144 / 4` | `7f865f731a294e88b4ca89f44b191878` | `efx_map` 访问违例 |
| `c1_ti60_engine_channel24_wrapper`（默认 unpacked affine） | `1 / 16896 / 24 / 144 / 4` | `a5c9f2c2fab0443f87a2dbe645a1d11b` | `efx_map` 访问违例 |
| `c1_ti60_engine_fullchannel_wrapper`（默认 unpacked affine） | `1 / 16896 / 48 / 144 / 4` | `ab513c37129f4250b4fc3b1a90961713` | `efx_map` 访问违例 |
| `c1_ti60_engine_fullcache_wrapper` | `1 / 16896 / 48 / 2592 / 72` | `70922a4c264a480e8bf8d3a01b2a35da` | `efx_map` 访问违例 |
| `c1_ti60_engine_fullshape_wrapper` | `22 / 16896 / 48 / 2592 / 72` | `3e8a694a04d4400e95d9a1ee0c1a1047` | `efx_map` 访问违例 |

另一个使用保守 map 选项的 `channel16_noopt`（run
`7983a974ace04d4f9aab4722fb7e0fb2`）仍然复现同一退出，说明简单切换
retiming/packing 选项不能绕过该门。小 wrapper 与 full-weight wrapper 的组合对比
表明：**权重深度/arena 容量单独增加并不是充分触发条件**。早期从 8 到 16
时同时变化的 `MAX_GROUPS`、DW/affine 参数化数组和变量索引曾是优先怀疑对象；
随后 `c1_ti60_engine_groups2_wrapper`（run
`c262bc7717d54e2bad234fcc4b914bce`，固定 `MAX_CHANNELS=8`、仅
`MAX_GROUPS_OVERRIDE=2`）也通过 map，因此 `MAX_GROUPS` 本身不是充分条件。
后面的 packed-affine A/B 结果支持“unpacked affine 动态索引是主要兼容性
嫌疑”的方向，但仍没有隔离出唯一 RTL 语句，不能把“阈值”写成器件资源上限。

### 可选 packed affine-cache 分支（map + PNR）

`PACKED_AFFINE_CACHE=1` 将 bias/multiplier/shift 的小缓存改为固定宽度 packed
向量和切片访问；它只用于板卡无关兼容性诊断，默认值仍为 `0`，尚未替换
生产 top。两次独立 map+PNR 均通过：

| wrapper | 关键参数 | run | 最终 timing（C4） |
|---|---|---|---|
| `c1_ti60_engine_channel16_packed_affine_wrapper` | `REQUIRED_STAGES=1`、`MAX_CHANNELS=16`、`MAX_GROUPS_OVERRIDE=1`、`MAX_WEIGHT_BYTES=144`、`PACKED_AFFINE_CACHE=1` | `407ec906b61e4066b57fcdd3db6fd46f` | final period `2.525 ns`，**396.040 MHz**，WNS `+7.475 ns`，WHS `+0.196 ns` |
| `c1_ti60_engine_fullchannel_packed_affine_wrapper` | `REQUIRED_STAGES=1`、`MAX_CHANNELS=48`（自然 6 groups）、`MAX_WEIGHT_BYTES=144`、`PACKED_AFFINE_CACHE=1` | `12e273493bf3452caef3b6b0591ad02d` | final period `3.115 ns`，**321.027 MHz**，WNS `+6.885 ns`，WHS `+0.167 ns` |

channel16 packed probe 固定了单 group 以隔离 affine 表示；fullchannel packed
probe 则覆盖 48 通道/6 groups，因而对“第二个及后续 C8 group”的兼容性证据更强。
这两个 wrapper 仍使用内部 stimulus、小 IO，不包含 Sapphire/DDR/视频 IP，也不
代表完整 22-stage CNN 的资源或 15 fps 结论。默认/packed 功能 A/B（含 stage21、
trained artifact）现已完成：Icarus `run_iverilog_stage1_handoff.ps1 -FullStage21
-PackedAffine` 与 detached xsim `run_r1_stage1_handoff_xsim_detached.ps1
-FullStage21 -PackedAffine` 均 PASS，marker 与默认一致
（`operands=896/results=836/final=64/stage_done=22/abort=0`；xsim run
`5e234f2e1b87483b8cd4c47bb9e3d667`）。packed 仍是可选候选，默认生产参数不变；
full-board/DDR3/15-fps sign-off 仍 OPEN。

### 22-stage packed CNN top candidate（map + PNR）

`c1_ti60_cnn_top_packed_wrapper` 保留 `c1_r1_microstyle_cnn_top` 的 22-stage
dispatcher、descriptor-cache 和完整参数化（`PARAM_ADDR_W=11`、
`PARAM_ARENA_BYTES=16896`、`MAX_CHANNELS=48`、`MAX_WEIGHT_BYTES=2592`），仅将
`PACKED_AFFINE_CACHE=1` 传入 top。run
`e9da5ca074f34939974e794ffd40ee81` 在 Ti60F225/C4 上 map+PNR PASS：final
period `2.296 ns`、**435.540 MHz**，WNS `+7.704 ns`、WHS `+0.109 ns`。

该工程是板卡无关的窄 stimulus 壳，保留 stimulus/observe 只是防止 mapper 把
协议完全裁掉；因此 PNR/模块资源计数会受壳层优化影响，不能当作最终 Ti60
板级 LE/FF/EBR/DSP 数字。它证明 packed affine 使 22-stage top candidate
能够完成一次 Efinity map+PNR timing gate，但真实 Sapphire/DDR3/MIPI/HDMI、
periphery/pin、全板资源和 15 fps 仍为 OPEN；默认生产 top 的
`PACKED_AFFINE_CACHE` 仍为 `0`。

### Portable SoC packed-affine 窄壳探针（仅 map）

为确认 packed 分支在完整板卡无关 SoC 层级是否能进入 Efinity 前端，新增
`c1_ti60_portable_soc_packed_wrapper`：它以 8×8 小帧和窄 stimulus/observe 壳
实例化真实 `c1_r1_portable_soc`，显式传入 `PACKED_AFFINE_CACHE=1`，并保持所有
板级时钟、DDR、视频和 pin/periphery IP 在层级之外。60 s 和 180 s 的独立 map
均未出现此前 `libefx.dll/libvfc_database.dll` 访问违例或 HDL unknown-module
错误，但完整 hierarchy 在 180 s 内未结束，最终由 runner 超时；因此没有可信的
LE/FF/EBR/DSP 数字，也没有运行 PNR。该结果只能说明 packed portable 壳未立即触发
已知前端崩溃，并量化其 map 复杂度高于 CNN-only 壳；不能当作资源或时序签核。
运行 `status.json`/failure tail 保留在
`logs/efinity_resource_runs/2473d08f8fe948df8d0056aeef857761/`（该超时 run 没有
资源 summary）；Efinity 临时 work tree 已由 worker 清理。

上述默认 unpacked/full-top 探针的失败均发生在 `efx_map.exe → libefx.dll/libvfc_database.dll`，没有 HDL
编译错误，也没有可信 LE/FF/EBR/DSP 报告；日志中的 `$error` synthesis warning
和冗余 descriptor warning 只是伴随告警。结论应写成“Efinity 2026.1 前端兼容性
阻塞，full-top 资源仍 OPEN”，而不是“设计超出 Ti60 资源”。本轮尝试过的固定
深度/扁平化/更激进 mux 变体未作为生产修复或资源证据保留；packed affine
仅作为 `PACKED_AFFINE_CACHE=1` 的可选候选。当前生产 RTL 默认参数仍为
`PACKED_AFFINE_CACHE=0`，以已通过 stage-21 及 cache/overlap 功能回归的基线为准。

运行目录（均为小型摘要，不含 Efinity work tree）：

- proxy：`logs/efinity_resource_runs/c7e43cf4430a4f76a7071c899a505b27/`
- dot：`logs/efinity_resource_runs/26e69f9662ec49c78d7679d9084166ff/`
- DW map：`logs/efinity_resource_runs/865b1a7913d040bca674ef05c43b046b/`
- DW wrapper：`logs/efinity_resource_runs/ded31bd398ce4d7395fcc73d033269ac/`
- scheduler：`logs/efinity_resource_runs/be1cc9f96e904ecda5d1973d5864744f/`
- decoder PNR 边界：`logs/efinity_resource_runs/e59371c7f3ca4283b8f2a6458fc040a2/`
- engine 失败焦点：`logs/efinity_resource_runs/f10f0f0537824619a0c16289a7eb3c70/`
- CNN top 失败焦点：`logs/efinity_resource_runs/b6de374e394640c295f524fd5dd69ecc/`
- packed affine channel16：`logs/efinity_resource_runs/407ec906b61e4066b57fcdd3db6fd46f/`
- packed affine fullchannel：`logs/efinity_resource_runs/12e273493bf3452caef3b6b0591ad02d/`
- packed CNN top candidate：`logs/efinity_resource_runs/e9da5ca074f34939974e794ffd40ee81/`

## 如何解读这些数字

### DSP 的“逻辑数量”和“物理数量”不同

map 报告中的 `EFX_DSP24/48` 是 RTL 运算原语数量；PNR 的 DSP Blocks 是经过
Ti60 fracturable DSP packing 后占用的物理块。DW wrapper 的 44→28 正是这种
打包差异。资源预算必须采用 PNR 物理块，逻辑数量只用于解释算术结构。

### 片上 RAM 与外部 DDR

`c1_ti60_resource_proxy` 的 4 个同步 bank 只验证了“可被 Efinity 推断成 EBR”
的写法，8 个 memory blocks 不等于 24 MiB tensor 存储。赛题的三块 8 MiB
tensor bank、五个 640×480 XRGB framebuffer 合计约 29.86 MiB，必须由 DDR3
控制器管理；QSPI 8 MiB 只能放 bitstream/少量启动数据，不能存整套 arena。

### RISC-V/Sapphire 的预算应单独留出

Efinity 安装目录的 Sapphire RV32 官方特性页给出的 Ti60F225 C4 典型基线
（文档标注 Efinity 2025.2）为：

- cacheless + external memory：Logic/Adders 7,166、FF 7,672、Memory 44、
  DSP48 4、`fMAX` 382 MHz；
- cached + external memory：Logic/Adders 7,560、FF 8,110、Memory 56、
  DSP48 4、`fMAX` 401 MHz；
- Lite + external memory：Logic/Adders 3,311、FF 2,789、Memory 14、DSP48 0、
  `fMAX` 383 MHz。

这些是官方配置表的参考值，不是本次 2026.1 map 实测；来源为安装目录
`D:\ELS\Efinity\2026.1\ipm\ip\efx_soc\efx_soc\ipm\doc\topics\riscv-saxon-efx-features-sapphire.html`。
将它们与本次 CNN 叶级数字叠加时，应保留 DDR/AXI/PLIC/UART/PLL 和板级 IO
余量，不能只做简单的 LUT 相加。

### 一个有用但非 sign-off 的 DSP 预算包络

若选择“cached Sapphire + 1 个 dot/requant 叶 + 1 个 DW 叶”并让两条算术路径
同时常驻，按本次 PNR 物理块做上界估算：

`4 (Sapphire) + 80 (dot) + 28 (DW) = 112 / 160 = 70% DSP`。

再加 scheduler 的 1 个 DSP48 和 decoder 的少量宽比较原语，仍约在 72% 左右，
但最终数值会受 Efinity packing、时分复用和综合裁剪影响。这个包络说明设计
还有余量，却不支持“再复制一个 dot core”：在上述同时常驻假设下，第二个 dot
core 会把理论包络推到约 192/160（120%），即使关闭 DW 并不计其他逻辑也已达
164/160（102.5%）。更稳妥的做法是保持一个 dot
阵列、让 engine 在 Conv/DW/Residual 阶段复用，并把性能投入到 DDR burst、
多 outstanding 和 cache hit rate。

片上 memory 的类似包络只能作为风险检查：官方 cached Sapphire external-memory
基线是 56 blocks，本次代理是 8 blocks；即使简单相加也只有 64/256，但真实
engine 的参数/窗口缓存尚未通过 full-top map，DDR controller、MIPI/HDMI FIFO
和 generated IP 还会增加 memory blocks。因此不能用 64/256 当最终结论。

## 对当前架构的工程含义

- 目标频率 100 MHz 本身不是 dot/DW 算术叶的时序风险；真正风险是共享 DDR
  fabric、AXI burst/多 outstanding、跨时钟 FIFO，以及加入 Sapphire/DDR PHY/
  MIPI/HDMI 后的布局拥塞。
- `c1_dot8x8_requant_core` 已占一半物理 DSP，适合保持单实例并由参数/窗口
  调度器复用；若需要更多吞吐，应先提升每个 DSP 的有效利用率（packing、
  output FIFO、burst/cache），而不是复制第二个 8×8 core。
- DW 路径的物理占用较低，但它与 dot 路径若同时常驻，仍需检查共享加法、
  requant 和路由拥塞；当前 engine 是时分复用语义，不能把两个叶级数字直接
  当成最终并行设计的总量。
- 原始 DW 宽 IO 的 PNR 失败说明“板级 wrapper/接口收敛”是独立门槛。最终
  工程必须使用官方 DDR/MIPI/PLL/IP 生成的 peri/pin/SDC，再把窄 IO 的核心
  接入 wrapper；不能用 map-only 叶级数字代替 board project。

## 下一步门槛

1. 在 Efinity IP Manager 生成 Ti60F225_devkit 的 Sapphire RV32（建议先单核、
   APB、UART、片上 RAM；再打开 DDR AXI），保存官方生成的 `.xml/.peri.xml/.pin`
   和 SDC 到 disposable staging。
2. 对 `c1_r1_microstyle_engine` 做二分映射：先用已通过的
   `PACKED_AFFINE_CACHE=1` 作为**候选** full-top 配置，再逐步加入 descriptor
   decoder、参数缓存和多 bank 数组；默认 `PACKED_AFFINE_CACHE=0` 不改变。若
   仍失败，再把 `$error` 断言移到仿真宏、把 `ram_style` 改成 Efinity 支持的同步
   RAM 模板，以定位当前 `libefx` 前端崩溃的最小复现。
3. 获得板卡 revision 的真实 pin/DDR 参数后，才运行 `interface → map → pnr →
   sta/compile`；届时重新计算 Sapphire、DDR、视频 IP 和 Case-1 的合计资源。
4. 通过板前 100 MHz/DDR calibration 和小帧 loopback 后，再测 burst、多
   outstanding、cache refill 与 15 fps；当前隔离 PNR 只证明“核心可放置且有
   正时序余量”。

## 复现命令

```powershell
# 同步 EBR/64-MAC 代理（map + PNR）
& .\case1\scripts\run_efinity_ti60_resource_map_detached.ps1 `
  -DesignName c1_ti60_resource_proxy -TopModule c1_ti60_resource_proxy -RunPnr

# 真实 dot/requant 叶（map + PNR）
& .\case1\scripts\run_efinity_ti60_resource_map_detached.ps1 `
  -DesignName c1_ti60_dot_core -TopModule c1_dot8x8_requant_core `
  -ProjectInPlace -RunPnr

# 小 IO DW 叶 wrapper（map + PNR）
& .\case1\scripts\run_efinity_ti60_resource_map_detached.ps1 `
  -DesignName c1_ti60_dw_leaf_wrapper -TopModule c1_ti60_dw_leaf_wrapper `
  -ProjectInPlace -RunPnr

# 引擎/完整顶层当前作为一次性兼容性探针；当前版本会记录工具崩溃，
# 不要把失败重跑当成资源结果。
& .\case1\scripts\run_efinity_ti60_resource_map_detached.ps1 `
  -DesignName c1_ti60_engine -TopModule c1_r1_microstyle_engine -ProjectInPlace
```
