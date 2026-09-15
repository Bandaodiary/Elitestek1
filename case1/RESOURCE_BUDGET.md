# Ti60 资源、吞吐与代理综合预算

2026-09-15模型侧新增：[算法候选审计](review/CNN_ALGORITHM_REASSESSMENT_20260915.md)比较14种复用当前算子的结构。均衡候选B在640×480下静态MAC减少31.0%、CNN DDR模型减少36.0%；这是待训练/RTL实测的候选，不改变下方C35真实资源，不等于RAM/XLR自动减少或新fps已经实现。

2026-09-15 00:24最新实测：[C35 PNR](logs/r2_c35_fused_pnr_gate_20260915_a.log)为 **44,352 XLR / 129 RAM / 130 DSP**，相对C34增加1,066 XLR、RAM/DSP不变。核心6.666ns约束setup/hold +0.579/+0.026ns，定向CDC路径通过但全量CDC分类仍未完成。与必要官方模块分项粗和为61,713 XLR / 234 RAM / 134 DSP，XLR较60,800上限超913；不是联合实现结果，不能宣布平台可装下。层级资源增量主要归属窗口存储（+917 XLR，其中overlay +627），下一轮须审查写地址/数据选择接口。C35尚无原生六帧FPS，不能继承C33的14.502105fps。详见[C35报告](review/R2_ROW_FUSED_TAIL_20260914.md)。

历史C34基线：[PNR](logs/r2_c34_pnr_gate_20260914_a.log)为43,286 XLR/129 RAM/130 DSP，写回占16 RAM；相对C33总145 RAM实际节省16 RAM。150MHz定向setup/hold +0.416/+0.026ns。与必要官方平台粗和60,647 XLR/234 RAM/134 DSP，仅余153 XLR，亦非联合实现。下方保留各阶段历史预算。

2026-09-14 22:35：[C33原生门禁](logs/r2_c33_native_gate_20260914_a.log)已证明同AW2压力配置下最慢14.502105fps@名义150MHz，最慢10,343,326拍，仍未达15fps；不是板级实测。C34实际92写侧配置和小图整机配对通过，32×32间隔保持74,525拍，但RAM节省尚未由Efinity验证。C35整行融合的净省9,278,592 B/frame为流量推导，新13源共享MAC候选尚未编译/仿真/PNR，不计入资源或帧率已实现收益。

2026-09-14 20:50 [C34候选](review/R2_RING_WRITE_STORAGE_20260914.md)默认写回物理容量32→16KiB，预计写回32→16 RAM、主机145→129 RAM；**均待实际MAP/PNR，不计入已完成节省**。若成立，必要官方平台粗和可降至234/256 RAM；环形地址/准入控制可能增加XLR，当前粗余139 XLR仍是红线。还须确认容量背压不抵消C33吞吐收益，不改变模型来掩盖资源差异。

2026-09-14 20时 [C33定向实现](review/R2_BURST_CREDIT_WRITER_20260914.md)：43,300 XLR / 145 RAM / 130 DSP，核心6.666ns setup/hold +0.463/+0.026ns；比C31增加148 XLR，RAM/DSP不变。官方必要平台粗加60,661/60,800 XLR、250/256 RAM、134/160 DSP，剩139 XLR/6 RAM，仍不能证明联合可装下。小尺寸32×32完成间隔−8.7732%，未取得C33原生帧率。AW_WAIT_W=2是BFM等待整个W突发后才接受AW的压力策略，不是固定两周期延迟，也未确认是官方DDR的实际行为。

2026-09-14最新[C31定向PNR](review/R2_RGB2_HOST_INTEGRATION_20260914.md)：43,152 XLR/145 RAM/130 DSP；核心6.666ns下setup/hold +0.366/+0.026ns。与必要官方平台粗加60,513/60,800 XLR、250/256 RAM、134/160 DSP，并非联合可装下证明。修复后的原生d六次功能已通过，AW2下最慢完成间隔10,637,008拍、名义150MHz约14.10171fps，超目标637,008拍。旧C26为AW0，不能据不同负载直接认定架构退步；板级与全量CDC仍未完成。C32仅做单元/写侧AXI诊断并发现队首阻塞，未跑MAP/PNR、未替换C31，不报告其资源或整机帧率收益。以下预算按历史阶段理解。

2026-09-14新增[C30前端MAP对照](review/R2_DEMO_RGB2_INGRESS_20260914.md)：相同512深度，单像素旧Resize为1,887 LUT4/1,642 FF/19 RAM/18 DSP，双像素+视频校验+overlap Resize为2,067 LUT4/1,772 FF/20 RAM/18 DSP；差额+180 LUT4/+130 FF/+1 RAM/0 DSP。未PNR，不将LUT差当XLR差；尚未联合C29/企业平台。完整1080p前端仿真峰404/512记录，不是带CNN/CPU/显示争用的容量保证。

本文件严格区分三类数字：

1. **结构估算**：由 manifest、RTL 协议和显式容量推导，不是综合/实测；
2. **Vivado 代理综合**：Artix-7 综合后报告，只能用于结构和关键路径趋势；
3. **Ti60实现/板测**：Efinity place-and-route 与实体板测分开记录；前者不能代替后者。

2026-09-14最新R2实测实现见[C29报告](review/R2_CAMERA_CAPACITY_20260914.md)：42,777 XLR/144 RAM/130 DSP、150MHz级核心setup/hold +0.650/+0.026ns。较C28减少972 XLR/4 RAM，DSP和已测执行周期不变。必要官方平台仍是分模块粗和17,361 XLR/105 RAM/4 DSP，合计60,138 XLR/249 RAM/134 DSP、仅余662 XLR/7 RAM，不是联合可装下证明；下方未更新的代理估算按历史阶段理解。

## 1. 器件上限与片上/片外边界

