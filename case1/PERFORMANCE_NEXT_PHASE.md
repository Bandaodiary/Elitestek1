# 赛题一下一阶段：tensor 性能化实施门槛

更新时间：2026-08-27。本文把当前 correctness-first 结果转成下一轮 RTL 迭代的可执行验收合同。

## 已经量化的事实

| 项目 | 当前证据 | 结论 |
|---|---|---|
| 顺序数据面 | Python 模型：21,388,800 个 64-bit 请求、342,220,800 B/frame | 不能直接满足 640×480@15 fps |
| 计算下界 | 428,236,800 MAC/frame ÷ 64 lanes = 6,691,200 cycle/frame | 已略超 6,666,667-cycle 预算；只压 DDR 不够 |
| 128-bit packing | 独立 RTL：100 request→51 AXI beat、48 对合并；proxy synth 412 LUT / 649 FF / 0 BRAM / 0 DSP，100 MHz WNS +2.588 ns | 合并器协议和可综合性可行，但尚未接入系统；裸模块 IO 未约束，不能外推板卡端口资源 |
| memory path seam | xsim `7a447dba98be413d9e36c9f20bee443d`：legacy/performance 两分支，3 requests→2 AXI beats、1 packed pair、3 responses；proxy synth `ca3e6b438d7e471bb39a083fc31746de` mode0/1：122/413 LUT、176/651 FF，WNS +6.274/+2.586 ns | `flush_req` 锁存到 `flush_done`，并提供 `quiescent`；尚未接入单 outstanding adapter |
| 3×3 line/window cache | Python：8×8、16×16、64×48 的 external words 为 408、1,632、19,584；按真实 group 交织、整行全 group refill时逐 tap 行命中率 98.7434%、99.3717%、99.8429% | 完整行预取流量模型；不是 RTL/DDR 测量，stride-2 与 stride-1 比例不同 |
| 3-row line/window cache RTL control | xsim `8991ff1ef0954d669c3a4568208ae5a2`：720 taps、16 refills、128 external words；proxy synth `7ee82460964f4926b9b5030655bd049d`：97 LUT、342 FF、0 BRAM/0 DSP、WNS +5.042 ns | row-tag-only、round-robin 的独立小帧控制壳；不含 pixel data BRAM，也未接入 adapter/DDR |
| all-group C8 payload cache | normal/fault/max-row xsim 全绿；640×1×2 完成 1280-word refill；proxy synth `d07c3a3c7348474ea465ff73f765707a`：288 LUT、203 FF、7.5 BRAM tile、0 DSP、WNS +1.086 ns | payload、容量、fault、flush/abort 已闭合到独立模块；仍是逐 tap/逐 word、单 outstanding |
| tensor window-cache seam hardening | xsim `1e6f562adbc34ea383932840b97aa0e4`：17/17 req/rsp、5 row refills、40 refill reads、8 bypass reads、2 writes、50 downstream，`cfg_rejects=1 runtime_fallbacks=1`；proxy `6dc7d474aff34448ba590ff615927a53`：1,236 LUT/792 FF/7.5 BRAM/0 DSP、WNS +1.086 ns | adapter↔cache↔narrow-memory 接口闭环已动态验证；配置拒绝和路由后错误以 route lock 安全收口，adapter/seam 协议、分类和 owner 断言启用；资源含 C8 cache，较历史 209b 基线仅 +2 LUT/+5 FF |
| adapter sideband 与兼容性 | 默认 `5cc1f6d0fcd242bf9de7fe48c5418270` 保持 2,230 requests；sideband `513714c5626b47e99bc730cf7d3fdf9f` 为 22 configs、1,512 cacheable/266 bypass reads | 默认 FSM 不变；3×3/DW tap 与安全旁路分类已验证。历史 trace 中 407/2,229（18.2593%）邻接可 pair，独立 packer 的 49% 不能外推当前 adapter |
| adapter/cache 动态 64-bit 小尺寸链 | xsim `9212d5a042ae4d9895a3162869e3815f`：22 configs，2,230/2,230 logical req/rsp；1,512 cacheable reads 中 1,493 hit/19 miss，19 refills/204 words；1,810 logical reads→502 downstream reads，下降 72.3%；420 writes，1 memory error，5-cycle abort drain；原 22-stage bit-exact marker同时 PASS | 真实 adapter→seam→C8→64-bit BFM 已闭环并保持请求/响应配平；`502=298 bypass+204 refill`。仍是 4×4/8×4、单 outstanding 小尺寸测量 |
| adapter/cache/AXI128 动态小尺寸链 | xsim `be4977424d9d484e80340f970d9904d0`：502/502 AR/R、420/420/420 AW/W/B；上下 lane 462/460；AW-first/W-first/same 318/81/21；AR/AW/W stall 1577/1583/1580，R/B gap 1194/915，B hold 2，error 1，abort 5 | 真实 bridge 与严格 AXI BFM 已闭环，`502 AR=298 bypass+204 refill`；仍是单拍/单 outstanding，不能外推 native 帧率 |
| portable SoC cache-enabled 小帧 gate 矩阵 | 8×8 单帧 `c1_8x8_gate_20260825`；16×8 两帧 `c1_16x8_two_gate_20260825`；64×48 单帧 `c1_64x48_single_gate_20260825`；64×48 两帧 `c1_64x48_two_gate_20260825` | 8×8 `AW/W/B=852/868/852`、`AR/R=1119/2199`；16×8 两帧 `done=2 swaps=2 drops=0`、`AW/W/B=3376/3472/3376`、`AR/R=4185/5463`；64×48 单帧 `AW/W/B=40224/41664/40224`、`AR/R=48427/51643`；64×48 两帧 `done=2 descriptors=44 swaps=2 drops=0`、`AW/W/B=80448/83328/80448`、`AR/R=96793/102295`；这是功能/协议与 ownership 证据，不是 native 帧率 |
| 64×48 shape boundary | `c1_64x48_gate_compile_20260825` | xvlog/xelab shape elaboration PASS；随后 latest gate 已完成单帧和两帧有界动态回归；不外推 native 动态带宽或性能 |
| native 640×480 shape boundary | `c1_640x480_final_elab_20260825` | tensor adapter 64-bit geometry/address fix、native address-map assertion 与 associative store 后 xvlog/xelab PASS、stderr 为空；未启动 portable SoC xsim |
| native 640×480 display prefetch staged preflight | `native_prefetch_run2_20260825` | 独立真实 display pair 双路完成 `responses=307200/307200`、`axi_ar=4800/4800`、`axi_r=76800/76800`、`underflow=0/0`；地址/4 KiB/行边界/line-store CDC 全部 PASS；不含 capture/CNN/共享仲裁/QoS |
| native 640×480 capture writer staged preflight | `c1_native_capture_writer_final_20260825` | 真实 XRGB writer 三 slot 写回/读回 `frames=3`、`AW/W/B=14400/230400/14400`、`readback_pixels=921600`；slot `00100000/0022c000/00358000`，AW/W/B/源端回压 PASS；不含 camera/CSI、input DMA、CNN/共享仲裁 |
| native 640×480 capture/table/ISP staged preflight | `c1_native_capture_table_paced_full_20260825` | 真实 `c1_r1_capture_subsystem` 完成 3×642×482 RAW10→640×480，`pixels/sof/eol/eof=921600/3/1440/3`，Gamma `1024`，table `AR/R=3/3`，writer `AW/W/B=14400/230400/14400`；按 sensor-overflow 合同插入 camera blanking；不含 CSI/portable SoC input DMA/共享仲裁/CNN/QoS |
| native 640×480 input-DMA/table/arbiter staged preflight | `c1_native_input_dma_full_20260825` | 真实 table reader + XRGB reader + `c1_axi2_serial_arbiter_128` 三 slot 逐像素通过；table `AR/R=3/3`、frame `AR/R=14400/230400`、shared `AR/R=14403/230403`，`frame_pixels=921600`；不含 boardless job/output DMA/七客户端/CNN/QoS |
| native 640×480 read→write DMA loopback staged preflight | `c1_native_dma_loopback_final2_20260825` | 真实 table/XRGB read + read arbiter + XRGB writer + write skid bridge + write arbiter + associative DDR 回读完成三 slot `frame_pixels=921600`；input `AR/R=14400/230400`，output `AW/W/B=14400/230400/14400`；闭合 DMA 集成与回压，不代表 CNN/QoS/15 fps |
| native 640×480 boardless job staged preflight | `native_boardless_job_hold_full_20260825` | 真实 boardless frontend + table/22 descriptor + input/output DMA + 外部 CNN echo 完成 `cnn_in/cnn_out=307200/307200`、input `AR/R=4800/76800`、output `AW/W/B=4800/76800/4800` 和逐像素 output 回读；不代表七客户端 fabric、真实 CNN/tensor、display QoS 或 15 fps |
| native 640×480 boardless + 7-client fabric contention preflight | `native_fabric_full2_20260825` | boardless job 为真实 arbiter client-0，六个 synthetic peer 各完成 `AW/W/B/AR/R=18/72/18/18/72`；job `AW/W/B/AR/R=4800/76800/4800/4800/76890`，output `307200` 像素；synthetic 最大 channel wait `104/105/103/107/117/118` cycles。证明 fabric forward progress/读回守恒，不代表 portable SoC 七个真实叶模块、真实 CNN/tensor、display QoS 或 15 fps |
| native 640×480 boardless + real parameter leaf fabric slice | `native_fabric_param_full_20260825` | client-1 使用真实 parameter-loader + parameter-bank，`param AR/R=66/1056`、`generation=1`；其余五个 peer 最大等待 `158/162/160/169/167` cycles，job/output 数据面仍完整。证明一个真实 read-only leaf 的 fabric 接入，不代表七个真实叶模块或 QoS |
| portable SoC 64×48 seven-client traffic monitor | `portable_client_gate_64x48_20260825` | c0..c6 必需方向全部出现，但 styled-display client-5 连续 AR wait 达 `1,243,738` cycles，超过 `1,000,000` guard；xsim exit 1。该失败是当前 ID-less read-owner 长 hold 的性能/QoS 基线，不能放宽阈值冒充 PASS |
| portable SoC display response FIFO（单帧） | `portable_display_fifo_reader_gate_full_64x48_20260825` | depth=128、预留 64 token credit；c4/c5 max AR wait `76/83`、R hold `2/2`，monitor + 完整 64×48 BFM 严格 PASS；reader pre-AR admission 保证 VALID stability |
| portable SoC display response FIFO（两帧 ownership） | `portable_display_fifo_credit_only_twoframe_8x8_20260825` | credit-only 版本 `done=2 swaps=2 drops=0 display_done=1` 严格 PASS；带 `!hold_requests` 的旧探索版本明确死锁于第二 pair，已移除该条件 |
| portable SoC display response FIFO（64×48 两帧） | `portable_display_fifo_credit_only_twoframe_64x48_20260825` | `done=2 swaps=2 drops=0`、`AW/W/B=80448/83328/80448`、`AR/R=96796/102358`，c4/c5 wait `76/83`、hold `2/2`；FIFO/line-store drain 与 display pair ownership 在 shape-scaled 长度下通过 |
| portable SoC display response FIFO（64×48 两帧 aggregate monitor） | `portable_display_fifo_twoframe_monitor2_64x48_20260825` | monitor 等待 `job_completions=2` 后汇总两帧：c4/c5 `AR/R=100/1600`、max wait `89/83`、hold `2/2`；BFM 同时 `done=2 swaps=2 drops=0` |
| shared-fabric read response skid | `readskid_burst4_missingrlast_final_20260826` / `legacy_burst4_postguard_20260826`；SoC `fabric_readskid_soc8x8_retry_20260826`；native elaboration `fabric_readskid_native_elab_postguard_20260826` | `c1_axi_n_serial_arbiter_128` 新增默认关闭的一拍 R response boundary。legacy/skid 均通过 7 clients、56 read bursts/224 R beats、56 writes；skid 额外覆盖缺失 RLAST 的 ARLEN 收口和 terminal beat 不误吞 extra beat。8×8 SoC 保持 `AW/W/B=852/868/852`、`AR/R=1119/2199`、22 descriptors、`done/swaps/drops=1/1/0`；DDR-side R stalls `1952595→0`，client-side `fabric_r_stalls=1951641`，证明反压被隔离而非删除。最终源码 640×480 elaboration PASS。 |
| shared-fabric read response skid proxy | `fabric_readskid_fulltree_proxy_retry_20260826` | full-tree/prevalidate/address/start 同条件 proxy 为 `44640 LUT/31490 FF/84 DSP`，direct/Q→D `-4.824/-4.701 ns`；最差仍是 camera FIFO→fatal/abort→output-DMA 控制链。该 proxy 在最后一条 terminal-extra-beat guard 前启动，最终 guard 已由 standalone + native elaboration 重验；不据此宣称最终源码时序改善。开关保持默认关闭。 |
| registered fatal fault ticket | controller legacy `8be7cfb239b449eabd37f12f9fbe276a` / ticket `e600e09f5487450c935bab144b7ff09c`；SoC `fatal_ticket_soc8x8_20260826`；native `fatal_ticket_native_elab_20260826`；paired proxy legacy `fatal_ticket_paired_legacy_proxy_20260826` / ticket `fatal_ticket_fulltree_proxy_retry2_20260826` | `REGISTER_FATAL_TICKET=1` 把内部 fatal 分类结果的 code/address 原子寄存并形成一整拍 abort，sticky source 在撤销前不会重复报错；软件 ABORT 与 system-disable 仍立即广播。controller 定向覆盖 capture error、单次 report、三路 abort 和未延迟的软件 ABORT；8×8 动态 SoC 保持 `AW/W/B=852/868/852`、`AR/R=1119/2199`、22 descriptors、`done/swaps/drops=1/1/0`，640×480 elaboration PASS。同源码/同泛型 proxy 仅 `44660 LUT/31374 FF`→`44672 LUT/31420 FF`，direct WNS `-4.824→-4.350 ns`，Q→D `-4.701→-0.877 ns`；旧 camera FIFO→fatal/abort 链退出两个 top-20，新的 direct/Q→D 瓶颈分别位于 parameter scheduler enable 与 job-controller→CNN-engine state。开关暂保持默认关闭，等待板前更完整 fault-injection/abort-drain 回归后再晋升推荐配置。 |
| parameter-scheduler staged validation + registered terminal metadata | artifact/fault `param_scheduler_directed_final_20260826`；engine `cc9e43673b88499a9813964e6d91ed81`；SoC `param_terminalflag_soc8x8_20260826`；proxy `param_terminalflag_ticket_proxy_20260826` | START 时快照配置和乘法结果，新增一拍 `ST_VALIDATE` 用寄存数据完成 size/range 检查；region 末拍有效字节数预计算为 5 bit，并以 1-bit terminal flag 隔离 word-count 比较。训练工件仍为 1,030 reads/writes、16,379 B；新增六类错误优先级、validate-abort 和 START 后 live-cfg 破坏回归。相对 ticket-only proxy，资源 `44672 LUT/31420 FF→44739 LUT/31618 FF`（`+67/+198`，DSP 仍 84），direct/Q→D `-4.350/-0.877→-2.069/-0.694 ns`；所有 scheduler 旧端点退出 top-20。每层增加 1 个校验周期；新 direct 瓶颈转到 tensor adapter tap-Y→pixel-index 地址计算。 |
| pipelined tensor tap-coordinate strength reduction | adapter legacy/pipeline `tapcoord_shift_legacy_20260826` / `tapcoord_shift_pipeline_20260826`；SoC `tapcoord_shift_soc8x8_20260826`；proxy `tapcoord_shift_ticket_proxy_retry1_20260826` | 仅在 `PIPELINED_TENSOR_ADDRESS=1` 时利用合法 descriptor 的 stride∈{1,2} 与 3×3 tap 合同，将 `integer out*stride+delta` 改为窄位移/加减/钳位；legacy 表达式与延迟不变。最差 direct WNS `-2.069→-1.066 ns`，旧 tap/pixel-index 路径退出 top-20；资源 `44739/31618/84→44706 LUT/31622 FF/80 DSP`。新 direct 瓶颈转为 job-controller state→conv-tile read-address CE，Q→D 仍为 controller→engine state `-0.692 ns`；100 MHz 尚未闭合。 |
| registered-owner system-disable qualification | controller legacy/ticket `disable_owner_legacy_20260826` / `disable_owner_ticket_20260826`；SoC `disable_owner_soc8x8_20260826`；proxy `disable_owner_ticket_proxy_20260826` | `run_armed_q` 已是全部前台事务的寄存 ownership，因此 system-disable 取消不再组合回读 parameter/capture/NN/boardless/pending-pair busy。定向用例确认 disable 当周期四路 abort 立即广播；完整 SoC 保持通过。旧 boardless-busy→abort→dot-ready 路径退出 top-20，direct/Q→D `-1.066/-0.692→-0.682/-0.380 ns`；资源 `44740 LUT/31617 FF/80 DSP`。新 direct 瓶颈为 parameter-bank BRAM→affine-invalid。 |
| registered affine-word verdict boundary | engine `affine_verdict_pipe_engine_20260826`；SoC `affine_verdict_pipe_soc8x8_20260826`；proxy `affine_verdict_pipe_ticket_proxy_20260826` | 参数 payload 仍在 BRAM 响应周期写 cache，只把 multiplier/shift 单字合法性 verdict 寄存一拍，再更新 sticky `affine_invalid_q`。engine 的 22层/1,115参数读/6故障（含 shift=48）与完整 SoC 均通过。旧 BRAM→affine-invalid 路径退出 top-20；direct/Q→D `-0.682/-0.380→-0.613/-0.380 ns`，资源 `44568 LUT/31617 FF/80 DSP`（LUT -172）。新 direct 瓶颈转到 weight-repack input-group/channel 控制。 |
| staged weight-layout verdict + repack terminals | engine `repack_terminal_pipe_engine_20260826`；SoC `repack_terminal_pipe_soc8x8_20260826`；proxy `repack_terminal_pipe_ticket_proxy_retry1_20260826` | parameter-done 边沿寄存 `input_groups×output_groups×taps` layout verdict，并预计算最后linear byte/input channel/tap；新增一拍 `ST_WEIGHT_LAYOUT`，使乘法、减法和FSM不再贯穿repack counter CE。engine/SoC均通过，engine增加10个控制等待周期。旧路径退出 top-20；direct/Q→D `-0.613/-0.380→-0.587/-0.380 ns`，资源 `44544 LUT/31641 FF/80 DSP`。新瓶颈为tensor adapter pixel-index→final request address。 |
| pipelined final tensor-address strength reduction | adapter `finaladdr_shiftadd_pipeline_20260826`；SoC `finaladdr_shiftadd_soc8x8_20260826`；proxy `finaladdr_shiftadd_ticket_proxy_20260826` | `tensor_addr_from_pixel_fn` 的64-bit `pixel×groups`与bank乘法改为descriptor合法域1–8 groups的32-bit显式移位/加减，以及bank 0/1/2常量分支；不增加状态或访问周期。adapter/SoC地址与AXI计数保持通过，旧pixel-index→request-address路径退出 top-20。direct/Q→D `-0.587/-0.380→-0.380/-0.380 ns`；资源 `44604 LUT/31656 FF/78 DSP`（`+60 LUT/+15 FF/-2 DSP`）。新瓶颈统一为frame-manager input-state候选搜索。 |
| frame-manager ordered READY queues | manager `ready_fifo_directed_20260826`；controller `frame_ready_fifo_soc_control_20260826`；SoC `ready_fifo_soc8x8_20260826`；proxy `ready_fifo_ticket_proxy_20260826` | 单路 capture 与单路 NN 的完成次序天然等于 frame-id 次序，因此用3-entry input READY FIFO和2-entry output READY FIFO替代每周期32-bit oldest-frame扫描。定向覆盖队满、两次drop-oldest、输入/输出同周期pop+push及abort保留display；完整SoC的22 descriptors和AXI计数保持。旧17-level/8-CARRY4 manager路径退出两个top-20；direct/Q→D `-0.380/-0.380→-0.306/-0.060 ns`，资源 `44272 LUT/31597 FF/78 DSP`（`-332 LUT/-59 FF`）。新瓶颈分别为resize插值DSP链和descriptor decode。 |
| bilinear complement-weight range reduction | primitives `interp_nosat_primitives_20260826`；resize system `interp_nosat_system_20260826`；SoC `interp_nosat_soc8x8_20260826`；proxy `interp_nosat_ticket_proxy_retry1_20260826` | Q0.12合同保证每级 `w0+w1=4096`，故rounded numerator最大仅1,046,528且输出天然为0–255；删除恒不可达的`>255`饱和比较，并将pair arithmetic收窄为20 bit，增加仿真期合同断言。10,726组插值向量、313个system输出及完整SoC均PASS。插值DSP/carry路径退出两个top-20；资源 `44175 LUT/31595 FF/78 DSP`（`-97 LUT/-2 FF`），direct/Q→D `-0.306/-0.060→-0.291/-0.060 ns`。新direct瓶颈为parameter fault/error/ready跨层反馈→tensor-adapter counter CE。 |
| registered launch-contract fault boundary | bridge `contract_fault_boundary_retry1_20260826`；SoC `contract_fault_boundary_soc8x8_20260826`；proxy `contract_fault_boundary_ticket_proxy_20260826` | live generation比较仍即时抑制尚未发出的双sink START，但运行期error/VALID/READY门只使用既有sticky `start_contract_fault_q/code_q`；故障捕获边沿最多退休一个在途beat，整帧随后abort且不能提交display。定向覆盖parameter/config generation错误码、单拍边界、停止传输及abort恢复；正常SoC计数保持。旧15-level跨层路径退出top-20；资源 `44165 LUT/31592 FF/78 DSP`（`-10 LUT/-3 FF`），direct/Q→D `-0.291/-0.060→-0.191/-0.060 ns`。两份首路径现统一为descriptor scheduler→decoder。 |
| pipelined descriptor verdict boundary | decoder兼容 `925d7efd0f734711b47b375e288ca213`；loader `76b1252b78934aad946ca4280d27a675`；SoC `659a381895554f4fa4b05b9248a8c011`；proxy `descriptor_verdict_pipe_ticket_proxy_retry2_20260826` | config-loader中的decoder先无条件锁存512-bit descriptor，再以本地寄存器完成完整ABI校验并寄存5-bit verdict，最后发布command/error；每descriptor增加2拍但不改变规则/优先级。兼容429向量、loader多启动/错误/abort及完整SoC均PASS。旧`descriptor_q.CE/command_valid.D`路径退出top-20，资源 `44202 LUT/31605 FF/78 DSP`（`+37 LUT/+13 FF`），direct/Q→D `-0.191/-0.060→-0.182/+0.344 ns`；全部Q→D路径闭合。 |
| preserved four-stage bilinear pipeline | primitives `interp_preserved_pipe_primitives_20260827`；system `interp_operand_pipe_system_20260826`；SoC `2dc8c3d400434b00a0de89c2a19cd91d`；proxy `interp_preserved_pipe_ticket_proxy_20260827` | 插值改为horizontal→registered operands→registered vertical products→rounded output四级弹性流水；单纯增加寄存级会被Vivado跨DSP平衡且WNS不变，故仅对算术payload边界使用`DONT_TOUCH`。10,726组最终向量、313个system输出及完整SoC均PASS。资源 `44568 LUT/32064 FF/78 DSP`（`+366 LUT/+459 FF`），direct/Q→D `-0.182/+0.344→+0.136/+0.340 ns`；两份top-20均无违例，Artix-7 100 MHz综合代理首次整体闭合。 |
| display response FIFO Vivado proxy synthesis | `display_fifo_proxy_async_final2_20260825` | bypass→fifo128 的 Xilinx proxy 资源为 `2600→3094 LUT`、`1141→1185 FF`、`1280→1584 LUTRAM`；core WNS `+3.265→+2.470 ns`，pixel WNS 不变；不能替代 Ti60/Efinity |
| portable SoC 640×480 FIFO system proxy synthesis | `portable_soc_fifo_proxy_post_pipeline_default_20260825` | 最终源码资源 `44792→45298 LUT`、`28082→28123 FF`、`5644→5948 LUTRAM`；strict FIFO128 core WNS `-53.327 ns`（旧 `-53.944 ns` 为历史快照），FIFO 不是主时序瓶颈，必须先做 engine/tensor/控制流水化 |
| descriptor/address timing isolation | final strict→relaxed→fast→pixel/final pipeline proxies | 最终 strict `-53.327 ns` → relaxed `-15.659 ns`（Q→D `-13.455 ns`）；fast-address `45506 LUT/28073 FF/93 DSP`、`-16.647 ns`（Q→D `-14.216 ns`），确认负优化；`PIPELINED_TENSOR_ADDRESS=1` 后 `44641 LUT/28069 FF/84 DSP`，Q→D 专用报告中 tensor-address 路径消失，系统数据最差 `-4.772 ns`（camera FIFO→resize），dot overflow 路径 `-4.601 ns`；这仍是 Xilinx proxy，不是 100 MHz/15 fps PASS |
| compute-start/config register boundary | `portable_soc_descriptor_relaxed_pipelined2_startcfg_proxy_20260825`；xsim `descriptor_pipelined2_compute_start_8x8_20260825` / `descriptor_pipelined2_startcfg_twoframe_8x8_20260825` / strict compatibility | 在 pixel/final 地址流水化上锁存 source/config 一拍；proxy `44670 LUT/28141 FF/84 DSP`，direct `-4.950 ns`，Q→D `-4.601 ns`，相对 `44641/28069/84` 增加 29 LUT/72 FF，Q→D 改善约 0.171 ns；单帧、两帧和 strict 兼容通过，默认关闭 |
| final-dot-sum/accumulator boundary experiment | `aba8388974174f209ea0c7c2cc2dcbf0`；`descriptor_pipelined2_startcfg_dottree_final_8x8_20260825`；proxy `portable_soc_descriptor_relaxed_pipelined2_startcfg_dottree_proxy_20260825` | 独立 dot/requant 与完整 8×8 链均 PASS；当前只寄存 final dot-sum/上下文，未切分内部 tree；640×480 proxy `44691 LUT/28606 FF/84 DSP`、direct `-4.950 ns`、Q→D `-4.752 ns`，相对 start-config `+21 LUT/+465 FF`，未改善时序，默认关闭 |
| full product/pair/quad/dot tree experiment | `4998087102b6420ba49009b7216b3f96`；engine `a3f71de333da470483f247902d497d52`；`descriptor_pipelined2_startcfg_treefull_8x8_20260825`；proxy `portable_soc_descriptor_relaxed_pipelined2_startcfg_treefull_proxy_20260825` | 真正四级弹性 dot tree（8 lanes）standalone/engine/8×8 链均 PASS；640×480 proxy `44594 LUT/31396 FF/84 DSP`、direct `-4.950 ns`、Q→D `-4.701 ns`，相对 start-config `-76 LUT/+3255 FF`；填充后 II=1，但约四级 latency 与 ready/control 高扇出仍使 100 MHz 未闭合，默认关闭 |
| full-tree cross-frame ownership | `descriptor_pipelined2_startcfg_treefull_16x8_twoframe_20260825` | 16×8 两帧 `done=2 swaps=2 drops=0 descriptors=44`，`drain_cycles=1438892`，`AW/W/B=3376/3472/3376`、`AR/R=4194/5502`；四级 latency 在更长 frame/ownership 链中仍守恒，仍不代表 native 640×480 性能 |
| full-tree shape-scaled 64×48 | `descriptor_pipelined2_startcfg_treefull_64x48_20260825` | 单帧 `done=1 swaps=1 drops=0 descriptors=22`，`AW/W/B=40224/41664/40224`、`AR/R=48427/51643`；更大 shape 的 AXI/ownership 通过，`drain_cycles=907593` 仅作功能回归计数，不作为帧率结论 |
| registered descriptor replay experiment | `descriptor_replay_treefull_8x8_20260825`；proxy `portable_soc_descriptor_relaxed_pipelined2_startcfg_treefull_descr_replay_proxy_20260825` | 8×8 功能 PASS、无 per-stage bubble；proxy `47114 LUT/41837 FF/84 DSP`、direct `-4.824 ns`、Q→D `-4.701 ns`，相对 full-tree 资源大幅增加，停止该路线，改做 decoder 分级校验 |
| capture-time descriptor prevalidation experiment | `prevalidate_replay_8x8_final_20260825`；`ed8badbe0e6a4809964e361b79d6cb7a`；proxy `prevalidate_treefull_proxy_final_20260825` | 每 stage 缓存 5-bit error code；8×8/外部 error-vector 回归 PASS；proxy `44660 LUT/31374 FF/84 DSP`、direct `-4.824 ns`、Q→D `-4.701 ns`，相对 full-tree 仅 `+66 LUT/-22 FF`，仍不闭合且默认关闭 |
| abort fanout replication experiment | `abortrep_8x8_postpatch_20260825`；proxy `abortrep_treefull_proxy2_20260825` | 组合 abort 广播树 `max_fanout=16` 不改变 8×8 AXI/ownership 计数，但 proxy `44727 LUT/31380 FF/84 DSP`、direct `-5.557 ns`、Q→D `-5.434 ns`，较 baseline 恶化约 `0.733 ns`；停止该方向 |
| table response elastic FIFO experiment | `tablefifo_8x8_20260825`；proxy `current_treefull_prevalidate_tablefifo_nohelper_20260825` | 单项已寄存 table payload、abort flush、无 fall-through；8×8 full-xsim PASS；当前同源码配对 proxy `46174 LUT/37790 FF/84 DSP`，相对 FIFO=0 `-6 LUT/+128 FF`，direct/Q→D WNS 均不变；保留为协议隔离开关，不是 timing fix |
| unified output FIFO protocol + optional SoC integration | `unified_output_fifo_latest_20260825`；`unified_output_fifo_registered_error_gate0_recheck_20260825`；`unified_fifo_errorgate0_gated_8x8_20260825`；`unified_fifo_errorgate0_gated_8x8_twoframe_20260825`；`unified_fifo_errorgate0_gated_native_elab_20260825`；paired proxy `current_treefull_prevalidate_unifiedfifo_errorgate0_gated_nohelper_retry1_20260825` | standalone 两种 error-gate 语义、8×8 单帧/两帧与最终 640×480 elaboration PASS；最终同条件 proxy `46390 LUT/37656 FF/5716 LUTRAM/84 DSP`、direct/Q→D `-4.831/-4.702 ns`，相对无 FIFO无 timing 收益，默认关闭，保留为协议隔离候选 |
| unified output skid 1-entry protocol + optional SoC integration | `skid_abort_error_default_retry_20260826`；`skid_abort_error_registered_retry_20260826`；`skid_soc_8x8_20260826`；`skid_soc_8x8_twoframe_20260826`；`skid_soc_16x8_20260826`；`skid_native_elab_20260826`；paired proxy `current_treefull_prevalidate_unifiedskid_nohelper_20260826` | 完整 103-bit payload 的 standalone（含 abort directed case）、8×8 单帧/两帧、16×8、640×480 elaboration PASS；同条件 proxy `46243 LUT/37766 FF/5636 LUTRAM/84 DSP`、direct/Q→D `-5.415/-5.415 ns`，相对无边界为负优化；深度减小没有切开 camera FIFO→abort/ready 控制锥，默认关闭 |
| all-optional native elaboration | `treefull_final_native_elab_20260825`（前一版 `dottree_final_native_elab_20260825`） | 640×480 在 FIFO、relaxed descriptor、tensor-address、start-config、full product/pair/quad/dot tree 全开组合下 xvlog/xelab PASS；未启动 native full-xsim，不代表长帧/QoS/帧率 |
| native-width fix compatibility gates | `c1_8x8_u64fix_gate_20260825` / `c1_64x48_two_u64fix_gate_20260825` | 现有小帧单帧/两帧全链重新 PASS；证明 64-bit 中间表达式修复未破坏当前 gate，不外推 native 性能 |
| optional-top cache wiring | bypass `7e76332ea7044371af9efcf39809258a`；最终 enabled `30658446f3d4442fb7f7a442bd5f9fe2` | 最终 route-lock/断言源码下 generate、CSR、idle/quiescent 与 `system_busy` cache fence 已接并定向检查 `fence=1`；`flush_req` 暂绑 0 |
| 训练工件 | RTL decoder + parameter scheduler 接收 22 descriptor、1,030 个 128-bit arena reads/cache writes | ABI 已有证据；native 640×480 算术 E2E 仍缺 |
| 共享仲裁 | 7 clients，56 写+56 读，随机停顿，最大等待 89/67 cycle | arbiter forward progress 已有独立证据；系统 QoS 仍缺 |