Efinix 官方 [Ti60 Data Sheet v3.7](https://www.efinixinc.com/docs/titanium60-ds-v3.7.pdf) 给出的器件级上限为：

| 资源 | Ti60 上限 | 证据类 |
|---|---:|---|
| Logic Elements | 62,016 | 器件规格 |
| XLR cells | 60,800 | 器件规格 |
| Embedded memory | 2.6 Mbit | 器件规格 |
| 10-Kbit memory blocks | 256 | 器件规格 |
| Embedded DSP blocks | 160 | 器件规格 |

### 1.1 Soft Sapphire 的额外资源预算（仅厂商参考）

Efinix 的 [Sapphire RV32 数据表](https://www.efinixinc.com/docs-html/rv32-sapphire-ds/topics/riscv-saxon-efx-features-sapphire.html)
在 Ti60 F225 C4、Efinity 2025.2 条件下给出
了 SoC **自身**的典型量级：无外部内存的 cacheless 配置约为
`4,467 logic/adders + 3,117 FF + 12 memory blocks + 4 DSP`；带外部内存的
cacheless 配置约为 `7,166 + 7,672 + 44 + 4`；带外部内存和 cache 的配置约
为 `7,560 + 8,110 + 56 + 4`，对应表中 `fMAX` 约 382/401 MHz。这里的
`memory blocks` 是厂商表的器件块计数，不应直接等同于 Vivado BRAM36 或
本文件后文的 M10K 估算；版本、参数、PLL/DDR/IP 和约束改变后也会变化。

因此当前选择顺序建议是：先用单核 Soft Sapphire、最小必要 OCR、cacheless
或小 cache 做 `map`，确认 APB/IRQ/DDR 连接和剩余 LE/EBR/DSP，再决定是否增大
cache/外部内存选项。CPU 只负责 Case-1 控制面，不应为逐像素 CNN 计算额外
堆多核。当前 full-top Vivado proxy（baseline `47512 LUT/34821 FF/32 BRAM/
85 DSP`；registered preclamp `47443/34784/32/81`）只能作为结构趋势；不能
把它与上面的 Sapphire 表做数值相加或宣称 Ti60 可放下，最终必须在 Efinity
2026.1 的目标器件、DDR 和 pin/clock 约束下重新 map/pnr。

M10K simple-dual-port 最宽 `512×20`、true-dual-port 最宽 `1024×10`，所以必须按端口形状和 banking 估算，不能只除总 bit。外部 DDR 容量/带宽不计入 2.6 Mbit 片上 RAM。

当前 tensor adapter 的 `3×8 MiB = 24 MiB` 是**外部 DDR arena**：

```text
bank0 tensor_base + 0 MiB
bank1 tensor_base + 8 MiB
bank2 tensor_base + 16 MiB
```

它不消耗 24 MiB 片上 RAM，也绝不能写成“Ti60 内部三缓冲”。software/SoC 要求 base 以 8 MiB 对齐且不高于 `0xfe80_0000`；adapter 自身另做 8-byte 对齐/溢出检查。每个 8 MiB bank 足以容纳最大 640×480×2 C8 group 的 4,915,200 B tensor，并留出地址余量。

## 2. 模型与片上状态结构估算

| 项目 | 数量 | 证据类/说明 |
|---|---:|---|
| 卷积权重 | 12,212 B INT8 | manifest |
| 参数 arena | 16,896 B/风格 | manifest；weight+bias+multiplier+shift/对齐 |
| 双参数 bank | 33,792 B payload | 当前 portable staging baseline；Vivado 推断 15 BRAM tile |
| 22-stage descriptor 双 bank | 22,528 bit | `2×22×512`；RTL 以 `352×32` 窄 RAM 组装 |
| Resize sampler | `4×MAX_WIDTH×24 bit` | `MAX_WIDTH=2048` 时 196,608 bit；Vivado 6 BRAM tile |
| Debayer 行存储 | 约 51,200 bit | 结构估算，按 RAW10/目标宽度 |
| Gamma | 24 Kibit | 三个 1024×8 读 bank，支持同拍 RGB 三读 |
| MAC/帧 | 428,236,800 | manifest，640×480 |

双参数 bank 当前为两个 `1056×128` portable RAM。按 Ti60 端口几何会横向分片，约需双 bank 42 个 M10K 的量级；最终 Efinity 可改成单 bank、较窄串行读或更符合 M10K 宽度的 banking。descriptor 默认窄模式约 4 个 M10K 量级；`FAST_WIDE=1` 的 512-bit 单拍模式会严重横向碎片化，不应作为 Ti60 终版默认。

真实 `c1_r1_microstyle_engine` 的当前参数路径为：128-bit 顺序 ABI cache 映射到 BRAM；每层配置后，多拍 OIHW walker 将该层有效权重重排到 64 个固定 Conv lane bank或 8 个固定 DW lane bank；dot/DW core 只对窄、顺序 tile 地址取数。它已取代旧的“64 路从完整 2,592-byte flat cache 任意选择”结构。

最终重排版完整 CNN proxy run `6cb8dfd59ed5473383eed87f52b2a013` 已严格 PASS、stderr 为空。它在 `xc7a200t` 代理上的综合资源为 28,298 Slice LUT（25,542 logic + 2,756 LUTRAM）、11,168 FF、2 BRAM36、35 DSP、32 个 F7 mux 和 8 个 F8 mux；相对下述旧 flat-cache 失败基线，LUT 下降约 96.15%。这证明权重存储/选择结构已经实质收敛，但不能直接换算为 Ti60 LE/M10K/DSP。

旧 flat-cache proxy run `50e2f738693246b2a2f05191bb10a4f7` 的 `synth_design` 以 0 error 生成 utilization report：735,256 Slice LUT（目标 `xc7a200t` 的 546.25%）、43,585 registers、0 BRAM、99 DSP，并产生 306,449 个 F7 mux 和 144,592 个 F8 mux。结构显然不可实现，因此在 timing report 生成前精确终止了进程树；status.json 可能残留 `running`，但该任务没有最终 PASS。该数字只保留为说明重排重构必要性的**历史失败基线**，不能再表述为当前 engine 结构。

## 3. 当前顺序 tensor 架构的确定性性能下界

以下数字由当前 22 层 manifest 和 adapter “逐 tap、逐 C8 group、每个 64-bit 访问一次请求”的 RTL 语义推导，属于**结构估算，不是测量**：

| 每帧 64-bit 请求 | 数量 |
|---|---:|
| source tensor 写入 | 307,200 |
| 22 stages 输入/tap 读取 | 17,376,000 |
| 中间 tensor 写入 | 3,705,600 |
| 合计 | **21,388,800** |

64→AXI128 bridge 将每笔 64-bit 请求扩成一个完整 16 B、单拍 AXI beat，因此形成：

- `342,220,800 B/frame` 的总线传输；
- 15 fps 时理论 `5,133,312,000 B/s`，约 **5.133 GB/s**，尚未计仲裁、刷新、地址/响应空洞和其他六个 client；
- 单 outstanding request→response 的绝对乐观下界按约 4 cycle/request，单帧仅内存就至少 **85,555,200 cycle**；
- 100 MHz、15 fps 预算只有 **6,666,667 cycle/frame**。

因此当前 adapter/bridge 明确是 functional correctness baseline，远达不到 15 fps。portable SoC 将 `JOB_CYCLE_BUDGET` 默认放宽为 `1,000,000,000` clocks，以便顺序基线仍有有限 watchdog；standalone controller 的 12,000,000 默认值在该顺序语义下会必然误超时。1G watchdog 不是性能目标，性能版必须根据实测 deadline 重设。

即使完全忽略 tensor/参数/控制开销，当前共享 engine 的 64 MAC 并行度对 `428,236,800 MAC/frame` 的纯算术下界也是：

```text
428,236,800 / 64 = 6,691,200 cycle/frame
```

它已经略高于 100 MHz/15 fps 的 6,666,667 cycle 预算，尚未包含 bias/requant、填充排空、stall 或 residual/upsample。故只优化 DDR 仍不够，还必须提高有效 MAC 并行度或降低网络工作量。

性能版本至少需要组合以下措施：

- 已实现 correctness-first 三行 window cache，并完成小尺寸 adapter→cache→AXI128 动态测量；仍需 native 帧、共享仲裁/DDR 与 burst 化，才能确认板上逐 tap DDR 流量和帧率；
- 将 C8 beat 打包成有效 AXI burst；
- 多 outstanding、read/write queue 和内存级并行；
- channel/group/MAC 并行与权重预取；
- display/capture/tensor QoS；
- 根据优化后最坏周期重定 watchdog。

### 3.1 性能原型与可选 cache 接入边界

`model/tensor_perf_model.py` 和 `test_tensor_perf_model.py` 现在把上述计数固化为 Python 验收基线。回归输出：

```text
C1_TENSOR_PERF_MODEL_TEST_PASS baseline_requests=21388800 baseline_bytes=342220800 candidate_bytes=47547744
```

其中一个候选配置为 `pack_factor=2, read_reuse=9, outstanding=16, mac_lanes=64`：内存字节下界降至 47,547,744 B/frame，但计算下界仍是 6,691,200 cycle/frame，乐观帧率约 14.945 fps，仍未达到 15 fps。模型明确假设理想 cache 命中和无仲裁/刷新开销，不能替代 RTL/DDR 测量。

`rtl/dma/c1_tensor_mem_axi128_packer.sv` 是独立的 64-bit 请求→AXI128 beat 原型，当前没有接入 `c1_r1_portable_soc`。detached xsim run `4d4c4edfb483422c9196b7fdc12b8e6a` 的实际结果为 100 requests、51 AXI beats、48 packed pairs、49% beat reduction、12 个 response stall，覆盖 1 个本地对齐错误。随后 proxy synth run `d011df7b1a7a4bd19275769b89a01f94` 在 `xc7a200t`/100 MHz 下使用 412 LUT（264 logic + 148 LUTRAM）、649 FF、0 BRAM、0 DSP，WNS=+2.588 ns、TNS=0。该裸模块综合没有真实端口约束，也没有 P&R/时钟树，不能直接从 49% 推导系统 fps 或板卡资源。

新的 `rtl/dma/c1_tensor_mem_path_seam.sv` 将 legacy bridge 与 performance packer 放在同一个窄请求/响应 ABI 下，并为性能路径增加锁存式 `flush_req/flush_done` 与 `quiescent`。xsim run `7a447dba98be413d9e36c9f20bee443d` 同时验证两种生成分支；proxy synth run `ca3e6b438d7e471bb39a083fc31746de` 的 mode 0/1 分别为 122 LUT/176 FF/WNS +6.274 ns 和 413 LUT/651 FF/WNS +2.586 ns。它仍未接入当前单 outstanding adapter；直接替换 bridge 而不改变请求发射会导致单请求等待伙伴，不能宣称 packing 已获得系统收益。

`model/window_cache_perf_model.py` 是独立的 3-row、3×3 SAME line/window traffic 模型。它按真实 adapter 的 pixel→C8-group 交织顺序，一次 refill 载入 x-major/group-minor 的完整多 group 行。8×8、16×16、64×48 的 tap 请求分别从 3,024/12,096/145,152 降到 408/1,632/19,584 external 64-bit words，逐 tap 行命中率为 98.7434%/99.3717%/99.8429%。这是完整行预取的流量上界模型，不是 RTL、DDR 或 cache miss 实测；stride-2 stage 的 external ratio 仍为 4/9，不能简单套用 stride-1 的 1/9。

`rtl/cnn/c1_window_line_cache_ctrl.sv` 已把这个模型的最小控制闭环落成独立 RTL：xsim run `8991ff1ef0954d669c3a4568208ae5a2` 对 8×8 stride-1/stride-2 共 720 taps 观察到 16 次 row refill、128 个 external words，并在 refill 后保持请求直到实际 handshake。proxy synth run `7ee82460964f4926b9b5030655bd049d`（xc7a200t、100 MHz、无 P&R/IO 约束）为 97 LUT、342 FF、0 BRAM、0 DSP、WNS/TNS=+5.042/0。该版本只存 3 个 row tag，采用确定性 round-robin；像素数据 BRAM、burst、多个 outstanding、真实 adapter 接入和 Ti60 映射仍未实现，因此这组资源只能作为控制壳下界。

`rtl/cnn/c1_window_line_cache_c8.sv` 已进一步实现真实 64-bit payload：三行均保存该物理行全部 C8 groups，最大为 `3*1280*64=245,760 bit`。正常、fault/maintenance 和最终 1280-word 最大行 detached xsim 分别由 `2a1766339f834f3b9eba6f0dd5deecd4`、`3373b871a3734d2ab2ca9607a206face`、`a3ac690fadf34c8fb123c8043f365cc1` 严格通过。Vivado proxy synth `d07c3a3c7348474ea465ff73f765707a`（xc7a200t、100 MHz、无 P&R/IO 约束）实际推断 7.5 BRAM tile，另用 288 LUT、203 FF、0 DSP，WNS/TNS=+1.086/0 ns。此前未流水版本的 `-2.410 ns/1 DSP` 仅是已修复的中间诊断；最终版本用常量 row-slot 基址 mux 和两级读地址流水消除了该 DSP/关键路径。

7.5 个 Artix-7 BRAM36 tile 与 30 KiB payload 容量一致，但不能直接换算到 Ti60。Ti60 仍只能先按约 24 个 M10K 的纯容量下界、约 32 个 M10K 的 `512x20` 展平映射估算，最终以 Efinity 推断/布局为准。当前 cache 仍逐 tap 本地读、逐 64-bit word refill且单 outstanding；资源/100 MHz proxy PASS 不是 15 fps 证明。

`rtl/dma/c1_tensor_window_cache_seam.sv` 把注册化请求分类、地址 guard、
owner/coherence/maintenance 与上述 payload cache 合成一个边界。当前加固
xsim `1e6f562adbc34ea383932840b97aa0e4` 为 17/17 logical req/rsp，除原有
refill/bypass/flush/abort/backpressure 外，还定向证明 C8 配置拒绝与已锁存
cache 路由后的 runtime fault 都会安全退回 direct path。当前合并 proxy synth
`6dc7d474aff34448ba590ff615927a53` 为 1,236 LUT、792 FF、7.5 BRAM tile、
0 DSP，100 MHz WNS/TNS=+1.086/0 ns。相对历史基线 `209b68d9b8c9429ba659d32b399a0911`
的 1,234 LUT/787 FF，仅增加 2 LUT/5 FF；该总量已经包含 C8 cache，不能再与
288 LUT/203 FF 的独立 cache 数字相加。

adapter sideband 与默认关闭的 portable SoC generate 已接通；当前 adapter
默认/sideband 回归为 `1f59974a3dd14fe5afa8c94e8f3c668c`/
`a3fcee365dde4361a3a1bb31bbd64287`。完整 22-stage 小尺寸流量又分别通过
64-bit seam BFM `9212d5a042ae4d9895a3162869e3815f` 和真实 bridge+AXI128 BFM
`be4977424d9d484e80340f970d9904d0`：1,810 个 logical reads 形成 502 个 AXI AR，
420 个 writes 形成 420 组 AW/W/B。portable SoC 最新 bypass/enabled smoke 为
`7e76332ea7044371af9efcf39809258a`/`30658446f3d4442fb7f7a442bd5f9fe2`；
enabled run 证明 cache busy 会进入 `system_busy` fence。随后当前源码 shape-scaled gate 矩阵
`c1_8x8_gate_20260825`、`c1_16x8_two_gate_20260825`、
`c1_64x48_single_gate_20260825` 和 `c1_64x48_two_gate_20260825` 又实际穿过
client-6、七客户端仲裁和 DDR BFM：8×8 单帧完成 `AW/W/B=852/868/852`、
`AR/R=1119/2199`；16×8 两帧完成 `AW/W/B=3376/3472/3376`、
`AR/R=4185/5463`、`swaps=2 drops=0`；64×48 单帧完成
`AW/W/B=40224/41664/40224`、`AR/R=48427/51643`；64×48 两帧完成
`AW/W/B=80448/83328/80448`、`AR/R=96793/102295`、
`swaps=2 drops=0`。gate 期间确认高 `R stalls` 来自刻意背压下的共享 ID-less
读响应 owner；控制层已加入 display prefetch quiescence gate，避免 CNN 被
display reader 的 held R beat 饿死。shape elaboration 前置证据为
`c1_64x48_gate_compile_20260825`；顶层 `flush_req` 仍暂绑 0。

adapter 默认兼容 run `5cc1f6d0fcd242bf9de7fe48c5418270` 保持 2,230 个请求；sideband run `513714c5626b47e99bc730cf7d3fdf9f` 通过 22 次配置、1,512 个 cacheable read 和 266 个 bypass read。历史 adjacency trace `61ac723d36b043d9b24272914e50856e` 中，同 16-byte base 636 次、可组成“相反 lane + 同读写方向” pair 407 次，即 18.2593% of 2,229 adjacent gaps。该数据来自 4×4 定向测试，只能作为发射重排的方向性证据；它明确否定“把独立 packer 直接串到单 outstanding adapter 就自然得到 49%”这一假设。

七客户端共享仲裁器的独立压力 run `bbaccd1453aa43368eebc4e1f5bdae5a` 完成 56 写+56 读事务，随机 AW/W/AR/B/R 停顿下最大观测等待 89/67 cycle，并同时观察读写方向前进。当前 shape-scaled 顶层 run `e2e36...`/`377f...`/`7273...`/`c1_64x48_single_20260825` 又把 capture、frame DMA、tensor 和 display 同时接入真实 fabric；16×8 相对 8×8 的单帧 AXI 计数约随宽度翻倍，64×48 单帧进一步达到 `AR/R=48427/51643`。display response FIFO prototype 进一步在 64×48 单帧将 c4/c5 max AR wait 降至 76/83、R hold 降至 2/2，并在 8×8 两帧保持 `swaps=2 drops=0`；这些仍是功能/QoS 观察，native 长帧、刷新余量、Efinity 资源和最坏 deadline 尚未测量。

### Display response FIFO prototype

可选 FIFO token 宽度为 59 bit，当前测试深度 128、两路总存储下界为
`59×128×2=15,104 bit`（depth=64 时 7,552 bit）。这是逻辑容量下界，不是
Ti60 M10K/LE 报告；实际映射取决于 Vivado/Efinity 对 `c1_stream_fifo` 的
RAM 推断。默认 `ENABLE_DISPLAY_RESPONSE_FIFO=0` 不增加该存储。native
640×480 FIFO 分支最新 run `native_display_fifo_final_20260825` 已逐像素通过（旧
`native_display_fifo_full_20260825` 为先前快照），但尚未
执行 proxy synthesis，不能把上述 bit 数换算为板卡资源或 15-fps 余量。

另一条可选路线是回到专用多速率 streaming stage 图。旧 80-lane schedule 的 5,898,240 cycle/frame 只是算力结构下界，不是当前 RTL 测量；它还需要大量片上 line/residual cache 和严格权重 banking，不能与当前共享顺序 engine 的资源/性能混为一谈。

## 4. Framebuffer、显示与传感器带宽

XRGB8888 下单个 640×480 帧为 1,228,800 B，三输入+双输出共 6,144,000 B（约 5.86 MiB，外部 DDR）。不含 tensor 时的粗略持续流量：

- 30 fps capture write：36.9 MB/s；
- 15 fps frame input read + output write：36.9 MB/s；
- 720p 分屏重复读取原图和风格图：约 147.5 MB/s；
- 合计约 221 MB/s。

该 221 MB/s 已明显小于 correctness-first tensor 路径的 5.133 GB/s 结构流量，但仍会与 tensor 争用同一 DDR。真实效率、refresh、仲裁和 line FIFO 深度只能在最终控制器/板卡上验证。

若 SC431 输出 2560×1440@30，仅 active pixel 已达 110.592 Mpixel/s；100 MHz、NPPC1 ISP 不足，blanking 还会提高像素时钟要求。必须选择传感器低分辨率、提高 ISP 时钟、NPPC2/4，或先写 DDR 后异步处理。当前 portable ISP 是 NPPC1 算法基线，不证明这一输入模式。

## 5. 最新 Vivado 组件代理综合

最新 14 组件 run 为 `4fdb28345b6b4b2c8342357e2e0d82ec`，目标 `xc7a200t`、100 MHz，全部组件综合完成、stderr 为空。下表是**综合后、未 place-and-route 的 Xilinx 代理数据**：

| 组件 | LUT | Reg | BRAM tile | DSP48 | WNS |
|---|---:|---:|---:|---:|---:|
| AXI parameter loader | 191 | 227 | 0 | 0 | +4.721 ns |
| dot8×8 + requant | 8,345 | 1,362 | 0 | 16 | -1.975 ns |
| boardless frame-job（含 frame DMA） | 4,568 | 7,080 | 7 | 24 | -0.191 ns |
| compute shell | 1,145 | 1,016 | 6 | 18 | -0.177 ns |
| config dispatcher | 111 | 588 | 0 | 0 | +4.215 ns |
| R1 ISP | 764 | 1,275 | 4.5 | 12 | +2.372 ns |
| job frontend | 2,619 | 4,582 | 1 | 2 | -0.191 ns |
| 双参数 bank | 164 | 55 | 15 | 0 | +5.830 ns |
| Resize pipeline | 906 | 725 | 6 | 18 | -0.154 ns |
| 双 stage-config bank | 790 | 1,633 | 1 | 0 | +3.831 ns |
| residual C8 | 141 | 307 | 0 | 0 | +4.460 ns |
| upsample C8 | 156 | 89 | 2 | 0 | +3.459 ns |
| SAME window C8 | 1,274 | 1,194 | 4 | 0 | +3.845 ns |

该 run 中的 DW 快照早于最终流水修订，不作为当前 DW 结论。最终独立 DW run `ba43851ef5a24071bad06edeb2460c7c` 为：

| 组件 | LUT | Reg | BRAM tile | DSP48 | WNS/TNS |
|---|---:|---:|---:|---:|---:|
| DW3×3 C8 + requant | 8,784 | 4,157 | 0 | 16 | **+3.039 ns / 0** |

DMA 集成路径从旧 run 的 `-12.093 ns` 改善到 boardless 当前 `-0.191 ns`，且当前最差已是 descriptor/control 路径，不再是旧的 frame-height 动态乘法；Resize 从 `-5.714 ns` 改善到 `-0.154 ns`；DW 最终专项已满足 100 MHz 代理约束。这些改进有意义，但 `-0.191/-0.154 ns` 仍不是闭合，且 Xilinx 映射不等于 Ti60。

完整重排版 CNN proxy 的最终报告为：

| run | LUT | FF | BRAM36 | DSP | F7/F8 | WNS/TNS |
|---|---:|---:|---:|---:|---:|---:|
| `6cb8dfd59ed5473383eed87f52b2a013` | 28,298（25,542 logic + 2,756 LUTRAM） | 11,168 | 2 | 35 | 32/8 | **-4.965/-2511.307 ns** |

该 run 完成综合和报告生成、严格 PASS、stderr 为空，但 PASS 只代表工具流程完成。最差路径为 `replay_index`→descriptor decoder error reset，14 级逻辑、14.351 ns；旧 window cache→dot overflow 最差路径已消失，首条计算相关路径仍约 `-4.601 ns`。因此 100 MHz 仍明确失败，后续应分别流水化 descriptor/error control 与计算路径；更不能据此宣称 Ti60 已容纳或时序已签核。

## 6. 证据总表与待测项

| 项目 | 当前状态 | 证据类 |
|---|---|---|
| 整数 artifact / QAT 一致性 | 32×32 artifact exact replay 22 stage；6 图 QAT/整数最终 RGB 最大误差 0 | Python 实测；两者均非 RTL E2E |
| trained artifact RTL ABI | 22 descriptors + 1,030 个 128-bit parameter reads/cache writes 通过 RTL decoder + scheduler | run `35f1aa0e76ed41d084f40e6637ac331e`；arena 16,896 B 含对齐/填充，仍仅 native 640×480 ABI 边界，不是算术帧 |
| tensor 24 MiB、请求数、5.133 GB/s | 已推导 | RTL/manifest 结构估算 |
| packing 性能原型 | 100 requests→51 AXI beats，49% reduction；412 LUT / 649 FF / 0 BRAM / 0 DSP；WNS +2.588 ns | xsim `4d4c4edfb483422c9196b7fdc12b8e6a` + Vivado proxy synth `d011df7b1a7a4bd19275769b89a01f94`；未接入 SoC，裸模块 IO/时序不可外推 |
| memory path seam | legacy/performance 两分支；3 requests→2 beats、1 packed pair、flush_done/quiescent PASS | xsim `7a447dba98be413d9e36c9f20bee443d` + proxy synth `ca3e6b438d7e471bb39a083fc31746de`；mode0 122 LUT/176 FF，mode1 413 LUT/651 FF；未接入 adapter |
| 3×3 line/window cache 模型 | 8×8/16×16/64×48 external requests 408/1,632/19,584；整行全 group refill、三行逐 tap 命中率 98.7434%/99.3717%/99.8429% | Python regression（13 commands）；流量模型，不是 RTL/DDR 测量 |
| 3-row line/window cache RTL control | 720 taps、16 refills、128 external words；97 LUT / 342 FF / 0 BRAM / 0 DSP；WNS/TNS +5.042/0 | xsim `8991ff1ef0954d669c3a4568208ae5a2` + proxy synth `7ee82460964f4926b9b5030655bd049d`；row-tag-only、round-robin、独立小帧，不是系统资源 |
| 3-row all-group C8 payload cache | 245,760-bit payload；288 LUT / 203 FF / 7.5 BRAM tile / 0 DSP；WNS/TNS +1.086/0 | normal/fault/max-row xsim `2a176...`/`3373...`/`a3ac...` + proxy synth `d07c...`；独立模块与 adapter/AXI 小尺寸动态链均已验证；Ti60 M10K 待 Efinity |
| tensor window-cache seam（含 C8 cache） | 17/17 req/rsp，配置拒绝/runtime fallback PASS；1,236 LUT / 792 FF / 7.5 BRAM tile / 0 DSP；WNS/TNS +1.086/0 | xsim `1e6f...` + proxy synth `6dc7...`；该总量已包含 cache，不与上一行相加；相对历史 `209b...` 增加 2 LUT/5 FF |
| adapter→cache→AXI128 小尺寸动态链 | 2,230/2,230 logical req/rsp；1,810 logical reads→502 AXI AR（-72.3%）；420 AW/W/B | 64-bit xsim `9212...`、真实 bridge+AXI BFM `be497...`；单拍/单 outstanding，未含 portable SoC 仲裁、DDR、burst 或 native frame |
| portable SoC cache-enabled 小帧 gate 全链 | 8×8 `c1_8x8_gate_20260825`；16×8 两帧 `c1_16x8_two_gate_20260825`；64×48 单帧 `c1_64x48_single_gate_20260825`；64×48 两帧 `c1_64x48_two_gate_20260825` | 真实 capture/CNN/client-6/七客户端 DDR/display；8×8 `AW/W/B=852/868/852`、`AR/R=1119/2199`；16×8 两帧 `AW/W/B=3376/3472/3376`、`AR/R=4185/5463`、`swaps=2 drops=0`；64×48 单帧 `AW/W/B=40224/41664/40224`、`AR/R=48427/51643`；64×48 两帧 `AW/W/B=80448/83328/80448`、`AR/R=96793/102295`、`swaps=2 drops=0`；功能/协议/ownership 证据，不是 native 帧率 |
| portable SoC 64×48 shape boundary | `c1_64x48_gate_compile_20260825` | xvlog/xelab shape elaboration exit 0、stderr 为空；后续单帧/两帧 xsim 已通过，不能外推 native 动态带宽或性能 |
| portable SoC native 640×480 shape boundary | `c1_640x480_final_elab_20260825` | tensor adapter 64-bit geometry/address fix、native address-map assertion 与 associative store 后 xvlog/xelab exit 0、stderr 为空；未启动 xsim；长帧 watchdog/QoS 仍待处理 |
| native 640×480 display prefetch staged preflight | `native_prefetch_run2_20260825` | 独立双 reader/双行 CDC 完成两路 `307200` 像素响应、`4800` AR、`76800` R beats，`underflow=0/0`；仅证明 native 显示/DDR 读回地址和 CDC，不含 SoC CNN、共享仲裁、资源综合或帧率 |
| native 640×480 capture-writer staged preflight | `c1_native_capture_writer_final_20260825` | 三块 input slot 真实写回/读回 `AW/W/B=14400/230400/14400`、`readback_pixels=921600`，slot 地址 `00100000/0022c000/00358000`；仅证明 writer/AXI W/B/slot map，不含 camera、input DMA、CNN、共享仲裁、资源综合或帧率 |
| native 640×480 capture/table/ISP staged preflight | `c1_native_capture_table_paced_full_20260825` | 真实 capture subsystem 完成 3×642×482 RAW10→640×480，`pixels/sof/eol/eof=921600/3/1440/3`、Gamma `1024`、table `AR/R=3/3`、writer `AW/W/B=14400/230400/14400`；仅证明 camera-paced capture/ISP/table/writer 边界，不含 CSI、portable SoC input DMA、共享仲裁、CNN、资源综合或帧率 |
| native 640×480 input-DMA/table/arbiter staged preflight | `c1_native_input_dma_full_20260825` | 两主机真实 table/XRGB reader + `c1_axi2_serial_arbiter_128` 完成三 slot `frame_pixels=921600`、shared `AR/R=14403/230403`；仅证明 read-side DMA/arbiter 地址和回压，不含 boardless/output DMA、七客户端 fabric、CNN、资源综合或帧率 |
| native 640×480 read→write DMA loopback staged preflight | `c1_native_dma_loopback_final2_20260825` | 真实 table/XRGB read、read arbiter、XRGB writer、`c1_axi_write_skid_bridge`、write arbiter 和 associative DDR 回读完成三 slot `frame_pixels=921600`、input `AR/R=14400/230400`、output `AW/W/B=14400/230400/14400`；这是板前功能/回压证据，不是七客户端资源、burst 性能、CNN/QoS 或 Ti60 映射 |
| native 640×480 boardless job staged preflight | `native_boardless_job_hold_full_20260825` | 真实 boardless top 完成 22 descriptor、`cnn_in/cnn_out=307200/307200`、input `AR/R=4800/76800`、output `AW/W/B=4800/76800/4800` 和逐像素 output line-store 回读；功能/协议证据，不是 portable SoC 七客户端资源、真实 CNN/tensor 吞吐或 Ti60 映射 |
| native 640×480 boardless + 7-client fabric contention preflight | `native_fabric_full2_20260825` | 真实 boardless client-0 与六个 synthetic peer 穿过 `c1_axi_n_serial_arbiter_128(CLIENTS=7)`；job 完成 `AW/W/B/AR/R=4800/76800/4800/4800/76890`，六 peer 完成 `18/72/18/18/72`，最大等待 `118` cycles。仅是 native fabric 功能/QoS 风险证据，不据此推断 portable SoC 七个真实叶模块、真实 CNN/tensor、Ti60 LE/BRAM/DSP 或 15 fps |
| native 640×480 fabric real parameter leaf slice | `native_fabric_param_full_20260825` | client-1 为真实 parameter-loader + parameter-bank，`param AR/R=66/1056`、`generation=1`，client-2..6 为五个 synthetic peer；job/output 数据面完整，peer max wait `158/162/160/169/167` cycles。仅是一个真实 read leaf 的功能/协议证据，不推断七个真实叶模块的资源、Ti60 映射、QoS 或 15 fps |
| portable SoC 64×48 seven-client monitor diagnostic | `portable_client_gate_64x48_20260825` | bind-only traffic monitor 统计真实内部 client-0..6；c5 styled-display `max AR wait=1,243,738` cycles，超过 1,000,000 guard，故 xsim exit 1。该行是 ID-less read-owner starvation 风险基线，不是资源报告或性能 PASS |
| portable SoC display response FIFO QoS prototype | `portable_display_fifo_reader_gate_full_64x48_20260825`; `portable_display_fifo_credit_only_twoframe_8x8_20260825` | depth=128、59-bit token×2；单帧 c4/c5 wait `76/83`、R hold `2/2`，8×8 两帧 `swaps=2 drops=0`；只做 xsim/elaboration，尚无 Vivado/Efinity utilization/timing |
| portable SoC display response FIFO 64×48 两帧 | `portable_display_fifo_credit_only_twoframe_64x48_20260825` | `done=2 swaps=2 drops=0`、`AW/W/B=80448/83328/80448`、`AR/R=96796/102358`；credit-only + drain guard 通过，仍无 proxy resource/timing |
| native 640×480 display response FIFO pixel preflight | `native_display_fifo_final_20260825` | 两路 `307200` pixel、`4800` AR、`76800` R、`underflow=0/0`；FIFO 数据/CDC/地址正确性通过，不是资源或帧率报告 |
| display response FIFO Vivado proxy | `display_fifo_proxy_async_final2_20260825` | `xc7a200tsbg484-1`：bypass/fifo128 `2600/3094 LUT`、`1141/1185 FF`、`1280/1584 LUTRAM`、`0/0 RAMB36+RAMB18`、`4/4 DSP`；core WNS `3.265/2.470 ns`。仅作结构预算，Efinity 可能改用 EBR |
| portable SoC native FIFO elaboration | `portable_fifo_native_elab_final_20260825` | 640×480 完整七客户端结构在 FIFO 参数下 elaboration 通过；未启动 xsim，不能从该行推导动态资源/帧率 |
| portable SoC native address-pipeline elaboration | `descriptor_strict_pipelined2_native_elab_20260825` | `640×480 + PIPELINED_TENSOR_ADDRESS=1` xvlog/xelab 通过、stderr 为空；仅结构闭合，不是 native 资源/性能签核 |
| portable SoC 640×480 FIFO system proxy | `portable_soc_fifo_proxy_post_pipeline_default_20260825` | 最终源码 bypass/fifo128：`44792/45298 LUT`、`28082/28123 FF`、`5644/5948 LUTRAM`、`20/20 RAMB36`、`9/9 RAMB18`、`99/99 DSP`；strict FIFO128 core WNS `-53.327 ns`，旧 `-53.944 ns` 为历史快照；资源为 Xilinx proxy、时序未闭合 |
| descriptor relaxed timing proxy | `portable_soc_descriptor_relaxed_post_pipeline2_20260825`；历史对照 `portable_soc_descriptor_relaxed_proxy_canonical_20260825` | 最终源码 strict=0 为 `44713 LUT/28061 FF/93 DSP`，直接 path `-15.659 ns`、Q→D `-13.455 ns`。旧 canonical `44799/-15.958` 只作历史快照；描述符长链被移除但地址生成仍超时，不能写成 100 MHz/15 fps PASS |
| fast tensor address arithmetic experiment | `portable_soc_descriptor_relaxed_fast_post_pipeline2_20260825`；xsim `descriptor_relaxed_fast_fifo_8x8_20260825` | 最终源码为 `45506 LUT/28073 FF/93 DSP`、直接 `-16.647 ns`、Q→D `-14.216 ns`；相对最终 relaxed 增加 793 LUT，仍为负优化，参数默认禁用 |
| tensor pixel/final address pipeline experiment | `descriptor_relaxed_pipelined2_fifo_8x8_20260825`；`portable_soc_descriptor_relaxed_pipelined2_data_proxy_20260825` | 两状态先寄存 `y*width+x`、再计算 group/base/byte；8×8 xsim PASS；640×480 proxy `44641 LUT/28069 FF/84 DSP`，Q→D 地址路径不再出现在 top-20，数据专用最差 camera FIFO→resize `-4.772 ns`（普通 max `-4.972 ns` 含控制/复位族），仍是 Xilinx proxy且未闭合 100 MHz |
| tensor pixel/final + compute-start boundary experiment | `descriptor_pipelined2_compute_start_8x8_20260825`；`descriptor_pipelined2_startcfg_twoframe_8x8_20260825`；strict compatibility `descriptor_pipelined2_startcfg_strict_8x8_20260825`；proxy `portable_soc_descriptor_relaxed_pipelined2_startcfg_proxy_20260825` | 在地址流水化之上锁存 start/config 一拍；640×480 proxy `44670 LUT/28141 FF/84 DSP`，direct `-4.950 ns`，Q→D `-4.601 ns`，相对 pixel/final `+29 LUT/+72 FF`；数据路径改善约 0.171 ns，默认关闭，仍为 Xilinx proxy且未闭合 100 MHz |
| optional final-dot-sum/accumulator boundary | `aba8388974174f209ea0c7c2cc2dcbf0`；`descriptor_pipelined2_startcfg_dottree_final_8x8_20260825`；proxy `portable_soc_descriptor_relaxed_pipelined2_startcfg_dottree_proxy_20260825` | `PIPELINED_DOT_TREE=1` 只寄存完整 final dot-sum/上下文，乘法与 reduction tree 未分级；top `44691 LUT/28606 FF/84 DSP`、`5948 LUTRAM/20 RAMB36/9 RAMB18`，direct `-4.950 ns`、Q→D `-4.752 ns`；相对 start-config `+21 LUT/+465 FF`，时序为负结果，默认关闭 |
| optional full product/pair/quad/dot tree | `4998087102b6420ba49009b7216b3f96`；`descriptor_pipelined2_startcfg_treefull_8x8_20260825`；native `treefull_final_native_elab_20260825`；proxy `portable_soc_descriptor_relaxed_pipelined2_startcfg_treefull_proxy_20260825` | `PIPELINED_DOT_TREE_FULL=1` 对 8 个 dot lane 分成 product→pair→quad→dot-sum→accumulator/overflow 四级弹性流水；top `44594 LUT/31396 FF/84 DSP`、`5948 LUTRAM/20 RAMB36/9 RAMB18`，direct `-4.950 ns`、Q→D `-4.701 ns`；相对 start-config `-76 LUT/+3255 FF`、相对 final-dot-sum `-97 LUT/+2790 FF`；填充后 II=1、增加约四级 latency，但仍未闭合 100 MHz，默认关闭 |
| optional registered descriptor replay（负优化） | `descriptor_replay_treefull_8x8_20260825`；proxy `portable_soc_descriptor_relaxed_pipelined2_startcfg_treefull_descr_replay_proxy_20260825` | full-tree 上增加 512-bit descriptor replay register；8×8 功能/AXI 守恒 PASS，但 top `47114 LUT/41837 FF/84 DSP`、`5636 LUTRAM/20 RAMB36/9 RAMB18`，direct `-4.824 ns`、Q→D `-4.701 ns`；相对 full-tree `+2520 LUT/+10441 FF`，只改善 0.126 ns 且仍未闭合，默认关闭 |
| optional capture-time descriptor prevalidation | `prevalidate_replay_8x8_final_20260825`；native `prevalidate_native_elab_640x480_20260825`；proxy `prevalidate_treefull_proxy_final_20260825` | 每 stage 缓存 5-bit error code，不复制 512-bit descriptor；top `44660 LUT/31374 FF/84 DSP`、`5832 LUTRAM/20 RAMB36/9 RAMB18`，direct `-4.824 ns`、Q→D `-4.701 ns`；相对 full-tree `+66 LUT/-22 FF`，功能计数不变但仍未闭合，默认关闭 |
| optional abort fanout replication（负优化） | `abortrep_8x8_postpatch_20260825`；proxy `abortrep_treefull_proxy2_20260825` | 同组合功能计数不变；top `44727 LUT/31380 FF/84 DSP`，direct `-5.557 ns`、Q→D `-5.434 ns`；相对 prevalidation `+67 LUT/+6 FF`，默认关闭并停止 |
| optional table response elastic FIFO | `tablefifo_8x8_20260825`；`current_treefull_prevalidate_tablefifo_nohelper_20260825` | 单项 table payload buffer；当前源码同条件 top `46174 LUT/37790 FF/84 DSP`，相对 FIFO=0 `46180/37662/84` 为 `-6 LUT/+128 FF`，RAMB/DSP 不变，direct/Q→D WNS 不变；默认关闭 |
| optional unified output FIFO（系统已接线，默认关闭） | `unified_output_fifo_latest_20260825`；`unified_output_fifo_registered_error_gate0_recheck_20260825`；`unified_fifo_errorgate0_gated_8x8_20260825`；`unified_fifo_errorgate0_gated_8x8_twoframe_20260825`；`unified_fifo_errorgate0_gated_native_elab_20260825`；paired proxy `current_treefull_prevalidate_unifiedfifo_errorgate0_gated_nohelper_retry1_20260825` | 固定 depth=2、103-bit payload；最终集成 proxy top `46390 LUT/37656 FF/5716 LUTRAM/20 RAMB36/9 RAMB18/84 DSP`，相对 FIFO=0 为 `+210 LUT/-6 FF/+80 LUTRAM`，direct/Q→D `-4.831/-4.702 ns`；timing无收益，只作协议隔离候选，不作默认资源预算 |
| optional unified output skid（系统已接线，默认关闭） | `skid_abort_error_default_retry_20260826`；`skid_soc_8x8_20260826`；`skid_soc_8x8_twoframe_20260826`；`skid_soc_16x8_20260826`；`skid_native_elab_20260826`；paired proxy `current_treefull_prevalidate_unifiedskid_nohelper_20260826` | 固定 depth=1、103-bit payload；最终集成 proxy top `46243 LUT/37766 FF/5636 LUTRAM/20 RAMB36/9 RAMB18/84 DSP`，相对无边界 `46180/37662/5636` 为 `+63 LUT/+104 FF`，BRAM/LUTRAM/DSP 不变；direct/Q→D `-5.415/-5.415 ns`，timing 负优化，仅作协议隔离候选，不作默认资源预算 |
| native write skid bridge 结构预算 | `c1_axi_write_skid_bridge` | 单项 AW/W/B 寄存器缓冲，资源预期以少量 LUT/FF 为主，不主动推断 BRAM/DSP；尚未做独立 Vivado/Efinity utilization，不能把结构估算当作 Ti60 资源报告 |
| native-width fix compatibility gates | `c1_8x8_u64fix_gate_20260825` / `c1_64x48_two_u64fix_gate_20260825` | 8×8 单帧与 64×48 两帧重新穿过真实 capture/CNN/cache/client-6/DDR/display；功能/协议证据，不是 native 资源或帧率 |
| 七客户端 arbiter forward progress | 56 写+56 读，最大等待 89/67 cycle | run `bbaccd1453aa43368eebc4e1f5bdae5a`；独立仲裁器，不是长帧系统 |
| 64-MAC 6,691,200 cycle | 已推导 | 算术下界 |
| DMA/Resize/DW 100 MHz 趋势 | `-0.191/-0.154/+3.039 ns` | Vivado 综合代理 |
| 完整 CNN 旧 flat-cache utilization | 735,256 LUT / 43,585 Reg / 99 DSP / 0 BRAM，明显不可实现 | status 残留 running 的历史中间失败基线；非最终 PASS |
| 完整 CNN 重排版资源/时序 | 28,298 LUT / 11,168 FF / 2 BRAM36 / 35 DSP；`WNS/TNS=-4.965/-2511.307 ns` | Vivado 综合代理已完成；100 MHz 未闭合 |
| Ti60 LE/DSP/M10K/WNS | 未做 | Efinity 待测 |
| DDR 实际带宽/QoS | 未做 | 板卡待测 |
| MIPI/HDMI/CDC/功耗 | 未做 | 板卡待测 |
| 640×480@15 fps | 未证明，当前结构确定不满足 | 重构后仿真+板卡待测 |

因此现有资源报告支持“板卡前功能架构可继续迭代”，不支持“Ti60 已容纳、100 MHz 已签核或 15 fps 已实现”。

## 2026-08-27 吞吐 seam 资源补充

新增 boardless 结构的 Artix-7 综合代理（`xc7a200tsbg484-1`，100 MHz，未布局布线）：

| 结构 | 配置 | LUT | FF | BRAM tile | DSP | WNS |
|---|---|---:|---:|---:|---:|---:|
| `c1_axi_n_write_burst_arbiter_128` | 3 clients / FIFO 4 | 370 | 478 | 0 | 0 | +3.787 ns |
| 两个 `c1_tensor_mem_axi128_read_burst_client` + `c1_axi_n_read_burst_arbiter_128`（优化前快照） | leaf burst 4 / fabric FIFO 8 / RSP FIFO 64 | 32,784 | 10,078 | 0 | 0 | +0.214 ns |

第二行的 0 BRAM 不是“无需片上存储”：该配置的请求/响应数组由 Vivado 映射为
distributed RAM/LUTRAM/寄存器，资源压力集中在 LUT。应在 Efinity 中比较同步读
EBR wrapper、缩短 response FIFO 和外部 DDR 直通三种实现，不能直接把 Xilinx
proxy 数字换算成 Ti60 M10K。

理想三行 cache + AXI128 pack2 的 640×480 流量为读 2,409,600 beat、写
2,006,400 beat（70,656,000 B/frame，写 beat share 45.43%）。在整数延迟模型中，
fabric effective outstanding 1/2/4/8/16/32 的 memory-only cycles 为
9,638,400/4,819,200/2,560,200/2,560,200/2,560,200/2,560,200；out=4 后受一拍
payload issue 上限限制。该结论不包含共享 CNN FSM、DDR refresh、QoS、CDC 或
布局布线余量。

新增文件及综合 runner 只保留小型 JSON/status/log；Vivado 私有 runRoot 在 worker
结束时删除。现有写 fabric 的多 outstanding 仅对多个独立 writer 的 AW 排队有效；
默认 `c1_tensor_mem_axi128_write_burst_client` 本身仍强制 `MAX_OUTSTANDING=1`，
不要把它重复计算为完整写端 MLP。另有独立的 burst-level MLP seam（见下表），但
它尚未接入该 logical adapter 或默认 SoC。

### 2026-08-27 响应 FIFO 反压优化与双 lane 写 fabric

本轮对两个 leaf 的 ready 反馈做了保守化处理：写侧 `rsp_space` 只比较当前
occupancy，读侧 `rsp_capacity` 按当前 AXI beat 需要的 0/1/2 个 logical half
使用静态阈值。这样牺牲满 FIFO 同拍 pop+push 时的一个潜在气泡，换取切断
`rsp_pop`→`RREADY/BREADY` 的组合 carry 路径。功能 xsim 已覆盖延迟/保持/错误
响应，未改变 pack2、burst 或逻辑顺序合同。

| 结构 | 配置 | LUT | FF | BRAM tile | DSP | WNS/TNS |
|---|---|---:|---:|---:|---:|---:|
| 两 leaf + read fabric（优化后） | 2 clients / leaf burst 4 / fabric FIFO 8 | 31,905 | 10,075 | 0* | 0 | +1.928 / 0 ns |
| 双 lane write fabric（优化后） | 2 lanes / block 16 / tag FIFO 64 / fabric FIFO 4 | 4,308 | 10,091 | 0 | 0 | +1.203 / 0 ns |

`*` 标记项的 payload/response arrays 在 Vivado proxy 仍可能为 distributed
RAM/LUTRAM；这不是 Ti60 M10K/EBR 结论。双 lane wrapper 首版为 4,374 LUT、WNS
`-0.160 ns`，优化后关键 tag→BREADY 路径消失；它仍由两个单 outstanding
leaf 组成，不能按“一个 writer 支持两个 AXI ID”计入预算。写 leaf 的 W hold
监视器宽度修正为 145 bit 仅影响仿真断言，不增加硬件资源。

### 2026-08-27 beat FIFO 与 ping-pong MAC 补充

| 结构 | 配置 | LUT | FF | BRAM tile | DSP | WNS/TNS |
|---|---|---:|---:|---:|---:|---:|
| 读 leaf logical-entry FIFO | REQ16 / BURST16 / MAX4 / RSP64 | 12,045 | 5,378 | 0 | 0 | +1.046 / 0 ns |
| 读 leaf beat-record FIFO（可选） | 同上，`RSP_FIFO_BEAT_MODE=1` | **1,714** | **1,182** | 0 | 0 | **+1.380 / 0 ns** |
| inter-pixel MAC ping-pong | 2 banks × 2 lanes，full tree，tag8 | 31,162 | 22,833 | 0 | 64 | +1.938 / 0 ns |
| inter-pixel MAC ping-pong（可选 4-bank） | 4 banks × 2 lanes，full tree，tag16 | 59,912 | 45,674 | 0 | 128 | +0.337 / 0 ns |
| burst-level `c1_axi128_write_mlp`（可选） | `MAX_OUTSTANDING=4` / `MAX_BEATS=16`，descriptor payload slot | 5,882 | 10,308 | 0 | 0 | +3.249 / 0 ns |
| logical `c1_tensor_mem_axi128_write_mlp_adapter`（可选） | `MAX_OUTSTANDING=4` / `MAX_BEATS=16`，64-bit pack2→MLP | 15,961 | 27,771 | 0* | 0 | +2.551 / 0 ns |
| adapter→两客户端 write MLP fabric（可选） | adapter MLP4 / raw peer / fabric FIFO6 | 16,291 | 28,296 | 0* | 0 | +2.197 / 0 ns |
| 四 lane write parallel fabric（可选 A/B） | `LANES=4` / block16 / fabric FIFO6 / tag FIFO128 | 9,858 | 20,168 | 0 | 0 | +2.166 / 0 ns |
| 两 leaf + read fabric（beat-record，可选） | 2 clients / fabric FIFO8 / leaf burst4 / leaf MAX4 / leaf RSP16 | 2,194 | 1,630 | 0* | 0 | +1.815 / 0 ns |
| DW weight tile cache + MAC overlap（可选） | full CNN top / tap-bank cache + `MAC_PREFETCH_OVERLAP=1` | 36,413 | 14,889 | 2 | 35 | **-4.959 / -1969.185 ns** |

这是同一 Artix-7 proxy 参数的布局对照，不能直接替代 Ti60/Efinity 资源报告。
beat FIFO 的每槽位宽（约133 bit）实际上略大于两个 logical 64-bit entry，
所以收益来自写入/指针/比较控制减少，而不是存储位数按二分之一减少；在 Ti60
上仍需验证 M10K 端口模式和读延迟。ping-pong 的 64 个 DSP 只对应两个 bank
各两条完整 dot lane，不能按整网可用 MAC 数量解读；其 xsim 仅证明事务级 overlap。

`c1_axi128_write_mlp` 的 0 BRAM 是因为 Artix proxy 中 descriptor payload 数组被
综合为寄存器/LUT 结构；默认参数约为 4×16×(128+16) bit 的 payload/strobe 存储，
并非“无需片上存储”。在 Ti60/Efinity 中应优先比较 EBR 推断、payload 深度与
`MAX_OUTSTANDING=2/4` 的时序；该模块现在由可选的
`c1_tensor_mem_axi128_write_mlp_adapter` 消费，但 adapter 的 payload/逻辑回显
数组在该 proxy 也仍映射为 LUT/FF，不能把 0 BRAM 理解成无需片上存储。两者都
尚未接入默认 SoC，资源预算不能直接叠加为完整 SoC 写端。四-bank MAC 的 128 DSP、+0.337 ns 也只是独立 full-tree
代理，需在真实 stage scheduler/权重带宽接线后重新估算。

DW weight tile cache 的小型 xsim 将首轮 engine cycles 从 30,570 降到 28,553；
将宽 576-bit variable-part-select 改为 tap-bank×64-bit word 后，当前 cache+
MAC-overlap full-top proxy 为 36,413 LUT/14,889 FF/2 BRAM/35 DSP，但 WNS
仍为 -4.959 ns。该存储布局明显优于旧宽数组 proxy，却仍需显式 Ti60 EBR/
同步读对照，再考虑打开；该行不能与默认 CNN 资源直接相加。

可选 `MAC_PREFETCH_OVERLAP` 不复制 DSP，只把 Conv/1x1 tile 的稳态发射从
II=2 改为 II=1。小型 engine xsim 为 30,570→29,192 cycles，和 DW cache
联合为 27,174；native 模型对应 39,571,200→31,238,400→21,715,384 cycles。
这是一条控制/存储带宽优化，仍需 full-top timing 和真实窗口供数验证。

### 2026-08-27：15 fps 吞吐 profile 的资源/时序边界

| 结构/选项 | 板前证据 | 资源含义与默认策略 |
|---|---|---|
| 读 `BURST_BEATS=16/MAX_OUTSTANDING=4` | leaf `ar=6/beats=10`；cache shell `20 bursts/320 beats/max_outstanding=4` | 只减少 AR descriptor 压力；descriptor lane-map 与响应 FIFO 随 burst 深度增长，先保留为 profile，不改 default |
| 读 `BURST_BEATS=16↔32` A/B | 紧凑 stream：`ar=9→7`、两者 `94 beats/94 packed/max_outstanding=3/page_split=1/cycles=397` | payload 不变；32-beat 的保守 logical RSP FIFO 为 `2×32×4=256` entries（16-beat 为 128），lane-map/EBR 深度需在 Ti60/Efinity 复核；仅 profile，不改 default |
| 读 `ALLOW_RSP_POP_REFILL` | depth-2 模型/RTL A-B 通过 | 不新增 RAM，增加 `rsp_ready→RREADY` 组合路径；默认 0 |
| 写 `ALLOW_RSP_POP_REFILL` | leaf `B stall 49→48`；adapter full pop+push 通过 | 不减少 payload；可能要求 EBR 同址读写 READ_FIRST/WRITE_FIRST；默认 0 |
| 写 `EMPTY_AW_BYPASS` | 首个 AW latency `1→0`，steady-state 计数不变 | 约一组 AW mux/control，代价是 source→downstream AW 组合路径；默认 0 |
| ping-pong first-beat skid | 2-bank×2-lane TB `40→38` cycles | 一项小 skid 存储；四-bank full-tree 已逼近 WNS 边界，默认仍二-bank/关闭首拍选项 |

长 burst 的 cache profile 使用 64×2-group 行以真正填满四个 AR descriptor，
但仍是串行 row miss：当前 shell 不会因为 burst 变长而自动获得行预取或计算重叠。
因此不能把 `20 bursts/320 beats` 与 native 帧的 DDR service time 直接相除；
需要在 Efinity 中确认 EBR 映射、控制器最大 ARLEN、QoS 以及 display/capture
竞争后再定案。`model/throughput_sweep.py` 的 burst 数仍是理想连续流下界，
4 KiB/行尾精确边界见 `THROUGHPUT_AUDIT_NOTES.md`。

四 lane write fabric 是双 lane wrapper 的水平 A/B，不是单 writer 的 AXI ID
乱序实现：四个单 outstanding leaf 以 block 轮转，外层 tag FIFO 恢复逻辑顺序。
`0 BRAM` 同样只代表该 Artix 配置下的 LUT/FF 映射；`9858 LUT/20168 FF` 和
`+2.166 ns` 不能直接换算 Ti60 资源或整帧吞吐，且尚未接入默认 portable SoC。

### 2026-08-27 新增吞吐边界开关

| 结构/选项 | 板前功能证据 | 资源/时序处理 |
|---|---|---|
| 读 request FIFO `ALLOW_REQ_POP_REFILL` | depth-4 满槽 `full_to_accept=5→4`，请求/AXI 计数不变 | 不新增存储；把 builder pop/地址邻接路径带入 `req_ready`，默认关闭，尚未计入 proxy |
| 读 arbiter `EMPTY_AR_BYPASS` | 空队列首个 AR latency `1→0`，正常/畸形 R 计数一致 | 一组 source→AR mux/组合路径；默认关闭，尚未计入资源预算 |
| MAC `ALLOW_OUTPUT_RESTART` | 二 bank×二 lane：`40→37` cycles、4 次同 bank 同拍重启，顺序 PASS | 不复制 DSP；增加 `out_ready→start_ready` 组合路径，默认关闭；最新同脚本 proxy default/optional 为 `31165/31163 LUT、22833 FF、64 DSP、WNS +1.247/+1.247 ns` |

上述数字是边界 A/B，不应与 full-top 资源相加。尤其是 output-restart 只改变
bank reuse 时刻，不会降低 `64 DSP` 的算术资源；若 output FIFO 或 scheduler
无法持续供数，开关不会带来有效吞吐。目标 Ti60/Efinity 上应分别检查 AR、
request-ready 和 bank-select 的关键路径，再决定是否打开。

### 2026-08-27 request/response FIFO 边界补充

| 结构/选项 | 板前证据 | 资源/时序处理 |
|---|---|---|
| 写 leaf `ALLOW_REQ_POP_REFILL` | `full_to_accept=6→5`，`req/aw/beats=12/12/12` | 不增存储；builder 邻接判断进入 `req_ready`，默认 0，尚未计入 proxy |
| 并行 MAC `ALLOW_TAG_POP_PUSH` | 2-bank `52→48`、`full_tag_pop_push=0→6`；4-bank `59→57`、`0→2` | 不增 DSP；仅满 tag FIFO 的组合 admission，需检查 `out_ready→start_ready` |
| cache 组合 `ALLOW_RSP_POP_REFILL` | 五选项长 profile `640 words/20 bursts/320 beats/max4/cycles1883` | 组合兼容性 smoke；read-leaf 专用 A/B 才覆盖满槽事件；默认 0 |

这些是边界控制优化，不能与 15 fps 资源预算线性相加，也不能替代真实
Ti60/Efinity EBR、DDR QoS、AXI ID/顺序和时序报告。

### 2026-08-27 最大行 burst32 门控

`-MaxRow` 只改变 testbench 几何（`1280` logical words、20 个 32-beat
descriptor、640 个 AXI beats、四 outstanding），没有改动综合默认 top，因而
不产生可单独计入的 LUT/FF/DSP 数字。它的用途是把 response/payload FIFO 的
容量和 4-KiB 分割边界推到冻结模型上限；实际 EBR 数量、同步读时序和 DDR
控制器占用必须在 Ti60/Efinity 重新综合测量。

### 2026-08-27 只读 cache-refill scheduler 控制面

| 结构 | 配置 | LUT | FF | BRAM tile | DSP | WNS/TNS |
|---|---|---:|---:|---:|---:|---:|
| `c1_cache_refill_scheduler` proxy（最新 detached run） | `CMD_FIFO_DEPTH=8` / `MAX_OUTSTANDING=4` / `EPOCH_W=4` / `EMIT_DRAIN_WORDS=1` | 839 | 1,647 | 0 | 0 | +1.274 ns / 0 ns |

该 proxy 目标为 Artix-7 `xc7a200tsbg484-1`、100 MHz，包含 command FIFO、
metadata credit、epoch fence 和可选 drain 端口，但不包含 AXI reader、line
cache、DDR controller 或 SoC。0 BRAM 只表示该小配置在 Vivado proxy 中被映射
为寄存器/LUT；不能换算成 Ti60 EBR，也不能与 read leaf/cache/MAC 表格直接
相加。

与资源数字对应的 boardless composition 是
`c1_cache_refill_scheduler_read_client`：其 scheduler logical-word credit
(`SCHED_MAX_OUTSTANDING=16`) 与 reader AXI burst credit
(`READER_MAX_OUTSTANDING=4`) 分开，smoke 为 3 words/1 burst/2 beats。该
wrapper 仍是 read-only staged seam；在 line-cache 端接入前还需为 abort 时
未发出的 declared-word suffix 增加 cancellation-token/completion 逻辑，故
本表不把它计入默认 SoC 资源或 15-fps 预算。随后在 2026-08-28 的
真实 line-cache exact shell gate 中已完成独立接线；这里保留的是 scheduler
控制面/早期 wrapper 的历史快照。

### 2026-08-27 exact-count completion composition

| 结构 | 配置 | LUT | FF | BRAM tile | DSP | WNS/TNS |
|---|---|---:|---:|---:|---:|---:|
| `c1_cache_refill_scheduler_read_client_exact` proxy | scheduler credit 16 / reader burst credit 4 / req FIFO 32 / burst 16 / exact-count adapter | 35,435 | 11,743 | 0 | 0 | +0.799 ns / 0 ns |

该 proxy 目标仍为 Artix-7 `xc7a200tsbg484-1`、100 MHz，包含 scheduler、
AXI128 read leaf、drain stream 和 exact-count completion adapter，但不包含
line-cache payload RAM、DDR controller、AXI shared mux 或 SoC。相较于当前
wrapper-only 的 35,202 LUT/11,683 FF，adapter 约增加 233 LUT/60 FF；这只是
同一参数下的结构差量，不能直接映射为 Ti60 EBR 或整网资源。

适配器生成的 suffix 是 zero/error poison，不是有效存储；`word_count=0` 只
产生错误 completion，不能让 line-cache 从 `ST_REFILL_DATA` 自动退出。因此
预算/接线必须把 `word_count>=1` 和三类 terminal token（`cmd_done`、
`abort_done`、`flush_done`）列为硬合同。ready 反压目前是组合贯通路径，若
目标器件时序不收敛，应额外预算一深度带 normal/drain sideband 的 skid FIFO。

### 2026-08-28 真实 line-cache exact shell 与时序 A/B

| 结构 | 配置 | LUT | FF | BRAM tile | DSP | WNS/TNS |
|---|---|---:|---:|---:|---:|---:|
| `c1_window_line_cache_c8_exact_burst_shell`（无 skid 对照） | 3 行、1280 words/行、scheduler 16、reader 4、16-beat | 35,543 | 11,923 | 7.5 | 0 | -1.622 ns / -97.709 ns |
| `c1_window_line_cache_c8_exact_burst_shell`（当前） | 同上，`REFILL_SKID_DEPTH=2` | 35,639 | 11,930 | 7.5 | 0 | +0.302 ns / 0 ns |

以上为 Artix-7 `xc7a200tsbg484-1`、100 MHz、detached Vivado proxy；当前
run id 为 `exact_cache_shell_proxy_skid2_v2_20260828`。注册 FIFO 增加约
96 LUT、7 FF 和最多两词缓存，但把真实 line-cache 接入后的关键路径拉回
正裕量。它仍是 read-only optional shell，不包含 shared read/write mux、
DDR controller、CNN/MAC 或 Ti60/Efinity 原语；7.5 BRAM tile 只代表 Vivado
对 3×1280×64 payload RAM 的 proxy 映射，不能直接当作 EBR 消耗。Vivado
仍提示 data_mem 的 7 个 BRAM 未合并可选输出寄存器，目标器件需另做 RAM
wrapper/tap pipeline 评估。

### 2026-08-28 共享 owner/epoch fence 控制面

| 结构 | 配置 | LUT | FF | BRAM tile | DSP | WNS/TNS |
|---|---|---:|---:|---:|---:|---:|
| `c1_axi_shared_owner_epoch_fence` proxy | `EPOCH_W=4`、`REQUIRE_CONTEXT=1`、`ALLOW_RESTART=1` | 24 | 206 | 0 | 0 | +5.948 ns / 0 ns |

该 detached Vivado proxy（run `owner_epoch_fence_proxy_v1`）只综合 admission、
abort/flush drain、epoch 和计数器控制面，目标为 Artix-7
`xc7a200tsbg484-1`、100 MHz；不包含 AXI payload mux、DDR controller、CNN、
line-cache 或 portable SoC。`c1_axi_n_serial_arbiter_128` 新增的
`read_busy/read_quiescent/write_busy/write_quiescent/read_owner/write_owner`
是既有状态/owner 寄存器的只读组合导出；shell 另外显式导出
`read_admit/write_admit/read_fire/write_fire` 诊断端口，未增加独立 FIFO 或 RAM，因此不能把
24 LUT/206 FF 当作完整共享 fabric 的增量，也不能把它与 arbiter/reader/cache
表格直接相加。接入真实 owner/QoS mux 后，应重新测量 owner 保持路径、
admission 组合路径和最终 Efinity LE/EBR/DSP。

focused xsim 的板前协议证据为：

```text
C1_AXI_SHARED_OWNER_EPOCH_FENCE_ARBITER_PASS ar=1 r=1 aw=1 b=1 epoch=2 cycles=23
```

测试覆盖维护期间阻止空闲新 owner、保留当前 stalled owner 直到 R/B 排空，
并检查 abort/flush 完成 token 与 epoch 只递增一次。该 marker 只说明控制面
合同成立；默认 portable SoC 尚未接入该 fence 或 shared read/write payload mux，
故资源表不计入默认 SoC，也不构成 native 640×480/15 fps 签核。

### 2026-08-28 可选 owner/epoch + serial-arbiter integration shell

| 结构 | 配置 | LUT | FF | BRAM tile | DSP | WNS/TNS |
|---|---|---:|---:|---:|---:|---:|
| `c1_axi_shared_owner_epoch_arbiter_128` proxy | `CLIENTS=2`、`READ_RESPONSE_SKID=0` | 434 | 233 | 0 | 0 | +5.769 ns / 0 ns |
| 同上 | `CLIENTS=7`、`READ_RESPONSE_SKID=1` | 1411 | 407 | 0 | 0 | +2.144 ns / 0 ns |

两次均为 detached Vivado `xc7a200tsbg484-1`、100 MHz proxy；第二行对应
默认 portable fabric 的 client 数与可选 read-response skid，适合作为板前资源
预算的控制/仲裁增量参考。shell 通过当前 owner 保持 gate 连接真实 serial
arbiter，未复制 payload FIFO，也不包含 DDR、CNN、line-cache 或 SoC。默认
`c1_r1_portable_soc` 仍未实例化它，因此不能把表中数字加到默认 SoC，也不能
把 focused xsim 或 proxy timing 当作 15 fps signoff。

integration shell 的板前回归 marker：

```text
C1_AXI_SHARED_OWNER_EPOCH_ARBITER_PASS ar=1 r=1 aw=1 b=1 epoch=2 cycles=23
```

### 2026-08-28 生产 RTL QoS monitor（默认关闭）

| 结构 | 配置 | LUT | FF | BRAM tile | DSP | WNS/TNS |
|---|---|---:|---:|---:|---:|---:|
| `c1_axi_shared_qos_monitor` proxy | `CLIENTS=7`、`COUNTER_W=24`、100 MHz | 2268 | 4000 | 0 | 0 | +1.465 ns / 0 ns |

该 proxy 只包含观测寄存器与计数器：每客户端 AW/AR wait、W/R/B stall，
accepted beat，read/write owner hold，以及 underflow、帧周期和 deadline miss。
24 bit 饱和计数在 100 MHz 下可覆盖约 167 ms 连续等待；仅 global owner max 使用
标量 `max+owner_id`，避免关键路径上的全局变量索引写回；per-client totals
仍保留按 owner 索引的诊断写回。资源/时序数字是独立 monitor 增量，
不能和完整 SoC 或 line-cache proxy 直接相加；若改为 32 bit，需重新综合，不能
沿用该 WNS。

生产顶层通过 `ENABLE_SHARED_QOS_MONITOR=0/1` 选择 generate 分支，默认 0；
启用时 `csr_clear_stats_pulse` 可清零。per-client 向量仍是层次化 native 调试
信号，选定 aggregate live read window 已占用 APB `0x108..0x12c`；monitor 关闭时
窗口返回 0。独立功能 marker：

```text
C1_AXI_SHARED_QOS_MONITOR_PASS aw0_wait=3 ar1_wait=2 b0_stall=2 r1_stall=4 read_hold=4 write_hold=3 underflow=1 deadline_miss=1
```

真实 8×8 tagged two-frame native BFM（`native_qos_8x8_tagged_twoframe_v7`）的端到端
聚合读窗口为
`frame_count=2/last_frame_cycles=3446518/deadline_miss=2/underflow=2`，并观察到
`raw_prefetch_done=3/tagged_new_done=2/swap=2`；其中
`r4_stall=5338987`、`ar5_wait=5339177` 暴露了原始 ID-less display HOL。另有
`C1_QOS_APB_READBACK pass=1` 逐字段核对层次化值与 APB 值（busy/owner 是 live
单调计数，APB 读期间允许增加）。这个结果是 QoS
风险定位证据，不是资源签核；启用 monitor 也不等于启用 owner/epoch payload
mux 或达到 15 fps。下一步应在 response FIFO/owner fence 候选配置和更大 frame
上重复测量，并复核 aggregate 寄存器在 Efinix EBR/逻辑资源中的映射。

同一 BFM 打开 response FIFO 的 A/B (`native_qos_fifo_tagged_twoframe_v1`) 将
`r4/r5` stall 降为 `27/27`、`ar4/ar5` wait 降为 `194/234`，但总窗口仍为
`3446518` cycles、deadline/underflow=`2/2`。FIFO 存储下界约 15,104 bit，
Vivado 独立 proxy 增量约 `+494 LUT/+44 FF/+304 LUTRAM`（完整 SoC proxy
约 `+506 LUT/+41 FF/+304 LUTRAM`）；这些是结构预算，尚未经过 Ti60/Efinity。

### 2026-08-28 full-top tensor burst logical/beat proxy

| 结构 | 配置 | LUT | FF | BRAM tile | DSP | WNS/TNS |
|---|---|---:|---:|---:|---:|---:|
| full-top logical-entry burst | `portable_soc_tensor_burst_logical_v4`，`RSP_FIFO_DEPTH=128` | 80,791 | 39,369 | 32 | 100 | **-52.200 / -175,089.359 ns** |
| full-top beat-record burst | `portable_soc_tensor_burst_beat_v1`，`RSP_FIFO_DEPTH=64` | 48,411 | 30,950 | 32 | 100 | **-52.550 / -191,612.156 ns** |

两行均为 Artix-7 `xc7a200tsbg484-1` full-top proxy；logical/beat 均为综合完成
但 timing failed，不能将 beat 的资源下降直接视为可用优化。此前 logical v3
的正 WNS 是解析错误，不再作为预算依据。
BRAM/DSP/LUT/FF 是 Xilinx proxy 观察值，不是 Ti60/Efinity 预算；native beat
8×8/64×48 两帧功能 PASS 也不改变该时序边界。

### 2026-08-28 REGISTER_ABORT_RESET A/B 资源与时序

native resize PASS；native 8×8/64×48 abortreg 均 PASS，`protocol=0`。proxy
baseline 为 `48192 LUT/31227 FF/32 BRAM/88 DSP`、WNS/TNS
`-5.900/-67577.578`；abortreg v2 为 `48211 LUT/31237 FF/32 BRAM/88 DSP`、
WNS/TNS `-5.416/-66644.070`，`timing_met=false`。剩余最差路径为 reset 相关的
descriptor decoder path；上述资源仍为 proxy 观察值。

### 2026-08-28 PIPELINED_DECODER_VALIDATION 资源与时序

decoder pipeline 已在 engine→cnn_top→system_bridge→portable_soc 参数化，默认为 0。
MicroStyle engine PASS marker：`C1_R1_MICROSTYLE_ENGINE_PASS ... outputs=836 ... first_run_cycles=30570`。
完整 8×8 两帧组合 PASS（`done=2/swaps=2/drops=0`、`protocol=0`、
`last_frame_cycles=3446518`、`r4/r5 stall=29/29`、`ar4/ar5 wait=202/244`）。

proxy `tensor_burst_beat_pipelined_split_addr_abortreg_decoderpipe_v1` 资源为
`47493 LUT/31441 FF/32 BRAM/88 DSP`，WNS/TNS `-5.362/-66042.227 ns`，
`timing_met=false`；abortreg v2 对比为 `48211/31237/-5.416/-66644.070`。配置阶段
每 descriptor 固定增加两拍，运行期协议不变；该 proxy 仍非 timing signoff。