packing RTL 的综合过程中曾暴露一个真实可综合性问题：无界 `while` 指针回绕在 Vivado 中被判定为“不收敛”。当前版本已改为针对最大步长 2 的有界两次减法，并重新通过 xsim 与 proxy synth；这条修复不能替代后续 Efinity 综合，但避免把仅仿真可过的 FIFO 草稿带入系统。

native DMA/boardless 集成门现已连续闭合：`c1_native_dma_loopback_final2_20260825`
将三 slot input read、stream backpressure、XRGB output writer、write-side arbiter
和 DDR 逐像素回读闭合；随后 `native_boardless_job_hold_full_20260825` 又把
640×480 table/22 descriptor、真实 boardless frontend、input/output DMA 与外部
CNN echo 串成一帧 `cnn_in/cnn_out=307200/307200` 的 job。loopback 使用的
`c1_axi_write_skid_bridge` 是单项 AW/W/B 隔离缓冲，两个 TB 的反相时钟 shell
只消除 xsim delta 竞态；它不改变下一阶段必须解决的七客户端竞争、burst、
multi-outstanding、QoS 和 MAC 并行度问题。

随后 `native_fabric_full2_20260825` 将同一个 640×480 boardless job 放到真实
`c1_axi_n_serial_arbiter_128(CLIENTS=7)` 的 client-0，并用六个独立 AXI
traffic peer 制造随机读写竞争。该切片已经把仲裁器在 native 长帧下的 forward
progress、RLAST、响应保持和最大等待量化到 `118` cycles；下一步不再增加
synthetic traffic，而是把这些 peer 逐一替换成 portable SoC 的真实 capture、
parameter/tensor、display 和 compute client，并在同一 scoreboard 中加入
underflow、abort/drain 与 frame-deadline 失败条件。

`native_fabric_param_full_20260825` 已将第一个真实 read-only leaf 接入该
fabric；portable SoC 64×48 monitor 的失败基线表明，当前 serial read
arbiter 会在某个 client 的 `RREADY` 长低时锁住 `RD_DATA` owner，使 styled
display client-5 的 AR 连续等待达到 1,243,738 cycles。protocol-safe
response FIFO prototype 已用 credit-only pre-AR admission 将单帧 wait/hold
降至 76/83 与 2/2，并在 8×8 两帧通过 ownership；下一步不是放宽 watchdog，
而是完成 native 长帧、underflow/deadline、代理资源/时序和 Efinity 边界。

## 下一轮 RTL 顺序

1. **描述符、启动边界与 dot arithmetic 的第一轮流水化已完成**：默认 strict/legacy 仍保持 `PIPELINED_TENSOR_ADDRESS=0`、`PIPELINED_START_CONFIG=0`、`PIPELINED_DOT_TREE_FULL=0`、`PIPELINED_DESCRIPTOR_REPLAY=0`、`PREVALIDATE_DESCRIPTOR_REPLAY=0`；地址/启动边界与 full product→pair→quad→dot 四级弹性树已在 standalone、22-stage engine、8×8/16×8/64×48 portable SoC 和 640×480 elaboration 通过。此前写作“同条件基线”的 `46180 LUT/37662 FF` run 实际同时打开了 `PIPELINED_DESCRIPTOR_REPLAY=1`，只能用于同组 FIFO/skid 配对，不能作为 replay=0 基线；本轮当前源码严格配对的 replay=0/prevalidate=1 基线为 `44660 LUT/31374 FF/84 DSP`、direct/Q→D `-4.824/-4.701 ns`。宽 descriptor replay 的资源负优化结论不变；table response FIFO、完整 payload unified FIFO 与 1-entry skid 也都没有提供时序收益，继续保持默认关闭。
   shared-fabric read-response skid 已切开 DDR-side `RREADY` 回传但不改善全局 WNS；注册化 fatal ticket 随后以 `+12 LUT/+46 FF` 将 Q→D 改善到 `-0.877 ns`。本轮 parameter scheduler 又通过 START 快照→`ST_VALIDATE`、5-bit terminal byte count 和 1-bit terminal flag，将 direct/Q→D 继续推进到 `-2.069/-0.694 ns`，代价相对 ticket-only 为 `+67 LUT/+198 FF` 和每层 1 个校验周期；乘法、region CE/bytes/word-count 旧路径均退出 top-20。100 MHz 仍未闭合：下一 timing 迭代转向 tensor adapter 的 tap-source-Y→pixel-index 12-level/8-CARRY 地址路径；其次分析 route 占 71.7% 的 job-controller→CNN-engine state。ticket 的多故障/abort-drain 系统恢复矩阵仍需扩展，但 scheduler 自身六类负例、validate-abort 与配置快照已经闭合。
2. **可插拔 memory seam 已完成**：`c1_tensor_mem_path_seam` 保留旧 bridge 为 `PERF_MODE=0`，packer/queue 为 `PERF_MODE=1`，共享窄请求/响应 ABI；xsim 同时验证两分支，proxy synth 验证两种生成配置。`flush_req` 已锁存并以 `flush_done/quiescent` 收口。
3. **packing 局部契约已完成，系统接入尚未开始**：独立 packer 已证明每个 64-bit 请求恰好一个 response；真实 4×4 adapter trace 只有 407/2,229（18.2593%）相邻 gap 可直接 pair，下一步必须先按 C8 group/line 组织 adapter 发射并重新测量，不能直接替换 bridge。abort 仍沿用 adapter 的“已接受请求必须排水”合同，尚未给多 outstanding queue 增加 cancel/epoch。
4. **line/window cache 的 64-bit、真实 AXI、client-6/七客户端和 portable SoC gate 矩阵已完成**：`c1_window_line_cache_c8`、注册化 `c1_tensor_window_cache_seam`、adapter 每层/逐请求 metadata 和 `ENABLE_TENSOR_WINDOW_CACHE` generate 均已落地；默认直通仍兼容。最终加固 run `1e6f562adbc34ea383932840b97aa0e4` 证明配置拒绝和路由后 runtime-error 的 route-lock 安全收口；动态 run `9212d5a042ae4d9895a3162869e3815f`、`be4977424d9d484e80340f970d9904d0` 与四个 latest gate run 分别闭合窄内存、真实单拍 AXI、8×8/16×8/64×48 顶层功能和两帧 ownership 链。gate 还验证 pending-pair hold CDC、防重复启动，以及 shared ID-less AXI read HOL 下 foreground CNN admission 的 quiescence gate；之后进入 QoS、`system_busy`→seam quiescent 统计和 burst/multi-outstanding；descriptor ABI 不变。
5. **增加有限 outstanding**：目标先设 4，再比较 8/16；每个 entry 保存 base、lane、owner、write/read、错误和序号，禁止跨 abort 泄漏。通过 scoreboard 检查乱序 AXI response 仍按逻辑序号返回；在此之前必须明确 `abort_req/abort_done` 和 queued-request 的 error response 语义。
6. **提高有效 MAC 并行度**：以 80-lane schedule 为候选上界，先把 64→80 的资源/时序变化做 proxy synth；验收条件是纯算术下界低于 6,666,667 cycle，并留出参数/填充/仲裁余量。final-dot-sum 边界与 full-tree 分级实验均已完成；full-tree 已证明四级 latency 能被当前小帧 engine/SoC 吸收，但没有改善系统 Q→D。下一步若继续并行化，必须同步定义 lane-bank、权重带宽和 output FIFO 资源上限，不能只增加算术寄存器。
7. **扩展系统压力**：8×8 单帧、16×8 两帧、64×48 单帧/两帧 gate 均已通过，独立 native display prefetch、capture-writer、capture/table/ISP、两主机 input-DMA/arbiter、read→write DMA loopback、640×480 boardless job、synthetic fabric preflight 和一个真实 parameter leaf slice 也已通过；display response FIFO 的单帧 QoS 与 8×8 两帧 ownership 也已通过。下一步用 credit-only FIFO 在 portable SoC native 640×480 长帧共同回归真实 capture、parameter/tensor、display 和 compute client，加入 underflow、abort/drain、frame deadline、FIFO occupancy 和每类 client 等待分布；shape elaboration、synthetic-fabric preflight 和各分阶段 DMA preflight 都不计入 native CNN 性能 PASS。

### native 640×480 扩展前置条件

- 地址图已在 native 分支切换为 `INPUT_BASE=0x0010_0000`、`OUTPUT_BASE=0x0060_0000`；640×480 的 XRGB `FRAME_SLOT_BYTES=0x12c000`，并加入 input/output/tensor 非重叠断言。独立 DMA/显示分阶段回归和 `native_boardless_job_hold_full_20260825` 已确认 frame-table/APB/DDR map 的读回守恒；剩余是 portable SoC 七客户端 fabric。
- native 分支已切换为按完整 AXI line 地址索引的 associative DDR BFM，绕开 `MEM_SLOTS=32768` 的 hash 碰撞；loopback 已统计三 input + 三 output 的地址覆盖和读回守恒，后续要在七客户端竞争下重新测量运行时间/QoS。
- 分阶段预检第一步的独立 `c1_display_prefetch_pair` native testbench 已由 `native_prefetch_run2_20260825` 通过：双 reader 使用 `0x0010_0000`/`0x0060_0000` 基址，BFM 对每个 AR/R beat 做 16-byte 对齐、4 KiB 边界、行内地址和 XRGB lane 校验，像素域逐点检查 640×480 两路响应，最终 `underflow=0/0`。该测试只覆盖显示预取/双行 CDC/读回，不启动 capture、CNN 或 descriptor watchdog；boardless native DMA 与 synthetic-fabric preflight 已由后续门闭合，下一步是 portable SoC 七客户端真实叶模块并发。复现命令和边界见 `NATIVE_DISPLAY_PREFLIGHT.md`。
- 第二步 native capture-writer staged preflight `c1_native_capture_writer_final_20260825` 也已通过：真实 `c1_axi_xrgb_frame_writer` 对 `0x0010_0000/0x0022c000/0x00358000` 三个 slot 完成 3×640×480 写入，BFM 逐 AW/W 校验 4 KiB/行边界与 XRGB lane，并逐像素读回 921,600 个像素。它只覆盖 writer/AXI W/B/slot map，不启动 camera/CSI、input DMA、CNN 或共享仲裁；复现命令和边界见 `NATIVE_CAPTURE_WRITER_PREFLIGHT.md`。
- 第三步 native capture/table/ISP staged preflight `c1_native_capture_table_paced_full_20260825` 已通过：真实 `c1_r1_capture_subsystem` 以 642×482 RAW10 输入完成三帧，Gamma LUT 先完成 1,024 次 ready/valid 配置，RGB stream 计数为 `921600/3/1440/3`（pixels/SOF/EOL/EOF），frame-table `AR/R=3/3`，writer `AW/W/B=14400/230400/14400`。由于当前 frontend 将 `valid&&!ready` 视为不可恢复 camera overflow，测试 BFM 以 sensor blanking 方式发射；它已覆盖 capture/ISP/table/writer 边界，但仍不含 CSI/MIPI、portable SoC input DMA、共享仲裁、CNN/QoS；复现命令和边界见 `NATIVE_CAPTURE_TABLE_PREFLIGHT.md`。
- 第四步 native input-DMA/table/arbiter staged preflight `c1_native_input_dma_full_20260825` 已通过：真实 table reader 与 XRGB reader 作为两个 read master 接入 `c1_axi2_serial_arbiter_128`，三 slot 完成 `frame_pixels=921600`、table `AR/R=3/3`、frame `AR/R=14400/230400`、shared `AR/R=14403/230403`，并覆盖 4 KiB/行边界、RGB/坐标/markers 和 AR/R/output 回压。它仍不含 boardless job/output DMA、七客户端 fabric、CNN/tensor/QoS；复现命令和边界见 `NATIVE_INPUT_DMA_PREFLIGHT.md`。
- 第五步 native read→write DMA loopback staged preflight `c1_native_dma_loopback_final2_20260825` 已通过：真实 read arbiter、XRGB writer、`c1_axi_write_skid_bridge` 和 write arbiter 将三 input slot 写入三 output slot，完成 `frame_pixels=921600`、input `AR/R=14400/230400`、output `AW/W/B=14400/230400/14400`，并逐像素回读。它仍不含 boardless job、七客户端 fabric、CNN/tensor、display/QoS；复现命令和边界见 `NATIVE_DMA_LOOPBACK_PREFLIGHT.md`。
- 第六步 native boardless job staged preflight `native_boardless_job_hold_full_20260825` 已通过：真实 `c1_r1_boardless_frame_system` 完成 table/22 descriptor/input-output DMA/外部 CNN echo，`cnn_in/cnn_out=307200/307200`，input `AR/R=4800/76800`，output `AW/W/B=4800/76800/4800`，并逐像素回读 output associative DDR。它仍不含 portable SoC 七客户端、真实 CNN/tensor、display/QoS；复现命令和边界见 `NATIVE_BOARDLESS_JOB_PREFLIGHT.md`。
- 第七步 native boardless + 7-client fabric preflight `native_fabric_full2_20260825` 已通过：真实 boardless job 作为 client-0 穿过 `c1_axi_n_serial_arbiter_128(CLIENTS=7)`，六个 synthetic peer 各完成 3 个四拍写/读回事务，最大等待 `118` cycles，job/output 逐像素闭环。它仍不含 portable SoC 七个真实叶模块、真实 CNN/tensor、display underflow/QoS；复现命令和边界见 `NATIVE_BOARDLESS_FABRIC_PREFLIGHT.md`。
- 第八步 native boardless + real parameter leaf fabric slice `native_fabric_param_full_20260825` 已通过：client-1 是真实 parameter-loader + parameter-bank，完成 16,896 B arena `AR/R=66/1056` 与 bank generation=1，五个 synthetic peer 和 boardless job 仍在同一七客户端 arbiter 下前进。它仍不含七个 portable SoC 真实叶模块或 QoS/15 fps；复现命令和边界见 `NATIVE_BOARDLESS_FABRIC_REAL_PARAMETER.md`。
- 目前 gate 通过的是 CNN forward progress/ownership，不冻结 raster；双 bank line-store 在长 CNN 期间可能产生 `display_underflow_event`。native 回归必须先放宽当前每 stage `1_000_000` watchdog、TB 全局 300/600 ms timeout 与有限 wait loop，再统计 underflow、pair deadline 和每 client 等待，并在 RTL 中加入 display reader FIFO（至少整 burst，建议每 reader 32 beats）、独立读端口或 AXI ID/response reorder 之一。

## 每一步的停止条件

- seam/packing 接入后若 `rsp_count != req_count`、`flush_done` 未出现或 `quiescent` 虚报，停止扩展 cache；
- cache-enabled 动态路径若 abort 后 `system_busy` 未保持到 seam quiescent，或错误/响应跨 stage 泄漏，停止扩展 outstanding；
- cache/queue 若资源或 proxy WNS 明显恶化，先缩小 entry/line 深度，不直接上板；
- 64/80 MAC 候选都无法把纯算术下界压到预算以内时，重新评估网络层数/通道数，而不是继续堆 FIFO；
- 小帧系统压力未通过前，不宣称 15 fps；Efinity/Ti60 和实体板只在板卡无关门槛通过后开始。

## 当前不应做的结论

独立 packing 的 49% beat reduction 不是系统带宽提升；adapter/cache 动态小帧的 72.3% 读请求下降虽已同时由 64-bit BFM 与真实单拍 AXI bridge/BFM 证实，且 8×8 顶层已穿过七客户端 DDR，但仍不是 native 帧率证明；artifact ABI PASS 不是 trained model 算术 PASS；独立七客户端 arbiter/8×8 PASS 不是长帧 QoS PASS；Vivado/Artix-7 proxy 资源和 WNS 不是 Ti60/Efinity 签核。

### 2026-08-26 pipelined tensor tap-coordinate strength reduction

- `PIPELINED_TENSOR_ADDRESS=1` 分支不再用通用 `integer` 乘法计算 tap 坐标；stride=2 用左移，stride=1 直通，3×3 tap delta 显式映射为 `-1/0/+1`，并以窄有符号值完成边界钳位。descriptor 校验已把卷积 stride 限定为 1 或 2，因此该变换没有放宽运行时合同；legacy 分支保持原实现。
- standalone adapter 的 legacy/pipeline 两种模式分别由 `tapcoord_shift_legacy_20260826`、`tapcoord_shift_pipeline_20260826` 通过；相同 performance 开关的完整 8×8 SoC `tapcoord_shift_soc8x8_20260826` 保持 `C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS`。
- proxy `tapcoord_shift_ticket_proxy_retry1_20260826` 为 `44706 LUT/31622 FF/5832 LUTRAM/20 RAMB36/9 RAMB18/80 DSP`。相对 `param_terminalflag_ticket_proxy_20260826` 为 `-33 LUT/+4 FF/-4 DSP`，最差 direct WNS 从 `-2.069 ns` 改善到 `-1.066 ns`；报告中 `tap_source_x/y_fn` 与 `addr_pixel_index` 匹配数均为 0。
- 新 direct 最差路径为 `job_controller/FSM_sequential_state_reg[0]/C`→`conv_tile_read_addr_q_reg[0]/CE`，15 levels、data delay `10.684 ns`，其中 route 占 76.7%；Q→D 最差仍是同一 controller state→CNN engine state，`-0.692 ns`、17 levels。下一轮应从 job start/enable 的本地注册或 enable 解码分层入手，而不是继续改 tensor 地址算术。
- 本轮五个新 Vivado/xsim 工作目录在验收后已精确删除，共 172 个文件、7.47 MiB；仅保留状态、小日志和三份文本综合报告，共约 0.68 MiB。后续同样不保留仿真/综合临时工程，除非专门要求调试复现。

### 2026-08-26 registered-owner system-disable qualification

- 原 `abort_due_disable` 组合检查 parameter/capture/NN/boardless/pending-pair busy；综合后形成 job-controller state→`boardless_busy`→manager abort→tensor result-ready→四级 dot-tree ready→conv-tile CE 的 15-level 跨层反馈。
- `run_armed_q` 本就是前台事务的寄存 ownership，并在 system disable 的下一边沿清零。现在用 `!system_enable && run_armed_q` 直接产生同周期取消，使全部同步子模块在清零边沿前采样 abort，同时移除 child-busy 组合回读。
- controller legacy/ticket 回归均新增并通过 disable-abort 定向用例，确认 parameter/capture/boardless/display 四路取消同周期有效；`disable_owner_soc8x8_20260826` 的正常 job、22 descriptors、AXI 和 display ownership 继续 PASS。
- proxy `disable_owner_ticket_proxy_20260826` 为 `44740 LUT/31617 FF/5832 LUTRAM/20 RAMB36/9 RAMB18/80 DSP`。相对上一阶段 `+34 LUT/-5 FF/0 DSP`，direct WNS `-1.066→-0.682 ns`，Q→D `-0.692→-0.380 ns`；旧 `boardless_busy/compute_abort/adapter_result_ready` 关键路径匹配数为 0。
- 新 direct 首路径是 parameter-bank BRAM clock-to-output→weight-word cache/mux→scheduler/decoder affine metadata 校验→`affine_invalid_q.D`，11 levels、data delay `10.531 ns`；下一轮应给 affine metadata 建立明确读取/校验寄存边界。100 MHz 仍未闭合。
- 本轮四个 Vivado/xsim 工作目录已删除，共 174 个文件、6.16 MiB；仅保留约 0.64 MiB 的状态、小日志和三份文本报告。

### 2026-08-26 registered affine-word verdict boundary

- 原 engine 在 parameter-bank 128-bit 响应到达时，同拍写 multiplier/shift cache，并直接完成每 lane 格式检查和 sticky `affine_invalid_q` 更新；该链从 BRAM clock-to-output 穿过11级 mux/校验/error-reset 逻辑。
- 新结构不寄存整个128-bit payload：cache 写入周期和参数读取吞吐保持不变，仅将当前参数字的非法 verdict 寄存一拍；下一拍再置位 sticky flag。卷积层在 `ST_PARAM_VALIDATE` 前必经 weight repack，因此 verdict 不会越过校验点，也不增加计算数据面 bubble。
- `affine_verdict_pipe_engine_20260826` 完成22层、836 outputs、1,115 parameter reads、8 aborts、6 injected faults，原 `shift=48` 仍准确产生 affine-format fault；`affine_verdict_pipe_soc8x8_20260826` 的正常全链继续 PASS。
- proxy `affine_verdict_pipe_ticket_proxy_20260826` 为 `44568 LUT/31617 FF/5832 LUTRAM/20 RAMB36/9 RAMB18/80 DSP`。相对上一阶段 `-172 LUT/0 FF/0 DSP`，direct WNS `-0.682→-0.613 ns`，Q→D 保持 `-0.380 ns`；`affine_invalid_q.D` 与 `affine_word_invalid` 均未出现在 direct top-20。
- 新 direct 首路径为 `input_groups_q` clock-to-Q→weight-repack channel/tap 计数与状态解码→`repack_input_channel_q.CE`，12 levels、data delay `10.231 ns`、route 71.6%。下一轮应优化 repack 终止条件和计数器使能，而不是继续改 affine path。
- 本轮三个 Vivado/xsim 工作目录已删除，共162个文件、6.46 MiB；仅保留约0.65 MiB的状态、小日志和三份文本报告。

### 2026-08-26 staged weight-layout verdict and repack terminals

- 原 `weight_layout_valid` 的 `output_groups×input_groups×taps` 计算被综合进FSM next-state，再继续控制 `repack_input_channel_q.CE`；同时linear byte、input channel和tap的末值在重排周期现算 `+1/-1`，形成12-level跨状态路径。
- parameter scheduler完成边沿现在寄存layout verdict与 `last_linear/last_input_channel/last_tap`；新增 `ST_WEIGHT_LAYOUT` 只消费寄存 verdict，随后重排使用等值比较。每个进入weight repack的层增加1个控制周期，不改变OIHW byte顺序或cache读写拍。
- `repack_terminal_pipe_engine_20260826` 保持22层、836 outputs、1,115 parameter reads、8 aborts、6 faults；等待计数 `260→270`。`repack_terminal_pipe_soc8x8_20260826` 保持22 descriptors以及 `AW/W/B=852/868/852`、`AR/R=1119/2199`。
- proxy `repack_terminal_pipe_ticket_proxy_retry1_20260826` 为 `44544 LUT/31641 FF/5832 LUTRAM/20 RAMB36/9 RAMB18/80 DSP`。相对上一阶段 `-24 LUT/+24 FF/0 DSP`，direct WNS `-0.613→-0.587 ns`，Q→D保持 `-0.380 ns`；旧repack-layout路径与新边界寄存器均不在direct top-20。
- 新 direct 首路径为 tensor adapter `addr_pixel_index_q.CLK`→`request_addr_q[31].D`，7 levels、data delay `10.468 ns`，包含2个DSP48E1与4个CARRY4；下一轮应切分pixel-index/group scaling与bank/base address相加。
- 首次proxy在HDL处理前因本地Vivado runtime缺失临时 `rtSynthParallelPrep.tcl` 退出，retry完整通过。四个工作目录（含空失败目录）均已删除，合计162个文件、6.46 MiB；仅保留约0.64 MiB状态、小日志和文本报告。

### 2026-08-26 pipelined final tensor-address strength reduction

- 已有地址流水把 `y×width+x` 寄存为 `addr_pixel_index_q`，但最终函数仍把32-bit pixel扩为64 bit后执行通用 `pixel×groups`，综合成两个串联DSP，再进入bank/base的32-bit carry链。
- 新函数在 `PIPELINED_TENSOR_ADDRESS=1` 路径利用descriptor合同：C8 groups合法范围1–6（实现覆盖1–8），显式采用移位/加减；bank固定为0/1/2，使用常量分支。invalid/default group不再保留通用乘法，legacy地址函数保持不变。
- `finaladdr_shiftadd_pipeline_20260826` 的流水adapter与 `finaladdr_shiftadd_soc8x8_20260826` 的完整SoC均PASS；没有增加FSM状态，SoC仍为22 descriptors、`AW/W/B=852/868/852`、`AR/R=1119/2199`。
- proxy `finaladdr_shiftadd_ticket_proxy_20260826` 为 `44604 LUT/31656 FF/5832 LUTRAM/20 RAMB36/9 RAMB18/78 DSP`。相对上一阶段 `+60 LUT/+15 FF/-2 DSP`，direct WNS `-0.587→-0.380 ns`，Q→D保持 `-0.380 ns`；旧 `addr_pixel_index_q→tensor_addr_from_pixel_fn→request_addr_q` 路径在top-20匹配数为0。
- direct与Q→D现在都指向 `c1_frame_manager` 的 `input_state[0]`→ready候选搜索/索引选择→`input_state[0].D`，17 levels、8 CARRY4、data delay `10.229 ns`、route 65.9%。下一轮应拆分三slot候选搜索与状态更新。
- 本轮三个Vivado/xsim工作目录已删除，共150个文件、6.51 MiB；仅保留约0.64 MiB状态、小日志和三份文本报告。

### 2026-08-26 frame-manager ordered READY queues

- 原三输入槽每周期扫描所有 `IN_READY_NN`，并串联两次32-bit frame-id比较来选最老槽；综合后形成 `input_state→candidate compare/index→dynamic state writeback` 的17-level、8-CARRY4路径。输出侧也用同类宽比较选最老显示帧。
- capture只有一个 active owner，故其完成次序严格等于已分配frame-id次序；CNN同样只有一个 active owner，故输出完成次序也保持输入顺序。新实现分别以3-entry input READY FIFO和2-entry output READY FIFO保存这一既有顺序，free-slot优先选择及对外接口/时延不变。
- `ready_fifo_directed_20260826` 覆盖三槽填满、frame 0/2两次drop-oldest、input完成与NN grant同周期pop+push、NN完成与vsync同周期pop+push，以及abort清空队列但保留当前display ownership；`frame_ready_fifo_soc_control_20260826` 与完整8×8 `ready_fifo_soc8x8_20260826` 均PASS。完整链保持 `done/swaps/drops=1/1/0`、22 descriptors、`AW/W/B=852/868/852`、`AR/R=1119/2199`。
- proxy `ready_fifo_ticket_proxy_20260826` 为 `44272 LUT/31597 FF/5832 LUTRAM/20 RAMB36/9 RAMB18/78 DSP`。相对上一阶段 `-332 LUT/-59 FF/0 DSP`，direct WNS `-0.380→-0.306 ns`，Q→D `-0.380→-0.060 ns`；frame-manager及新queue信号在两份top-20中的匹配数均为0。
- 新direct首路径位于resize bilinear interpolation的DSP cascade→饱和/舍入carry→输出DSP B输入，6 levels、data delay `9.675 ns`；新Q→D首路径为descriptor scheduler锁存字段→decoder `command_valid.D`，9 levels、data delay `9.908 ns`。Artix-7 proxy在100 MHz仍分别差0.306/0.060 ns，下一轮优先评估插值输出前的算术边界，其次处理descriptor verdict/command-valid边界。
- 四个Vivado/xsim工作目录均已删除，共173个文件、6.034 MiB；仅保留27个状态、小日志和三份文本报告，共0.632 MiB。专用runner会在结束时自动清理自己的xsim目录。

### 2026-08-26 bilinear complement-weight range reduction

- R1 resize合同在坐标发生器边界明确生成 `w0=4096-w1`，固定点规范也规定水平/垂直两级各自执行half-up后直接取Q0.12结果。因此任意合法u8输入的rounded numerator不超过 `255×4096+2048=1,046,528 < 2^20`，右移12位后天然落在0–255。
- `interpolate_pair_u8` 的product/sum由21/22 bit收窄为20 bit，并直接返回 `rounded_sum[19:12]`；删除合法输入恒不可达、但会在DSP后生成3级CARRY4的 `shifted>255` 饱和器。接口、两级elastic pipeline及ready/valid延迟不变；仿真期在输入accept边界断言X/Y两组权重和均为4096。
- `interp_nosat_primitives_20260826` 通过50组坐标配置、3,211 requests和10,726组随机/定向插值；`interp_nosat_system_20260826` 通过12组配置、313 requests/outputs；完整8×8 `interp_nosat_soc8x8_20260826` 保持22 descriptors、`done/swaps/drops=1/1/0`、`AW/W/B=852/868/852`、`AR/R=1119/2199`。
- proxy `interp_nosat_ticket_proxy_retry1_20260826` 为 `44175 LUT/31595 FF/5832 LUTRAM/20 RAMB36/9 RAMB18/78 DSP`。相对上一阶段 `-97 LUT/-2 FF/0 DSP`，direct WNS `-0.306→-0.291 ns`，Q→D保持 `-0.060 ns`；所有 `u_interp/stage0_h03/out_rgb1` 匹配均退出两份top-20。
- 新direct首路径由parameter-bank generation合同错误比较，经CNN error、compute-egress/center-codec ready链回传到tensor-adapter `output_x_q.CE`，15 levels、data delay `9.909 ns`、route 67.6%。下一轮应在不破坏abort/error drain的前提下切断这条跨层error/ready组合反馈；descriptor `command_valid.D` 的Q→D `-0.060 ns`仍为次目标。
- 首次proxy在HDL处理前因Vivado on-demand runtime瞬时看不到 `common.tcl` 退出，retry完整PASS。五个工作目录（含失败空目录）已删除，共184个文件、6.692 MiB；保留34个小日志、状态和三份文本报告，共0.649 MiB。

### 2026-08-26 registered launch-contract fault boundary

- 原 bridge 把 live `start_contract_fault`（stage/config/parameter generation比较）直接并入公开 `cnn_error`；compute shell又以该错误组合门控所有transfer READY，最终形成parameter-bank→CNN error→compute egress/center codec→adapter final-ready→坐标counter CE的15-level跨层路径。
- 新结构保留live fault对尚未发出的CNN/adapter START valid的即时抑制，但运行期 `bridge_error_now`、error code和全部VALID/READY只使用既有sticky `start_contract_fault_q/code_q`。若活动帧期间generation突变，捕获边沿最多允许一个已经present的beat退休；随后整帧错误触发abort，output ownership不会进入display，因此该beat不会成为可见帧。
- 新定向 `tb_c1_r1_microstyle_bridge_fault_boundary.sv` 使用真实CNN top，验证live fault不组合泄漏、下一拍parameter/config错误码分别为`0x04/0x03`、捕获边沿恰好允许一个在途beat、sticky后停止传输、abort后可重新启动。首次定向运行还发现并修复了同一 `always_comb` 中先读后写 `error` 的事件仿真求值顺序问题；retry完整PASS。
- 正常8×8 `contract_fault_boundary_soc8x8_20260826` 保持 `done/swaps/drops=1/1/0`、22 descriptors、`AW/W/B=852/868/852`、`AR/R=1119/2199`。
- proxy `contract_fault_boundary_ticket_proxy_20260826` 为 `44165 LUT/31592 FF/5832 LUTRAM/20 RAMB36/9 RAMB18/78 DSP`。相对上一阶段 `-10 LUT/-3 FF/0 DSP`，direct WNS `-0.291→-0.191 ns`，Q→D保持 `-0.060 ns`；旧generation/error/ready/adapter-CE路径在两份top-20匹配数为0。
- 新direct与Q→D均来自descriptor scheduler `descriptor_latched[79]` 到decoder：direct终点为 `descriptor_q[0].CE`（8 levels、data delay `9.808 ns`），Q→D终点为 `command_valid.D`（9 levels、data delay `9.908 ns`）。下一轮集中处理descriptor verdict/command-valid边界，不再同时追逐两个无关瓶颈。
- 四个工作目录已删除，共202个文件、7.390 MiB；保留27个小日志、状态和三份文本报告，共0.644 MiB。两个定向目录均由runner自动清理。

### 2026-08-26 pipelined descriptor verdict boundary

- 原decoder在scheduler descriptor握手同拍执行完整ABI校验；`output_width×output_channels` 的DSP、row-stride比较及错误优先级树同时控制512-bit `descriptor_q.CE` 和 `command_valid.D`，形成direct/Q→D共同首违例。
- 新 `PIPELINED_VALIDATION` 模式在config-loader默认启用：握手边沿无条件锁存descriptor；下一拍从本地寄存器计算并锁存5-bit error；再下一拍发布command或error。完整 `c1_validate_descriptor` 规则、错误码优先级、abort及ready/valid稳定性不变，启动加载仅增加每descriptor两拍；standalone decoder默认仍为零额外周期的兼容模式。
- 默认decoder 429向量回归PASS（244个valid command、186个error event）；config-loader覆盖5次start、2次done、2次error、1次abort、61次bank command并PASS；完整8×8 SoC保持 `done/swaps/drops=1/1/0`、22 descriptors、`AW/W/B=852/868/852`、`AR/R=1119/2199`。
- proxy `descriptor_verdict_pipe_ticket_proxy_retry2_20260826` 为 `44202 LUT/31605 FF/5832 LUTRAM/20 RAMB36/9 RAMB18/78 DSP`。相对上一阶段 `+37 LUT/+13 FF/0 DSP`；旧scheduler→decoder路径在direct/Q→D top-20中均为0，direct WNS `-0.191→-0.182 ns`，Q→D `-0.060→+0.344 ns`，Q→D报告20条路径全部满足100 MHz。
- 新direct top-20全部为resize bilinear interpolation的DSP寄存输入路径，首路径5 levels、data delay `9.373 ns`；它是剩余唯一的100 MHz代理违例类别。下一阶段应集中评估插值DSP输入/输出寄存映射，不再改动已经闭合的descriptor边界。
- 前两次proxy均在RTL处理前因持久 `.vivado_rt` 对detached Vivado helper不可见而退出；改用run-local普通runtime stage后通过。runner现会将三份文本报告复制到日志目录并在成功/失败后自动删除综合/runtime目录。本轮清除646个文件、92.464 MiB（含旧45.2 MiB runtime副本），保留35个状态、小日志和报告，共0.634 MiB。

### 2026-08-27 preserved four-stage bilinear pipeline

- 原两级插值在垂直阶段仍形成horizontal DSP PREG `CLK→P`、一个垂直乘法DSP、3级CARRY4到后级DSP BREG的单周期路径，data delay `9.373 ns`，20条同构路径均为 `-0.182 ns`。
- RTL先增加独立vertical-product结果级，再增加纯operand级；两次功能仿真均bit-exact，但Vivado自动寄存器平衡把这些寄存器吸收到相邻DSP PREG/BREG，proxy分别为 `44224 LUT/31638 FF` 和 `44236 LUT/31678 FF`，direct WNS均保持 `-0.182 ns`。这证明“RTL中出现寄存器”并不等于综合后存在算术边界。
- 最终四级结构为horizontal interpolation→registered vertical operands→registered vertical products→rounded vertical sum/output；仅对74-bit operand payload和120-bit product payload添加 `DONT_TOUCH`，metadata/control仍可优化。流水停顿时sample、weight、坐标及SOF/EOL/EOF作为完整payload冻结，填充后仍保持II=1。
- 最终primitives `interp_preserved_pipe_primitives_20260827` 通过50组配置、3,211 requests和10,726组插值；同一四级功能结构的system通过12组配置、313 requests/outputs，完整8×8 SoC保持 `done/swaps/drops=1/1/0`、22 descriptors、`AW/W/B=852/868/852`、`AR/R=1119/2199`。综合属性不改变仿真语义。
- proxy `interp_preserved_pipe_ticket_proxy_20260827` 为 `44568 LUT/32064 FF/5832 LUTRAM/20 RAMB36/9 RAMB18/78 DSP`，相对descriptor阶段 `+366 LUT/+459 FF/0 DSP`。旧插值路径在两份top-20中为0；overall direct WNS `+0.136 ns`、Q→D `+0.340 ns`，两份各20条路径均MET，Artix-7 100 MHz综合代理首次整体闭合。
- 新direct首路径为registered fatal ticket→CNN `conv_tile_read_addr_q.CE`，13 levels、data delay `9.482 ns`、route 76.4%，但仍有 `+0.136 ns` 裕量。此结果不是Artix-7 place/route、更不是Ti60/Efinity签核；下一阶段应停止继续挤压综合代理WNS，转向15 fps吞吐瓶颈（AXI packing/burst、cache、多outstanding与并行MAC）。
- 综合runner的短路径runtime cache在失败时供紧邻重试复用，成功后自动删除；三份报告直接保存在log目录。本轮累计删除1,322个临时文件、187.044 MiB，当前xsim/Vivado/runtime目录均为0；保留80个小日志、状态和报告，共1.880 MiB。

### 2026-08-27 15 fps 吞吐优化阶段

本阶段已从纯模型推进到可独立复用的 AXI/cache/fabric seam，详见
[`15FPS_THROUGHPUT_PHASE.md`](15FPS_THROUGHPUT_PHASE.md)。关键结果：

- 读 pack/burst leaf、3-row cache shell、ID-less 多 outstanding read arbiter 和
  两客户端 read-fabric wrapper 均 detached xsim PASS；集成测试
  `16 logical→6 AR/8 R beats/max_inflight=5`。
- 写 pack/burst leaf PASS（当前单 outstanding）；新增 write arbiter 允许三个独立
  writer 的 AW descriptor 预排，PASS `6 AW/12 W/6 B/max_outstanding=3`，并覆盖
  AW/W/B stall 与 BVALID hold。
- 双 lane `c1_dot8x8_requant_bank` PASS；独立 proxy 的 LANES=1/2/4 资源近似线性
  增长，说明下一步瓶颈是调度/供数而不是单个乘法器。
- 响应阈值优化后，读集成 proxy（两个 leaf + fabric）为
  `31905 LUT/10075 FF/WNS +1.928 ns`，仍没有 BRAM inference；基础写 fabric
  为 `370 LUT/478 FF/WNS +3.787 ns`，双 lane write wrapper 为
  `4308 LUT/10091 FF/WNS +1.203 ns`。读 response arrays 必须在 Efinity 中
  做 EBR/同步 FIFO 对照，不能把 Xilinx LUTRAM 结果直接外推到 Ti60。
- 新的 `fabric_outstanding_sweep` 显示理想 cache+pack2 下 memory-only bound 在
  effective outstanding=2 已越过 15 fps 门槛，out=4 后受 payload issue 限制；
  shared engine 仍远低于目标，因此只增加 outstanding/FIFO 不足以交付 15 fps。

本阶段下一步优先级：

1. 在不改默认 top 的前提下，把一个真实 tensor client 接到 read fabric，加入
   cache flush/abort/generation 和 native 长帧 underflow/deadline 断言；
2. 决定写端是实现 descriptor+B response FIFO（真正单 writer 多 outstanding）还是
   直接调用厂商 AXI DMA/DDR IP，并测量 AW/W/B QoS；
3. 选择 2/4 个 MAC output-group lane，重写 inter-pixel/inter-stage scheduler 和
   egress FIFO，避免当前 engine 的 collect/prefetch/egress 气泡；
4. 对读 response FIFO 做同步 EBR 变体的小型综合对照，再进入 Ti60/Efinity。

在上述四项和 native 640×480 长帧回归完成前，仍不宣称 15 fps。

### 2026-08-27 响应反压解耦与双 lane 写实验（追加）

本轮先处理吞吐 seam 的时序可实现性，而没有把未经验证的多 lane 结构接入
默认 SoC：

- 读 leaf 的 `rsp_capacity` 改为静态 0/1/2 槽阈值，写 leaf 的 `rsp_space`
  改为 occupancy-only；两者都切断下游 `rsp_pop`→AXI `RREADY/BREADY` 的
  组合反馈。xsim 的 pack、乱序等待、满槽反压和错误响应场景重新通过。
- 新增 `c1_tensor_mem_axi128_write_parallel_fabric.sv`：两个单 outstanding
  写 leaf 以连续 block 轮转，外层 tag FIFO 恢复逻辑顺序，内部 write arbiter
  允许 AW 预排。双 lane xsim 观察到 `max_outstanding=2`；它是验证 MLP 的
  可选 seam，不等于单 writer 已经支持 AXI ID/乱序 B。
- proxy 结果：read fabric `31905 LUT/10075 FF/WNS +1.928 ns`，双 lane
  write fabric `4308 LUT/10091 FF/WNS +1.203 ns`，均为 100 MHz 综合代理
 通过；读写 response RAM 仍是 LUTRAM 映射，必须在 Ti60/Efinity 做 EBR/同步
 读变体。

因此下一步按风险排序为：

1. 给真实 tensor client 增加 bounded request/response FIFO，并接入 read
   fabric 做小尺寸 backpressure/flush/abort gate；
2. 将已实现的 burst-level descriptor/payload+B seam 接到单 writer logical
   adapter（或明确采用厂商 AXI DMA/ID），再测量有效写 MLP；
3. 将 2-lane MAC bank 接到 output-group scheduler，显式扩宽权重供数、egress
   FIFO 和 stage boundary；
4. 只有上述链路稳定后，才做 native 640×480 长帧周期/QoS/deadline 测量。

### 2026-08-27 beat-record FIFO 与 ping-pong MAC（本轮收口）

- 读 leaf 的可选 `RSP_FIFO_BEAT_MODE=1` 已完成正常和 malformed xsim。它把
  一个 AXI128 `R` beat 作为一个 FIFO record，再按 lane 顺序拆成 local 64-bit
  响应；同参数 Artix proxy（`REQ16/BURST16/MAX4/RSP64`）从 logical
  `12045 LUT/5378 FF/+1.046 ns` 降为 `1714 LUT/1182 FF/+1.380 ns`。
  该收益来自 metadata/双写逻辑收缩，AXI beat 数不变；当前 fabric/cache 仍
  默认 mode=0，待 Efinity EBR 和长帧压力确认后再启用。
- `c1_dot8x8_requant_pingpong` 以两个完整 bank 轮转接收事务，tag FIFO 保持
  输出顺序。xsim 的 6 事务回归显示 `max_inflight=2`、首个 overlap 提前
  8 cycles；full-tree Artix proxy 为 `31162 LUT/22833 FF/64 DSP/WNS
  +1.938 ns`。它隐藏的是 bank 内部 latency，不是 stage 间完整流水。
- 因而下一阶段优先级不变但边界更明确：
  1. 把 beat FIFO 作为**可选 leaf 配置**转发到真实 tensor/cache client，先做
     小尺寸 response/backpressure/flush gate；
  2. 将 burst-level descriptor + payload/B FIFO seam 接到单 writer logical
     adapter（或锁定厂商 AXI DMA），形成真实的写侧 outstanding；
  3. 将 ping-pong bank 接到 output-group scheduler，补齐权重预取、egress FIFO
     和 stage boundary，再用周期模型核算是否接近 15 fps；
     4. 最后才跑 native 640×480 长帧 QoS/deadline。当前所有数字仍是 boardless
     seam/proxy，不是 Ti60 实测。

### 2026-08-27：本阶段已完成的吞吐收口

上述优先级已转化为可复现的 A/B 入口：

1. 读侧 `BURST_BEATS=16/MAX_OUTSTANDING=4` 已在 leaf 和 cache shell 压力
   回归通过；cache shell 的 64×2-group 行使四个 descriptor 实际保持在途，
   便于后续替换成真实 DDR BFM。`BURST_BEATS=32` 仍只在几何模型中评估，避免
   过早占满共享 ID-less fabric。
2. 写侧 `ALLOW_RSP_POP_REFILL` 已从 burst MLP 传到 logical adapter/2-client
   fabric；默认/可选路径计数和错误顺序一致，收益仅一个 B stall。`EMPTY_AW_BYPASS`
   同样只消除首拍空队列 bubble。两者都不减少 AXI payload，且默认关闭以保护
   时序边界。
3. cache 的三行完整 refill 仍是当前最有效的板前带宽削减；本阶段没有贸然加入
   行预取，因为 `c1_window_line_cache_c8` 的 miss/refill 合同一次只接受一行，
   预取必须先定义 tap scheduler 的 look-ahead、abort/flush 和额外 EBR 端口。
4. 并行 MAC 继续采用二-bank ping-pong 作为可行基线；首拍 skid 仅是可选微优化，
   四-bank与 full-top DW cache+overlap 的 timing 余量不足，不能直接作为15 fps
   方案。

下一阶段的验收门槛因此明确为：在真实 tensor client 接入后，分别记录每个 leaf
的 `AR/AW wait`、burst 长度分布、`max_outstanding`、cache row-miss latency、
MAC input starvation 和 egress backpressure；只有这些计数在 native 长帧和
video/capture 竞争下仍满足 deadline，才考虑打开任何 optional mode。

随后已把 `LEAF_RSP_FIFO_BEAT_MODE` 转发到两客户端 read fabric，并保持 cache
shell 可选转发。集成 xsim 仍为 `16 logical→6 AR/8 R beats/max_inflight=5`；
Artix proxy 由 logical `31905 LUT/10075 FF/+1.928 ns` 降为 beat
`2194 LUT/1630 FF/+1.815 ns`。这使“先在一个真实 tensor leaf 打开 beat mode、
再扩到 fabric”的路径可执行，但不改变下一阶段的核心任务：单 writer 真正
多 outstanding、MAC scheduler 供数，以及 native 长帧 QoS/deadline。

### 2026-08-27 burst-level write MLP seam 与四-bank MAC A/B（追加）

- `c1_axi128_write_mlp` 已把“单 writer descriptor + payload/B FIFO”的关键接口
  独立成 boardless seam：AW 可对多个 descriptor 预排，W/B 仍保持 descriptor
  顺序，并对 payload framing、flush、orphan 和错误 B 做 sticky 诊断。xsim
  `desc=6/aw=3/w=12/b=3/max_out=3`（AW/W/B stall=`18/5/49`，errors=`4`）和
  Artix proxy `5882 LUT/10308 FF/+3.249 ns` 均通过。新的 logical adapter 已
  将 64-bit pack2 接到该 backend；两者仍未接入默认 SoC，因此不能把该结果当成
  整帧写带宽提升。
- `c1_tensor_mem_axi128_write_mlp_adapter` 小配置 xsim（`MAX_BEATS=4`）通过
  `desc=5/req=26/rsp=26/aw=4/beats=12/packed=13/errors=2/max_out=4`；
  `MAX_OUTSTANDING=4/MAX_BEATS=16` 的 Artix proxy 为
  `15961 LUT/27771 FF/0 BRAM/0 DSP/WNS +2.551 ns`。另有可选两客户端
  `c1_tensor_mem_axi128_write_mlp_fabric_2c`，用于把 adapter 与 raw peer 放进
  同一 ID-less AW/W/B fabric，下一步以真实 tensor client 和七客户端 QoS 回归。
- `c1_dot8x8_requant_pingpong` 的四-bank A/B xsim 为
  `banks=4/lanes=2/transactions=12/max_inflight=4/first_overlap=8/cycles=47`；
  full-tree proxy 为 `59912 LUT/45674 FF/128 DSP/WNS +0.337 ns`。相较二-bank
  proxy 的 `+1.938 ns`，余量明显收窄，故四-bank只保留为并行度上限证据，不作为
  默认配置。
- 四 lane write parallel fabric A/B 也已通过：四个单 outstanding leaf 以 block
  轮转隐藏写侧 latency，xsim `req=32/aw=8/beats=16/packed=16/errors=4/
  max_outstanding=4`，Artix proxy `9858 LUT/20168 FF/0 BRAM/0 DSP/WNS
  +2.166 ns`。它验证横向 lane scaling 和 tag FIFO 保序，不提供单 writer 的
  AXI-ID/乱序 B 语义，且尚未接入默认 SoC。
- 两个新的可选 engine 控制开关已完成板前 A/B：
  `MAC_PREFETCH_OVERLAP=1` 在当前已接受 Conv/1x1 beat 的同一边沿捕获下一
  tile，关闭/开启小测试首轮 cycles 为 `30570/29192`；与
  `CACHE_DW_WEIGHT_TILES=1` 联合为 `27174`。tap-bank×64-bit 重构后的
  cache+overlap full-top proxy 为 `36413 LUT/14889 FF/2 BRAM/35 DSP/WNS
  -4.959 ns`，对应 native 共享-FSM 模型为
  `39,571,200→31,238,400→21,715,384` cycles（约 `2.527→3.201→4.605 fps`
  的计算上界），仍远低于 15 fps；该 full-top proxy timing 仍未闭合，
  所以默认仍关闭，需要在 Efinity 复测 EBR/同步读和时序。
- 下一步边界更新为：
  1. 先在两客户端 seam 上完成 adapter→fabric 的 backpressure/顺序/错误回归，
     再把 generation/flush/abort drain/ownership 合同接到真实 tensor client，
     并在七客户端 fabric 中以 `MAX_OUTSTANDING=2` 起步；
  2. 再将二-bank MAC 接入 output-group scheduler，补齐权重预取、egress FIFO
     和 stage boundary；四-bank只有在真实供数链路显示仍受算术吞吐限制时再评估；
  3. 对 payload/response 数组做 Efinity EBR、同步读延迟和 native
      640×480 QoS/deadline 对照，最后才重算 15 fps cycle budget。

### 2026-08-27：边界气泡 A/B 已补齐

本阶段又完成了三条可回退路径，均不改默认 SoC：

1. 读 request FIFO 的 `ALLOW_REQ_POP_REFILL` 在满槽且 builder 同拍取头时
   允许替换写入；专用 depth-4 TB 的 `full_to_accept` 为 `5→4`，但
   `req/ar/beats/max_req=12/12/12/4` 不变。
2. 读 arbiter 的 `EMPTY_AR_BYPASS` 在两个 descriptor ring 为空时直通首个
   AR；`first_ar_latency=1→0`，正常/畸形 R beat 及错误 containment 不变。
3. MAC core/bank/ping-pong 的 `ALLOW_OUTPUT_RESTART` 在结果退休边沿复用
   同一 bank；二 bank×二 lane xsim 为 `40→37` cycles、4 次 same-bank
   restart，独立事件模型为 `22→20` cycles。

这些路径的共同限制是：只削减边界等待，不减少 AXI payload、不增加真实 DDR
带宽，也不把共享 FSM 变成 stage-overlapped CNN。它们分别引入 ready→source、
source→AR 或 out_ready→start_ready 的组合路径，因此保持默认关闭。后续工作
应把收益放回 native frame budget，而不是把三个小 TB 节拍简单相加：

- 先接真实 tensor/cache client，测 `AR/AW wait`、burst 分布、FIFO occupancy、
  row-miss latency 和 abort/flush；
- 再以二 bank、`MAX_OUTSTANDING=2` 在 Efinity 做 EBR/时序/QoS 对照；
- 只有 MAC input starvation 接近零且 output-group scheduler 能持续供数时，才
  试开 output restart；否则维持兼容默认值。

### 2026-08-28：共享 owner/epoch fence 与可选 arbiter integration shell

为给 native 长帧 QoS 接入建立明确的维护边界，新增
`c1_axi_shared_owner_epoch_fence` 控制 seam，并在真实
`c1_axi_n_serial_arbiter_128` 上增加只读的
`read_busy/read_quiescent/write_busy/write_quiescent/read_owner/write_owner`
观测端口。维护边沿关闭空闲新 owner，但保留已锁定且可能 stalled 的 owner；
两方向完全排空后才发出 abort/flush completion token 并递增 epoch。

独立真实 arbiter+fence 回归通过：

```text
C1_AXI_SHARED_OWNER_EPOCH_FENCE_ARBITER_PASS ar=1 r=1 aw=1 b=1 epoch=2 cycles=23
```

随后新增可选 `c1_axi_shared_owner_epoch_arbiter_128` shell，把 gate 放到
arbiter 前而不改 payload 路由；2-client/no-skid 与 read-skid=1 的 shell xsim
均通过，七客户端 read-skid 版本的 proxy 为
`1411 LUT / 407 FF / 0 BRAM / 0 DSP / WNS +2.144 ns / TNS 0`。完整
cache-enabled portable SoC wiring smoke 也仍通过
`C1_R1_PORTABLE_SOC_CACHE_WIRING_SMOKE_PASS tensor=02000000 quiescent=1 fence=1`，
说明新增 arbiter status 端口没有破坏默认 named instantiation；该 smoke 不
表示 shell 已接入 default SoC。

本阶段仍不打开默认吞吐开关，也不把 shell/proxy 数字叠加到完整 SoC。下一步
应在该 fence seam 上接入真实 capture/parameter/tensor/display/compute client，
记录每类 AR/AW wait、burst/long-frame occupancy、display underflow、MAC input
starvation 与 deadline，再决定是否切换 burst/multi-outstanding QoS。新增
Vivado/xsim runner 使用 detached WMI worker、xvlog response file 和 finally
runRoot 清理；历史大文件保持不动，需单独确认后再清理。

### 2026-08-28：生产 QoS monitor 与端到端 native 基线（已完成）

`c1_axi_shared_qos_monitor` 已从 testbench bind monitor 提升为可选 RTL 观测
边界。它不改变 AXI owner/payload，支持 `csr_clear_stats_pulse` 清零，并输出
每客户端 AW/AR wait、W/R/B stall、accepted beat、owner hold，以及 underflow、
frame/deadline/protocol counters。24-bit 版本的独立 Artix-7 100 MHz proxy 为
`2268 LUT / 4000 FF / WNS +1.465 ns / TNS 0`；32-bit 版本的时序不能直接推断。

native 8×8 BFM 用 `-SharedQosMonitor` 已通过，且端到端统计窗口改为
accepted boardless start→`display_prefetch_new_done_event`（对应新 pair 的
prefetch/FIFO/line-store terminal）：

```text
frame_count=2 last_frame_cycles=3446518 deadline_miss=2 underflow=2
read_busy=5358372 write_busy=12955 r4_stall=5338987 r5_stall=2205
ar4_wait=2365 ar5_wait=5339177 protocol=0 overflow=0
```

这证实 `control_done_event` 早于显示排空，若用它作 deadline 会漏掉大量
ID-less HOL；raw `display_prefetch_done` 还可能是 current-pair 后台刷新，不能
替代带新帧标签的 terminal。当前 default SoC 仍不实例化 owner/epoch payload mux、
burst writer 或 multi-outstanding；monitor 默认关闭，per-client 统计只在层次化
native debug 接口可见，aggregate 已通过 APB `0x108..0x12c` 读回（native BFM
还执行逐字段 APB/hierarchical 比对）。`display_swap_event` 是独立 VSYNC
ownership commit，当前允许早于 tagged done。下一阶段按以下顺序推进：

1. 在同一 monitor 上跑 response-FIFO/read-skid 与 owner/epoch shell 的 A/B，
   对照 `r4/r5` hold、underflow 和端到端 deadline，而不是只比较总周期；
2. 评估 response-FIFO/owner-fence A/B 后是否需要冻结式 APB snapshot；当前 live
   aggregate 窗口已映射到 `0x108..0x12c`，保留 per-client 深度统计为软件可选
   层次化诊断，避免 4k FF 全部常开；
3. 在 native 16×8/64×48 以及最终可承受的 640×480 compile/短窗口上复用门，
   再决定是否把 owner/epoch admission 接入默认 SoC；
4. 只有 QoS/underflow 证据稳定后，才重新计算 15 fps 与并行 MAC/AXI burst
    的组合收益。当前 tagged two-frame `deadline_miss=2`、`underflow=2` 是风险
    定位，不是性能达标声明；standalone monitor 的单次 underflow/deadline marker
    属于另一组 2-client directed test，不能混用。

同一 tagged two-frame BFM 打开 `C1_DISPLAY_RESPONSE_FIFO` 后，`r4/r5` stall
从约 `5.34 M` 降为 `27/27`，`ar4/ar5` wait 为 `194/234`，`read_busy` 约
`17 k`；但 `last_frame_cycles` 仍为 `3446518`，deadline/underflow 仍为
`2/2`。因此 FIFO 已证明能消除 display response HOL，却没有释放端到端帧预算；
下一轮应把 cycle attribution 细化到 client-6 tensor、descriptor/compute-start
和共享 arbiter，而不是继续单独堆叠 display FIFO。

64×48 tagged 两帧 FIFO 回归 `native_qos_fifo_tagged_64x48_twoframe_v2` 已补齐
该边界：`done=2/swaps=2/drops=0`、`frame_count=2`、
`last_frame_cycles=5086618`，`r4/r5 stall=4305/3499`、`ar4/ar5 wait=941/1005`、
`read_busy=626599`，`protocol=0/overflow=0`，APB `0x108..0x12c` 逐字段读回通过。
首轮 v1 的失败发生在固定 5 M-cycle 测试台观察上限；将大 shape 的观察上限
设为 20 M 后第二 tagged terminal 在约 90.48 ms 到达，证实不是 FIFO 死锁。
该回归的 `underflow=3` 来自 64×48 shape 与固定 720p/640×480 compositor
请求窗不匹配，属于尺度诊断；不得与 native 640×480 的 underflow 结论混用。

### 2026-08-28：可选 tensor client-6 burst/refill 维护闭环（已完成）

本阶段把 refill-side burst seam 从“正常 miss/hit 可运行”推进到可作为后续
板前集成基线的维护契约：

1. `c1_tensor_window_cache_burst_axi_client` 的 pending tap 在 abort/flush
   期间同时关闭 `s_req_ready` 与 `tap_valid`，防止上游在 fence 间隙错误撤回
   尚未被 child 接收的 logical request；响应侧仍保持可排空。
2. exact shell 在 `REFILL_REQ` 已可见、但 command 尚未握手时捕获 command，
   通过旧 epoch rejection 和 exact-count poison suffix 完成 fence；standalone
   TB 已分别覆盖 flush-before-AR 与 abort-before-AR。
3. 取消错误策略已从隐含的 adapter 默认值提升为显式参数：
   `BURST_CANCEL_IS_PROTOCOL_ERROR` / `TENSOR_BURST_CANCEL_IS_PROTOCOL_ERROR`。
   默认值 0 允许预期帧 fence 恢复，结构性 sideband/LAST fault 仍保持 sticky。

最终 standalone marker：

```text
C1_TENSOR_CACHE_BURST_AXI_CLIENT_PASS
burst_ar=4 single_ar=5 beats=13 aw/w/b=2/2/2
flush_done=2 abort_done=3 ar_stall=3 r_stall=0 r_gap=21
aw_stall=1 w_stall=2 cycles=265
```

64×48 `-SharedQosMonitor -TensorBurstRefill -DisplayResponseFifo` compile-only
gate 也通过；此前同条件两帧 full BFM 的代表性结果为
`client-6 AR/R=59664/76800`，相比 legacy `96384/96384` 分别减少约 38.1%
和 20.3%。但 `last_frame_cycles=5086618` 未下降，说明当前瓶颈仍在共享
ID-less display/其它 client，而非 client-6 row refill；该 optional seam 不应
被写成 15 fps signoff。

下一步应转为目标板工具链验证：先做 Efinity EBR/时序综合，再接真实 DDR
controller 和 QoS monitor；只有测得 client-6 owner hold、display underflow、
MAC starvation 与 native deadline 后，才决定是否需要真正的 tile-level
cross-request outstanding。完整接口、参数、证据和限制见
`TENSOR_CLIENT_BURST_REFILL_INTEGRATION.md`。

本阶段结束前又完成同参数组合的 640×480 compile-only gate：
`C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS frame=640x480`。它只确认 native 几何
和 optional generate 可以展开，不改变“尚未进行 native 长帧仿真/板卡时序签核”
的结论。

### 2026-08-28：logical/beat full-top proxy 与 native beat gate（已完成）

本轮完成 tensor burst 的 logical-entry 与 beat-record 两种 full-top proxy
综合，并以相同 optional 配置跑通 8×8/64×48 native 两帧 gate。logical
最终 `portable_soc_tensor_burst_logical_v4` 为 `80791 LUT/39369 FF/32 BRAM/100 DSP`、
WNS `-52.20 ns`（此前 v3 的 `+14.92 ns` 是解析错误，已废弃）；beat
`portable_soc_tensor_burst_beat_v1` 为 `48411 LUT/30950 FF/32 BRAM/100 DSP`，
`48411 LUT/30950 FF/32 BRAM/100 DSP`，但 WNS `-52.55 ns`，故 beat 仅记综合
完成，不记 timing PASS。native `tensor_burst_beat_8x8_twoframe_v1` 与
`tensor_burst_beat_64x48_twoframe_v1` 均严格 PASS，分别完成
`done=2/swaps=2/drops=0`、`AR/R=1451/2970` 与 `60165/84187`。

下一步优先处理 beat path 的时序收敛（response/record 边界与 payload 控制
分级），再做 Ti60/Efinity EBR 映射；native beat shape PASS 目前只作为功能与
drain/ownership 证据，不外推 640×480@15 fps。

### 2026-08-28：REGISTER_ABORT_RESET A/B 结果与下一步

native resize PASS；native 8×8/64×48 abortreg 均 PASS，`protocol=0`。proxy
baseline 为 `48192 LUT/31227 FF/32 BRAM/88 DSP`、WNS/TNS
`-5.900/-67577.578`；abortreg v2 为 `48211 LUT/31237 FF/32 BRAM/88 DSP`、
WNS/TNS `-5.416/-66644.070`，`timing_met=false`。剩余最差路径是 reset 相关的
descriptor decoder path，下一阶段应围绕该路径继续做时序收敛。

### 2026-08-28：PIPELINED_DECODER_VALIDATION

decoder pipeline 已沿 engine→cnn_top→system_bridge→portable_soc 参数化，默认关闭（0）。
MicroStyle engine marker `C1_R1_MICROSTYLE_ENGINE_PASS ... outputs=836 ... first_run_cycles=30570`；
完整 8×8 两帧组合 PASS：`done=2/swaps=2/drops=0`、`protocol=0`、
`last_frame_cycles=3446518`、`r4/r5 stall=29/29`、`ar4/ar5 wait=202/244`。

proxy `tensor_burst_beat_pipelined_split_addr_abortreg_decoderpipe_v1` 为
`47493 LUT/31441 FF/32 BRAM/88 DSP`、WNS/TNS `-5.362/-66042.227 ns`，
`timing_met=false`；abortreg v2 为 `48211/31237/-5.416/-66644.070`。该配置在
配置阶段每 descriptor 固定增加两拍，运行期协议不变，仍非 timing signoff。

### 2026-08-28：REGISTER_FATAL_TICKET / replicate 下一步

decoderpipe full-top proxy（`REGISTER_FATAL_TICKET=1`、`REPLICATE=0`）为
`47467 LUT/31471 FF/32 BRAM/88 DSP`，WNS/TNS `-4.601/-960.989`，
`timing_failed`；worst path 为 `dot_weight_tile_q_reg C→dot_core/g_dot[*]/acc_overflow_reg D`。
打开 `REPLICATE_ABORT_CONTROL=1` 后为 `47474 LUT/31502 FF/32 BRAM/88 DSP`，
WNS/TNS `-4.601/-969.458`，几乎无收益。native 8×8 two-frame ticket PASS：
`done=2/swaps=2/drops=0`、`protocol=0`、`last_frame_cycles=3446518`，client-6
`AW/W/B=1672/1672/1672`、`AR/R=1268/1600`。ticket 是 timing candidate，replicate
默认关闭；仍不得写成 timing signoff。

### 2026-08-28：deep pixel-index 实验结论

`PIPELINED_TENSOR_PIXEL_INDEX` 新增但默认关闭。standalone adapter PASS：
`requests=2230 reads=1810 writes=420 pipeline=1`；8×8 两帧 full BFM PASS：
`done=2/swaps=2/protocol=0`。

proxy `tensor_burst_beat_pipelined_deeppixel_abortreg_decoderpipe_v1` 为
`47522 LUT/31431 FF/32 BRAM/88 DSP`、WNS/TNS `-5.544/-66243.875`，相对
decoderpipe baseline `47493/31441/-5.362/-66042.227` 变差 `0.182 ns`；worst
path 转为 `camera FIFO→tensor_adapter/state_q CE`。后续仅保留为可回退研究开关，
默认弃用，不再加深。

### 2026-08-28：dot-tree full A/B 下一步

推荐组合 functional 8×8 two-frame PASS：`done=2/swaps=2/drops=0/protocol=0`，
`AW/W/B=1704/1736/1704`、`AR/R=1451/2970`、`last_frame_cycles=3446518`。
推荐 full-top proxy `recommended_fatal_ticket_dotfull_v1`（Beat+PipelinedAddress+
descriptor pipeline+narrow+abort reset+decoder pipeline+REGISTER_FATAL_TICKET+
PIPELINED_DOT_TREE_FULL）为 `47392 LUT/34763 FF/32 BRAM/88 DSP`、WNS/TNS
`-3.450/-33.977 ns`；dotbase ticket 同组合为 `47464/31504/32/88`、
`-4.601/-969.458`。瓶颈已由 dot weight→acc_overflow 转为 descriptor size
narrow return→`descriptor_input/output_size_result_q`（`-3.450`）。dotfull 仅作
可选 timing candidate，默认 0，仍非 timing signoff。

### 2026-08-28：descriptor-size arithmetic / fixed-threshold A/B

descriptor size arithmetic v3 standalone PASS；完整 8×8 两帧 full BFM PASS：
`done=2/swaps=2/drops=0/protocol=0`、`last=3446518`，AXI
`1704/1736/1704/1451/2970`（AW/W/B/AR/R），QoS `r4/r5=36/35`。

proxy size0 为 `47399 LUT/34764 FF/32 BRAM/88 DSP`、WNS/TNS
`-2.907/-24.206`；size1 为 `47544 LUT/34819 FF/32 BRAM/87 DSP`、
`-2.363/-62.605`；fixed-threshold 为 `47512 LUT/34821 FF/32 BRAM/85 DSP`、
`-1.079/-20.120`。fixed 相对 size1：LUT `-32`、FF `+2`、DSP `-2`、WNS
`+1.284`、TNS `+42.485`；最差路径转为 `16x16 pixel_count`。默认关闭，且仅在
Case1 固定 8MiB/22-stage 严格条件下评估，仍非 timing signoff。

### 2026-08-28：pixel-count split

standalone/BFM 均 PASS；BFM AXI=`1704/1736/1704/1451/2970`（AW/W/B/AR/R），
`last_frame_cycles=3446518`，QoS `r4/r5=28/27`，配置
`descriptor_size_arith=1 fixed=1 pixel=1`。proxy 为
`47542 LUT/34818 FF/32 BRAM/83 DSP`、WNS/TNS `-1.217/-18.572`，相对 fixed
baseline WNS `-0.138 ns`；最差路径为 `cache height_q→adapter state CE`。
默认关闭，仍非 timing signoff。

### 2026-08-28：iterative descriptor pixel-count shift-add

standalone PASS marker；BFM two-frame PASS，AXI=`1704/1736/1704/1451/2970`
（AW/W/B/AR/R），`last_frame_cycles=3446518`、`protocol=0`、QoS `r4/r5=27/27`。
iterative native-control proxy 为 `47611 LUT/34917 FF/32 BRAM/82 DSP`、WNS/TNS
`-1.206/-23.233`；同 runner fixed native control 为
`47512 LUT/34821 FF/32 BRAM/85 DSP`、`-1.079/-20.120`。相对 fixed，迭代 WNS
`-0.127 ns`、LUT `+99`、FF `+96`、DSP `-3`，瓶颈迁移为
`cache height_q→state CE`。两次旧 cache env failure 后最终使用 native runtime；
默认关闭，仍非 timing signoff。

### 2026-08-28：registered preclamp A/B 与坐标语义收口

新增 `PRECLAMPED_TAP_COORDS`（默认 `0`）。在 opt-in 模式，adapter 在既有
request-Q 边界复用物理地址的 `tap_source_x/y_fn`，寄存 Conv3x3/DWConv3x3 的
钳位坐标，再送入 line-cache/burst exact shell；因此 cache 侧不再重复做
width/height 比较。该优化只针对已通过 descriptor/shape 校验的 window request，
不改变默认 signed logical sideband，也不增加新的 ready→state 组合路径。

功能 gate `preclamped_registered_tap_8x8_twoframe_v1` 已通过：
`done=2/swaps=2/drops=0/descriptors=44/protocol=0`，
`drain_cycles=3464876`；与 fixed baseline 的 `AW/W/B=1704/1736/1704`、
`AR/R=1451/2970` 和 AXI stalls `231/464/212/1879` 完全一致，并通过 APB
QoS readback。该证据只说明 traffic/ownership/背压等价，尚无时序收益结论。

早期 raw sign-only clamp 候选 `preclamped_tap_8x8_twoframe_v1` 虽通过生命周期
marker，却改变为 `AR/R=1463/3042`（client-6 `1280/1672`），原因是把未钳位
signed logical 坐标直接送入 physical cache。该候选已拒绝，后续不得用于性能
对比。随后 native helper=all 已修复 full-top `common.tcl` runtime failure 并得到
完整 A/B（详见文末）；保持默认关闭，结果仍是 xc7a proxy/timing_failed，不写成
Ti60/Efinity timing signoff。

### 2026-08-28：native helper=all full-top PRECLAMP A/B

native helper=all 已解决 full-top Vivado `common.tcl` runtime failure，因而本轮
首次得到有效的严格同条件综合 A/B。两组仅切换 `PRECLAMPED_TAP_COORDS`，其余
beat-record、`RSP_FIFO_DEPTH=64`、strict descriptor、pipelined address/decoder/
size arithmetic、fixed limits、dot-tree full、narrow return、abort reset 和 fatal
ticket 配置一致；part=`xc7a200tsbg484-1`，frame=`640×480`。

| 配置 | LUT | FF | BRAM tile | DSP | WNS | TNS |
|---|---:|---:|---:|---:|---:|---:|
| `baseline_helper_all_v1`，`PRECLAMP=0` | 47,512 | 34,821 | 32 | 85 | -1.079 ns | -20.120 ns |
| `preclamped_registered_helper_all_v1`，`PRECLAMP=1` | 47,443 | 34,784 | 32 | 81 | -1.079 ns | -15.868 ns |

registered 相对 baseline 的 delta 为 LUT `-69`、FF `-37`、BRAM `0`、DSP `-4`、
WNS `0 ns`、TNS `+4.252 ns`。因此该候选在 xc7a proxy 上有小幅资源收益、WNS
不变且 TNS 改善，但状态仍为 `timing_failed`（WNS 仍为负）；helper=all 只修复
了 Vivado runtime，不能视为时序优化本身。两组均为 synthesis-only、未做 P&R，
不能外推为 Ti60/Efinity signoff；保持 `PRECLAMPED_TAP_COORDS=0`，待真实
器件/约束下复核后再决定是否启用。
