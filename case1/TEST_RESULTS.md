# 赛题一：板卡无关验证结果

最新[C31验证记录](review/R2_RGB2_HOST_INTEGRATION_20260914.md)：原图24正确CNN、变体24、故障48及40个故障后新任务、8实际RAM负控、小图xsim6次CNN与定向PNR已通过。原生c的CPU激励失败已修复，d实际完成6CNN/13Capture/26源帧，峰404/512，末尾CPU/AXI/CSR检查通过；[独立原生门禁](logs/r2_c31_native_d_gate_20260914_a.log)给出AW2下约14.10171fps，15fps字段false。[C32诊断](review/R2_CUTTHROUGH_WRITER_20260914.md)另通过22单元/24写侧AXI配置，但真实队首阻塞使其暂不晋升主线；不是整机优化成功。旧C26 AW0不与C31 AW2作同口径因果比较；以下结果保留其原阶段边界。

最新新增[C30报告](review/R2_DEMO_RGB2_INGRESS_20260914.md)/[门禁](logs/r2_c30_gate_20260914_c.log)：真实企业5文件的接口/golden/错误打包负控；普通/奇数ROI各两背压合计60好帧与56预期坏帧；完整1080p VS/DE连续两帧、3,110,400 ROI像素/153,600 AXI字/峰404；独立Resize22配置、raster边界8配置；xsim企业/故障路径与Icarus事件周期一致，六证据篡改拒绝。Ti60前端MAP 20 RAM/18 DSP，未PNR、未接完整主机。20个临时运行工程清理，运行文本214,415字节，无波形。

另行保留C26的原生长仿真已完成：[native门禁](logs/r2_c26_native_gate_20260914_a.log)为13采集/6正确CNN/12,902,400显示像素，最慢间隔9,793,756周期；150MHz和既定DDR模型约15.31588fps，非板测、非C29/C30新路径帧率。

最新R2截点：2026-09-14，[C29报告](review/R2_CAMERA_CAPACITY_20260914.md)与[统一门禁](logs/r2_c29_gate_20260914_b.log)：量化/窗口独立golden与周期对比、22/18节点图各24正确CNN、故障48正确CNN、8项实际RAM负控、6帧小图xsim和Ti60定向实现检查均通过。C29对应C28的1,792条记录逐条相等；16个私有运行工程已删除，保留运行文本约3.918MiB。无新增原生fps、板测或全量CDC签核结论。

以下旧版验证截点：2026-08-29。Vivado/xsim runner 均通过 WMI 创建隐藏 worker，避免工具进程绑定当前 Codex Windows Job。除特别说明外，“严格 PASS”表示：状态 complete、工具退出码 0、stderr 为空、Fatal/Error/FAIL 扫描为 0、目标 marker 唯一。

## 0. 本轮 Efinity 与 Icarus 收口

- `run_iverilog_stage1_handoff.ps1 -FullStage21`：`C1_IVERILOG_STAGE1_PASS`
  / `C1_R1_STAGE21_FULL_8X8_PASS`，`operands=896 results=836 final=64
  stage_done=22 abort=0`；临时 vvp/vector 目录在脚本 `finally` 中删除。
- Efinity 同步 EBR/64-MAC proxy、dot core、DW leaf wrapper 的 map/PNR 结果见
  [`efinity/RESOURCE_MAP_RESULTS_20260829.md`](efinity/RESOURCE_MAP_RESULTS_20260829.md)。
  代表性结果：dot PNR DSP=80/160、final 189.717 MHz；DW wrapper PNR
  DSP=28/160、final 271.592 MHz；scheduler PNR DSP=1/160、final 236.855 MHz。
- 默认 `PACKED_AFFINE_CACHE=0` 时，Efinity `c1_r1_microstyle_engine` 和完整
  CNN top 的 map 探针均记录同一 `EXCEPTION_ACCESS_VIOLATION`，没有生成伪造
  资源数字；失败被归类为当前 Efinity 前端/复杂 SV 兼容性待定位，而非功能
  回归 FAIL。
- 默认 unpacked affine 尺寸阈值探针中，`MAX_CHANNELS=8` 的 small/full-weight
  wrapper map 通过，而 `MAX_CHANNELS=16/24/48`、full-cache/full-shape 均在同一
  `efx_map.exe → libefx.dll/libvfc_database.dll` 访问违例退出；这不是资源超限
  证明。完整参数和 run ID 见
  [`efinity/RESOURCE_MAP_RESULTS_20260829.md`](efinity/RESOURCE_MAP_RESULTS_20260829.md)。
- 可选 `PACKED_AFFINE_CACHE=1` 的两个 boardless wrapper 已通过 map+PNR：
  channel16 run `407ec906b61e4066b57fcdd3db6fd46f`，final `396.040 MHz`
  （2.525 ns）；fullchannel/48-channel run
  `12e273493bf3452caef3b6b0591ad02d`，final `321.027 MHz`（3.115 ns）。
  该分支只改变 affine 小缓存表示，默认参数仍为 0；wrapper 结果不是完整
  22-stage CNN、板级资源或 15 fps sign-off。随后完成的默认/packed stage21
  trained-artifact A/B 也通过：Icarus
  `run_iverilog_stage1_handoff.ps1 -FullStage21 -PackedAffine` 与 detached xsim
  `run_r1_stage1_handoff_xsim_detached.ps1 -FullStage21 -PackedAffine` 均给出
  `operands=896/results=836/final=64/stage_done=22/abort=0`（xsim run
  `5e234f2e1b87483b8cd4c47bb9e3d667`）。该证据仍限于 8×8 scaled handoff。
- `c1_ti60_cnn_top_packed_wrapper`（`PACKED_AFFINE_CACHE=1`）进一步保留了
  22-stage dispatcher/descriptor-cache，并通过 Efinity map+PNR：run
  `e9da5ca074f34939974e794ffd40ee81`，final `2.296 ns / 435.540 MHz`，
  WNS `+7.704 ns`、WHS `+0.109 ns`。这是窄 stimulus 的 boardless candidate；
  stimulus 壳可能使逻辑/资源被优化，资源计数不能当作最终 Ti60 板级值，真实
  Sapphire/DDR3/视频/peri/pin/full-board sign-off 仍 OPEN。
- 新增 `c1_ti60_portable_soc_packed_wrapper.sv/.xml/.sdc`，将完整
  `c1_r1_portable_soc` 纳入 packed-affine 前端探针；60 s/180 s 独立 map 均未见
  已知 `libefx.dll/libvfc_database.dll` 访问违例或 HDL unknown-module 错误，但
  由 180 s 上限超时，未执行 PNR，也没有可信 LE/FF/EBR/DSP 数字。它只说明
  packed portable SoC 壳未立即触发前端崩溃，不是资源/时序签核；status/failure tail 见
  `efinity/logs/efinity_resource_runs/2473d08f8fe948df8d0056aeef857761/`。
- 最新 detached engine regression（cache 默认开启、`-OverlapMac`）仍为
  `C1_R1_MICROSTYLE_ENGINE_PASS stages=22 outputs=836 mac=312 dw=248
  bypass=276 param_reads=1115 stalls=300 aborts=8 faults=6 cache_dw=1
  mac_overlap=1 first_run_cycles=27174`；这只是功能/周期基线，不是 15 fps 或
  Ti60 时序签核。
- 收口审计：`xsim/xelab/xvlog/vvp/efx_map/efx_pnr/vivado` 活跃进程为 0，
  `%TEMP%` 中 Case-1 runner 临时目录为 0；保留的 Efinity 摘要约 0.8 MB、
  handoff marker 日志约 0.15 MB，不包含仿真波形或 Efinity work tree。
- Efinity/RISC-V 本地工具链复核（`verify_efinity_toolchain.ps1 -BuildSmoke`）
  通过：`riscv-none-elf-gcc` 13.4.0 以 `rv32imc/ilp32` 编译并链接最小
  Sapphire 软件探针，生成 ELF/HEX/BIN/反汇编，`SMOKE_BUILD_PASS files=8
  bytes=35952`。该产物是 BSP 之前的编译链检查，不等于生成的 Sapphire
  启动、APB 或板上下载已完成。

本轮还重新验证了两条系统级 xsim seam：

```text
C1_R1_PORTABLE_SOC_SMOKE_PASS tensor=02000000
C1_R1_PORTABLE_SOC_CACHE_WIRING_SMOKE_PASS tensor=00000000 quiescent=1 fence=1 qos=1
```

这两条 smoke 均由脱离当前 Windows Job 的 native worker 执行；源文件通过
response file 传入，失败路径也会清理 disposable xsim runRoot。第二条同时验证
当前生成层级下的 tensor cache seam、idle QoS snapshot 和 `system_busy` fence。
它们是结构/控制面证据，不代表真实 DDR3、长帧 CNN 或 15 fps。

packed 参数贯通 smoke 亦已复核：

- `run_portable_soc_smoke_xsim_detached.ps1 -PackedAffine`：PASS，run
  `40ef92de11024301abe4dcc069ee855e`，marker
  `C1_R1_PORTABLE_SOC_SMOKE_PASS tensor=02000000`。
- `run_portable_soc_cache_wiring_smoke_xsim_detached.ps1 -PackedAffine`：PASS，run
  `dc4e49c39efc40ac8ccca802b6c9f7a6`，marker
  `C1_R1_PORTABLE_SOC_CACHE_WIRING_SMOKE_PASS tensor=00000000 quiescent=1
  fence=1 qos=1`。

这两项只验证 `PACKED_AFFINE_CACHE` 参数定义贯通 portable-SoC/cache seam；默认
生产参数仍为 0，不构成完整 CNN、板级资源或 15-fps sign-off。

### 2026-08-29：native 640×480 boardless job 与 portable-SoC elaboration

在本轮板卡前门禁中，`run_r1_native_boardless_job_xsim_detached.ps1` 增加了
WMI 被策略拒绝时的 `CREATE_BREAKAWAY_FROM_JOB` fallback，并在 worker 的
`finally` 中删除完整 Vivado/xsim runRoot。随后 native 640×480 的
`xvlog + xelab + xsim` 全流程通过（run
`76927b77e5b14cc998e43951d162bae8`；xsim 16.183 s，stderr 为空）：

```text
C1_R1_NATIVE_BOARDLESS_JOB_PASS frame=640x480 stages=22 cnn_in=307200 cnn_out=307200 table_ar=2 descriptor_ar=22 input_ar=4800 input_r=76800 output_aw=4800 output_w=76800 output_b=4800 ar_stalls=517 r_gaps=115167 aw_stalls=697 w_stalls=5216 b_delays=6691 stage_stalls=3 cnn_in_stalls=224913 cnn_out_stalls=80451 output_pixels=307200
```

同一 runner 的 `-CompileOnly` 门也通过（run
`1fcd542bc74145c186807b22865a6ba1`，marker
`C1_R1_NATIVE_BOARDLESS_JOB_ELAB_PASS frame=640x480`）。

该结果闭合了 native frame-table、22-stage descriptor barrier、640×480 输入/输出
XRGB DMA、外部 CNN ready/valid seam、AXI 背压和终止 drain；它仍是
`c1_r1_boardless_frame_system` 的外部 CNN echo，不是 portable SoC 真实训练
CNN、DDR3 PHY 或 15 fps 证明。另一个更高层的
`run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -Frame 640x480 -CompileOnly`
也通过（run `09850789d6ba4d2180fa5831cf6f26dc`，8.274 s），说明完整
portable-SoC 640×480 层次可展开；受控的 full portable-SoC 长帧数据面仍保留为
后续性能门，不在本轮无界运行。

## 1. Python Golden、QAT 工件与软件

### 1.1 当前 21 命令回归合同

`scripts/run_python_regression.ps1` 当前依次执行 21 个命令：

1. R0 Golden；
2. R1 ISP/Resize；
3. descriptor ABI；
4. framebuffer ABI；
5. MicroStyle layout；
6. MicroStyle 80-lane schedule 分析；
7. QAT artifact 回归；
8. 6 图 QAT/整数验证；
9. 模型 smoke；
10. untrained layout 导出兼容回归；
11. 6 图×4 Bayer 自然图验证；
12. tensor traffic/performance model；
13. 3×3 line/window cache traffic model；
14. AXI packing/burst、cache、outstanding 与并行 MAC 吞吐扫描；
15. read burst geometry/4-KiB split model；
16. read response FIFO pop/refill model；
17. write response FIFO pop/refill model；
18. empty-queue read AR bypass model；
19. MAC output-restart ownership model；
20. MAC tag FIFO pop/push model；
21. write request FIFO pop/refill model。

runner 成功终标为：

```text
C1_PYTHON_REGRESSION_PASS commands=21
```

本次实际回归还输出：

```text
C1_TENSOR_PERF_MODEL_TEST_PASS baseline_requests=21388800 baseline_bytes=342220800 candidate_bytes=47547744
C1_WINDOW_CACHE_MODEL_TEST_PASS sizes=8x8,16x16,64x48 line_rows=3 8x8_external= 408 64x48_external= 19584
C1_THROUGHPUT_SWEEP_TEST_PASS
READ_BURST_PROFILE_TEST_PASS steady_bursts_16_32=40/20 crossing_lengths=[1, 16]
READ_RSP_POP_REFILL_TEST_PASS default=13 optional=10
WRITE_RSP_POP_REFILL_TEST_PASS
READ_AR_BYPASS_TEST_PASS
MAC_OUTPUT_RESTART_TEST_PASS
MAC_TAG_POP_PUSH_TEST_PASS
WRITE_REQ_POP_REFILL_MODEL_PASS depth=4 requests=12 baseline_stalls=10 refill_stalls=9 baseline_full_to_accept=3 refill_full_to_accept=2 full_pop_push=8
```

该模型将当前顺序 adapter 的精确请求计数与候选 packing/cache/outstanding/MAC 参数转成乐观周期下界；它不读取 RTL 实测计数，也不等价于 15 fps 证明。

当前仓库没有为这次 Python 总回归保存独立 status/stdout 日志，因此这里记录的是 runner 合同和已经落盘的验证 artifact，不把它描述成具有 WMI run_id 的日志证据。

### 1.2 功能性 QAT artifact

`model/microstyle24_starry_functional/` 已包含：

| 工件 | 结果 |
|---|---:|
| float/QAT 训练 | 240 / 80 step |
| descriptor | 22×64 B = 1,408 B |
| 参数 arena | 16,896 B |
| 卷积权重 | 12,212 个 INT8 |
| 固定整数回归 | 32×32，22 个 stage |
| QAT checkpoint vs 整数输出 | 最大绝对误差 0 |

artifact 单测成功标记合同为：

```text
C1_MICROSTYLE_QAT_ARTIFACT_TEST_PASS descriptors=22 arena=16896 weights=12212 float_steps=240 qat_steps=80 regression_pixels=1024 stages=22 change_mae=43.2258
```

`outputs/microstyle_qat/validation/validation_metrics.json` 记录了 6 张许可明确内容图的 64×64 验证：每张图的 QAT/整数逐像素最大误差均为 0，总体 `integer_qat_max_abs_error=0`，输出相对输入的平均变化 `31.5377 u8`，平均饱和比例 `0.041870`。对应标记合同为：

```text
C1_MICROSTYLE_QAT_IMAGE_VALIDATION_PASS images=6 size=64 integer_error=0 mean_change=31.5377 mean_saturation=0.041870
```

这证明 22-stage 导出/重载/整数执行 bit-exact 且输出未退化，不证明最终艺术画质。训练只使用 6 张内容图和一个 public-domain 风格图，artifact 明确标记为 `functional_qat_checkpoint_not_final_quality`。

R1 RAW/ISP 自然图验证仍为：

```text
C1_R1_NATURAL_IMAGE_VALIDATION_PASS images=6 patterns=24 skipped=0 min_psnr=29.3864 mean_psnr=31.7270
```

该 PSNR 衡量 Bayer 合成/重建与 Resize，不是神经风格指标。Lenna 等本地经典图不进入公开资产。

### 1.3 软件 host

当前主机执行输出：

```text
C1_SOFTWARE_HOST_TEST_PASS registers=76 descriptor=64 framebuffer=16 isp=0x200..0x268 qos=0x108..0x12c
```

它覆盖 CSR 写读镜像、64-bit 地址拆分、`0x098 TENSOR_BASE`/24 MiB arena 校验、display mode、start/abort、IRQ、descriptor/framebuffer/ISP ABI。最新 host 用例还验证 configure 在 busy、非640×480、非22层及 input/output table metadata、descriptor、16,896 B parameter、24 MiB tensor 五个区域重叠时拒绝；`c1_accel_start()` 在 busy 时返回 false，并在合法 START 前 W1C 清旧 DONE/ERROR；`c1_accel_wait_idle(device,poll_limit)` 只在 STATUS.BUSY 降低后允许复用 job 内存。frame payload 的范围/重叠仍由读取表项后的 allocator 另验。runner 会编译后检查唯一 marker，但仓库没有持久化 host run status；它不替代 Sapphire BSP、cache coherency 或真实 APB。

## 2. 真实 MicroStyle engine 与 tensor 数据面

| 模块 | run | 严格结果 |
|---|---|---|
| 22-stage arithmetic engine/parameter scheduler | `c382d6f1705041d4a7d2e3650799ebce` | `C1_R1_MICROSTYLE_ENGINE_PASS stages=22 outputs=836 mac=312 dw=248 bypass=276 param_reads=1116 stalls=252 aborts=8 faults=6`；stderr 为空 |
| 22-stage arithmetic engine with final-dot-sum boundary | `8b6b7df80aa1482ead7c3cdea4269e55` | `C1_PIPELINED_DOT_TREE` 专用回归：`C1_R1_MICROSTYLE_ENGINE_PASS stages=22 outputs=836 mac=312 dw=248 bypass=276 param_reads=1116 stalls=306 aborts=8 faults=6`；xvlog/xelab/xsim exit 0、stderr 为空。该证据覆盖 engine ready/valid 对一拍 dot latency 的吸收，不覆盖 standalone compute-shell start ABI |
| engine cycle-budget margin 对照 | `f00e07cb7e884af7960dfaae36696bfb`（legacy） / `0475bd62524b40388af6fe685dfd2cc9`（final-dot-sum） | 两个 runner 均编译 `C1_NONZERO_CYCLE_BUDGET`，对最大合法 stage 18 施加 `10,000` cycle budget；legacy/pipeline 均 PASS，未触发 `ERR_CYCLE_BUDGET`。pipeline 版本 stalls=306、legacy stalls=252；这是小尺寸 margin gate，不是 native deadline 证明 |
| 顺序 tensor adapter（默认兼容） | `5cc1f6d0fcd242bf9de7fe48c5418270` | `requests=2230 reads=1810 writes=420 operands=448 final=32 mem_stall=2247 rsp_gap=3044 engine_stall=480 final_stall=28 borders=132 upsample=88 residual=18 drains=5 adjacent_same_base=636 adjacent_pairable=407`；默认关闭 cache sideband，保持旧 FSM/计数。pairable=407/2,229（18.2593%）只是 4×4 temporal adjacency，不是系统 packing 吞吐 |
| tensor adapter cache sideband | `513714c5626b47e99bc730cf7d3fdf9f` | `configs=22 config_stalls=44 cacheable_reads=1512 bypass_reads=266`；仅 3×3/DW3×3 tap read 标 cacheable，1×1/upsample/residual/write 旁路；同时保留原 adapter PASS，stderr 为空 |
| 64→AXI128 tensor bridge | `b587aa890cc04165bd5a88ce76868087` | `transactions=1209 ar=484 aw=723 lower=604 upper=605 localerr=2 axierr=78 missing_rlast=13 arstall=468 awstall=734 wstall=723 rspstall=2423 awfirst=358 wfirst=189 same=176` |

engine 测试证明 descriptor/parameter 驱动的真实 Conv3×3、Conv1×1、DW、upsample/residual/final 算术与生命周期，并覆盖 128-bit ABI cache→逐层多拍 OIHW 重排→固定 Conv/DW lane bank；但使用小尺寸合成参数，不是 QAT artifact 的 640×480 RTL E2E。

adapter 覆盖 SAME border、stride/upsample、residual 三 bank 映射、memory/engine/final backpressure、abort/drain；bridge 覆盖低/高 64-bit 半字、WSTRB、AW/W 三种相对次序、RRESP/BRESP、missing RLAST 和稳定性。二者证明协议正确性，不证明吞吐；当前 64-bit 单 outstanding 结构确定不能达到 15 fps。

### 2.1 下一阶段性能/工件/并发专项

2026-08-27 的 inter-pixel MAC scaling A/B 也已补齐：默认双 bank 回归保持
`banks=2/lanes=2/transactions=6/max_inflight=2/cycles=40`；可选四 bank
回归为 `banks=4/lanes=2/transactions=12/max_inflight=4/cycles=47`。四 bank
proxy 为 `59,912 LUT/45,674 FF/128 DSP/WNS +0.337 ns`，仅用于量化复制
代价，不代表已经把顺序 CNN engine 改成四 bank。

| 专项 | run | 严格结果与边界 |
|---|---|---|
| 64→128 packing 原型（未接入 SoC） | `4d4c4edfb483422c9196b7fdc12b8e6a`；proxy synth `d011df7b1a7a4bd19275769b89a01f94` | `requests=100 axi_beats=51 packed_pairs=48 responses=100 local_or_axi_errors=1 ... reduction_pct=49.000000`；xsim 只证明相邻半字合并、顺序 response 和 stall/error 处理；Vivado proxy 为 412 LUT（264 logic + 148 LUTRAM）、649 FF、0 BRAM、0 DSP，100 MHz WNS=+2.588 ns/TNS=0。裸模块 IO 未约束，不能作为板卡端口资源结论 |
| trained artifact RTL ABI | `35f1aa0e76ed41d084f40e6637ac331e` | `stages=22 param_bytes=16896 param_words=1056 param_payload_bytes=16379 nonzero_words=1030 param_reads=1030 cache_writes=1030 boundary=RTL_DECODER_SCHEDULER_ARENA_ONLY_NATIVE_640x480`；覆盖 RTL descriptor decoder、真实 parameter scheduler 和注册读响应，不覆盖 native 640×480 算术帧 |
| native 640×480 artifact descriptor/parameter commit preflight | `native_artifact_preflight_elab_20260828` / `native_artifact_preflight_full_20260828` | detached xvlog/xelab 结构门与 xsim 均通过；真实 22-stage descriptor 连续性/几何约束通过，真实 arena 完成 `66 bursts/1056 beats`、`ar_stalls=23`、`r_stalls=242`、generation=1 原子提交和首/中/尾 bank 读回，marker `C1_R1_NATIVE_ARTIFACT_PREFLIGHT_PASS ... boundary=DESCRIPTOR_CONTINUITY_PLUS_PARAMETER_COMMIT_ONLY`。这是 native CNN 数据平面之前的有界门，不启动 640×480 长帧；工作树自动清理 |
 | native 640×480 首层有限窗口 preflight | `native_first_window_elab2_20260828` / `native_first_window_full_20260828` | Icarus 与 detached Vivado/xsim 均通过；真实 adapter 完成 `source_writes=307200`，首层第一个 stride-2/SAME_REPLICATE window `first_window_reads=9`、`engine_inputs=1`，两个 output group 写入 `output_writes=2` 后安全 abort，marker `C1_R1_NATIVE_FIRST_WINDOW_PREFLIGHT_PASS ... boundary=NATIVE_SOURCE_INGEST_PLUS_FIRST_STAGE_WINDOW_ONLY`。不含后续 21 层、native 全网长帧、15 fps；runRoot 自动清理 |
 | native 640×480 首层流水化有限窗口 A/B | `native_first_window_pipe_elab_20260828` / `native_first_window_pipe_full_20260828` | detached Vivado/xsim `pipeline=1 pixel_pipeline=1` 通过；`source_writes=307200`、`first_window_reads=9`、`engine_inputs=1`、`output_writes=2`、`abort=1` 保持不变。仅为可选流水寄存器的功能/协议 gate，不是时序或 15 fps 证明 |
| native 640×480 首层真实 engine/parameter-bank 算术 preflight | `native_first_window_engine_default_postroi_20260828` | Icarus 与 detached Vivado/xsim 均通过；真实 dual-bank parameter load 后，stage-0 golden `group0=0e09000000320005`、`group1=0000000000190006`，并保持 `window_pixels=1 source_writes=307200`、`first_window_reads=9`、`engine_inputs=1`、`engine_outputs=2`、`output_writes=2`、`abort=1`。不含后续 21 层/native 全网/15 fps；runRoot 自动清理 |
| native 640×480 首层真实 engine 流水化 A/B | `native_first_window_engine_pipe_full_20260828` | `C1_USE_PARAMETER_BANK` + `pipeline=1 pixel_pipeline=1 window_pixels=1` 的 detached xsim 通过；stage-0 两组 golden、地址/握手计数与默认版一致。仅为功能/协议 A/B，不是时序签核 |
| native 640×480 首层真实 engine 有限四像素 gate | `native_first_window_engine_roi4_elab2_20260828` / `native_first_window_engine_roi4_full_20260828` | Icarus 与 detached Vivado/xsim 均通过；`pipeline=1 pixel_pipeline=1 window_pixels=4` 下连续首行 x=0..3 的 stage-0 两组 golden 全部通过，`source_writes=307200`、`first_window_reads=36`、`engine_inputs=4`、`engine_outputs=8`、`output_writes=8`、`abort=1`。marker 的 group0/group1 是首像素摘要；不含 stage 1–21/native 全网/15 fps |
 | native 640×480 首层连续窗口扩展（8/16 像素） | `native_first_window_engine_roi8_full_20260829` / `native_first_window_engine_roi16_full_20260829`；Icarus `native16_iverilog_20260829`；Python 五档 | Icarus 与 detached Vivado/xsim 均通过；`pipeline=1 pixel_pipeline=1` 下真实 parameter-bank + stage-0 连续首行 golden 通过。N=8：`source_writes=307200 first_window_reads=72 engine_inputs=8 engine_outputs=16 output_writes=16 abort=1`；N=16：`source_writes=307200 first_window_reads=144 engine_inputs=16 engine_outputs=32 output_writes=32 abort=1`。两者 x=0 首像素 group0/group1 均为 `0e09000000320005/0000000000190006`；Icarus N=16 marker 与 xsim 一致，Python `--pixels 1/2/4/8/16` 全部 PASS。仍仅覆盖 stage 0，不代表 stage 1–21/native 全网/15 fps；detached runner 自动清理私有 runRoot |
| 8×8 production-bank stage-1 handoff（首像素/完整 2×2） | `stage1_handoff_metadata_final_20260829` / `stage1_full_metadata_final_20260829`；源码更新后回归 `stage1_handoff_post_stage2_20260829` / `stage1_full_post_stage2_20260829`；`run_iverilog_stage1_handoff.ps1` | 两种模式均由 Icarus 与 detached Vivado/xsim 通过。首像素：`operands/results=18/35`、`stage1_reads/inputs/writes=18/2/3`、`stage_done=1`；完整 2×2：`C1_R1_STAGE1_FULL_8X8_PASS operands=24 results=44 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage_done=2 abort=1 abort_response_delay=3`。三组首像素/首末 group 与向量一致，末个写响应强制延迟 3 周期并完成 abort drain，且输出 x/y/group-last/SOF/EOL/EOF 元数据逐项检查；不代表 stage 2–21、native 长帧或 15 fps；xsim runRoot 与 Icarus `%TEMP%` 目录均自动清理 |
| 8×8 production-bank stage-2 full handoff | `stage2_full_metadata_final_20260829`；`run_iverilog_stage1_handoff.ps1 -FullStage2` | Icarus 与 detached Vivado/xsim 均通过。`C1_R1_STAGE2_FULL_8X8_PASS operands=36 results=68 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage2_reads=12 stage2_inputs=12 stage2_pixels=4 stage2_writes=24 stage2_outputs=24 stage_done=3 abort=1 abort_response_delay=3`；stage-2 `res0.expand1x1` 只消费 1×1 center tap，bank0 provenance、bank1 写回、算术数据及 x/y/group-last/SOF/EOL/EOF 均逐项检查；不代表 stage 3–21、native 长帧、共享 DDR QoS 或 15 fps；xsim runRoot 与 Icarus `%TEMP%` 目录均自动清理 |
| 8×8 production-bank stage-3 full handoff | `stage3_full_metadata_final_20260829`；`run_iverilog_stage1_handoff.ps1 -FullStage3` | Icarus 与 detached Vivado/xsim 均通过。`C1_R1_STAGE3_FULL_8X8_PASS operands=60 results=92 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_writes=12 stage2_reads=12 stage2_writes=24 stage3_reads=216 stage3_inputs=24 stage3_pixels=4 stage3_writes=24 stage3_outputs=24 stage_done=4 abort=1 abort_response_delay=3`；stage-3 `res0.depthwise3x3` 的 2×2/C48→C48/SAME_REPLICATE 地址、独立 stage2→stage3 provenance、bank2 写回、算术数据及 x/y/group-last/SOF/EOL/EOF 均逐项检查，边界重复地址未被去重；不代表 stage 4–21、native 长帧、共享 DDR QoS 或 15 fps；xsim runRoot 与 Icarus `%TEMP%` 目录均自动清理 |
  | 8×8 production-bank stage-4/5/6/7 full handoff | `stage4_full_metadata_final_20260829` / `stage5_full_metadata_final_20260829` / `stage6_full_metadata_final_20260829` / `stage7_full_metadata_final_20260829`；Icarus `run_iverilog_stage1_handoff.ps1 -FullStage4/-FullStage5/-FullStage6/-FullStage7` | 四个有限 2×2 gate 均由 Icarus 与 detached Vivado/xsim 通过。stage4：`C1_R1_STAGE4_FULL_8X8_PASS operands=84 results=104 stage4_reads=24 stage4_writes=12 stage_done=5 abort=1 abort_response_delay=3`；stage5：`C1_R1_STAGE5_FULL_8X8_PASS operands=96 results=116 stage5_reads=24 stage5_main_reads=12 stage5_residual_reads=12 stage5_writes=12 stage_done=6 abort=1 abort_response_delay=3`；stage6：`C1_R1_STAGE6_FULL_8X8_PASS operands=108 results=140 stage6_reads=12 stage6_writes=24 stage_done=7 abort=1 abort_response_delay=3`；stage7：`C1_R1_STAGE7_FULL_8X8_PASS operands=132 results=164 stage7_reads=216 stage7_writes=24 stage_done=8 abort=1 abort_response_delay=3`。四层 stage3→4、stage4→5、stage1→5 residual、stage5→6→7 provenance、算术结果、SAME_REPLICATE 地址与 output metadata 均逐项检查；xsim stderr 为空，私有 runRoot 与 Icarus `%TEMP%` 目录均自动清理。仅覆盖 stage 0–7，不代表 stage 8–21/native/15 fps |
| native stage-0 Python golden guard | `golden/test_native_stage0_window.py` | `C1_NATIVE_STAGE0_WINDOW_GOLDEN_PASS frame=640x480 pixels=4 groups=2`；从当前训练 arena 重算 x=0..3 的两个 C8 group，作为 RTL 常量漂移护栏，不启动仿真 |
| parameter scheduler staged-validation final | artifact/directed `param_scheduler_directed_final_20260826`；engine `cc9e43673b88499a9813964e6d91ed81`；SoC `param_terminalflag_soc8x8_20260826`；proxy `param_terminalflag_ticket_proxy_20260826` | artifact 原 1,030 reads/writes、16,379 B marker 不变，另有 `C1_R1_PARAMETER_SCHEDULER_DIRECTED_PASS negative=6 validate_aborts=1 captured_configs=1`；full-tree/nonzero-budget engine 和 ticket 8×8 SoC PASS。最终 proxy `44739 LUT/31618 FF/84 DSP`、direct/Q→D `-2.069/-0.694 ns`；相对 ticket-only `+67 LUT/+198 FF`、direct/Q→D 改善 `2.281/0.183 ns`。 |
| 七客户端 AXI arbiter 压力 | `bbaccd1453aa43368eebc4e1f5bdae5a` | `clients=7 write_txns=56 read_txns=56 aw_stalls=25 ar_stalls=19 b_stalls=57 r_stalls=70 max_aw_wait=89 max_ar_wait=67 parallel=1`；独立验证 `c1_axi_n_serial_arbiter_128` 的公平/前进性，不替代 portable SoC 长帧回归 |
| portable SoC 七客户端 traffic monitor（64×48，QoS diagnostic） | `portable_client_gate_64x48_20260825` | 真实 `dut.axi_s_*[0:6]` 全部必需方向均出现：c0 `AW/W/B/AR/R=48/768/48/72/858`，c1 `48/768/48`，c2 `AR/R=66/1056`，c3 `1/1`，c4 `48/768`，c5 `48/768`，c6 `AW/W/B/AR/R=40128/40128/40128/48192/48192`；但 c5 styled-display `max AR wait=1,243,738` cycles > 1,000,000 guard，xvlog/xelab exit 0、xsim exit 1、stderr 为空。该失败是当前 ID-less fabric 的真实 starvation/QoS 证据，不是 traffic 缺失或功能 PASS |
| portable SoC 七客户端 response-hold follow-up（64×48，QoS diagnostic） | `portable_client_gate_hold_64x48_20260825` | 同一 client traffic 结果；增强 monitor 记录 response hold `r0=1124 r4=1243662 r5=368 r6=0`（其余 r/b hold max=0），确认原始 display client-4 的低 `RREADY` 长 hold 直接拖住 styled-display client-5；xvlog/xelab exit 0、xsim exit 1、stderr 为空。该结果用于选择 response skid/FIFO/独立读端口方案，不是 PASS |
| portable SoC display response FIFO QoS（64×48，protocol-safe prototype） | `portable_display_fifo_reader_gate_elab_20260825` / `portable_display_fifo_reader_gate_full_64x48_20260825` | FIFO depth=128、每 reader 预留 64 token credit；reader 在 `ST_PREPARE` 门控，进入 `ST_AR` 后保持 VALID/payload。完整 run 严格 PASS：c4/c5 `max AR wait=76/83`、`r4/r5 hold=2/2`，`AW/W/B=40224/41664/40224`、`AR/R=48427/51643`，`display_done=1`；elaboration/full 三阶段 stderr 为空。FIFO 分支不代表 Ti60 资源或 15 fps |
| portable SoC display response FIFO（64×48，两帧 credit-only ownership） | `portable_display_fifo_credit_only_twoframe_64x48_20260825` | 严格 PASS：`done=2 swaps=2 drops=0 descriptors=44 display_done=1`，`AW/W/B=80448/83328/80448`、`AR/R=96796/102358`；证明移除 `!hold_requests` 后第二 pair 不死锁，FIFO/line-store drain guard 生效；该 run 的 monitor 仍是首帧 snapshot |
| portable SoC display response FIFO（64×48，两帧 aggregate monitor） | `portable_display_fifo_twoframe_monitor2_64x48_20260825` | 严格 PASS：`job_completions=2` 后汇总 c4/c5 `AR/R=100/1600`、max wait `89/83`、R hold `2/2`，并再次得到 `done=2 swaps=2 drops=0`、`AW/W/B=80448/83328/80448`、`AR/R=96796/102358`；三阶段 stderr 为空 |
| portable SoC display response FIFO（早期 hold-gated 两帧探索） | `display_fifo_twoframe_review_64x48_20260825` | 诊断 FAIL：monitor traffic 本身 PASS，但第二 pair `count=1` 未 swap；根因是 `!hold_requests` 错误阻塞 core-domain AR，已由 credit-only 版本修正，不作为当前实现结果 |
| portable SoC display response FIFO default-bypass compatibility | `portable_display_fifo_bypass_functional_8x8_20260825` / `portable_display_fifo_bypass_gate_8x8_20260825` | 默认 `ENABLE_DISPLAY_RESPONSE_FIFO=0` 的功能 run 严格 PASS（`done=1 display_done=1 AW/W/B=852/868/852 AR/R=1119/2199`）；monitor gate 仍按预期暴露 c5 `max AR wait=1940204`、c4 `R hold=1940197` 并 exit 1，记录为历史 QoS 基线而非功能回归失败 |
| `c1_axi2_serial_arbiter_128` 写握手修复回归 | `4e035ad9cea447eb98bfd6595a52cfa2` | `wr_bursts=24 wr_beats=104 rd_bursts=24 rd_beats=100`；覆盖随机 AW/W/B/AR/R 停顿、早/缺 RLAST、读写争用，`C1_AXI2_SERIAL_ARBITER_PASS` 唯一且 xvlog/xelab/xsim stderr 为空；为 native loopback 的 write-side handshake registration 提供独立兼容证据 |
| memory path seam（legacy + performance） | `7a447dba98be413d9e36c9f20bee443d`；proxy synth `ca3e6b438d7e471bb39a083fc31746de` | legacy 1 response；performance 3 requests→2 AXI beats、1 packed pair、3 responses；`flush_req/flush_done/quiescent` 契约 PASS。proxy PERF_MODE=0：122 LUT/176 FF/WNS +6.274 ns；PERF_MODE=1：413 LUT/651 FF/WNS +2.586 ns；未接入 adapter |
| 3×3 line/window cache traffic model | Python regression（13 commands） | 8×8 `3024→408`、16×16 `12096→1632`、64×48 `145152→19584` external requests；真实 pixel→C8-group 交织、整行全 group refill 下逐 tap 行命中率 98.7434%/99.3717%/99.8429%；模型不是 RTL/DDR 测量 |
| 3-row line/window cache RTL control | xsim `8991ff1ef0954d669c3a4568208ae5a2`；proxy synth `7ee82460964f4926b9b5030655bd049d` | `taps=720 hits=720 misses=16 refills=16 external_words=128`；RTL 只存 row tag、round-robin 替换，不含 pixel data BRAM；proxy 为 97 LUT/342 FF/0 BRAM/0 DSP，100 MHz WNS +5.042 ns/TNS 0；独立小帧控制证据，未接入 adapter/DDR |
| 3-row all-group C8 payload cache | normal `2a1766339f834f3b9eba6f0dd5deecd4`；fault `3373b871a3734d2ab2ca9607a206face`；max-row `a3ac690fadf34c8fb123c8043f365cc1`；proxy synth `d07c3a3c7348474ea465ff73f765707a` | normal：1445 responses/18 refills/288 words；fault：9 configs/3 fault classes/2 maintenance；max-row：640×1×2、1280-word refill、16 bit-exact taps；proxy：288 LUT/203 FF/7.5 BRAM tile/0 DSP，100 MHz WNS/TNS +1.086/0 ns。三项 xsim 与 synth stderr 均为空；该独立专项不测试系统 DDR，后续另有 optional-top 结构接线 |
| tensor window-cache seam hardening | xsim `1e6f562adbc34ea383932840b97aa0e4`；proxy synth `6dc7d474aff34448ba590ff615927a53` | `logical_req/rsp=17/17 row_refills=5 refill_reads=40 bypass_reads=8 writes=2 downstream=50 sreq_stalls=17 srsp_stalls=31 mreq_stalls=11 mrsp_stalls=18 stages=5 flushes=1 aborts=2 cfg_rejects=1 runtime_fallbacks=1`；除原注册前端、地址/容量 fallback、coherence、abort drain 和回压外，新增 cache 配置拒绝与路由后 runtime error 安全旁路/route lock 验证：未取得 cache owner 的请求锁定 direct，已取得 owner 的请求不得重复旁路。adapter/seam 的 stalled payload/config、cacheable 分类、WSTRB、对齐及 owner/refill 断言随回归启用。最终合并 seam+C8 proxy 为 1,236 LUT/792 FF/7.5 BRAM tile/0 DSP，100 MHz WNS/TNS +1.086/0 ns；相对历史 `209b68d9b8c9429ba659d32b399a0911` 仅 +2 LUT/+5 FF |
| adapter→window-cache seam 动态 64-bit 链 | `9212d5a042ae4d9895a3162869e3815f` | 最终加固后真实 adapter sideband 的 22 configs（8 cache/14 bypass）穿过 seam+C8 到单 outstanding 64-bit BFM；`logical_req/rsp=2230/2230`、`logical_reads/writes=1810/420`、`cacheable=1512`、`hits/misses=1493/19`、`row_refills/refill_words=19/204`、`downstream_req/rsp=922/922`、`downstream_reads/writes=502/420`，其中 `502=298 bypass+204 refill`，读请求减少 72.3%。1×1/upsample/residual、966 request stalls、1145 response gaps、1 次 memory error 和 5-cycle abort drain PASS；原 22-stage bit-exact marker（448 operands/32 final）与新 marker 各唯一一次，三阶段 stderr 均为空 |
| adapter→window-cache seam→AXI128 bridge 动态链 | `be4977424d9d484e80340f970d9904d0` | 同一最终源码和 22-stage scoreboard 穿过真实 `c1_tensor_mem_axi128_bridge` 到严格单 outstanding AXI128 BFM；`bridge_req/rsp=922/922`、`AR/R=502/502`、`AW/W/B=420/420/420`，上下 lane `462/460`，AW-first/W-first/same `318/81/21`。AR/AW/W stall `1577/1583/1580`，R/B gap `1194/915`，定向 B hold `2`，memory error `1`，abort drain `5`；`502 AR=298 bypass+204 refill`，两枚 marker 唯一且三阶段 stderr 均为空。仍为小尺寸、单拍、单 outstanding，未经过 portable SoC 仲裁或 DDR BFM |
| portable SoC 可选 cache wiring | bypass `7e76332ea7044371af9efcf39809258a`；最终 enabled `30658446f3d4442fb7f7a442bd5f9fe2` | 默认 `ENABLE_TENSOR_WINDOW_CACHE=0` 保持原 marker；最终 route-lock/断言源码下置 1 后确认 seam generate、APB ID/tensor CSR、空闲无 AXI、`cache_error=0`、`quiescent=1`，并以 `fence=1` 定向证明 `tensor_cache_busy` 纳入软件 `system_busy`。两项 stderr 为空。`flush_req` 暂绑 0；只证明结构/空闲控制，不是动态 stage/refill 或全帧 |
| 显式 tensor/cache AXI client-6 边界 | `54d6d7ec0b28445f8f80edeb67281c72` | 新增 `c1_tensor_window_cache_axi_client` 封装 optional seam + 64→AXI128 bridge，`ENABLE_CACHE=0` 保持 wire bypass；真实 wrapper→`c1_axi_n_serial_arbiter_128(CLIENTS=7)` slot 6→AXI BFM 完成 `refill_ar=4`、`direct_ar=1`、`writes=1`、`responses=6`，marker 唯一、xvlog/xelab/xsim stderr 为空。该专项是 client 边界回归，不替代 portable SoC 全生命周期 |
| portable SoC 全链小帧 + cache-enabled DDR BFM（最终单帧） | `5c416178cd90437ea6e223a3711717e8` | `frame=8x8 done=1 descriptors=22 stage_mask=1fffff display_done=1 drain_cycles=1951831`；AXI `AW/W/B=852/868/852`、`AR/R=1119/2199`；AW/W/AR stalls `126/237/96`、R gaps `3685`、B gaps `2710`；真实 capture、frame DMA、CNN、client-6、七客户端仲裁、输出写回和显示预取均通过。小帧/单拍/单 outstanding，不替代 native 长帧/15 fps |
| portable SoC 全链小帧 + cache-enabled DDR BFM（最终两帧 ownership） | `4b28f72f506043cf905abbaa74d3b9b7` | `frame=8x8 done=2 descriptors=44 stage_mask=1fffff swaps=2 drops=0 display_done=1 drain_cycles=1443599`；AXI `AW/W/B=1704/1736/1704`、`AR/R=2353/3703`；AW/W/AR stalls `256/480/244`、R gaps `6917`、B gaps `5401`；干净源码与干净测试台通过串行两帧生命周期。小帧/单拍/单 outstanding，不替代 native 长帧/15 fps |
| portable SoC shape-scaled 小帧（8×8，当前源码） | `e2e36e004f35429f93f4bc297490d713` | `frame=8x8 done=1 descriptors=22 stage_mask=1fffff display_done=1 drain_cycles=1951831`；AXI `AW/W/B=852/868/852`、`AR/R=1119/2199`；AW/W/AR stalls `126/237/96`、R gaps `3685`、B gaps `2710`；shape-parameterized BFM 源码下重新通过，三阶段 stderr 为空 |
| portable SoC shape-scaled 小帧（16×8，当前源码） | `377f5dbeded545318e1bde1950d9bebe` | `frame=16x8 done=1 descriptors=22 stage_mask=1fffff display_done=1 drain_cycles=1900769`；AXI `AW/W/B=1688/1736/1688`、`AR/R=2123/3251`；AW/W/AR stalls `299/481/182`、R gaps `6210`、B gaps `5329`；全 RTL 动态单帧 PASS，三阶段 stderr 为空 |
| portable SoC shape-scaled 小帧（16×8，两帧 ownership） | `7273cf5182874941a893d9b1a8b085a8` | `frame=16x8 done=2 descriptors=44 stage_mask=1fffff swaps=2 drops=0 display_done=1 drain_cycles=1443471`；AXI `AW/W/B=3376/3472/3376`、`AR/R=4505/6743`；AW/W/AR stalls `625/947/538`、R gaps `13150`、B gaps `10676`；当前源码串行两帧动态 PASS |
| portable SoC shape elaboration（64×48） | `efc0181ebc9a427c8d9dd7a48da98c1a` | xvlog/xelab 全 RTL elaboration 完成、exit 0、stderr 为空，marker `C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS frame=64x48`；这是编译/形状边界证据，未启动 xsim，不能写成动态帧或性能 PASS |
| portable SoC shape-scaled 全链（64×48，单帧） | `c1_64x48_single_20260825` | `frame=64x48 done=1 descriptors=22 stage_mask=1fffff swaps=1 drops=0 display_done=1 drain_cycles=1348110`；AXI `AW/W/B=40224/41664/40224`、`AR/R=48427/51643`；AW/W/AR stalls `8043/12828/6294`、R gaps `109813`、B gaps `127887`；xvlog/xelab/xsim exit 0、三阶段 stderr 为空 |
| portable SoC shape-scaled 门控回归（8×8，单帧，latest source） | `c1_8x8_gate_20260825` | `frame=8x8 done=1 descriptors=22 stage_mask=1fffff display_done=1 drain_cycles=1951831`；AXI `AW/W/B=852/868/852`、`AR/R=1119/2199`；AW/W/AR stalls `126/237/92`、R stalls `1952595`、R/B gaps `3690/2710`；xvlog/xelab/xsim exit 0、三阶段 stderr 为空 |
| portable SoC shape-scaled 门控回归（16×8，两帧） | `c1_16x8_two_gate_20260825` | `frame=16x8 done=2 descriptors=44 stage_mask=1fffff swaps=2 drops=0 display_done=1 drain_cycles=1443471`；AXI `AW/W/B=3376/3472/3376`、`AR/R=4185/5463`；AW/W/AR stalls `580/1072/366`、R stalls `3225557`、R/B gaps `11264/10587`；xvlog/xelab/xsim exit 0、三阶段 stderr 为空 |
| portable SoC shape-scaled 门控回归（64×48，单帧） | `c1_64x48_single_gate_20260825` | `frame=64x48 done=1 descriptors=22 stage_mask=1fffff swaps=1 drops=0 display_done=1 drain_cycles=1348110`；AXI `AW/W/B=40224/41664/40224`、`AR/R=48427/51643`；AW/W/AR stalls `8043/12828/6294`、R stalls `1384510`、R/B gaps `109784/127887`；xvlog/xelab/xsim exit 0、三阶段 stderr 为空 |
| portable SoC shape-scaled 门控回归（64×48，两帧，latest gate） | `c1_64x48_two_gate_20260825` | `frame=64x48 done=2 descriptors=44 stage_mask=1fffff swaps=2 drops=0 display_done=1 drain_cycles=3079641`；AXI `AW/W/B=80448/83328/80448`、`AR/R=96793/102295`；AW/W/AR stalls `16129/25561/12698`、R stalls `2006402`、R/B gaps `218066/256041`；xvlog/xelab/xsim exit 0、三阶段 stderr 为空 |
| portable SoC 64×48 gate compile/elaboration | `c1_64x48_gate_compile_20260825` | xvlog/xelab exit 0、stderr 为空，marker `C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS frame=64x48`；未启动 xsim，不作为动态性能证据 |
| portable SoC native shape compile/elaboration（64-bit geometry/address + associative-map fix 后） | `c1_640x480_final_elab_20260825` | `frame=640x480` 的 xvlog/xelab exit 0、stderr 为空，marker `C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS frame=640x480`；含 input/output/tensor 非重叠断言与按 line 地址 associative store，未启动 xsim，不能写成 native 动态/性能 PASS |
| native 640×480 display prefetch staged preflight | `native_prefetch_run2_20260825` | 独立真实 `c1_display_prefetch_pair` 双路全帧读回：`responses=307200/307200`、`axi_ar=4800/4800`、`axi_r=76800/76800`、`underflow=0/0`；逐 burst 校验 16-byte 对齐、4 KiB/行边界，像素 RGB 与 line-store CDC 全部通过；xvlog/xelab/xsim exit 0、stderr 为空。该专项不含 capture、CNN、SoC 仲裁或帧率结论 |
| native 640×480 display response FIFO pixel preflight | `native_display_fifo_elab_20260825` / `native_display_fifo_full_20260825` | FIFO depth=128 分支 elaboration 与逐像素 RGB 全帧回归均严格 PASS：`responses=307200/307200`、`axi_ar=4800/4800`、`axi_r=76800/76800`、`ar_stalls=612/481`、`r_stalls=216000/216000`、`underflow=0/0`；三阶段 stderr 为空。该专项只覆盖 display/DDR/CDC，不含 SoC CNN/QoS/帧率 |
| native 640×480 display response FIFO pixel preflight（latest reader/drain guard） | `native_display_fifo_final_20260825` | 最新源码下 depth=128 分支逐像素 RGB/地址/CDC 严格 PASS：`responses=307200/307200`、`axi_ar=4800/4800`、`axi_r=76800/76800`、`underflow=0/0`；xvlog/xelab/xsim stderr 为空 |
| display response FIFO Vivado proxy synthesis | `display_fifo_proxy_async_final2_20260825` | bypass/fifo128 两变体在 `xc7a200tsbg484-1` 均 PASS；资源 `2600→3094 LUT`、`1141→1185 FF`、`1280→1584 LUTRAM`、`0 BRAM/4 DSP`，core WNS `+3.265→+2.470 ns`，pixel WNS `+8.470 ns` 不变；这是 Xilinx proxy，不是 Ti60/Efinity sign-off |
| portable SoC descriptor relaxed xsim | `descriptor_relaxed_fifo_8x8_20260825` | `STRICT_DESCRIPTOR_VALIDATION=0`、FIFO128，22 descriptors 与完整小帧链严格 PASS；`AW/W/B=852/868/852`、`AR/R=1119/2199`、`done=1 swaps=1 drops=0`，simulation-time ABI guard 未触发 |
| portable SoC descriptor relaxed + fast-address xsim | `descriptor_relaxed_fast_fifo_8x8_20260825` | relaxed + `FAST_TENSOR_ADDRESS_ARITH=1` 小帧严格 PASS，计数与 marker 守恒；该参数只作综合实验，不能据此推断 native 性能 |
| portable SoC descriptor timing proxy（最终源码 strict/relaxed/fast） | `portable_soc_fifo_proxy_post_pipeline_default_20260825`；`portable_soc_descriptor_relaxed_post_pipeline2_20260825`；`portable_soc_descriptor_relaxed_fast_post_pipeline2_20260825` | strict FIFO128 `45298 LUT/28123 FF/99 DSP`、core `-53.327 ns`；relaxed-only `44713 LUT/28061 FF/93 DSP`、direct `-15.659 ns`、Q→D `-13.455 ns`；fast-address `45506 LUT/28073 FF/93 DSP`、direct `-16.647 ns`、Q→D `-14.216 ns`，因此不启用。旧 canonical `45269/28114/-53.944` 与 `44799/28063/-15.958` 只保留为历史快照。relaxed `report_timing_summary` 的 Vivado 2023.1 异常退出单独记录，不计为 RTL FAIL |
| portable SoC descriptor pixel/final address pipeline | `descriptor_relaxed_pipelined2_fifo_8x8_20260825`；proxy `portable_soc_descriptor_relaxed_pipelined2_data_proxy_20260825` | `PIPELINED_TENSOR_ADDRESS=1` 下 8×8 完整链严格 PASS：`done=1 swaps=1 drops=0 descriptors=22 stage_mask=1fffff display_done=1`、`AW/W/B=852/868/852`、`AR/R=1119/2199`；640×480 proxy `44641 LUT/28069 FF/84 DSP`，tensor-address 路径从 Q→D top-20 中消失；数据专用报告最差 camera FIFO→resize `-4.772 ns`（普通 max report `-4.972 ns` 含控制/复位族），仍不是 100 MHz 闭合 |
| portable SoC descriptor pixel/final address pipeline（两帧 ownership） | `descriptor_relaxed_pipelined2_twoframe_8x8_20260825` | 两帧 relaxed + FIFO128 + pipeline 严格 PASS：`done=2 swaps=2 drops=0 descriptors=44 stage_mask=1fffff display_done=1`，`AW/W/B=1704/1736/1704`、`AR/R=2188/3374`，stderr 为空；证明新增地址状态不会破坏跨帧 ownership |
| portable SoC descriptor pixel/final + compute-start boundary（单帧） | `descriptor_pipelined2_compute_start_8x8_20260825` | relaxed + FIFO128 + `PIPELINED_TENSOR_ADDRESS=1` + `PIPELINED_START_CONFIG=1`；`done=1 swaps=1 drops=0 descriptors=22 stage_mask=1fffff display_done=1`，`AW/W/B=852/868/852`、`AR/R=1119/2199`，三阶段 stderr 为空 |
| portable SoC descriptor pixel/final + compute-start boundary（两帧） | `descriptor_pipelined2_startcfg_twoframe_8x8_20260825` | 同一配置 `done=2 swaps=2 drops=0 descriptors=44 stage_mask=1fffff display_done=1`，`AW/W/B=1704/1736/1704`、`AR/R=2188/3374`，三阶段 stderr 为空；跨帧 pending/config 清理通过 |
| portable SoC descriptor pixel/final + compute-start boundary（strict 兼容） | `descriptor_pipelined2_startcfg_strict_8x8_20260825` | strict descriptor validation + 两个可选 pipeline 宏 PASS：`done=1 swaps=1 drops=0 descriptors=22 stage_mask=1fffff display_done=1`，`AW/W/B=852/868/852`、`AR/R=1119/2199`，三阶段 stderr 为空；证明 strict descriptor validation、跨帧 ownership 与集成 bridge BFM 兼容，不等价于 standalone compute-shell 的 same-edge external-CNN ABI 兼容 |
| portable SoC descriptor pixel/final + compute-start boundary proxy | `portable_soc_descriptor_relaxed_pipelined2_startcfg_proxy_20260825` | 640×480 relaxed proxy `44670 LUT/28141 FF/84 DSP`；direct `-4.950 ns`，Q→D `-4.601 ns`；相对 pixel/final `+29 LUT/+72 FF`，Q→D 改善约 `0.171 ns`，仍不是 100 MHz/Ti60 sign-off |
| standalone INT8 dot/requant final-dot-sum boundary | `aba8388974174f209ea0c7c2cc2dcbf0` | `PIPELINED_DOT_TREE=1`；`C1_DOT8X8_REQUANT_CORE_PASS cases=160 groups=781 tail_masks=141 full_masks=19 overflow_cases=2 input_hold=160 output_hold=635 output_stall=635 source_gaps=926`；xvlog/xelab/xsim exit 0、stderr 为空；最终结果/overflow 相对最后输入 beat 多一拍，填充后 II=1 |
| portable SoC descriptor pixel/final + compute-start + final-dot-sum boundary | `descriptor_pipelined2_startcfg_dottree_final_8x8_20260825` | relaxed + FIFO128 + `PIPELINED_TENSOR_ADDRESS=1` + `PIPELINED_START_CONFIG=1` + `PIPELINED_DOT_TREE=1`；`done=1 swaps=1 drops=0 descriptors=22 stage_mask=1fffff display_done=1`，`AW/W/B=852/868/852`、`AR/R=1119/2199`、`drain_cycles=1948048`；三阶段 exit 0、stderr 为空 |
| portable SoC descriptor final-dot-sum boundary proxy | `portable_soc_descriptor_relaxed_pipelined2_startcfg_dottree_proxy_20260825` | 640×480 relaxed proxy `44691 LUT/28606 FF/84 DSP`、`5948 LUTRAM/20 RAMB36/9 RAMB18`；direct `-4.950 ns`，Q→D `-4.752 ns`（camera FIFO→engine state）；相对 start-config `+21 LUT/+465 FF`，未改善时序，默认关闭 |
| standalone full product/pair/quad/dot tree | `4998087102b6420ba49009b7216b3f96` | `PIPELINED_DOT_TREE_FULL=1`；`C1_DOT8X8_REQUANT_CORE_PASS cases=160 groups=781 tail_masks=141 full_masks=19 overflow_cases=2 input_hold=160 output_hold=596 output_stall=596 source_gaps=926`；随机输入/输出保持与 backpressure 通过，xvlog/xelab/xsim exit 0、stderr 为空 |
| 22-stage engine full tree + nonzero budget | `a3f71de333da470483f247902d497d52` | 四级 dot tree 接入真实 engine：`stages=22 outputs=836 mac=312 dw=248 bypass=276 param_reads=1116 stalls=263 aborts=8 faults=6`；stage-18 `10,000`-cycle budget margin 未触发，xvlog/xelab/xsim exit 0、stderr 为空 |
| portable SoC descriptor full tree（8×8） | `descriptor_pipelined2_startcfg_treefull_8x8_20260825` | relaxed + FIFO128 + tensor-address/start-config/full tree；`done=1 swaps=1 drops=0 descriptors=22 display_done=1 drain_cycles=1947286`，`AW/W/B=852/868/852`、`AR/R=1119/2199`；四级 latency 被 engine/bridge/ownership 吸收，三阶段 stderr 为空 |
| portable SoC descriptor full tree（16×8，两帧） | `descriptor_pipelined2_startcfg_treefull_16x8_twoframe_20260825` | 同一 full-tree 配置；`done=2 swaps=2 drops=0 descriptors=44 display_done=1 drain_cycles=1438892`，`AW/W/B=3376/3472/3376`、`AR/R=4194/5502`；xvlog/xelab/xsim exit 0、stderr 为空，跨帧 ownership/drain 通过 |
| portable SoC descriptor full tree（64×48，单帧） | `descriptor_pipelined2_startcfg_treefull_64x48_20260825` | `done=1 swaps=1 drops=0 descriptors=22 display_done=1 drain_cycles=907593`，`AW/W/B=40224/41664/40224`、`AR/R=48427/51643`；xvlog/xelab/xsim exit 0、stderr 为空，shape-scaled AXI/ownership 通过 |
| portable SoC descriptor full-tree proxy | `portable_soc_descriptor_relaxed_pipelined2_startcfg_treefull_proxy_20260825` | 640×480 relaxed proxy `44594 LUT/31396 FF/84 DSP`、`5948 LUTRAM/20 RAMB36/9 RAMB18`；direct `-4.950 ns`，Q→D `-4.701 ns`；相对 start-config `-76 LUT/+3255 FF`，仍未闭合 100 MHz/Ti60 |
| portable SoC descriptor replay + full-tree proxy（负优化） | `portable_soc_descriptor_relaxed_pipelined2_startcfg_treefull_descr_replay_proxy_20260825` | 640×480 relaxed proxy `47114 LUT/41837 FF/84 DSP`、`5636 LUTRAM/20 RAMB36/9 RAMB18`；direct `-4.824 ns`，Q→D `-4.701 ns`；相对 full-tree `+2520 LUT/+10441 FF`，功能开关默认关闭 |
| portable SoC capture-time descriptor prevalidation（8×8） | `prevalidate_replay_8x8_final_20260825` | `PREVALIDATE_DESCRIPTOR_REPLAY=1`；`done=1 swaps=1 drops=0 descriptors=22 display_done=1`，`AW/W/B=852/868/852`、`AR/R=1119/2199`；xvlog/xelab/xsim exit 0、stderr 为空 |
| descriptor external-validation vector regression | `ed8badbe0e6a4809964e361b79d6cb7a` | 429 vectors（23 directed invalid + 400 random bit-flip）在 `USE_EXTERNAL_VALIDATION=1` 下 PASS，held-output、abort/restart 与 error-priority 契约保持 |
| portable SoC capture-time descriptor prevalidation proxy | `prevalidate_treefull_proxy_final_20260825` | 640×480 relaxed full-tree `44660 LUT/31374 FF/84 DSP`、`5832 LUTRAM/20 RAMB36/9 RAMB18`；direct `-4.824 ns`，Q→D `-4.701 ns`；相对 full-tree `+66 LUT/-22 FF`，仍未闭合 100 MHz |
| portable SoC abort fanout replication regression/proxy | `abortrep_8x8_postpatch_20260825`；`abortrep_treefull_proxy2_20260825` | `REPLICATE_ABORT_CONTROL=1` 下 8×8 `done=1 swaps=1 drops=0 descriptors=22 display_done=1`，AXI `852/868/852`、`1119/2199`；proxy `44727 LUT/31380 FF/84 DSP`、direct `-5.557 ns`、Q→D `-5.434 ns`，相对 baseline 负优化，保持关闭 |
| registered fatal ticket controller A/B | legacy `8be7cfb239b449eabd37f12f9fbe276a`；ticket `e600e09f5487450c935bab144b7ff09c` | 两模式均为唯一 `C1_R1_SOC_CONTROL_PASS capture=1 nn=1 prefetch=6 swaps=1 repeats=5 errors=1`，xvlog/xelab/xsim stderr 为空。ticket 定向检查内部 capture fatal 当拍不组合泄漏、下一完整周期 capture/boardless/display abort 同时有效、`code=0x45/address=0` 且只报一次；共同 manual ABORT case 确认软件取消仍立即广播。 |
| registered fatal ticket portable SoC + paired proxy | dynamic `fatal_ticket_soc8x8_20260826`；native `fatal_ticket_native_elab_20260826`；legacy proxy `fatal_ticket_paired_legacy_proxy_20260826`；ticket proxy `fatal_ticket_fulltree_proxy_retry2_20260826` | 8×8 为 `done=1 swaps=1 drops=0 descriptors=22 stage_mask=1fffff display_done=1`、`AW/W/B=852/868/852`、`AR/R=1119/2199`；640×480 elaboration PASS。当前源码/同泛型 paired proxy：legacy `44660 LUT/31374 FF/84 DSP`、direct/Q→D `-4.824/-4.701 ns`；ticket `44672 LUT/31420 FF/84 DSP`、`-4.350/-0.877 ns`。旧 camera FIFO→fatal/abort 链退出两个 top-20；仍不是 100 MHz/Ti60 sign-off。 |
| portable SoC table response FIFO regression/proxy | `tablefifo_compile_8x8_20260825`；`tablefifo_8x8_20260825`；`current_treefull_prevalidate_tablefifo_nohelper_20260825` | `ENABLE_TABLE_RESPONSE_FIFO=1`；xvlog/xelab/xsim 8×8 PASS，`done=1 swaps=1 drops=0 descriptors=22 display_done=1`，AXI `852/868/852`、`1119/2199`；当前源码 640×480 proxy `46174 LUT/37790 FF/84 DSP`、direct `-4.824 ns`、Q→D `-4.701 ns`，相对同条件 FIFO=0 为 `-6 LUT/+128 FF`、时序不变，默认关闭 |
| unified output FIFO standalone protocol | `unified_output_fifo_latest_20260825`；`unified_output_fifo_default_recheck_20260825` | `c1_r1_unified_output_fifo` depth=2、完整 103-bit payload；空队列无 fall-through、满时同拍 pop 不替换、随机 ready/valid、payload stall 保持、abort/error flush 与新 epoch 均 PASS；默认 gate recheck marker `C1_R1_UNIFIED_OUTPUT_FIFO_PASS depth=2 payload=103`，xvlog/xelab/xsim stderr 为空 |
| portable SoC unified output FIFO 8×8 integration | `unified_fifo_errorgate0_gated_8x8_20260825` | `ENABLE_UNIFIED_OUTPUT_FIFO=1`、bridge-local `COMBINATIONAL_ERROR_GATE=0`；`done=1 swaps=1 drops=0 descriptors=22 display_done=1`，AXI `AW/W/B=852/868/852`、`AR/R=1119/2199`；xvlog/xelab/xsim PASS，stderr 为空 |
| portable SoC unified output FIFO 8×8 two-frame integration | `unified_fifo_errorgate0_gated_8x8_twoframe_20260825` | `done=2 swaps=2 drops=0 descriptors=44 display_done=1`，AXI `AW/W/B=1704/1736/1704`、`AR/R=2177/3351`；xvlog/xelab/xsim PASS，stderr 为空；最终 gate 版本保持跨帧 ownership |
| portable SoC unified output FIFO native elaboration | `unified_fifo_errorgate0_gated_native_elab_20260825` | 最终 640×480 + unified FIFO/error-gate0 的 xvlog/xelab PASS，stderr 为空；只证明结构可展开，不代表 native full-xsim/帧率 |
| unified output FIFO registered-error unit protocol | `unified_output_fifo_registered_error_gate0_recheck_20260825` | `COMBINATIONAL_ERROR_GATE=0`；error 边沿前队列保持、error 时钟边沿清空、旧 payload 不跨 epoch；`C1_R1_UNIFIED_OUTPUT_FIFO_PASS depth=2 payload=103`，xvlog/xelab/xsim stderr 为空 |
| portable SoC unified output FIFO paired proxy | `current_treefull_prevalidate_unifiedfifo_errorgate0_gated_nohelper_retry1_20260825` | 同 descriptor-replay/prevalidation/full-tree 条件下 `46390 LUT/37656 FF/5716 LUTRAM/84 DSP`；direct `-4.831 ns`、Q→D `-4.702 ns`、data delay `14.449/14.551 ns`，相对 FIFO=0 资源增加但 timing 无收益，默认关闭 |
| unified output skid standalone protocol | `skid_abort_error_default_retry_20260826`；`skid_abort_error_registered_retry_20260826` | `c1_r1_unified_output_skid` depth=1、完整 103-bit payload；无 fall-through、满态不替换、stall 保持、abort/error flush/restart 均 PASS；默认与 `COMBINATIONAL_ERROR_GATE=0` 均输出 `C1_R1_UNIFIED_OUTPUT_SKID_PASS depth=1 payload=103` |
| portable SoC unified output skid integration | `skid_soc_8x8_20260826`；`skid_soc_8x8_twoframe_20260826`；`skid_soc_16x8_20260826` | `ENABLE_UNIFIED_OUTPUT_SKID=1`；8×8 单帧 `done=1 swaps=1 drops=0 descriptors=22 display_done=1`、AXI `852/868/852` 与 `1119/2199`；两帧 `done=2 swaps=2 drops=0 descriptors=44`、AXI `1704/1736/1704` 与 `2177/3351`；16×8 单帧 `done=1`、descriptors=22、AXI `1688/1736/1688` 与 `2123/3251`；三阶段 stderr 为空 |
| portable SoC unified output skid native elaboration | `skid_native_elab_20260826` | 640×480 + `C1_UNIFIED_OUTPUT_SKID` xvlog/xelab PASS，stderr 为空；只证明结构可展开，不代表 native full-xsim/帧率 |
| portable SoC unified output skid paired proxy | `current_treefull_prevalidate_unifiedskid_nohelper_20260826` | 同 descriptor-replay+prevalidate/full-tree/address/start 条件下 `46243 LUT/37766 FF/5636 LUTRAM/20 RAMB36/9 RAMB18/84 DSP`；direct/Q→D `-5.415/-5.415 ns`，data delay `15.264 ns`、route `11.613 ns`（76.1%）；相对无边界 `46180/37662`、`-4.824/-4.701 ns` 为负优化，默认关闭；这组 replay=1 数据不作为本轮 replay=0 ticket 的基线。 |
| full-tree default compatibility after descriptor parameter | `treefull_default_after_descriptor_param_8x8_20260825` | `PIPELINED_DESCRIPTOR_REPLAY=0` 当前默认分支再次 PASS：`done=1 swaps=1 drops=0 descriptors=22`，`AW/W/B=852/868/852`、`AR/R=1119/2199`；xvlog/xelab/xsim exit 0、stderr 为空 |
| portable SoC native FIFO elaboration | `portable_fifo_native_elab_final_20260825` | `640×480 + C1_DISPLAY_RESPONSE_FIFO` 完整七客户端顶层 xvlog/xelab 严格 PASS，stderr 为空；这是参数/结构闭合证据，不是 native full-xsim 性能结论 |
| portable SoC native address-pipeline elaboration | `descriptor_strict_pipelined2_native_elab_20260825` | `640×480 + PIPELINED_TENSOR_ADDRESS=1` xvlog/xelab PASS，stderr 为空；未启动 native full-xsim，不代表性能 |
| portable SoC native address/start-config elaboration | `compute_start_native_elab_20260825` | `640×480 + PIPELINED_TENSOR_ADDRESS=1 + PIPELINED_START_CONFIG=1` xvlog/xelab PASS，stderr 为空；只证明参数化结构闭合，不代表 native full-xsim/帧率 |
| portable SoC native all-optional elaboration | `treefull_final_native_elab_20260825`（前一版 final-dot-sum：`dottree_final_native_elab_20260825`） | `640×480 + C1_DISPLAY_RESPONSE_FIFO + RELAXED_DESCRIPTOR + PIPELINED_TENSOR_ADDRESS + PIPELINED_START_CONFIG + PIPELINED_DOT_TREE_FULL` xvlog/xelab exit 0、stderr 为空，marker `C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS frame=640x480`；未启动 native full-xsim |
| portable SoC native prevalidation elaboration | `prevalidate_native_elab_640x480_20260825` | `640×480 + PIPELINED_TENSOR_ADDRESS + PIPELINED_START_CONFIG + PIPELINED_DOT_TREE_FULL + PREVALIDATE_DESCRIPTOR_REPLAY` xvlog/xelab exit 0、stderr 为空；只证明结构闭合 |
| portable SoC 640×480 FIFO system proxy synthesis | `portable_soc_fifo_proxy_post_pipeline_default_20260825` | 最终源码 bypass/fifo128 完整顶层均 PASS：`44792→45298 LUT`、`28082→28123 FF`、`5644→5948 LUTRAM`、`20 RAMB36/9 RAMB18/99 DSP` 不变；strict FIFO128 core WNS `-53.327 ns`，旧 `-53.944 ns` 为流水化前历史快照，当前关键路径仍未实时闭合 |
| native 640×480 capture writer staged preflight | `c1_native_capture_writer_final_20260825` | 真实 `c1_axi_xrgb_frame_writer` 串行写入三块 input slot 并逐像素读回：`frames=3 frame_pixels=307200 aw=14400 w=230400 b=14400 readback_pixels=921600`，slot `00100000/0022c000/00358000`；AW/W/B 与源端随机回压通过，xvlog/xelab/xsim exit 0、stderr 为空。该专项不含 camera/CSI、input DMA、CNN、共享仲裁或帧率结论 |
| native 640×480 capture/table/ISP staged preflight | `c1_native_capture_table_paced_full_20260825` | 真实 `c1_r1_capture_subsystem` 完成 3×642×482 RAW10→640×480：`pixels/sof/eol/eof=921600/3/1440/3`，Gamma LUT `1024` 次配置，table `AR/R=3/3`，writer `AW/W/B=14400/230400/14400`；slot `00100000/0022c000/00358000`，table/writer 回压和无 X WDATA 通过，xvlog/xelab/xsim exit 0、stderr 为空。camera BFM 按 frontend 的 sensor-overflow 合同插入 blanking；不含 CSI/MIPI、portable SoC input DMA、共享仲裁、CNN/QoS/帧率 |
| native 640×480 input-DMA/table/arbiter staged preflight | `c1_native_input_dma_full_20260825` | 真实 `c1_axi_frame_buffer_table_reader` + `c1_axi_xrgb_frame_reader` 共享 `c1_axi2_serial_arbiter_128`，三 slot 逐像素检查：`frame_pixels=921600`，table `AR/R=3/3`，frame `AR/R=14400/230400`，shared `AR/R=14403/230403`；`ar_stalls=714 r_stalls=692267 r_gaps=34898 output_stalls=44623`，地址/4 KiB/行边界、坐标/marker、stalled payload 全部通过，xvlog/xelab/xsim exit 0、stderr 为空。该专项不含 boardless job/output DMA、七客户端 fabric、CNN/tensor/display/QoS/帧率 |
| native 640×480 read→write DMA loopback staged preflight | `c1_native_dma_loopback_final2_20260825` | 真实 table reader + XRGB reader → read arbiter → XRGB writer → `c1_axi_write_skid_bridge` → write arbiter，三 slot 逐像素 DDR 回读：`frame_pixels=921600`，input `AR/R=14400/230400`，output `AW/W/B=14400/230400/14400`；`read_ar_stalls=625 read_r_stalls=1233856 read_gaps=29256 stream_stalls=585856 aw_stalls=1055 w_stalls=67961 b_delays=57240`；xvlog/xelab/xsim exit 0、stderr 为空。该专项不含 boardless job、七客户端完整 fabric、CNN/tensor、display、CSI/MIPI、QoS/帧率 |
| native 640×480 boardless job staged preflight | `native_boardless_job_hold_full_20260825` | 真实 `c1_r1_boardless_frame_system` 接入 table/22 descriptor/input-output DMA/外部 CNN echo，完成 `stages=22`、`cnn_in/cnn_out=307200/307200`、`table_ar=2 descriptor_ar=22`、input `AR/R=4800/76800`、output `AW/W/B=4800/76800/4800`、`output_pixels=307200`；`ar_stalls=565 r_gaps=114547 aw_stalls=646 w_stalls=5211 b_delays=6489`，逐像素 output associative DDR 回读通过；xvlog/xelab/xsim exit 0、stderr 为空。该专项不含 portable SoC 七客户端 fabric、真实 CNN/tensor、display、CSI/MIPI、QoS/帧率 |
| native 640×480 boardless + 7-client fabric contention preflight | `native_fabric_full2_20260825` | 真实 boardless job 为 client-0，client-1..6 各完成 3 个四拍写/读回事务，共享真实 `c1_axi_n_serial_arbiter_128(CLIENTS=7)` 与随机延迟 associative DDR BFM；synthetic `AW/W/B/AR/R=18/72/18/18/72`，job `AW/W/B/AR=4800/76800/4800/4800`，input `R=76800`，output `307200` 像素；六个 synthetic client 最大 channel wait 为 `104/105/103/107/117/118` cycles，三阶段 exit 0、stderr 为空。该专项证明 native job 可在七路 fabric 竞争下前进和逐像素闭环，但 client-1..6 是 procedural traffic，不等于 portable SoC 七个真实叶模块并发或 15 fps |
| native 640×480 boardless + real parameter leaf fabric slice | `native_fabric_param_full_20260825` | client-0 为真实 boardless job，client-1 为真实 `c1_axi_parameter_loader` + `c1_r1_parameter_bank`，client-2..6 为五个 procedural peer；参数 `AR/R=66/1056`、`generation=1`，job `AW/W/B/AR/R=4800/76800/4800/4800/76890`，output `307200` 像素；peer 最大等待 `158/162/160/169/167` cycles；xvlog/xelab/xsim exit 0、stderr 为空。证明一个真实 read-only leaf 可在七路 fabric 中提交/读回，不等于七个 portable SoC 真实叶模块或 QoS/15 fps |
| boardless frame-system compatibility after arbiter change | `c1_boardless_after_arbiter_20260825` | 既有 `c1_r1_boardless_frame_system` 9-job 回归重新通过：`jobs=9 launches=7 done=2 errors=5 aborted=2 stages=110 dispatches=5 drains=5 reverse=2145 midread=1`；xvlog/xelab/xsim exit 0、stderr 为空。该 run 是 8×3 小帧/外部 CNN loopback，不是 native 性能证据 |
| tensor adapter sideband（native-width arithmetic fix 后兼容回归） | `c1_adapter_u64fix_20260825` | `C1_R1_MICROSTYLE_TENSOR_ADAPTER_CACHE_SIDEBAND_PASS` 唯一；22 configs、随机回压/abort/错误路径保持通过，xvlog/xelab/xsim stderr 为空 |
| portable SoC 8×8 gate（native-width arithmetic fix 后） | `c1_8x8_u64fix_gate_20260825` | `frame=8x8 done=1 swaps=1 drops=0 descriptors=22 stage_mask=1fffff display_done=1`；AXI `AW/W/B=852/868/852`、`AR/R=1119/2199`；R stalls `1952595`；xvlog/xelab/xsim exit 0、三阶段 stderr 为空 |
| portable SoC 64×48 两帧 gate（native-width arithmetic fix 后） | `c1_64x48_two_u64fix_gate_20260825` | `frame=64x48 done=2 swaps=2 drops=0 descriptors=44 stage_mask=1fffff display_done=1`；AXI `AW/W/B=80448/83328/80448`、`AR/R=96793/102295`；R stalls `2006402`、R/B gaps `218066/256041`；xvlog/xelab/xsim exit 0、三阶段 stderr 为空 |

### 2.2 `PIPELINED_START_CONFIG` 的接口边界

`PIPELINED_START_CONFIG=0` 保留 compute-shell 的 legacy 原子启动契约：在同一
个 `start_valid && start_ready` 握手边沿启动 source、ingress、egress 和
external CNN。设为 1 时，shell 先在该边沿锁存全部 source/config 字段，再在后续
边沿（或内部 READY 恢复后）发出 `child_start/cnn_start_valid`；因此会增加至少一拍
start-to-child latency，并改变 standalone `c1_r1_compute_shell` 的 same-edge
external-CNN start ABI。当前 `tb_c1_r1_compute_shell.sv` 的 same-edge 断言不能作为
该可选模式的通过证明；上述 strict 小帧 PASS 只覆盖集成 portable-SoC/bridge 路径。

可选模式仍以 `all_children_ready`（包括 `cnn_start_ready`）门控
`child_start/cnn_start_valid`，pending 队列没有独立 timeout。若外部 CNN 在原始
engine-start 边沿后撤下 READY、只短脉冲 READY，或等待 VALID 才拉高 READY，pending
可能无限等待，直到 abort 或更上层 watchdog；当前 `c1_r1_microstyle_system_bridge`
的 level-ready 行为可规避该情形，但不能泛化为任意 external-CNN seam。由于 job
controller 在原始 start 边沿已进入 RUN，固定 cycle budget 至少要为延迟启动预留
一拍（并验证 pending 等待不会吞掉 deadline）；默认构建仍建议保持
`PIPELINED_START_CONFIG=0`。

packing 原型与 performance memory path seam 仍未接到 `c1_r1_portable_soc`；C8 payload cache/window seam 已有默认关闭的可选结构接线。当前源码的 shape-scaled BFM 门控矩阵已通过 8×8 单帧 `c1_8x8_gate_20260825`、16×8 两帧 `c1_16x8_two_gate_20260825`、64×48 单帧 `c1_64x48_single_gate_20260825` 和 64×48 两帧 `c1_64x48_two_gate_20260825`；四者均使用同一套真实 capture/CNN/cache/client-6/七客户端 DDR/display 组合，且两帧均保持 `swaps=2 drops=0`。64×48 两帧最新 marker 为 `done=2 descriptors=44 stage_mask=1fffff display_done=1`，实际完成 `AW/W/B=80448/83328/80448`、`AR/R=96793/102295`，并在高背压 BFM 下记录 `R stalls=2006402`。此前 64×48 两帧失败 run 不是地址或采集错误：无 ID、单响应 owner 的共享 AXI serial arbiter 中，display original reader 因 line-store `s_ready=0` 反压而撤下 `m_axi_rready`，使 DDR/arbiter 侧 R beat 保持未握手，阻塞 tensor/NN client，stage0 在 `(x,y)=(0,8)` 触发 1,000,000-cycle stage watchdog（`ERR_CYCLE_BUDGET=0x08`）。修复为控制层在 foreground CNN admission 前等待 `display_prefetch_busy=0`，并在 boardless/NN active/request 期间禁止 display refresh；gate 后四个矩阵 run 均 PASS。首次尝试 16×8 时固定 8×8 descriptor 触发 `ERR_SOURCE (0x05)`，随后将测试 descriptor 宽高按 frame 参数缩放后动态回归通过，这一失败记录说明形状/ABI 仍需在 native descriptor 上再次核对，而不是功能 PASS。所有这些 run 仍是小帧、单拍、单 outstanding 和功能性零参数测试；不能把 72.3% 小帧 AR 下降、49% 独立 packing reduction 或 cache 模型计数直接换算成系统帧率。artifact ABI 专项之所以停在 decoder/arena 边界，是因为真实 640×480 描述符首层参数装载后会进入 `ST_COLLECT` 等待完整数据平面；这是已显式记录的验证边界，不是端到端 PASS。

在上述 portable SoC gate 之后，独立 native display staged preflight `native_prefetch_run2_20260825` 已通过：真实 `c1_display_prefetch_pair` 完成两路 640×480 全帧（每路 307,200 像素、4,800 个 AR、76,800 个 R beat），地址 checker 覆盖 16-byte 对齐、4 KiB 与行边界，line-store CDC 像素读回 `underflow=0/0`。随后 native capture-writer staged preflight `c1_native_capture_writer_final_20260825` 完成三块 input slot、921,600 像素读回和 `AW/W/B=14400/230400/14400`；capture/table/ISP staged preflight `c1_native_capture_table_paced_full_20260825` 又把真实 642×482 RAW10 ingress、Gamma、R1 ISP、frame-table lookup 和 writer 串起来，完成 `pixels/sof/eol/eof=921600/3/1440/3`；input-DMA/table/arbiter staged preflight `c1_native_input_dma_full_20260825` 再把 table reader 和 XRGB reader 接入真实两主机 ID-less read arbiter，完成三 slot `shared AR/R=14403/230403` 与逐像素坐标/marker 检查；read→write loopback `c1_native_dma_loopback_final2_20260825` 又把真实 input read、stream、XRGB writer、write arbiter 和 output DDR 回读串成三帧，完成 `frame_pixels=921600`、input `AR/R=14400/230400`、output `AW/W/B=14400/230400/14400`；最新 native boardless job `c1_native_boardless_job_full_20260825` 再把真实 boardless frontend、22 descriptor、input/output DMA 和外部 CNN echo 串起来，完成 `cnn_in/cnn_out=307200/307200` 与 output 逐像素回读。这些分阶段证据仍不覆盖 CSI/MIPI、portable SoC 七客户端完整 fabric、真实 CNN/tensor、长帧 QoS 或 15 fps；复现与边界见 `NATIVE_DISPLAY_PREFLIGHT.md`、`NATIVE_CAPTURE_WRITER_PREFLIGHT.md`、`NATIVE_CAPTURE_TABLE_PREFLIGHT.md`、`NATIVE_INPUT_DMA_PREFLIGHT.md`、`NATIVE_DMA_LOOPBACK_PREFLIGHT.md`、`NATIVE_BOARDLESS_JOB_PREFLIGHT.md`。

上段的 boardless 初步 run `c1_native_boardless_job_full_20260825` 已通过；随后为严格遵守外部 CNN ready/valid 的 VALID hold 合同，又以 `native_boardless_job_hold_full_20260825` 重跑并作为 canonical 动态证据，指标以后者为准。

再下一层 `native_fabric_full2_20260825` 已把 canonical native job 放到真实 7-client arbiter 的 client-0，并由六个独立 AXI master 持续制造读写竞争；每个 synthetic client 均完成完整写入、B response、读回和 RLAST 检查，最大等待不超过 118 cycles。该 run 的 `clients=6` 字段表示六个 synthetic peer，总 fabric 宽度仍为 7；portable SoC 的 capture/parameter/display/tensor 真实叶模块并未被这些 procedural clients 冒充为已验证。

## 3. Capture、control 与 display 收口

| 子系统 | run | 严格结果 |
|---|---|---|
| lifecycle control（指定收口快照） | `14817510235e4da8882511ec46606626` | `capture=1 nn=1 prefetch=5 swaps=1 repeats=4` |
| lifecycle control（当前最新源码专项） | `595748663d3541248c8ef4c1c46b1fd3` | 同一 PASS/计数，stderr 为空 |
| capture frontend | `11e14099eb784ccba3b6397650a80278` | `frames=5 ingress=2 dropped=1 aborted=1 output=24 stalls=4 cleanup_entries=4 cleanup_cycles=114` |
| display compositor/raster | `aaf5846df1a84216aa88515a82b2eda8` | bootstrap/drain 修复后 `C1_COMPOSITOR_MODES_PASS points=11`；`C1_SPLIT_COMPOSITOR_PASS frame_cycles=1237500 active=921600 original=307200 styled=307200` |
| display prefetch/CDC/OSD | `cd08f3e85aca45c281e09bfb130eb3e7` | pair `jobs=1 aborts=1 ar=8 pixels=24`；CDC `lines=3 pixels=12 stalls=3 underflows=1 osd=3` |
| display prefetch/CDC（bootstrap/drain 修复后） | `3bf346fd0896450681875829c29ff0e9` | `C1_DISPLAY_PREFETCH_CDC_PASS`；独立 pair/CDC 回归仍通过 |
| SoC reset/APB infrastructure | `66ab397cd4254dc19becd9fcb194e654` | `reads=5 writes=1 core_reset=14 pixel_reset=5` |

capture 专项覆盖正常 ingress、显式 drop、abort、输出 stall，以及 idle/半帧遗留的 4 次 silent cleanup。silent discard 不增加 drop 统计，cleanup 必须到 EOF/recover 安全边界。

完整小帧顶层回归还验证了首次显示 pair 的启动闭环：bootstrap feed 允许 primed line store 在尚无 current pair 时开始被像素域消费；单源模式对未选中的 reader 发出同步 drain，避免另一 reader 因 ping-pong bank 永久占用而停在 `ST_EMIT`。两帧回归还覆盖了 pending pair 的 core→pixel hold CDC，确认预取期间不会过早消费新 pair。这不是显示画质或 HDMI/TMDS 物理验证。

display 专项覆盖 styled、original、split、reserved fail-black 四模式和完整 1650×750 raster；OSD overlay 已集成到 display subsystem，bit7 使能。该具体 run 的两个 marker 各出现一次、stderr 为空且人工严格扫描为 0；现有 display runner 本身还应补“marker 唯一、stderr/FAIL”自动门禁。

## 4. 既有板卡无关专项回归

最新统一基础回归 run `31e1280a9b634f85a212db4a3535351e` 为 complete、exit 0，13 个 testbench 全部 PASS、所有 stderr 为空。它覆盖 FIFO/reset/event CDC、scheduler、RGB/C8 codec、RAW unpack、Gamma、R0 ISP/CNN/system、APB/frame control 和 R1 integration skeleton；control TB 已定向读写 `0x098`。该统一源列表不包含 portable SoC 的完整动态链，不能替代下列专项或顶层重跑。

以下核心 run 继续有效：

| 领域 | run | 摘要 |
|---|---|---|
| 完整 R1 ISP | `6e2e44fe911d4c7fb977260440bc6a72` | `frames=16 input=1280 output=768` |
| 完整 Resize pipeline | `72b757bc8768459b876eba8903527b77` | `configs=7 outputs=127 cfg_errors=3 aborts=2` |
| compute ingress/egress | `d90d626f14e2484e942006a253da1fbb` / `2afff26a33fa41209e0af69c33daa098` | RGB↔C8、stall、padding、abort/restart |
| compute shell | `a522a976d7aa4208b26ce1137710ed17` | `starts=4 ... done=3 aborts=1 cnn_faults=1 frames=3` |
| config dispatcher | `ee259dad86e54a7f8adc74f46be70a38` | generation、timeout、zero-latency read |
| job frontend | `aad1d4efe8fa444f9feac6cbaad6efce` | `starts=11 launches=5 done=3 faults=6 aborted=2` |
| XRGB reader/writer cancel | `e5f199b11ce14a0fb86ba8ad8b9507f3` / `793e9f08a1d346e58e98f90b3150d980` | committed AXI drain、协议错误、restart |
| boardless frame-job | `ae0e704e95424efca51334059063d8cb` | `jobs=9 launches=7 done=2 errors=5 aborted=2 dispatches=5 drains=5` |

boardless run 使用 external CNN loopback，证明 preflight、frame DMA、config barrier、error/abort safe drain；它不能替代后来加入的真实 engine+adapter 端到端验证。

## 5. Portable SoC 顶层证据

当前源码默认旁路与 cache-enabled wiring smoke run：

```text
run 7e76332ea7044371af9efcf39809258a
C1_R1_PORTABLE_SOC_SMOKE_PASS tensor=02000000
run 30658446f3d4442fb7f7a442bd5f9fe2
C1_R1_PORTABLE_SOC_CACHE_WIRING_SMOKE_PASS tensor=02000000 quiescent=1 fence=1
```

两项 run 均在把 `tensor_cache_busy` 纳入 `system_busy` 后对当前源码完成 xvlog/xelab/xsim，三阶段 stderr 均为空。默认 run 保持原 marker/CSR 行为；enabled run 额外展开 `u_tensor_cache_axi_client.g_cache.u_seam` 并检查空闲诊断。顶层 cache `flush_req` 暂绑 0。它们仍只是 smoke，完整动态证据见 5.2。

## 5.1 Cache client + seven-client DDR BFM

为在接入便携 SoC 全部生命周期以前先闭合“真实 cache 客户端→仲裁器→DDR”边界，新增独立小帧 fabric 回归：4×4、单 C8 group 的 `c1_tensor_window_cache_axi_client #(.ENABLE_CACHE(1))` 接入 slot 6，与 6 个合成读写客户端共同进入真实 `c1_axi_n_serial_arbiter_128`。主 AXI 端由字节可写、读回可校验的 DDR BFM 驱动，随机化 AW/W/AR 接受和 R/B 响应间隙，并覆盖 cache hit/miss、旁路读写、flush、上半 64-bit lane 及读后写一致性。

```text
run 75ac975f5ec049a6b579e00c14dd41d0
C1_CACHE_FABRIC_DDR_BFM_PASS clients=7 client_txns=3 cache_logical_reads=9 cache_refill_reads=16 cache_rsp=12 writes=1 axi_aw=19 axi_w=19 axi_b=19 axi_ar=36 axi_r=36 aw_stalls=15 w_stalls=4 ar_stalls=14 r_stalls=121 b_stalls=149 r_gaps=175 b_gaps=81
```

该 run 的 xvlog/xelab/xsim stderr 均为空且 marker 唯一；16 次缓存 refill 下游读相对于 9 次逻辑缓存读的 36 次逐字直读上界有明确下降，并且本次 PASS 穿过了新增 wrapper 的真实 client-6 端口。该专项仍是 fabric-level、小帧、单拍/单 outstanding，不替代 portable SoC 的 capture/display/控制生命周期或 Ti60/Efinity 实现。

## 5.2 Portable SoC capture→CNN→display 小帧动态回归

在 5.1 的共享 fabric 边界之后，新增真实 `c1_r1_portable_soc` 顶层回归。测试台使用参数化 active frame、RAW10 camera、22 个合法 MicroStyle descriptor、零参数 arena（保持 ABI 合法但不把该测试当作画质对比），并将 cache-enabled client-6 接入真实七客户端 AXI serial arbiter。DDR BFM 对 AW/W/AR 独立背压，延迟并保持 R/B，执行 WSTRB 和稀疏 128-bit line store；显示端保留真实 720p timing。旧的 `78f...`/`b828...`/`5c416...`/`4b28...` 只作为历史基线；当前源码的形状门控收口证据见下方四个 latest gate run。

```text
run 5c416178cd90437ea6e223a3711717e8
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS frame=8x8 done=1 descriptors=22 stage_mask=1fffff display_done=1 drain_cycles=1951831 axi_aw=852 axi_w=868 axi_b=852 axi_ar=1119 axi_r=2199 aw_stalls=126 w_stalls=237 ar_stalls=96 r_stalls=1952597 b_stalls=0 r_gaps=3685 b_gaps=2710

run 4b28f72f506043cf905abbaa74d3b9b7
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_TWO_FRAME_PASS frame=8x8 done=2 descriptors=44 stage_mask=1fffff swaps=2 drops=0 display_done=1 drain_cycles=1443599 axi_aw=1704 axi_w=1736 axi_b=1704 axi_ar=2353 axi_r=3703 aw_stalls=256 w_stalls=480 ar_stalls=244 r_stalls=3334981 b_stalls=0 r_gaps=6917 b_gaps=5401
```

随后将 BFM 的 frame-manager table image 改为按 entry index 返回独立的
0x100 对齐 buffer，并对同一单帧重新执行 detached 回归：
`b82811285e52462c9c5b7ed7d76f01be` 同样以唯一 marker、空 stderr 和完全相同的
AXI/descriptor/display 计数通过；`78f...` 保留为改动前的基线快照。最终干净源码
单帧 `5c416...` 与干净测试台两帧 `4b28...` 均由同一 WMI runner 完成，后者额外确认
`swaps=2 drops=0`。

该 run 完成 `capture → frame table → 参数首次加载 → 22 descriptor CNN → tensor cache/refill → client-6 → 七客户端 AXI/DDR → output write → display pair prefetch`，descriptor stage mask 覆盖 0..20，`display_done=1`，控制/compute/capture error 均为 0。仿真还暴露并修复了四个真实 RTL 边界：

1. `c1_r1_soc_control` 在 `parameter_done` 与 `loaded_weight_base_q` 跨拍更新之间可能重复启动 parameter reload，导致 generation 误增；现在以 `!parameter_done` 作为 reload admission fence。
2. 首次显示 pair 没有 current feed 时，两行 ping-pong store 会因未选中源不被消费而停在两行；`c1_r1_display_subsystem` 现在提供 bootstrap feed，并在单源 ORIGINAL/STYLED 模式 drain 未选中的 line store。

3. 控制器在同一 pending pair 尚未完成时会按 raster 周期重复发起相同预取；`c1_r1_soc_control` 现在以 `!prefetch_loading_new_q` 作为 admission guard，避免重复启动和 generation/livelock。
4. 新 pair 预取期间，core 域 ready/valid 继续消费 pixel 域当前帧请求，可能在 VSYNC 前把 primed 数据耗尽；`display_hold_requests` 经过两级 CDC 后同时门控 pixel request，直到 frame-boundary swap 再释放。

上述历史 run 是小帧、单拍、单 outstanding 和功能性零参数测试；它们不证明 trained 640×480 算术 bit-exact、15 fps、DDR QoS 或 Ti60 资源。当前 gate run 的根因分析与修复记录见 5.3。显示专项在修复后独立回归 `3bf346fd0896450681875829c29ff0e9` 仍通过 `C1_DISPLAY_PREFETCH_CDC_PASS`，四模式/完整 raster 回归 `aaf5846df1a84216aa88515a82b2eda8` 也通过。

### 5.3 64×48 两帧根因与共享读通道门控

shape-scaled 64×48 两帧的首轮尝试在 stage0 的 `(x,y)=(0,8)` 触发 `ERR_CYCLE_BUDGET=0x08`。诊断显示第二帧 capture writer、input DMA 和 frame-table slot 均已完整结束；停滞点是 ID-less `c1_axi_n_serial_arbiter_128` 的全局读响应 owner：display original reader 因 line-store `s_ready=0` 反压而撤下 `m_axi_rready`，于是 DDR/arbiter 侧的 `RVALID` beat 保持未握手，tensor/NN client 无法取得下一笔 AR。该失败只作为根因证据保留，不计入 PASS。

修复包含两层：`c1_r1_soc_control` 在 foreground CNN admission 前要求 display prefetch quiescent，并在 boardless/NN active/request 期间禁止启动后台 display refresh；已有的 `display_hold_requests` CDC 和 `!prefetch_loading_new_q` 继续保证 pending pair 不被重复发起或过早消费。修复后 latest gate 矩阵全部满足退出码 0、三阶段 stderr 为空、唯一 PASS marker；在 tensor adapter native-width arithmetic 修复后，`c1_8x8_u64fix_gate_20260825` 与 `c1_64x48_two_u64fix_gate_20260825` 又分别重跑单帧和两帧并通过，最新两帧结果为 `done=2 swaps=2 drops=0 descriptors=44 stage_mask=1fffff display_done=1`，AXI `AW/W/B=80448/83328/80448`、`AR/R=96793/102295`。高 `R stalls` 是刻意背压 BFM 下的协议压力统计，不是 native 帧率声明。该 gate 只保证当前 ID-less BFM 下 CNN forward progress；它没有冻结 raster，双 bank line-store 在长 CNN 期间仍可能产生 display underflow，当前 TB 尚未把 `display_underflow_event` 纳入 PASS 条件。上板前应采用独立 display/NN 读端口、读响应 FIFO（至少一整 burst，建议每 reader 32 beats）或 AXI ID+重排，并把 underflow/QoS 计数加入回归。

### 5.4 native 640×480 前置门

在上述门控修复后，runner 已支持 `-Frame 640x480 -CompileOnly`；`c1_640x480_final_elab_20260825` 通过 xvlog/xelab、退出码 0、stderr 为空。随后独立 `c1_display_prefetch_pair` 的 `native_prefetch_run2_20260825` 与真实 XRGB writer 的 `c1_native_capture_writer_final_20260825` 均已通过，说明 native 显示读回和三 slot 写回可以先在不启动 CNN 的情况下闭合。完整 portable-SoC native 动态 run 仍有以下前置工作：

1. frame-table 地址图已在 native 分支修复为 `INPUT_BASE=0x0010_0000`、`OUTPUT_BASE=0x0060_0000`；单个 XRGB slot 为 `0x12c000`，并加入 input/output/tensor 非重叠断言。display-only、writer-only、capture/table/ISP、input-DMA/table/arbiter、read→write loopback 和 native boardless job 均已通过；boardless job 又确认同一地址图能被真实 frontend/table/descriptor/input-output DMA 消费。
2. native 分支已经改为按完整 AXI line 地址索引的 associative DDR store；display-only、writer-only、loopback 和 boardless job 分别覆盖 R/AW/W/B 计数与逐像素回读，均验证 4 KiB/行边界。boardless job 的 BFM shell 只注册化仿真边界，仍不能替代真实七客户端 fabric、CNN/tensor 争用和板上 DDR。
3. 放宽 native 单帧的 TB 等待/timeout 和 descriptor stage budget（当前测试 descriptor 的 `d[511:480]=1_000_000` 是每 stage watchdog，TB 还有 300/600 ms 全局 timeout 与有限 wait loop），并把 `display_underflow_event`、pair deadline、每 client QoS 纳入 scoreboard。当前 gate 只证明小帧 ownership/forward progress，不能证明长帧显示连续或 15 fps。

loopback 的新增 RTL 变更为 `c1_axi_write_skid_bridge` 以及 write-side arbiter 的握手登记/延后一拍状态转移；独立 `c1_axi2_serial_arbiter_128` 回归和 loopback 均通过。该修复解决的是组合 writer/arbiter 边界的握手可观测性，不应解读为已完成 burst、multi-outstanding 或性能优化。

native boardless job 目前仍使用外部 CNN echo 和单个 read arbiter/直连 write AXI；随后 `native_fabric_full2_20260825` 已把它放入真实七客户端 fabric，并以六个 synthetic peer 完成 contention preflight。下一项不是再扩大独立 DMA，而是用 `c1_r1_portable_soc` 的真实 capture、parameter/tensor、compute 和双路 display client 叶模块替换这些 peer，再把它们放到同一个 QoS/ownership scoreboard。

## 6. Vivado 时序/资源代理

最新 14 组件 run `4fdb28345b6b4b2c8342357e2e0d82ec` complete，14 个组件 marker + 1 个最终 marker、stderr 为空：

- boardless（含 frame DMA）：4,568 LUT、7,080 Reg、7 BRAM、24 DSP，`WNS=-0.191 ns`，当前最差为 descriptor/control path；没有独立 XRGB DMA timing top；
- Resize：906 LUT、725 Reg、6 BRAM、18 DSP，`WNS=-0.154 ns`；
- parameter-loader DMA：`WNS=+4.721 ns`。

最终 DW 专项 run `ba43851ef5a24071bad06edeb2460c7c` complete：8,784 LUT、4,157 Reg、16 DSP，`WNS=+3.039 ns`、TNS=0。14 组件 run 内的 DW 报告早于最终流水修改，应以该专项为准。

最终重排版完整 CNN proxy run `6cb8dfd59ed5473383eed87f52b2a013` complete、唯一 `C1_MICROSTYLE_CNN_TOP_PROXY_SYNTH_PASS`、stderr 为空：28,298 Slice LUT（25,542 logic + 2,756 LUTRAM）、11,168 FF、2 BRAM36、35 DSP、F7 mux 32、F8 mux 8，`WNS/TNS=-4.965/-2511.307 ns`。最差路径为 `replay_index`→descriptor decoder error reset，14 级/14.351 ns；旧 window cache→dot overflow 最差路径已经消失，但首条计算相关路径仍约 `-4.601 ns`。该 PASS 证明综合/报告流程完成，不表示 100 MHz 时序闭合。

完整 CNN 旧 flat-cache run `50e2f738693246b2a2f05191bb10a4f7` 的 `synth_design` 以 0 error 生成 utilization report：735,256 Slice LUT（546.25%）、43,585 Reg、0 BRAM、99 DSP、F7 mux 306,449、F8 mux 144,592。结构已明确不可实现，因此任务在 timing report 前被手动终止；status.json 残留 `running` 不代表进程仍在运行，也不存在最终 PASS。该报告只能作为要求权重 RAM/窄索引重构的失败基线，不能写成完整 CNN 综合通过或最终资源结果。

以上全部是 Vivado/Artix-7 综合后代理，不是 Efinity/Ti60 place-and-route。

### 6.1 Shared-fabric R-response skid

最终 standalone 对照：

```text
readskid_burst4_missingrlast_final_20260826
C1_R1_AXI7_SERIAL_ARBITER_STRESS_PASS
clients=7 write_txns=56 read_bursts=56 read_beats=224

legacy_burst4_postguard_20260826
C1_R1_AXI7_SERIAL_ARBITER_STRESS_PASS
clients=7 write_txns=56 read_bursts=56 read_beats=224
```

skid run 覆盖 4-beat 连续响应、随机客户端 RREADY、consume-and-replace、ARLEN-derived terminal 和一笔定向 missing-RLAST。两个 run 的 xvlog/xelab/xsim stderr 均为空、PASS marker 唯一。

portable SoC 动态对照：

```text
fabric_readskid_soc8x8_retry_20260826
done=1 swaps=1 drops=0 descriptors=22 stage_mask=1fffff
AW/W/B=852/868/852 AR/R=1119/2199
r_stalls=0 fabric_r_stalls=1951641

fabric_legacy_soc8x8_recheck_20260826
done=1 swaps=1 drops=0 descriptors=22 stage_mask=1fffff
AW/W/B=852/868/852 AR/R=1119/2199
r_stalls=1952595 fabric_r_stalls=1952595
```

两项均为唯一 `C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS`，三阶段 stderr 为空。最终 terminal guard 后，`fabric_readskid_native_elab_postguard_20260826` 通过 640×480 xvlog/xelab。full-tree proxy `fabric_readskid_fulltree_proxy_retry_20260826` 为 `44640 LUT/31490 FF/84 DSP`、direct/Q→D `-4.824/-4.701 ns`；该 proxy 启动早于最后一条 terminal-extra-beat guard，不能替代最终源码下一次完整 proxy，也不证明全局时序改善。

### 6.2 Registered fatal fault ticket

控制器 A/B：

```text
8be7cfb239b449eabd37f12f9fbe276a
C1_R1_SOC_CONTROL_PASS capture=1 nn=1 prefetch=6 swaps=1 repeats=5 errors=1 fatal_ticket=0

e600e09f5487450c935bab144b7ff09c
C1_R1_SOC_CONTROL_PASS capture=1 nn=1 prefetch=6 swaps=1 repeats=5 errors=1 fatal_ticket=1
```

两项 xvlog/xelab/xsim 均 exit 0、stderr 为空。ticket 模式的 capture-error directed case 证明 fatal 当拍没有组合 abort/error 泄漏，下一完整周期三路 abort 同时拉高并只产生一次 `0x45` report；随后共同的软件 ABORT case 保持 legacy 的立即广播。

系统级 ticket run：

```text
fatal_ticket_soc8x8_20260826
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS
done=1 swaps=1 drops=0 descriptors=22 stage_mask=1fffff display_done=1
AW/W/B=852/868/852 AR/R=1119/2199

fatal_ticket_native_elab_20260826
C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS frame=640x480
```

动态 run 三阶段 stderr 为空；native run 的 xvlog/xelab stderr 为空。严格配对 proxy 使用当前同一源码和相同 replay=0/prevalidate=1/address/start/full-tree 泛型，只切换 ticket：

| proxy | LUT / FF / DSP | direct WNS | Q→D WNS | 首条路径 |
| --- | ---: | ---: | ---: | --- |
| `fatal_ticket_paired_legacy_proxy_20260826` | `44660 / 31374 / 84` | `-4.824 ns` | `-4.701 ns` | camera FIFO→fatal/abort→output DMA / CNN engine |
| `fatal_ticket_fulltree_proxy_retry2_20260826` | `44672 / 31420 / 84` | `-4.350 ns` | `-0.877 ns` | parameter scheduler enable / job controller→CNN engine state |

ticket 代价为 `+12 LUT/+46 FF`；direct 和 Q→D 违例分别缩小 `0.474 ns` 与 `3.824 ns`。ticket 报告前 20 条中不再出现 camera FIFO、fatal ticket 或 manager-abort 数据路径。前两次 ticket proxy 启动在 `synth_design` 的 RTL 处理前因本地 Vivado on-demand runtime 分别缺失 `unimacro_verilog.tcl` / `common.tcl` 而退出，不是 HDL 失败；第三次及严格配对 legacy run 均完整 PASS。

### 6.3 Parameter scheduler staged validation and terminal metadata

最终功能门禁：

```text
param_scheduler_directed_final_20260826
C1_R1_MICROSTYLE_ARTIFACT_ABI_PASS
stages=22 param_reads=1030 cache_writes=1030 param_payload_bytes=16379
C1_R1_PARAMETER_SCHEDULER_DIRECTED_PASS
negative=6 validate_aborts=1 captured_configs=1

cc9e43673b88499a9813964e6d91ed81
C1_R1_MICROSTYLE_ENGINE_PASS

param_terminalflag_soc8x8_20260826
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS
done=1 swaps=1 drops=0 descriptors=22 stage_mask=1fffff display_done=1
AW/W/B=852/868/852 AR/R=1119/2199
```

artifact run 的两个 marker 均唯一，三阶段 stderr 为空。六个负例依次覆盖 opcode、channels、depthwise channel mismatch、alignment、weight size、arena range 的错误码 `1..6`，且均未发出 parameter read；`ST_VALIDATE` abort 返回 clean idle 且无请求泄漏。配置快照 case 在 START 后立即把所有 live `cfg_*` 改为非法值，scheduler 仍按接受时配置完成 `9 reads/9 writes/136 B`。

同一 ticket/full-tree/prevalidate/address/start 配置的迭代 proxy：

| proxy | 结构 | LUT / FF / DSP | direct WNS | Q→D WNS |
| --- | --- | ---: | ---: | ---: |
| `fatal_ticket_fulltree_proxy_retry2_20260826` | ticket-only baseline | `44672 / 31420 / 84` | `-4.350 ns` | `-0.877 ns` |
| `param_ce_eager_ticket_proxy_retry_20260826` | START 无条件捕获 weight metadata | `44571 / 31427 / 84` | `-3.629 ns` | `-0.880 ns` |
| `param_validate_pipe_ticket_proxy_20260826` | 加 `ST_VALIDATE` | `44788 / 31616 / 84` | `-2.692 ns` | `-2.692 ns` |
| `param_lastcount_ticket_proxy_20260826` | 加 5-bit terminal byte count | `44750 / 31617 / 84` | `-2.236 ns` | `-2.236 ns` |
| `param_terminalflag_ticket_proxy_20260826` | 加 1-bit current terminal flag | `44739 / 31618 / 84` | `-2.069 ns` | `-0.694 ns` |

最终相对 ticket-only 增加 `67 LUT/198 FF`，DSP、LUTRAM 和 BRAM 不变；direct/Q→D 违例分别缩小 `2.281/0.183 ns`。最终两份 top-20 中均不再出现 `weight_bytes_calc1`、`region_base_q.CE`、`region_bytes_q[4]` 或 `region_word_count_q[4]`。新的 direct 最差是 tensor adapter tap-Y→pixel-index 地址链（12 levels、8 CARRY4、`-2.069 ns`）；Q→D 最差是 job controller→CNN engine state（route 71.7%、`-0.694 ns`）。这些均为 Artix-7 proxy，不是 Efinity/Ti60 sign-off。

### 6.4 Pipelined tensor tap-coordinate strength reduction

功能门禁：

```text
tapcoord_shift_legacy_20260826
C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS

tapcoord_shift_pipeline_20260826
C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS

tapcoord_shift_soc8x8_20260826
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS
```

三项状态均为 `complete/exit_code=0`。pipeline 分支用 stride 1/2 的窄位移和显式 3×3 tap delta 替代通用 tap-coordinate 乘法；legacy 分支不变。Vivado 首次尝试在 HDL 综合前因本地 on-demand runtime 缺失临时 `rtSynthCleanup.tcl` 退出；`tapcoord_shift_ticket_proxy_retry1_20260826` 完整 PASS。

| proxy | LUT / FF / DSP | LUTRAM / RAMB36 / RAMB18 | direct WNS | Q→D WNS |
| --- | ---: | ---: | ---: | ---: |
| `param_terminalflag_ticket_proxy_20260826` | `44739 / 31618 / 84` | `5832 / 20 / 9` | `-2.069 ns` | `-0.694 ns` |
| `tapcoord_shift_ticket_proxy_retry1_20260826` | `44706 / 31622 / 80` | `5832 / 20 / 9` | `-1.066 ns` | `-0.692 ns` |

旧 tap-source→pixel-index 路径不再出现在 direct top-20。新的 direct 首路径为 job-controller state→`conv_tile_read_addr_q.CE`，15 levels、data delay `10.684 ns`、route 76.7%；Q→D 首路径仍为 job-controller state→CNN-engine state，17 levels、data delay `10.541 ns`。这是有效的板前优化，但仍不是 100 MHz 或 Ti60 时序签核。

本轮新建的五个仿真/综合工作目录均已删除，共 172 个文件、7.47 MiB；保留的状态、小日志和三份文本报告合计约 0.68 MiB。

### 6.5 Registered-owner system-disable qualification

功能门禁：

```text
disable_owner_legacy_20260826
C1_R1_SOC_CONTROL_PASS ... fatal_ticket=0 disable_abort=1

disable_owner_ticket_20260826
C1_R1_SOC_CONTROL_PASS ... fatal_ticket=1 disable_abort=1

disable_owner_soc8x8_20260826
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS
```

两个 controller run 都确认：事务已 armed 时拉低 `system_enable`，parameter/capture/boardless/display 四路 abort 在同一周期有效；完整 SoC 的正常 job、descriptor、AXI 与显示 ownership 保持通过。RTL 以寄存的 `run_armed_q` 资格化 disable-abort，不再把 child busy 组合反馈到 CNN ready tree。

| proxy | LUT / FF / DSP | LUTRAM / RAMB36 / RAMB18 | direct WNS | Q→D WNS |
| --- | ---: | ---: | ---: | ---: |
| `tapcoord_shift_ticket_proxy_retry1_20260826` | `44706 / 31622 / 80` | `5832 / 20 / 9` | `-1.066 ns` | `-0.692 ns` |
| `disable_owner_ticket_proxy_20260826` | `44740 / 31617 / 80` | `5832 / 20 / 9` | `-0.682 ns` | `-0.380 ns` |

旧 `boardless_busy/compute_abort/adapter_result_ready` 路径在 direct top-20 中匹配数为 0。新 direct 首路径为 parameter-bank BRAM clock-to-output→weight-word cache/mux→scheduler/decoder affine 校验→`affine_invalid_q.D`，11 levels、data delay `10.531 ns`、route 63.8%；Q→D 首路径为 input-state arithmetic，17 levels、data delay `10.229 ns`。这仍是 Artix-7 proxy，不是 100 MHz 或 Ti60 签核。

本轮四个仿真/综合工作目录均已删除，共 174 个文件、6.16 MiB；保留的状态、小日志和三份文本报告约 0.64 MiB。

### 6.6 Registered affine-word verdict boundary

功能门禁：

```text
affine_verdict_pipe_engine_20260826
C1_R1_MICROSTYLE_ENGINE_PASS
stages=22 outputs=836 param_reads=1115 aborts=8 faults=6

affine_verdict_pipe_soc8x8_20260826
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS
```

engine run 覆盖完整22层、nonzero cycle budget、full dot tree、参数读错误及 `shift=48` affine-format 错误。新结构只寄存 per-word 非法 verdict；128-bit payload 仍在原 BRAM 响应周期写入 cache，sticky flag 在下一拍更新，并在进入 `ST_PARAM_VALIDATE` 前可见。

| proxy | LUT / FF / DSP | LUTRAM / RAMB36 / RAMB18 | direct WNS | Q→D WNS |
| --- | ---: | ---: | ---: | ---: |
| `disable_owner_ticket_proxy_20260826` | `44740 / 31617 / 80` | `5832 / 20 / 9` | `-0.682 ns` | `-0.380 ns` |
| `affine_verdict_pipe_ticket_proxy_20260826` | `44568 / 31617 / 80` | `5832 / 20 / 9` | `-0.613 ns` | `-0.380 ns` |

旧 parameter-bank BRAM→`affine_invalid_q.D` 路径已退出 direct top-20，新 `affine_word_invalid` 也未成为 top-20 端点。新的 direct 首路径为 `input_groups_q`→weight-repack 计数/状态解码→`repack_input_channel_q.CE`，12 levels、data delay `10.231 ns`、route 71.6%；Q→D 首路径仍为 input-state arithmetic。该结果仍是 Artix-7 proxy，100 MHz 尚差0.613 ns。

本轮三个仿真/综合工作目录均已删除，共162个文件、6.46 MiB；保留的状态、小日志和三份文本报告约0.65 MiB。

### 6.7 Staged weight-layout verdict and repack terminals

功能门禁：

```text
repack_terminal_pipe_engine_20260826
C1_R1_MICROSTYLE_ENGINE_PASS
stages=22 outputs=836 param_reads=1115 stalls=270 aborts=8 faults=6

repack_terminal_pipe_soc8x8_20260826
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS
done=1 swaps=1 drops=0 descriptors=22
AW/W/B=852/868/852 AR/R=1119/2199
```

parameter-done边沿现在寄存weight-layout verdict和三个重排终值；新增 `ST_WEIGHT_LAYOUT` 后，FSM只消费寄存结果。engine相对上一阶段增加10个控制等待周期，但所有数据与故障计数保持一致；SoC没有cycle-budget、ownership或AXI回归。

| proxy | LUT / FF / DSP | LUTRAM / RAMB36 / RAMB18 | direct WNS | Q→D WNS |
| --- | ---: | ---: | ---: | ---: |
| `affine_verdict_pipe_ticket_proxy_20260826` | `44568 / 31617 / 80` | `5832 / 20 / 9` | `-0.613 ns` | `-0.380 ns` |
| `repack_terminal_pipe_ticket_proxy_retry1_20260826` | `44544 / 31641 / 80` | `5832 / 20 / 9` | `-0.587 ns` | `-0.380 ns` |

旧 `input_groups_q→weight_layout_valid→repack_input_channel_q.CE` 路径已退出direct top-20。新首路径为tensor adapter `addr_pixel_index_q.CLK`→`request_addr_q[31].D`，7 levels、data delay `10.468 ns`，其中包含2个DSP48E1与4个CARRY4。首次proxy在RTL综合前因本地Vivado runtime缺失临时 `rtSynthParallelPrep.tcl` 退出；retry完整PASS。

本轮四个工作目录均已删除，共162个文件、6.46 MiB；保留的状态、小日志和三份文本报告约0.64 MiB。

### 6.8 Pipelined final tensor-address strength reduction

功能门禁：

```text
finaladdr_shiftadd_pipeline_20260826
C1_R1_MICROSTYLE_TENSOR_ADAPTER_PASS

finaladdr_shiftadd_soc8x8_20260826
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS
done=1 swaps=1 drops=0 descriptors=22
AW/W/B=852/868/852 AR/R=1119/2199
```

流水地址模式的最终函数以1–8 groups显式移位/加减替代64-bit通用乘法，并用bank 0/1/2常量分支替代bank乘法；没有新增状态或每请求周期。standalone adapter与完整SoC均保持地址、数据、ownership和AXI守恒。

| proxy | LUT / FF / DSP | LUTRAM / RAMB36 / RAMB18 | direct WNS | Q→D WNS |
| --- | ---: | ---: | ---: | ---: |
| `repack_terminal_pipe_ticket_proxy_retry1_20260826` | `44544 / 31641 / 80` | `5832 / 20 / 9` | `-0.587 ns` | `-0.380 ns` |
| `finaladdr_shiftadd_ticket_proxy_20260826` | `44604 / 31656 / 78` | `5832 / 20 / 9` | `-0.380 ns` | `-0.380 ns` |

旧 `addr_pixel_index_q→tensor_addr_from_pixel_fn→request_addr_q.D` 路径已退出direct top-20。direct与Q→D首路径现在一致：frame manager `input_state[0][1]`→ready候选搜索/索引选择→`input_state[0][0].D`，17 levels、8 CARRY4、data delay `10.229 ns`、route 65.9%。该结果仍是Artix-7 proxy，100 MHz尚差0.380 ns。

本轮三个工作目录均已删除，共150个文件、6.51 MiB；保留的状态、小日志和三份文本报告约0.64 MiB。

### 6.9 Frame-manager ordered READY queue regression

功能门禁：

```text
ready_fifo_directed_20260826
C1_FRAME_MANAGER_READY_FIFO_PASS drops=2 display_id=4

frame_ready_fifo_soc_control_20260826
C1_R1_SOC_CONTROL_PASS

ready_fifo_soc8x8_20260826
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS
done=1 swaps=1 drops=0 descriptors=22
AW/W/B=852/868/852 AR/R=1119/2199
```

专用回归证明三槽排队与两次drop-oldest的顺序正确，并覆盖input READY在capture-done/NN-grant同周期的pop+push、output READY在NN-done/vsync同周期的pop+push，以及abort清队列但保留当前display引用。完整SoC的描述符、ownership和AXI守恒不变。

| proxy | LUT / FF / DSP | LUTRAM / RAMB36 / RAMB18 | direct WNS | Q→D WNS |
| --- | ---: | ---: | ---: | ---: |
| `finaladdr_shiftadd_ticket_proxy_20260826` | `44604 / 31656 / 78` | `5832 / 20 / 9` | `-0.380 ns` | `-0.380 ns` |
| `ready_fifo_ticket_proxy_20260826` | `44272 / 31597 / 78` | `5832 / 20 / 9` | `-0.306 ns` | `-0.060 ns` |

原frame-manager `input_state→32-bit oldest compare/index→input_state.D` 路径与新READY queue信号在direct/Q→D top-20中均未出现。direct首路径现在是resize插值 `stage0_h03 DSP→stage0_h01 DSP/carry→out_rgb1 DSP B`，6 levels、data delay `9.675 ns`；Q→D首路径是descriptor scheduler `descriptor_latched[79]→command_valid.D`，9 levels、data delay `9.908 ns`。

四个工作目录均已删除，共173个文件、6.034 MiB；保留27个状态、小日志和三份文本报告，共0.632 MiB。

### 6.10 Bilinear complement-weight range regression

```text
interp_nosat_primitives_20260826
C1_R1_RESIZE_PRIMITIVES_PASS configs=50 requests=3211 interp=10726

interp_nosat_system_20260826
C1_R1_RESIZE_SYSTEM_PASS configs=12 requests=313 outputs=313

interp_nosat_soc8x8_20260826
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS
done=1 swaps=1 drops=0 descriptors=22
AW/W/B=852/868/852 AR/R=1119/2199
```

所有合法插值权重满足 `w0+w1=4096`。因此每级rounded numerator严格小于 `2^20`，移除输出饱和器不会改变任何合法结果；新增simulation-only断言确保上游合同一旦退化便立即失败。两级elastic handshake、stall保持和元数据时延均未改变。

| proxy | LUT / FF / DSP | LUTRAM / RAMB36 / RAMB18 | direct WNS | Q→D WNS |
| --- | ---: | ---: | ---: | ---: |
| `ready_fifo_ticket_proxy_20260826` | `44272 / 31597 / 78` | `5832 / 20 / 9` | `-0.306 ns` | `-0.060 ns` |
| `interp_nosat_ticket_proxy_retry1_20260826` | `44175 / 31595 / 78` | `5832 / 20 / 9` | `-0.291 ns` | `-0.060 ns` |

原 `stage0_h03→stage0_h01→3×CARRY4→out_rgb1` 路径及全部插值实例名在direct/Q→D top-20中均为0次。新direct首路径为parameter-bank generation错误检查→CNN error/egress ready→tensor-adapter `output_x_q.CE`，15 levels、data delay `9.909 ns`、route 67.6%；Q→D仍为descriptor scheduler→decoder `command_valid.D`。

首次proxy因本机Vivado runtime瞬时缺失 `common.tcl` 在HDL处理前退出，retry完整通过。五个工作目录已删除，共184个文件、6.692 MiB；保留34个状态、小日志和三份文本报告，共0.649 MiB。

### 6.11 Registered launch-contract fault boundary

```text
contract_fault_boundary_retry1_20260826
C1_R1_MICROSTYLE_BRIDGE_FAULT_BOUNDARY_PASS

contract_fault_boundary_soc8x8_20260826
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS
done=1 swaps=1 drops=0 descriptors=22
AW/W/B=852/868/852 AR/R=1119/2199
```

定向测试使用真实MicroStyle CNN top：parameter/config generation突变的live比较当拍成立但不组合改变公开error/ready；下一拍sticky error分别给出`0x04/0x03`。故障捕获边沿恰好可退休一个已经present的beat，随后传输停止；abort清除sticky状态并恢复start-ready。该beat所属错误帧不会获得display ownership。

| proxy | LUT / FF / DSP | LUTRAM / RAMB36 / RAMB18 | direct WNS | Q→D WNS |
| --- | ---: | ---: | ---: | ---: |
| `interp_nosat_ticket_proxy_retry1_20260826` | `44175 / 31595 / 78` | `5832 / 20 / 9` | `-0.291 ns` | `-0.060 ns` |
| `contract_fault_boundary_ticket_proxy_20260826` | `44165 / 31592 / 78` | `5832 / 20 / 9` | `-0.191 ns` | `-0.060 ns` |

旧parameter generation→CNN error/compute-egress ready→adapter final-ready→`output_x_q.CE`路径在两份top-20中为0次。新direct首路径为`descriptor_latched[79]→descriptor_q[0].CE`，8 levels、data delay `9.808 ns`；Q→D为`descriptor_latched[79]→command_valid.D`，9 levels、data delay `9.908 ns`。

首次定向回归发现同一组合块中先读取、后赋值`error`导致事件仿真保留旧门控值；提前计算`bridge_error_now`并让所有传输门直接引用后，retry通过。四个工作目录已删除，共202个文件、7.390 MiB；保留27个状态、小日志和三份文本报告，共0.644 MiB。

### 6.12 Pipelined descriptor verdict boundary

```text
925d7efd0f734711b47b375e288ca213
C1_LAYER_COMMAND_DECODER_PASS
vectors=429 valid=244 errors=186 random_valid=237 random_invalid=163

76b1252b78934aad946ca4280d27a675
C1_R1_CONFIG_LOADER_SUBSYSTEM_PASS
starts=5 done=2 errors=2 aborted=1 bank_commands=61 generation=2

659a381895554f4fa4b05b9248a8c011
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS
done=1 swaps=1 drops=0 descriptors=22
AW/W/B=852/868/852 AR/R=1119/2199
```

config-loader默认启用 `PIPELINED_VALIDATION`：descriptor握手后先锁存payload，下一拍锁存完整validator的5-bit结果，再下一拍发布command/error；因此每descriptor增加2拍。standalone decoder的默认兼容路径仍通过全部429个golden向量；loader回归另外覆盖invalid descriptor、AXI error、abort/restart、backpressure和双bank提交。

| proxy | LUT / FF / DSP | LUTRAM / RAMB36 / RAMB18 | direct WNS | Q→D WNS |
| --- | ---: | ---: | ---: | ---: |
| `contract_fault_boundary_ticket_proxy_20260826` | `44165 / 31592 / 78` | `5832 / 20 / 9` | `-0.191 ns` | `-0.060 ns` |
| `descriptor_verdict_pipe_ticket_proxy_retry2_20260826` | `44202 / 31605 / 78` | `5832 / 20 / 9` | `-0.182 ns` | `+0.344 ns` |

旧 `descriptor_latched[79]→descriptor_q.CE/command_valid.D` 在两份top-20中均为0次；Q→D报告20条全部MET。新direct top-20全部为resize bilinear interpolation的DSP寄存输入路径，首路径5 levels、data delay `9.373 ns`。

前两次proxy因持久 `.vivado_rt` 对detached Vivado helper不可见而在RTL处理前退出；run-local普通runtime stage通过。综合runner现自动保留三份文本报告并清除工作/runtime目录。本轮共删除646个临时文件、92.464 MiB，保留35个状态、小日志和报告、0.634 MiB。

### 6.13 Preserved four-stage bilinear pipeline

```text
interp_preserved_pipe_primitives_20260827
C1_R1_RESIZE_PRIMITIVES_PASS
configs=50 requests=3211 interp=10726

interp_operand_pipe_system_20260826
C1_R1_RESIZE_SYSTEM_PASS
configs=12 requests=313 outputs=313

2dc8c3d400434b00a0de89c2a19cd91d
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS
done=1 swaps=1 drops=0 descriptors=22
AW/W/B=852/868/852 AR/R=1119/2199
```

四级插值流水依次寄存horizontal result、vertical operands、vertical products和rounded output。无保层的product-only与operand+product实验均通过功能回归，但Vivado自动寄存器平衡后首路径仍为 `-0.182 ns`；最终仅对operand/product算术payload使用 `DONT_TOUCH`，迫使综合网表保留真实边界。该属性不改变仿真语义。

| proxy | LUT / FF / DSP | LUTRAM / RAMB36 / RAMB18 | direct WNS | Q→D WNS |
| --- | ---: | ---: | ---: | ---: |
| `descriptor_verdict_pipe_ticket_proxy_retry2_20260826` | `44202 / 31605 / 78` | `5832 / 20 / 9` | `-0.182 ns` | `+0.344 ns` |
| `interp_vprod_pipe_ticket_proxy_retry1_20260826` | `44224 / 31638 / 78` | `5832 / 20 / 9` | `-0.182 ns` | `+0.345 ns` |
| `interp_operand_pipe_ticket_proxy_20260826` | `44236 / 31678 / 78` | `5832 / 20 / 9` | `-0.182 ns` | `+0.343 ns` |
| `interp_preserved_pipe_ticket_proxy_20260827` | `44568 / 32064 / 78` | `5832 / 20 / 9` | `+0.136 ns` | `+0.340 ns` |

最终两份报告的20条路径全部MET，旧horizontal-DSP→vertical-DSP/carry→output-DSP路径匹配数为0。新direct首路径为registered fatal ticket→CNN `conv_tile_read_addr_q.CE`，13 levels、data delay `9.482 ns`、route 76.4%；Q→D首路径同属fatal-ticket扇出，仍有 `+0.340 ns` 裕量。

首次proxy仅因Vivado runtime provider无法读取 `unimacro_vhdl.tcl` 在RTL处理前退出；runner立即清除45.2 MiB并以短路径cache重试。全部综合运行和7个xsim目录累计删除1,322个文件、187.044 MiB，当前工作/runtime目录为0；保留80个小日志、状态和报告，共1.880 MiB。

### 6.14：生产 QoS monitor、APB live aggregate window 与 tagged frame boundary（2026-08-28）

| 回归 | run | 严格结果与边界 |
|---|---|---|
| standalone `c1_axi_shared_qos_monitor` xsim | `qos_monitor_v4` | PASS：`C1_AXI_SHARED_QOS_MONITOR_PASS aw0_wait=3 ar1_wait=2 b0_stall=2 r1_stall=4 read_hold=4 write_hold=3 underflow=1 deadline_miss=1`；该 TB 固定 `CLIENTS=2`、`COUNTER_W=16`，定向覆盖请求/响应等待、owner hold、underflow、deadline 与同步 clear；不等于七客户端 native SoC 或 APB 回归 |
| standalone monitor Artix-7 proxy synthesis | `qos_monitor_owner_scalar_v1` | PASS：`CLIENTS=7`、`COUNTER_W=24`、100 MHz，`2268 LUT / 4000 FF / 0 BRAM tile / 0 DSP / WNS +1.465 ns / TNS 0`；这是 observation-only monitor 的独立增量，不可直接叠加完整 SoC 资源，也不是 Ti60/Efinity 结果 |
| portable SoC QoS/APB/cache wiring smoke | `qos_apb_smoke_v2` | PASS：`C1_R1_PORTABLE_SOC_CACHE_WIRING_SMOKE_PASS tensor=00000000 quiescent=1 fence=1 qos=1`；`ENABLE_SHARED_QOS_MONITOR=1`、`ENABLE_TENSOR_WINDOW_CACHE=1`，idle 读通 `0x108..0x12c` live aggregate window 并检查 monitor enabled、cache quiescent/fence；无 AXI 数据流量，不是动态 QoS/整帧 PASS |
| native 8×8 tagged two-frame（已完成的历史基线） | `native_qos_8x8_tagged_twoframe_v4` | PASS：`done=2 swaps=2 drops=0 descriptors=44`；事件计数 `start=2 raw_prefetch_done=3 tagged_new_done=2 swap=2`、monitor `frame_count=2 active=0`；APB 读前层次化聚合值 `last_frame_cycles=3446518 deadline_miss=2 underflow=2 read_busy=5358372 write_busy=12955 r4_stall=5338987 r5_stall=2205 ar4_wait=2365 ar5_wait=5339177`。`tagged_new_done` 才是每个新 CNN pair 的 QoS terminal；`swap` 是 pixel VSYNC ownership commit，v4 中可早于最后的 prefetch drain，故 underflow/deadline 仍是风险证据 |
| native 8×8 tagged two-frame（当前重跑，APB 读回前） | `native_qos_8x8_tagged_twoframe_v5` | PASS：`C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_TWO_FRAME_PASS done=2 swaps=2 drops=0 descriptors=44`；事件计数 `start=2 raw_prefetch_done=3 tagged_new_done=2 swap=2`、monitor `frame_count=2 active=0`；聚合窗口 `last_frame_cycles=3446518 deadline_miss=2 underflow=2`。该 run 是 tagged boundary 的功能基线，未包含动态 APB 逐字段读回 |
| native 8×8 tagged two-frame（APB aggregate readback） | `native_qos_8x8_tagged_twoframe_v7` | PASS：同一功能 marker；`C1_QOS_APB_READBACK pass=1 status=00000019 frame=2 last=3446518 deadline=2 underflow=2 read_busy=5358385 write_busy=12955 r_owner=3364427 w_owner=10 protocol=0`；事件计数 `start=2 raw_prefetch_done=3 tagged_new_done=2 swap=2`、monitor `frame_count=2 active=0`，最终层次化统计 `read_busy=5358396/r4_stall=5338989/r5_stall=2207/ar5_wait=5339190`。live 单调计数允许在 APB 多寄存器读期间继续增加；帧终值/状态位严格核对。仍是 8×8 功能/QoS 风险基线，不是 native 640×480 或 15 fps 结论 |
| native 8×8 tagged two-frame + display response FIFO A/B | `native_qos_fifo_tagged_twoframe_v1` | PASS：`-DisplayResponseFifo -SharedQosMonitor`，`done=2 swaps=2 drops=0`，事件 `start/raw_prefetch_done/tagged_new_done/swap=2/3/2/2`；`C1_QOS_APB_READBACK pass=1 status=00000019 frame=2 last=3446518 deadline=2 underflow=2 read_busy=17243 write_busy=12955 r_owner=399 w_owner=10 protocol=0`；最终 `r4_stall=27 r5_stall=27 ar4_wait=194 ar5_wait=234 read_busy=17254`，AXI `AW/W/B=1704/1736/1704 AR/R=2191/3378`。相对 bypass 的约 5.34 M-cycle display HOL 显著下降，但 `last_frame_cycles=3446518`、`deadline_miss=2`、`underflow=2` 未改善，说明瓶颈已转移，不是 15 fps 签核 |
| native 64×48 tagged two-frame + display response FIFO（首轮诊断） | `native_qos_fifo_tagged_64x48_twoframe_v1` | 诊断 FAIL（非 RTL PASS）：在原 5,000,000 core-cycle boundary guard 到期时，真实 AXI traffic 已持续完成，事件为 `start/raw_prefetch_done/tagged_new_done/swap=2/2/1/2`、`monitor_frame=1`；第二 pair 已 swap 但像素域尚未完成最后 line-store drain。该结果暴露测试台固定 50 ms 观察上限过短，不能据此判定 FIFO 死锁；runRoot 已清理，仅保留 bounded 日志 |
| native 64×48 tagged two-frame + display response FIFO（形状分级观察上限） | `native_qos_fifo_tagged_64x48_twoframe_v2` | 严格 PASS：`done=2 swaps=2 drops=0 descriptors=44 stage_mask=1fffff display_done=1`；事件 `start/raw_prefetch_done/tagged_new_done/swap=2/3/2/2`、`monitor_frame=2 active=0`；`C1_QOS_APB_READBACK pass=1 status=00000019 frame=2 last=5086618 deadline=2 underflow=3 read_busy=626587 write_busy=623169 r_owner=1169 w_owner=28 protocol=0`；最终层次化 `read_busy=626599/write_busy=623169 r4_stall=4305 r5_stall=3499 ar4_wait=941 ar5_wait=1005`，AXI `AW/W/B=80448/83328/80448 AR/R=96884/103766`，`drain_cycles=5193536`。第二个 tagged completion 在约 90.48 ms 到达；测试台仅将 64×48 观察上限提升到 20 M core cycles，未改变 DUT。 |
| native 64×48 tagged two-frame + 七客户端归因转储 | `native_qos_fifo_tagged_64x48_twoframe_v3_clientdump` | 严格 PASS：与 v2 相同的 `done=2 swaps=2 drops=0`、`monitor_frame=2 active=0`、`protocol=0` 和 `drain_cycles=5193536`；额外输出 7 条 `C1_QOS_CLIENT` 记录。client-6 tensor/cache 占主要流量（`AR/R=96384/96384`、`AW/W/B=80256/80256/80256`，`ar_wait=108987`、`owner_hold=511230/618270`），且无响应侧 stall；client-0 boardless 输入仍有 `r_stall=83399`。因此下一轮优化目标从 display client-4/5 转移到 tensor client-6 的请求发射/写回批处理及 client-0 输入缓冲；本 run 只增加 TB 归因打印，不改变 DUT。 |

当前生产顶层的 `qos_frame_done_event` 接的是
`display_prefetch_new_done_event = display_prefetch_done && prefetch_active_is_new_q`，
而不是可包含后台 refresh 的 raw `display_prefetch_done`。live aggregate 已通过 APB
只读窗口映射：`0x108 QOS_STATUS`、`0x10c FRAME_COUNT`、`0x110 LAST_FRAME`、
`0x114 DEADLINE`、`0x118 UNDERFLOW`、`0x11c/0x120 READ/WRITE_BUSY`、
`0x124/0x128 R/W_OWNER_MAX`、`0x12c PROTOCOL`；`CONTROL[5]` 同步清零 legacy
与 QoS counters。per-client wait/stall/accepted/owner vectors 仍只在层次化
diagnostic 接口提供，legacy wrappers 将 QoS 输入绑零。上述 smoke 只验证 idle
窗口和接线，不验证运行时快照更新或 full-frame deadline。

## 7. 仍未通过的终局门槛

- QAT 工件尚未达到竞赛级视觉收敛；
- 已完成 QAT artifact 的 RTL descriptor/arena ABI 边界回归，以及 8×8 artifact→tensor adapter→真实 engine 的逐阶段/逐拍 bit-exact；仍未完成 native 640×480 逐层/端到端 RTL bit-exact；
- 当前 tensor 路径每帧结构估算 21,388,800 个 64-bit 请求、342,220,800 B AXI 流量，单 outstanding 的乐观下界已超过 85,555,200 cycle；
- portable SoC 的 1,000,000,000-cycle 默认 watchdog 只是功能基线的宽松有限保护，不是性能指标；15 fps 预算为 6,666,667 cycle；
- 已有 128-bit packing 原型、性能模型和 correctness-first 三行 cache；cache 已有可选顶层结构接线，AXI burst/packing、多 outstanding、并行供数/MAC/channel/group 也已有板卡前 seam，但它们在默认 SoC 的动态收益、QoS 与 native 长帧上仍未闭合；
- 已有 8×8 capture→CNN→tensor/cache→七客户端 DDR→display 全链回归，并覆盖真实显示 prefetch 启动；仍需扩到 16×8/64×48/native 640×480 长帧，测量 QoS、无饿死、abort/drain 和无撕裂；
- 没有 Efinity/Ti60 综合布局布线，也没有 MIPI、DDR、HDMI、功耗和 15 fps 实体板测试。

因此本报告证明的是“功能 QAT/整数合同与板卡无关 RTL 架构可复现”，不是“完整参赛作品或实时 bitstream 已完成”。

## 2026-08-27：15 fps 吞吐 seam 回归

本节记录本阶段新增的板卡前证据；默认 portable SoC 顶层仍保持原接线。

| 回归 | 结果 |
|---|---|
| `run_tensor_mem_axi128_read_burst_client_xsim_detached.ps1` | PASS：`C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_PASS req=19 ar=6 beats=10 packed=7`；含后继 misaligned 对齐门控 |
| `run_window_line_cache_c8_burst_shell_xsim_detached.ps1` | PASS：`taps=6 refills=5 words=80 bursts=10 beats=40 max_outstanding=2` |
| `run_axi_n_read_burst_arbiter_xsim_detached.ps1` | PASS：正常 `normal_beats=16`、malformed `malformed_beats=10`、`max_inflight=4`，early/missing RLAST sticky flags 均验证 |
| `run_tensor_mem_axi128_read_fabric_2c_xsim_detached.ps1` | PASS：`req=16 ar=6 beats=8 packed=6 max_inflight=5`；两个 leaf 与读 fabric 端到端按客户端检查顺序/数据 |
| `run_tensor_mem_axi128_write_burst_client_xsim_detached.ps1` | PASS：`req=21 aw=10 beats=13 packed=7 errors=2 b_stall=1`；含 4 KiB、partial strobe、同 lane payload 和 local error |
| `run_axi_n_write_burst_arbiter_xsim_detached.ps1` | PASS：`aw=6 beats=12 b=6 max_outstanding=3 max_bfm_queue=3 aw_stall=2 w_stall=4 b_stall=5` |
| `run_dot8x8_bank_xsim_detached.ps1` | PASS：`C1_DOT8X8_REQUANT_BANK_PASS`；锁步双 lane 与 full-tree 选项回压通过 |
| `run_axi_n_write_burst_arbiter_proxy_synth_detached.ps1` | PASS（Artix-7 proxy）：3 clients/FIFO4，`370 LUT/478 FF/0 BRAM/0 DSP/WNS +3.787 ns` |
| `run_tensor_mem_axi128_read_fabric_proxy_synth_detached.ps1` | PASS（Artix-7 proxy，响应容量阈值优化后）：2 leaf/FIFO8，`31905 LUT/10075 FF/0 BRAM/0 DSP/WNS +1.928 ns`；读 leaf response memory 在该配置映射为 distributed RAM/LUTRAM |
| `run_axi_n_write_burst_arbiter_orphan_xsim_detached.ps1` | PASS：孤立 B 被诊断并消费，`orphan=1 count=0 b=0`；不会使 descriptor/FIFO 计数下溢 |
| `run_tensor_mem_axi128_write_parallel_fabric_xsim_detached.ps1` | PASS：双 lane `req=16 aw=4 beats=8 packed=8 errors=4 max_outstanding=2`；全局 tag FIFO 恢复逻辑响应顺序 |
| `run_tensor_mem_axi128_write_parallel_fabric_proxy_synth_detached.ps1` | PASS（Artix-7 proxy，响应容量阈值优化后）：`4308 LUT/10091 FF/0 BRAM/0 DSP/WNS +1.203 ns`；首版 `-0.160 ns` 的 tag→BREADY 路径已消失 |

新增 Python 标记：`C1_THROUGHPUT_SWEEP_TEST_PASS` 现在还检查 fabric
outstanding=1/2/4/8/16/32 的 memory-only 扫描；理想 cache+pack2 下 out=2 已越过
15 fps 的 memory-only 门槛，但共享 CNN FSM 仍是主要瓶颈。

本轮还修正了写 leaf 仿真监视器的 W payload 宽度：`WDATA(128)+WSTRB(16)+WLAST(1)`
必须保留 145 bit，否则 WLAST/最高位变化会产生伪造的 VALID hold 报错。该修正
不改变综合硬件。读写 leaf 均将响应 FIFO 空间判断改为不依赖同周期 `rsp_pop` 的
静态阈值；xsim 的满槽/延迟 BFM 场景仍通过，综合代理分别获得 +1.714 ns 和
+1.363 ns 的 WNS 改善（相对本阶段首版）。

### 2026-08-27：beat-FIFO 与 inter-pixel MAC seam

| 回归/代理 | 结果 |
|---|---|
| `run_tensor_mem_axi128_read_burst_client_beatfifo_xsim_detached.ps1` | PASS：`C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_BEAT_FIFO_PASS req=19 ar=6 beats=10 packed=7 fifo_depth=12` |
| `run_tensor_mem_axi128_read_burst_client_beatfifo_malformed_xsim_detached.ps1` | PASS：early-RLAST + missing-RLAST，`req=16 ar=2 beats=6 errors=8 fifo_depth=8` |
| logical/beat FIFO 同参数 proxy | 均 PASS；logical `12045 LUT/5378 FF/WNS +1.046 ns`，beat `1714 LUT/1182 FF/WNS +1.380 ns`，参数均为 `REQ16/BURST16/MAX4/RSP64` |
| 集成两客户端 beat-FIFO read fabric xsim | PASS：`req=16 ar=6 beats=8 packed=6 max_inflight=5`，两 leaf 均通过 `LEAF_RSP_FIFO_BEAT_MODE=1` |
| 集成两客户端 beat-FIFO read fabric proxy | PASS：beat leaf RSP16 为 `2194 LUT/1630 FF/0 BRAM/0 DSP/WNS +1.815 ns`；logical leaf RSP64 对照为 `31905/10075/+1.928 ns` |
| cache burst shell beat-FIFO xsim | PASS：`taps=6 refills=5 words=80 bursts=10 beats=40 max_outstanding=2`，`RSP_FIFO_BEAT_MODE=1` 透明转发 |
| `run_dot8x8_requant_pingpong_xsim_detached.ps1` | PASS：双 bank×双 lane，6 个事务按序输出，`max_inflight=2`，首个 overlap 提前 8 cycles |
| `run_dot8x8_requant_pingpong_proxy_synth_detached.ps1`（同脚本 default/`-OutputRestart`） | 均 PASS：default `31165 LUT/22833 FF/64 DSP/WNS +1.247 ns`；optional `31163/22833/64/+1.247 ns`，full product→pair→quad→dot tree |

beat FIFO 只改变 response-record 的存储布局，不改变 AXI payload 或逻辑响应
数量；当前 integrated read fabric/cache wrapper 仍保持默认 logical mode。ping-pong
只证明事务级 inter-pixel 隐藏 bank latency，尚未替换真实 22-stage engine 的
stage scheduler，也没有声称整帧达到 15 fps。所有 Vivado/xsim worker 都由 WMI
脱离当前 Codex Job 启动，私有工程树在 runner 结束时删除。

### 2026-08-27：burst-level write MLP 与四-bank MAC A/B

| 回归/代理 | 结果 |
|---|---|
| `run_axi128_write_mlp_xsim_detached.ps1` | PASS：`C1_AXI128_WRITE_MLP_PASS desc=6 aw=3 w=12 b=3 max_out=3 aw_stall=18 w_stall=5 b_stall=49 errors=4`；覆盖 AW ahead、W/B 有序、payload hold、早/晚 `TLAST`、flush 和错误 B |
| `run_axi128_write_mlp_proxy_synth_detached.ps1` | PASS（Artix-7 proxy）：`5882 LUT/10308 FF/0 BRAM/0 DSP/WNS +3.249 ns`；`MAX_OUTSTANDING=4/MAX_BEATS=16`，payload slot 采用 128-bit beat 存储 |
| `run_tensor_mem_axi128_write_mlp_adapter_xsim_detached.ps1` | PASS（小配置 `MAX_BEATS=4`）：`C1_TENSOR_MEM_AXI128_WRITE_MLP_ADAPTER_PASS desc=5 req=26 rsp=26 aw=4 beats=12 packed=13 errors=2 max_out=4`；覆盖 logical pack2、连续地址、早 `LAST` 局部 poison 与有序响应 |
| `run_tensor_mem_axi128_write_mlp_adapter_proxy_synth_detached.ps1` | PASS（Artix-7 proxy，`MAX_OUTSTANDING=4/MAX_BEATS=16`）：`15961 LUT/27771 FF/0 BRAM/0 DSP/WNS +2.551 ns`；payload 数组标记 block，但该 proxy 仍映射为 LUT/FF |
| `run_tensor_mem_axi128_write_mlp_fabric_2c_xsim_detached.ps1` | PASS：logical adapter + raw AXI128 peer 共享 write fabric，`aw=4 w=7 b=4 adapter_rsp=8 peer_b=2 max_inflight=4 packed=4`；覆盖跨 client AW 预排、W/B 保序和响应反压 |
| `run_tensor_mem_axi128_write_mlp_fabric_2c_proxy_synth_detached.ps1` | PASS（Artix-7 proxy）：`16291 LUT/28296 FF/0 BRAM/0 DSP/WNS +2.197 ns`；0 BRAM 仅是 LUT/FF proxy，不代表 Ti60 EBR 映射 |
| `run_tensor_mem_axi128_write_parallel_fabric_lanes4_xsim_detached.ps1` | PASS：四 lane `req=32 aw=8 beats=16 packed=16 errors=4 max_outstanding=4`；连续 block 分发和全局 tag FIFO 保持逻辑响应顺序 |
| `run_tensor_mem_axi128_write_parallel_fabric_lanes4_proxy_synth_detached.ps1` | PASS（Artix-7 proxy）：`9858 LUT/20168 FF/0 BRAM/0 DSP/WNS +2.166 ns`；`LANES=4/BLOCK_LOGICAL=16/TAG_FIFO_DEPTH=128` |
| `run_dot8x8_requant_pingpong_banks4_xsim_detached.ps1` | PASS：四 bank×双 lane，`transactions=12 max_inflight=4 first_overlap=8 cycles=47`，tag FIFO 保持输出顺序 |
| `run_dot8x8_requant_pingpong_banks4_proxy_synth_detached.ps1` | PASS（Artix-7 proxy）：`59912 LUT/45674 FF/0 BRAM/128 DSP/WNS +0.337 ns`；full product→pair→quad→dot tree |
| `run_r1_microstyle_engine_dwcache_xsim_detached.ps1`（cache A/B） | PASS：关闭/开启 DW tile cache 的 `first_run_cycles=30570/28553`，均 `22 stages/836 outputs/mac=312/dw=248/bypass=276` 且 bit-exact；联合 MAC overlap 后为 `27174` cycles |
| `run_microstyle_cnn_top_dwcache_proxy_synth_detached.ps1` | PASS（可综合但 timing 未闭合）：tap-bank cache + MAC overlap 当前源码 `36413 LUT/14889 FF/2 BRAM/35 DSP/WNS -4.959 ns`；相对 cache=0 仍未闭合，暂不打开默认路径 |
| `run_r1_microstyle_engine_dwcache_xsim_detached.ps1 -DisableCache -OverlapMac` | PASS：可选 Conv/1x1 steady-state prefetch overlap，`first_run_cycles=29192`，`mac_overlap=1`；与 cache 联合为 `27174`，均保持原输出计数/错误注入检查 |

`c1_axi128_write_mlp` 是 burst-level descriptor seam：它允许多个 descriptor 的
AW 先行，但 W 与 B 仍按 descriptor 顺序推进；新的 logical adapter 已把 64-bit
pack2 接到该 backend，并由可选两客户端 wrapper 暴露给共享 fabric。当前 AW 先行仍
以 payload 完整入槽为默认边界，下一步才是验证真正的 payload-fill/AW 重叠。它们仍未接入
七客户端 fabric 或默认 portable SoC，因此不能把该 proxy 直接当成单 writer 的整帧
吞吐提升。四-bank MAC 只是二-bank ping-pong 的压力 A/B；资源和时序
已接近 Artix proxy 的边界，尚未替换真实 22-stage scheduler、权重预取或 egress
FIFO。四 lane write fabric 同样只是多个单 outstanding leaf 的横向 scaling，不能
替代单 writer 的 AXI-ID/乱序 B。DW tile cache 的小 TB 周期收益被 full-top
proxy 的负 WNS 抵消，必须先做 RAM-friendly EBR/Efinity 对照。以上结果均为板卡前证据，不是 640×480@15 fps
signoff。

### 2026-08-27：15 fps 吞吐 profile / response boundary 增量

| 回归/代理 | 结果 |
|---|---|
| `run_tensor_mem_axi128_read_burst_client_xsim_detached.ps1 -LongBurst` | PASS：`burst_beats=16/max_outstanding=4/req=19/ar=6/beats=10/packed=7` |
| `run_tensor_mem_axi128_read_burst_profile_xsim_detached.ps1`（16-beat） | PASS：`req=189/ar=9/beats=94/packed=94/full_bursts=5/short_bursts=4/max_outstanding=3/page_split=1/cycles=397` |
| 同 runner `-Burst32`（32-beat） | PASS：`req=189/ar=7/beats=94/packed=94/full_bursts=2/short_bursts=5/max_outstanding=3/page_split=1/cycles=397`；4-KiB split 与逻辑响应顺序一致 |
| `run_window_line_cache_c8_burst_shell_xsim_detached.ps1`（默认 profile） | PASS：`BURST_BEATS=4/MAX_OUTSTANDING=3`，`80 words/10 bursts/40 beats/max_outstanding=2/cycles=303` |
| 同 runner `-LongBurst` | PASS：`64×2-group` 行、`640 words/20 bursts/320 beats/max_outstanding=4/cycles=1883` |
| cache runner `-LongBurst -BeatFifo -TailFlush -ReqPopRefill` | PASS：`640 words/20 bursts/320 beats/max_outstanding=4/tail_flush=5/flush_closes=5/cycles=1883` |
| `run_axi128_write_mlp_xsim_detached.ps1`（默认/`-RspPopRefill`） | 均 PASS：`desc=6/aw=3/w=12/b=3/max_out=3/errors=4`，`B stall=49→48`，可选模式 `full_pop_push=1` |
| `run_tensor_mem_axi128_write_mlp_adapter_xsim_detached.ps1`（默认/`-RspPopRefill`） | 均 PASS：`desc=5/req=26/rsp=26/aw=4/beats=12/packed=13/errors=2/max_out=4`，可选模式 `full_pop_push=1` |
| `run_tensor_mem_axi128_write_mlp_fabric_2c_xsim_detached.ps1 -RspPopRefill` | PASS：`aw=4/w=7/b=4/adapter_rsp=8/peer_b=2/max_inflight=4/packed=4`；`full_pop_push=0` 为两 descriptor BFM 限制 |
| `model/write_rsp_pop_refill_model.py` / test | PASS：`baseline_stalls=6/refill_stalls=5/full_pop_push=10` |

这些 profile 都通过 WMI detached worker 执行；runner 结束后删除私有 xsim
runRoot，只保留小型 status/stdout/stderr。它们验证的是参数传播、排序和压力边界，
不是 native DDR 服务时间或 15 fps signoff。

### 2026-08-27：读 AR 直通与 MAC 同拍重启 A/B

| 回归/模型 | 结果 |
|---|---|
| `run_axi_n_read_burst_arbiter_xsim_detached.ps1`（默认） | PASS：`empty_ar_bypass=0 first_ar_latency=1 hold_capture=0 normal_beats=16 malformed_beats=10 max_inflight=4 ar_total=4 early=1 missing=1` |
| 同 runner `-EmptyArBypass` | PASS：`empty_ar_bypass=1 first_ar_latency=0 hold_capture=1`，其余计数/错误标志一致；另验证 downstream stall 时 AR payload hold |
| `run_tensor_mem_axi128_read_fabric_2c_xsim_detached.ps1 -EmptyArBypass` | PASS：`req=16 ar=6 beats=8 packed=6 max_inflight=5 req_pop_refill=0 empty_ar_bypass=1` |
| `run_dot8x8_requant_pingpong_xsim_detached.ps1`（默认） | PASS：`first_beat=0 output_restart=0 banks=2 lanes=2 transactions=6 max_inflight=2 same_bank_restart=0 first_overlap=8 cycles=40` |
| 同 runner `-OutputRestart` | PASS：`output_restart=1 max_inflight=3 same_bank_restart=4 cycles=37` |
| 同 runner `-FirstBeat -OutputRestart` | PASS：`first_beat=1 output_restart=1 same_bank_restart=4 cycles=37` |
| `run_dot8x8_requant_pingpong_banks4_xsim_detached.ps1`（默认/`-OutputRestart`） | 均 PASS：四 bank×二 lane `cycles=47→45`、`same_bank_restart=0→1` |
| `model/mac_output_restart_model.py` / test | PASS：`baseline_cycles=22 optional_cycles=20 saved_cycles=2 same_edge_restarts=4` |

读 AR 直通和 MAC 同拍重启均是默认关闭的边界 seam；前者不减 payload，后者不
复制 DSP。新增 runner 仍使用 detached WMI worker，并在完成后删除私有仿真目录。
这些 A/B 不能替代 native 640×480 长帧下的 EBR、QoS、供数和时序测量。

### 2026-08-27：写 request FIFO pop/refill A/B

| 回归/模型 | 结果 |
|---|---|
| `run_tensor_mem_axi128_write_burst_client_xsim_detached.ps1 -ReqPopRefillBaseline` | PASS：`mode=0 full_cycle=9 first_post_full_cycle=15 full_to_accept=6 same_cycle=0 req=12 aw=12 beats=12 max_req=4` |
| 同 runner `-ReqPopRefill` | PASS：`mode=1 full_cycle=9 first_post_full_cycle=14 full_to_accept=5 same_cycle=1 req=12 aw=12 beats=12 max_req=4` |
| 同 runner（默认旧 TB） | PASS：`req=21 aw=10 beats=13 packed=7 errors=2 b_stall=1` |
| `model/write_req_pop_refill_model.py` / test | PASS：`baseline_stalls=10→refill_stalls=9`、`full_pop_push=8` |
| `run_tensor_mem_axi128_write_parallel_fabric_xsim_detached.ps1` | PASS：参数透传后的默认两路 fabric `req=16 aw=4 beats=8 packed=8 errors=4 max_outstanding=2` |
| 同 runner `-ReqPopRefill` | PASS：可选参数透传/编译及两路 traffic 仍为 `req=16 aw=4 beats=8 packed=8 errors=4 max_outstanding=2` |

该 seam 只消除满 FIFO 时的 producer ready 气泡，不减少 AXI payload 或增加
outstanding；默认仍关闭，不能把上述小规模 A/B 直接解释为 15 fps。

### 2026-08-27：cache/读 response pop-refill 组合 smoke

| 回归 | 结果 |
|---|---|
| `run_window_line_cache_c8_burst_shell_xsim_detached.ps1 -LongBurst -BeatFifo -TailFlush -ReqPopRefill -RspPopRefill` | PASS：`taps=6 refills=5 words=640 bursts=20 beats=320 max_outstanding=4 tail_flush=5 rsp_pop_refill=1 req_pop_refill=1 cycles=1883` |
| `run_tensor_mem_axi128_read_burst_client_xsim_detached.ps1 -PopRefill` | PASS：独立 depth-2 response FIFO A/B 已覆盖满槽 pop/refill，详见 `READ_RSP_POP_REFILL_OPTIMIZATION.md` |

组合 smoke 只证明 cache 行 refill、beat FIFO、四 outstanding 和选项传播可共同
运行；response-pop/refill 的窄分支不从 cache BFM 周期推导帧率，仍以 read-leaf
专用 A/B 作为功能证据。

### 2026-08-27：并行 MAC 满 TAG FIFO pop/push A/B

| 回归 | 结果 |
|---|---|
| `run_dot8x8_requant_pingpong_xsim_detached.ps1 -TagPopPush` | PASS：2 bank×2 lane、`TAG_FIFO_DEPTH=2`、8 事务；`max_inflight=2 same_bank_restart=0 full_tag_pop_push=0 cycles=52` |
| 同 runner `-TagPopPush -OutputRestart` | PASS：`max_inflight=3 same_bank_restart=6 full_tag_pop_push=6 cycles=48`；按序 payload/metadata 与 overflow 检查通过 |
| `run_dot8x8_requant_pingpong_banks4_xsim_detached.ps1 -TagPopPush` | PASS：4 bank×2 lane、16 事务；`max_inflight=4 full_tag_pop_push=0 cycles=59` |
| 同 runner `-TagPopPush -OutputRestart` | PASS：`max_inflight=5 same_bank_restart=2 full_tag_pop_push=2 cycles=57`；signed-8 饱和期望已覆盖 |
| `model/mac_tag_pop_push_model.py` / test | PASS：`baseline_cycles=35 optional_cycles=31 saved_cycles=4 full_pop_push=6 max_tag=2` |
| `run_dot8x8_requant_pingpong_proxy_synth_detached.ps1`（同 output-restart 下切换 tag pop/push） | Artix-7 proxy 均 PASS：`31163 LUT/22833 FF/64 DSP/WNS +1.247 ns` → `31159/22833/64/+1.845 ns`，TNS=0；仅作结构/资源观察，不作 WNS 因果结论 |

该选项默认关闭，只在 tag FIFO 已满且队首本周期退休时生效；它不增加
乘法器/累加器或 AXI payload，不能单独推出 native 15 fps。四次 xsim 均由
detached WMI worker 执行，私有 runRoot 已清除，仅保留小日志与状态。

### 2026-08-27：最大行 cache burst32 profile

| 回归 | 结果 |
|---|---|
| `run_window_line_cache_c8_burst_shell_xsim_detached.ps1 -MaxRow` | PASS：`C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_MAXROW_PASS taps=8 refills=1 words=1280 bursts=20 beats=640 packed=640 ar=20 ar_beats=640 page_splits=2 max_outstanding=4 tail_flush=0 cycles=1636` |

该 profile 将 `width*groups=1280` 的最大冻结行实际送过 32-beat reader，检查
两次 4-KiB 页边界、AR 顺序、pack2 两 lane 和 resident-row 命中。它是
boardless geometry/order 证据，不是 native 帧率或 Efinity 资源签核；运行结束后
私有 xsim runRoot 已删除。

### 2026-08-27：native 640×480 compile-only gate 与 bounded log

| 回归 | 结果 |
|---|---|
| `run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -Frame 640x480 -CompileOnly` | PASS：`C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS frame=640x480`（`xvlog`/`xelab` exit 0） |

该 runner 改用私有 `xvlog -f` source manifest，避免 117 个绝对路径超过 Windows
命令行长度而被 `xvlog` 报成 access denied；工具原始 stdout/stderr 只写入私有
runRoot，持久化日志只保留 marker/短尾部，worker 结束后 runRoot 不存在且无
Vivado/xsim 残留。compile-only 仅证明 RTL 可编译/展开，不是 native CNN、DDR
QoS 或 15 fps signoff。

### 2026-08-27：只读 cache-refill scheduler protocol gate

| 回归 | 结果 |
|---|---|
| `run_cache_refill_scheduler_xsim_detached.ps1` | PASS：`cmd_accept=3 req=4 rsp=5 words=3 stale_drop=1 orphan=1 max_outstanding=2 epoch=2 abort_done=1 flush_done=1 flush_pulse=1 cycles=68` |

该小型 BFM 覆盖 pending request 跨 abort 边沿保持、命令 FIFO 丢弃、credit
上限、leaf close pulse、旧 epoch drain、新 epoch 顺序/last、held-high flush
one-shot 和 orphan response。runner 使用 detached WMI worker 与 bounded logs；
该 gate 不代表默认 SoC 或 native 15 fps 已启用。

### 2026-08-28：tensor client-6 burst/refill 维护契约与 shape gate

| 回归 | 结果 |
|---|---|
| `run_tensor_cache_burst_client_xsim_detached.ps1 -RunId burst_client_abort_prear_v2` | PASS：`burst_ar=4 single_ar=5 beats=13 aw/w/b=2/2/2 flush_done=2 abort_done=3 ar_stall=3 r_stall=0 r_gap=21 aw_stall=1 w_stall=2 cycles=265`；覆盖 packed miss、same-row hit、legacy read/write、flush-before-AR、abort-before-AR、partial-refill fence、response hold |
| `run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -Frame 64x48 -CompileOnly -SharedQosMonitor -TensorBurstRefill -DisplayResponseFifo` | PASS：`C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS frame=64x48`；最终 ready/valid 门控与取消策略参数传播后重新 xvlog/xelab |
| `run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -Frame 640x480 -CompileOnly -SharedQosMonitor -TensorBurstRefill -DisplayResponseFifo` | PASS：`C1_R1_PORTABLE_SOC_SHAPE_ELAB_PASS frame=640x480`；只做 native 几何/optional-generate 展开，不启动长帧 xsim |
| `run_window_line_cache_c8_exact_burst_shell_xsim_detached.ps1 -RunId exact_shell_after_cancel_param_v1` | PASS：`responses=4 refills=3 words=24 ar=5 beats=10 flush=1 epoch=1 cancel_req=3 cancel_source=3 cancel_drain=3 cancel_synthetic=5 cancel_unified=8 cycles=143`；确认取消策略参数透传不破坏既有 exact-count/flush 回归 |
| `tensor_burst_refill_64x48_twoframe_maintenance_v1`（optional tensor burst/refill 两帧 full BFM） | PASS：`done=2 swaps=2 drops=0`、`AW/W/B=80448/83328/80448`、`AR/R=60165/84187`、`last_frame_cycles=5086618`、`protocol=0 overflow=0`；client-6 `AR/R=59664/76800` |

本阶段把 routine debug trace 删除，仅保留失败时的有界诊断；所有 runner 通过
detached WMI worker 执行，私有 xsim runRoot 在结束后清理。burst 分支仍是
`ENABLE_TENSOR_BURST_REFILL=0` 默认关闭的实验路径，且 serial ID-less fabric
尚未提供真正的跨 logical request MLP；详细集成契约和板前/板后计划见
`TENSOR_CLIENT_BURST_REFILL_INTEGRATION.md`。

### 6.15：full-top logical/beat proxy 综合与 native beat shape gate（2026-08-28）

| 回归 | 结果 |
|---|---|
| full-top logical tensor-burst proxy | `portable_soc_tensor_burst_logical_v4`；综合完成但 timing failed：`mode=logical beat_mode=0 rsp_depth=128`，Artix-7 proxy `80791 LUT/39369 FF/32 BRAM/100 DSP`，WNS/TNS `-52.20/-175089.359 ns` |
| full-top beat-record tensor-burst proxy | `portable_soc_tensor_burst_beat_v1`；综合 marker PASS：`mode=beat beat_mode=1 rsp_depth=64`，`48411 LUT/30950 FF/32 BRAM/100 DSP`；但 WNS/TNS `-52.55/-191612.156 ns`，`timing_met=false`，不作为时序签核 |
| native beat two-frame 8×8 | `tensor_burst_beat_8x8_twoframe_v1`；严格 PASS：`done=2 swaps=2 drops=0 descriptors=44 stage_mask=1fffff display_done=1`，`AW/W/B=1704/1736/1704`、`AR/R=1451/2970`、`drain_cycles=3464876` |
| native beat two-frame 64×48 | `tensor_burst_beat_64x48_twoframe_v1`；严格 PASS：`done=2 swaps=2 drops=0 descriptors=44 stage_mask=1fffff display_done=1`，`AW/W/B=80448/83328/80448`、`AR/R=60165/84187`、`drain_cycles=5193536` |

native beat 两个 shape gate 均为真实 full-top BFM、三阶段 stderr 为空；它们证明 beat-record 可选路径的功能、ownership 与 drain 完成，不等于 native 640×480 实时性能。logical/beat proxy 均为 Xilinx Artix-7 结构观察，beat 版本当前仍需切断长路径并在 Ti60/Efinity 重新评估。

### 2026-08-28：REGISTER_ABORT_RESET A/B

| 回归/配置 | 结果 |
|---|---|
| native resize | PASS |
| native 8×8 / 64×48 abortreg | PASS，`protocol=0` |
| proxy baseline | `48192 LUT/31227 FF/32 BRAM/88 DSP`，WNS/TNS `-5.900/-67577.578` |
| abortreg v2 | `48211 LUT/31237 FF/32 BRAM/88 DSP`，WNS/TNS `-5.416/-66644.070`，`timing_met=false` |

REGISTER_ABORT_RESET A/B 的剩余最差路径为 reset 相关的 descriptor decoder path。

### 2026-08-28：PIPELINED_DECODER_VALIDATION

| 回归/配置 | 结果 |
|---|---|
| MicroStyle engine | PASS：`C1_R1_MICROSTYLE_ENGINE_PASS ... outputs=836 ... first_run_cycles=30570` |
| 完整 8×8 两帧组合（burst+beat+address+adapter descriptor pipeline+narrow+abort reset+QoS+display FIFO+decoder pipeline） | PASS：`done=2/swaps=2/drops=0`，`protocol=0`，`last_frame_cycles=3446518`，`r4/r5 stall=29/29`，`ar4/ar5 wait=202/244` |
| proxy `tensor_burst_beat_pipelined_split_addr_abortreg_decoderpipe_v1` | `47493 LUT/31441 FF/32 BRAM/88 DSP`，WNS/TNS `-5.362/-66042.227 ns`，`timing_met=false` |

相较 abortreg v2（`48211/31237/-5.416/-66644.070`），本配置在配置阶段每个
descriptor 固定增加两拍；运行期协议不变，仍非 timing signoff。

### 2026-08-28：decoderpipe + REGISTER_FATAL_TICKET / replicate 对照

| 配置 | 结果 |
|---|---|
| full-top proxy，`REGISTER_FATAL_TICKET=1`、`REPLICATE=0` | `47467 LUT/31471 FF/32 BRAM/88 DSP`，WNS `-4.601`，TNS `-960.989`，`timing_failed`；最差路径 `dot_weight_tile_q_reg C→dot_core/g_dot[*]/acc_overflow_reg D` |
| 同配置，`REPLICATE_ABORT_CONTROL=1` | `47474 LUT/31502 FF/32 BRAM/88 DSP`，WNS `-4.601`，TNS `-969.458`，几乎无收益 |
| native 8×8 two-frame ticket | PASS：`done=2/swaps=2/drops=0`，`protocol=0`，`last_frame_cycles=3446518`，client-6 `AW/W/B=1672/1672/1672`、`AR/R=1268/1600` |

ticket 作为 timing candidate，replicate 默认关闭；上述结果不构成 timing signoff。

### 2026-08-28：deep pixel-index 实验

新增 `PIPELINED_TENSOR_PIXEL_INDEX`（默认关闭）。standalone adapter PASS：
`requests=2230 reads=1810 writes=420 pipeline=1`；8×8 两帧 full BFM PASS：
`done=2/swaps=2/protocol=0`。

proxy `tensor_burst_beat_pipelined_deeppixel_abortreg_decoderpipe_v1`：
`47522 LUT/31431 FF/32 BRAM/88 DSP`，WNS/TNS `-5.544/-66243.875`。相对
decoderpipe baseline `47493/31441/-5.362/-66042.227` 变差 `0.182 ns`，worst
path 转为 `camera FIFO→tensor_adapter/state_q CE`。结论：保留为可回退研究开关，
默认弃用，不再加深。

### 2026-08-28：dot-tree full A/B

推荐组合 functional 8×8 two-frame PASS：`done=2/swaps=2/drops=0/protocol=0`，
`AW/W/B=1704/1736/1704`、`AR/R=1451/2970`、`last_frame_cycles=3446518`。

| proxy 配置 | 结果 |
|---|---|
| `recommended_fatal_ticket_dotfull_v1`（Beat+PipelinedAddress+descriptor pipeline+narrow+abort reset+decoder pipeline+REGISTER_FATAL_TICKET+PIPELINED_DOT_TREE_FULL） | `47392 LUT/34763 FF/32 BRAM/88 DSP`，WNS/TNS `-3.450/-33.977 ns` |
| dotbase ticket 同组合 | `47464 LUT/31504 FF/32 BRAM/88 DSP`，WNS/TNS `-4.601/-969.458` |

瓶颈由 dot weight→acc_overflow 转为 descriptor size narrow return→
`descriptor_input/output_size_result_q`（`-3.450`）。dotfull 为可选 timing candidate，
默认 0，非 timing signoff。

### 2026-08-28：descriptor-size arithmetic / fixed-threshold A/B

descriptor size arithmetic v3 standalone PASS；完整 8×8 两帧 full BFM 亦 PASS，
marker 为 `done=2/swaps=2/drops=0/protocol=0`、`last=3446518`，AXI
`1704/1736/1704/1451/2970`（AW/W/B/AR/R），QoS `r4/r5=36/35`。

| 配置 | LUT | FF | BRAM | DSP | WNS/TNS |
|---|---:|---:|---:|---:|---:|
| size0 | 47,399 | 34,764 | 32 | 88 | `-2.907/-24.206 ns` |
| size1 | 47,544 | 34,819 | 32 | 87 | `-2.363/-62.605 ns` |
| fixed-threshold | 47,512 | 34,821 | 32 | 85 | `-1.079/-20.120 ns` |

fixed-threshold 相对 size1 为 LUT `-32`、FF `+2`、DSP `-2`、WNS `+1.284 ns`、
TNS `+42.485 ns`；最差路径转为 `16x16 pixel_count`。descriptor-size
arithmetic/fixed-threshold 默认关闭，Case1 固定 8MiB/22-stage 严格条件，仍非
timing signoff。

### 2026-08-28：pixel-count split

standalone 与完整 8×8 两帧 BFM 均 PASS；BFM AXI 为
`1704/1736/1704/1451/2970`（AW/W/B/AR/R），`last_frame_cycles=3446518`，
QoS `r4/r5=28/27`，配置标志为 `descriptor_size_arith=1 fixed=1 pixel=1`。

proxy 结果为 `47542 LUT/34818 FF/32 BRAM/83 DSP`、WNS/TNS
`-1.217/-18.572`，相对 fixed baseline WNS `-0.138 ns`；最差路径为
`cache height_q→adapter state CE`。pixel-count split 默认关闭，结果仍非 timing
signoff。

### 2026-08-28：iterative descriptor pixel-count shift-add

standalone PASS marker；BFM two-frame PASS：AXI
`1704/1736/1704/1451/2970`（AW/W/B/AR/R），`last_frame_cycles=3446518`，
`protocol=0`，QoS `r4/r5=27/27`。

| 配置 | 结果 |
|---|---|
| iterative native-control | `47611 LUT/34917 FF/32 BRAM/82 DSP`，WNS/TNS `-1.206/-23.233` |
| 同 runner fixed native control | `47512 LUT/34821 FF/32 BRAM/85 DSP`，WNS/TNS `-1.079/-20.120` |

迭代方案相对 fixed 的 WNS 为 `-0.127 ns`，资源为 LUT `+99`/FF `+96`/DSP `-3`，
瓶颈迁移为 `cache height_q→state CE`。两次旧 cache env failure 后最终使用 native
runtime；该开关默认关闭，结果仍非 timing signoff。

### 2026-08-28：registered preclamped tap coordinates（语义修正版）

为避免 cache 侧重复做 signed logical 坐标钳位，新增默认关闭的
`PRECLAMPED_TAP_COORDS`。adapter 在现有 request-Q 边界，复用生成物理地址的
`tap_source_x/y_fn`，把 Conv3x3/DWConv3x3 tap 坐标寄存后再送入 line-cache/
burst exact shell；未启用时 ABI 和未钳位 sideband 语义完全不变。opt-in 仿真还
对握手请求检查坐标范围，避免把 `-1` 等 logical 坐标误当作物理坐标。

| 回归 | 结果 |
|---|---|
| `preclamped_registered_tap_8x8_twoframe_v1` | PASS：`frame=8x8 done=2 swaps=2 drops=0 descriptors=44 stage_mask=1fffff display_done=1`，`drain_cycles=3464876`，`protocol=0`，`preclamped_tap_coords=1` |
| 同 run AXI/QoS | 与 fixed baseline 完全一致：`AW/W/B=1704/1736/1704`、`AR/R=1451/2970`，`aw/w/ar/r stalls=231/464/212/1879`；APB `pass=1 status=00000019 frame=2 last=3446518` |
| 早期 `preclamped_tap_8x8_twoframe_v1`（raw sign-only clamp） | **拒绝**：虽有 lifecycle marker，但 `AR/R=1463/3042`（client-6 `1280/1672`）偏离 baseline，说明 logical/physical 坐标语义错误，不作为优化证据 |

该结果目前只证明 registered preclamp 的功能与流量等价，不证明时序收益或
15 fps。随后 native helper=all 已修复 full-top `common.tcl` runtime failure，
并取得有效的严格 A/B（见下节）；结果仍为 xc7a proxy/timing_failed，不是 Ti60
timing signoff。

### 2026-08-28：Soft Sapphire APB/IRQ vendor seam

新增 `rtl/vendor/c1_sapphire_apb_master_adapter.sv` 与
`rtl/vendor/c1_sapphire_irq_adapter.sv`，并由
`scripts/run_sapphire_apb_adapter_xsim_detached.ps1` 完成 detached xsim 回归。
marker 为：

```text
C1_SAPPHIRE_APB_ADAPTER_PASS writes=2 read=c1a00001 irq=00 upper_error=1
```

该专项覆盖 Soft Sapphire 生成端 `io_apbSlave_0_*` 到 Case-1 APB 从端的方向和
地址宽度转换、完整字写入/读回、非法高位地址本地报错与后续事务恢复，以及
IRQ one-hot 选择。生成的 Sapphire APB 端口没有 `PSTRB`：adapter 在写事务输出
参数 `WRITE_PSTRB`（当前默认 `4'hf`，对应现有 32-bit word ABI），读事务输出
`c1_pstrb=4'h0`；后续若 BSP 支持 byte write，只需在该 seam 扩展 byte-enable
语义。对于更宽的生成地址窗口，只有高位全零才转发到 Case-1；高位非零访问
由 adapter 以 `PREADY=1/PSLVERR=1` 完成本地错误响应，不产生 `c1_psel` 或 CSR
副作用。

`c1_sapphire_irq_adapter` 将单根 Case-1 level `irq` 映射到
`sapphire_user_interrupt[7:0]` 的 `USER_INTERRUPT_INDEX`（0..7，默认 0；本次
TB 选 index 3，验证 one-hot `8'h08`）。`c1_apb_csr` 的 IRQ 在软件清除相应
状态位前保持为电平，因此直接接 Sapphire PLIC 用户中断输入，不需要脉冲展宽器；
板级若使用不同 CPU 时钟，仍需在 wrapper 中放合法 APB/IRQ CDC。该回归只覆盖
vendor seam 的 RTL 协议，不代表已生成 Sapphire BSP、Ti60 P&R 或板卡调试完成。

### 2026-08-28：Efinity/RV32 boardless Makefile smoke

`case1/software/efinity_smoke` 已在本机 Efinity RISC-V 工具链环境执行：

```powershell
make -C .\case1\software\efinity_smoke clean all
```

构建成功，`build/` 生成 ELF/HEX/BIN/MAP/反汇编和三个目标文件共 8 个文件、
`35,952 B`（约 `35.1 KiB`）。`c1_efinity_smoke.elf` 经 ELF 属性检查为 ELF32 RISC-V、
`RVC`、`soft-float ABI`，默认编译选项为 `-march=rv32imc -mabi=ilp32`；该
smoke 的 `main.c` 只做无副作用 CSR probe/status poll。

同一环境检查也可由 `scripts/verify_efinity_toolchain.ps1 -BuildSmoke` 一键
复现；该脚本只保留版本摘要和 smoke 产物统计，不启动 Vivado/Efinity map。
Makefile 支持 `SOC_INCLUDE`/`SOC_HEADER` 注入生成 BSP 的 `soc.h`，并允许
显式 `C1_ACCEL_MMIO_BASE=0x...` 覆盖，避免把占位地址写死到源码。

本轮 housekeeping 已将 `../src/c1_accel.c` 显式映射为 `build/c1_accel.o`，新构建不再由
模式规则把对象文件落到 `software/src`；因此 `make clean` 可完整清理本次构建的
生成对象（旧版本遗留文件需单独清理）。该结果只证明本机 GCC/objcopy/链接脚本能够产出 RV32 固件，不是最终 Sapphire
BSP、CPU 启动、真实 APB 访问或板卡 PASS。IP Manager 生成 Soft Sapphire 后，
必须用生成 BSP 的 `startup.S` 和 linker script 替换 smoke 工程中的最小版本，
并从生成的 `soc.h`/address map 设置 `C1_ACCEL_MMIO_BASE`；不得继续依赖占位
地址 `0xf8100000`。硬件生成参数、`soc.h`、startup、linker 和
`-march/-mabi` 必须保持成套匹配，最终 `.elf/.hex` 再交由生成工程进行片上 RAM
初始化。`build/` 可用 `make clean` 删除，不应视为 BSP 或 bitstream 产物。

### 2026-08-28：Icarus/GTKWave boardless interoperability smoke

用户更新 Icarus 安装后，`D:\iverilog\bin` 实测为 Icarus Verilog **14.0
(devel)**、VVP 14.0 和 GTKWave 3.3.128。新入口
`scripts/run_iverilog_smoke.ps1 -TrySapphireAdapter` 在 `%TEMP%` 的一次性目录中
完成以下 marker：

```text
C1_IVERILOG_VERILOG2005_PASS
C1_IVERILOG_SYSTEMVERILOG_PASS flag=-g2012
C1_SAPPHIRE_APB_ADAPTER_PASS
C1_IVERILOG_SMOKE_PASS
```

该结果说明当前 Icarus 能够编译/运行一个纯 Verilog-2005 smoke，并能编译现有
APB/IRQ vendor seam；它不是 Soft Sapphire 加密 CPU 的仿真结果，也不是 Efinity
`rtlsim`/`mapsim` 的生成工程结果。所有中间 `.vvp`/VCD 默认在脚本结束时删除；
只有显式 `-KeepVcd` 才保留一个小波形。当前 Case-1 其余 251 个 RTL 文件仍是
SystemVerilog，主回归继续使用 Vivado/xsim；Efinity 生成的加密 Sapphire RTL
仍需 ModelSim/Questa/Aldec。

同一阶段还在仓库外的一次性目录用 Efinity 通用 `efx_run_sim.py` 跑过官方
`helloworld.v`/`helloworld_tb.v` 纯 Verilog 示例：`rtlsim` 走 Icarus fallback，
`helloworld.rtl.simlog` 出现 `Helloworld Passed` 且进程退出 0；`work_sim` 和
`outflow` 随后删除。该小实验确认 Efinity↔Icarus 的**通用未加密 Verilog**路径
可用，不改变“Soft Sapphire 加密 RTL 需 ModelSim/Questa/Aldec、Case-1 主线用
xsim”的边界，也没有运行 `compile/full` 或 P&R。

### 2026-08-28：native helper=all registered PRECLAMP full-top A/B

native helper=all 修复了此前 full-top Vivado 在 HDL 处理前无法解析
`common.tcl` 的 runtime failure；以下两次严格 proxy 均完成综合并生成完整
utilization/timing 报告。除 `PRECLAMPED_TAP_COORDS` 外，配置相同（beat-record、
`RSP_FIFO_DEPTH=64`、strict descriptor、pipelined address/decoder/size arithmetic、
fixed limits、dot-tree full、narrow return、abort reset、fatal ticket），part 为
`xc7a200tsbg484-1`、frame 为 `640×480`：

| run | PRECLAMP | LUT/FF/BRAM/DSP | WNS | TNS | 状态 |
|---|---:|---|---:|---:|---|
| `baseline_helper_all_v1` | 0 | `47512/34821/32/85` | `-1.079 ns` | `-20.120 ns` | `timing_failed` |
| `preclamped_registered_helper_all_v1` | 1 | `47443/34784/32/81` | `-1.079 ns` | `-15.868 ns` | `timing_failed` |

delta（registered − baseline）为 LUT `-69`、FF `-37`、BRAM `0`、DSP `-4`、
WNS `0.000 ns`、TNS `+4.252 ns`。这说明 registered preclamp 在该 proxy
配置下减少资源且没有恶化 WNS，TNS 违例量有所降低，但两组 WNS 仍为负，且
均为 synthesis-only `timing_failed`；helper=all 是运行环境修复，不是 RTL
时序闭合。该结果属于 Xilinx Artix-7 `xc7a200tsbg484-1` proxy、无 P&R，不能
当作 Ti60/Efinity 资源或 timing signoff；`PRECLAMPED_TAP_COORDS` 仍默认关闭。

### 2026-08-28：默认 BFM 可选 QoS 层级保护与 Icarus 全 RTL 编译烟测

本阶段修复了一个**测试台可选层级保护问题**：当未定义
`C1_SHARED_QOS_MONITOR` 时，portable-SoC BFM 仍在 `$display` 中直接引用
`dut.g_shared_qos_monitor.u_monitor`，会使默认配置在 xelab 阶段失败。现已用
条件编译包住该层级；关闭 monitor 时输出固定的
`monitor_active=0 monitor_frame=0`，不改变 DUT/默认 RTL 接线。

修复后的默认 8×8 单帧 detached xsim 通过：

```text
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS frame=8x8 done=1 swaps=1 drops=0 descriptors=22 stage_mask=1fffff display_done=1
AXI aw/w/b/ar/r=852/868/852/1119/2199
```

随后用 `-TwoFrame -SharedQosMonitor -TensorBurstRefill -TensorBurstBeatMode
-DisplayResponseFifo -PreclampedTapCoords` 做了一个 8×8 两帧可选路径闭环，
结果为 `done=2/swaps=2/drops=0/descriptors=44/protocol=0`，并完成 QoS APB
读回；该诊断配置仍报告 `deadline_miss=2/underflow=2`，所以不能作为 15 fps
候选通过，只能说明 burst beat-record、display FIFO、QoS 观测和 preclamp 在
小帧上可拼接。临时 xsim runRoot 已由 detached runner 删除。

新增 `scripts/run_iverilog_rtl_compile.ps1`：按固定顺序先编译四个 package，
再编译其余 RTL，并以 `c1_r1_portable_soc` 为顶层。实测结果为 Icarus 14.0
(devel)、127 个 SystemVerilog 源、`-g2012`、`exit_code=0`、596 条兼容性
告警、0 个错误，输出 marker 为 `C1_IVERILOG_RTL_COMPILE_PASS`。告警主要是
 constant-select sensitivity 与 `$fatal` 综合提示；它不代表 Efinity 资源或
时序结论。response file、诊断和 VVP 均在 `%TEMP%` 一次性目录中，退出后清理。
详见 `efinity/IVERILOG_RTL_COMPILE.md`。

同日重新执行 `scripts/run_python_regression.ps1`，21 个 Python/golden 命令全部
通过（`C1_PYTHON_REGRESSION_PASS commands=21`）；该结果只更新板前算法/模型回归
证据；engine+arena 的小尺寸逐阶段 RTL bit-exact 已由下方独立回归闭合，tensor
adapter/portable SoC/native 长帧仍未闭合。

新增 `scripts/probe_microstyle_artifact.py` 做了一个有界的 trained-artifact
参考探针：native 22 个 descriptor 与冻结 layout 一致，arena 为 16,896 bytes；
8×8 确定性 RGB 输入经同一整数权重路径得到 22 个阶段张量，输出样本首像素为
`[104, 103, 110]`，脚本返回 `status=PASS`。这是 Python integer golden
证据，不等价于 RTL 逐层 bit-exact。

随后新增 `golden/generate_microstyle_engine_bitexact_vectors.py` 与
`scripts/run_r1_microstyle_engine_artifact_8x8_xsim_detached.ps1`，将同一真实
parameter arena 配合 `8×8` 缩放 descriptor 拓扑送入 RTL engine。detached xsim
完成 22 个 trained descriptor、16,896-byte arena、896 个输入窗口/残差记录和
836 个逐阶段输出的逐拍比较：

```text
C1_R1_MICROSTYLE_ENGINE_ARTIFACT_8X8_PASS stages=22 records=896 outputs=836 cycles=28276
```

该结果把 trained artifact→RTL engine 的 bit-exact 边界从“待接入”推进为已闭合的
小尺寸证据；仍不覆盖 tensor adapter 地址/缓存、portable SoC 共享 DDR、native
`640×480` 全帧或 15 fps。向量和 xsim runRoot 均为小体积/一次性目录，runner
结束后自动清理。

在此基础上新增 `sim/tb_c1_r1_microstyle_artifact_tensor_engine_8x8.sv` 与
`scripts/run_r1_microstyle_artifact_tensor_engine_8x8_xsim_detached.ps1`。该独立
probe 将同一组 22 个 descriptor、16,896-byte parameter arena 和确定性 8×8
输入图像接入真实 tensor adapter；adapter 的地址/窗口/残差调度驱动真实
`c1_r1_microstyle_cnn_top`，中间结果经小型三 bank DDR BFM 写回并供下一 stage
读取，所有 engine operand 与逐阶段 output 均逐拍比较。detached xsim 和
Icarus 14.0 同一 TB 均通过：

```text
C1_R1_MICROSTYLE_ARTIFACT_TENSOR_ENGINE_8X8_PASS stages=22 operands=896 results=836 final=64 cycles=46326 stage_done=22
```

这闭合了当前板前最小的 trained artifact→adapter→engine→tensor write-back
正确性边界；仍是 8×8、单 outstanding、无共享七客户端仲裁的功能证据，不覆盖
portable SoC 全生命周期、native 640×480、burst/多 outstanding、QoS、时序或
15 fps。runner 使用 WMI 失败时的 `CREATE_BREAKAWAY_FROM_JOB` fallback，且
Vivado/xsim 工作目录在结束后自动删除。

### 2026-08-29：production parameter-bank 的 stage-0→stage-1 handoff

在上述 8×8 全链 probe 之后，新增同一测试台的 `C1_USE_PARAMETER_BANK` 与
`C1_STAGE1_HANDOFF` 分支，专门把“真实参数 Bank”和“中间 tensor 跨 stage
写回/读入”组合起来。测试台仍保留完整 22 个 descriptor 和原始向量 ABI，
但将动态截点限定为：stage 0 完成 4×4×2 的 32 个 bank-1 output group，stage 1
首像素完成两个输入 group 的 18 次 3×3 tap 读取，再写回三个 output group。
BFM 检查每个 bank/local word 的顺序和已写入位图，scoreboard 同时逐项检查
stage/output 的 x/y、group-last 及 SOF/EOL/EOF 边界；最后一个 stage-1 写响应被
刻意延迟 3 个周期，验证 abort 只等待/排空已接受 response，不会丢 pending
事务或产生偶发死锁：

```text
C1_R1_STAGE1_HANDOFF_8X8_PASS frame=8x8 stages=22 operands=18 results=35 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=18 stage1_inputs=2 stage1_writes=3 stage1_outputs=3 stage_done=1 abort=1 abort_response_delay=3 group0=0100050300000005 group1=0000010208020002 group2=0300000000010200 boundary=SCALED_STAGE0_COMPLETE_PLUS_STAGE1_FIRST_PIXEL_BANK_HANDOFF
```

`stage1_handoff_metadata_final_20260829` 的 detached Vivado/xsim 与
`run_iverilog_stage1_handoff.ps1` 默认模式均通过，xvlog/xelab/xsim stderr
为空，私有 runRoot 已删除。该专项闭合的是 production bank/跨 stage 地址、
元数据、算术向量和 abort-drain 边界；仍不等于 stage 1 全部 2×2 输出、
stage 2–21、native 640×480、共享 DDR QoS、100 MHz 时序或 15 fps。

复现入口为 `scripts/run_r1_stage1_handoff_xsim_detached.ps1`，详细拓扑、
计数和停止条件见 `STAGE1_HANDOFF_PREFLIGHT.md`。

同一分支随后以 `-FullStage1` 扩展到 stage 1 的完整 2×2 输出。该模式仍保持
22-stage 配置屏障和 8×8 向量 ABI，只把停止点推迟到 stage 1 EOF：

```text
C1_R1_STAGE1_FULL_8X8_PASS frame=8x8 stages=22 operands=24 results=44 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage_done=2 abort=1 abort_response_delay=3 first_group=0100050300000005 last_group=0001010003030000 boundary=SCALED_STAGE0_COMPLETE_PLUS_STAGE1_FULL_2X2_HANDOFF
```

`stage1_full_metadata_final_20260829` 的 detached xsim 和同宏 Icarus 运行均通过。
这证明 stage 1 全部 12 个 group 的地址/数据/EOF 顺序及跨 bank 写回，但仍不
启动 stage 2–21 或 native 长帧。

### 2026-08-29：production parameter-bank 的 stage-2 full handoff

在 stage-1 完整 2×2 交接稳定后，将停止点再推迟到 descriptor 2
`res0.expand1x1` 的 EOF。`C1_STAGE2_FULL` 自动启用 `C1_STAGE1_FULL`，因此同一
次运行先完成 stage 0 的 32 个 bank-1 group 和 stage 1 的 12 个 bank-0 group，
再从被 stage 1 覆盖的 bank0 低地址读取 stage 2 的 12 个 C8 输入 group。由于
stage 2 是 1×1 opcode，adapter 每个像素/输入 group 只发 center-tap read；输出
为 2×2×6=24 个 bank-1 group。测试台用独立 `bank0_stage1_written_q` provenance
bitmap，避免把早先的 source bank0 写入误计为 stage-1 数据：

```text
C1_R1_STAGE2_FULL_8X8_PASS frame=8x8 stages=22 operands=36 results=68 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage2_reads=12 stage2_inputs=12 stage2_pixels=4 stage2_writes=24 stage2_outputs=24 stage_done=3 abort=1 abort_response_delay=3 first_group=0c00000631000031 last_group=00010000210a0000 boundary=SCALED_STAGE0_STAGE1_COMPLETE_PLUS_STAGE2_FULL_2X2_HANDOFF
```

`stage2_full_metadata_final_20260829` 的 detached Vivado/xsim 通过，Icarus 同宏
运行也通过；xvlog/xelab/xsim stderr 为空，marker 唯一，stage-2 最后写响应固定
延迟 3 周期后仍完成 adapter/engine/memory drain。该证据只覆盖 stage 0–2 的
production-bank handoff、1×1 地址/算术和元数据，不启动 stage 3–21、完整
22-stage production-bank 全链、native 640×480、burst/multi-outstanding、QoS、
100 MHz 时序或 15 fps。复现命令与停止条件见 `STAGE2_HANDOFF_PREFLIGHT.md`。

### 2026-08-29：production parameter-bank 的 stage-3 full handoff

本轮再将停止点推迟到 descriptor 3 `res0.depthwise3x3` 的 EOF。`C1_STAGE3_FULL`
自动蕴含 stage-1/2 full：stage 2 的 24 个 bank-1 output group 先被独立
`bank1_stage2_written_q` 标记，stage 3 再按 2×2 raster、6 个输入 group、每组 9
个 SAME_REPLICATE tap 读取，共 216 次 tensor read，最后向 bank2 写回 24 个 group。
边界处物理地址重复是 replicate 语义的一部分，测试台明确不做去重：

```text
C1_R1_STAGE3_FULL_8X8_PASS frame=8x8 stages=22 operands=60 results=92 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage2_reads=12 stage2_inputs=12 stage2_pixels=4 stage2_writes=24 stage2_outputs=24 stage3_reads=216 stage3_inputs=24 stage3_pixels=4 stage3_writes=24 stage3_outputs=24 stage_done=4 abort=1 abort_response_delay=3 first_group=19090000110c0021 last_group=0300300f00040000 boundary=SCALED_STAGE0_STAGE1_STAGE2_COMPLETE_PLUS_STAGE3_FULL_2X2_HANDOFF
```

`stage3_full_metadata_final_20260829` 的 detached Vivado/xsim 通过，Icarus 同宏
运行也通过；xvlog/xelab/xsim stderr 为空，marker 唯一，最后一个 stage-3 写响应
固定延迟 3 周期后完成 adapter/engine/memory drain。该证据只覆盖 stage 0–3 的
production-bank handoff、depthwise 地址/算术和元数据，不启动 stage 4–21、完整
22-stage production-bank 全链、native 640×480、burst/multi-outstanding、QoS、
100 MHz 时序或 15 fps。复现命令与停止条件见 `STAGE3_HANDOFF_PREFLIGHT.md`。

同一源码随后回归 `stage2_full_post_stage3_20260829`、
`stage1_full_post_stage3_20260829` 和 `artifact_tensor_8x8_post_stage3_20260829`；
三项 detached xsim 均为 `state=complete`、exit 0、stderr 为空且私有 runRoot
已清理，确认新增 stage-3 分支没有改变既有 stage-1/stage-2/default 行为。

### 2026-08-29：production parameter-bank 的 stage-4/5/6 full handoff

本轮把停止点从 stage 3 EOF 推进到第一个残差块尾部和下一个扩展层。三个
`FullStageN` 开关均保持完整 22-stage 配置屏障，并由高编号宏自动包含所有前置
阶段：

- stage 4 `res0.project1x1`：2×2、C48→C24，bank2→bank1；24 个 center-tap
  reads、12 个 output writes；
- stage 5 `res0.add_relu`：2×2、C24→C24，bank1 primary 与 bank0 residual
  各 12 reads，合计 24 reads，向 bank2 写 12 个 group；
- stage 6 `res1.expand1x1`：2×2、C24→C48，bank2→bank0；12 个 center-tap
  reads、24 个 output writes。

三个 detached xsim run 的 marker 如下（Icarus 同宏运行也通过）：

```text
C1_R1_STAGE4_FULL_8X8_PASS frame=8x8 stages=22 operands=84 results=104 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage2_reads=12 stage2_inputs=12 stage2_pixels=4 stage2_writes=24 stage2_outputs=24 stage3_reads=216 stage3_inputs=24 stage3_pixels=4 stage3_writes=24 stage3_outputs=24 stage4_reads=24 stage4_inputs=24 stage4_pixels=4 stage4_writes=12 stage4_outputs=12 stage_done=5 abort=1 abort_response_delay=3 first_group=fefe0100fd00fe03 last_group=fffffcfd0100fd03 boundary=SCALED_STAGE0_STAGE1_STAGE2_STAGE3_COMPLETE_PLUS_STAGE4_FULL_2X2_HANDOFF
C1_R1_STAGE5_FULL_8X8_PASS frame=8x8 stages=22 operands=96 results=116 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage2_reads=12 stage2_inputs=12 stage2_pixels=4 stage2_writes=24 stage2_outputs=24 stage3_reads=216 stage3_inputs=24 stage3_pixels=4 stage3_writes=24 stage3_outputs=24 stage4_reads=24 stage4_inputs=24 stage4_pixels=4 stage4_writes=12 stage4_outputs=12 stage5_reads=24 stage5_main_reads=12 stage5_residual_reads=12 stage5_inputs=12 stage5_pixels=4 stage5_writes=12 stage5_outputs=12 stage_done=6 abort=1 abort_response_delay=3 first_group=0000060300000008 last_group=0000000004030003 boundary=SCALED_STAGE0_STAGE1_STAGE2_STAGE3_STAGE4_COMPLETE_PLUS_STAGE5_FULL_2X2_HANDOFF
C1_R1_STAGE6_FULL_8X8_PASS frame=8x8 stages=22 operands=108 results=140 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage2_reads=12 stage2_inputs=12 stage2_pixels=4 stage2_writes=24 stage2_outputs=24 stage3_reads=216 stage3_inputs=24 stage3_pixels=4 stage3_writes=24 stage3_outputs=24 stage4_reads=24 stage4_inputs=24 stage4_pixels=4 stage4_writes=12 stage4_outputs=12 stage5_reads=24 stage5_main_reads=12 stage5_residual_reads=12 stage5_inputs=12 stage5_pixels=4 stage5_writes=12 stage5_outputs=12 stage6_reads=12 stage6_inputs=12 stage6_pixels=4 stage6_writes=24 stage6_outputs=24 stage_done=7 abort=1 abort_response_delay=3 first_group=0804000900100400 last_group=0004000300000001 boundary=SCALED_STAGE0_STAGE1_STAGE2_STAGE3_STAGE4_STAGE5_COMPLETE_PLUS_STAGE6_FULL_2X2_HANDOFF
```

对应 run ID 为 `stage4_full_metadata_final_20260829`、
`stage5_full_metadata_final_20260829` 和 `stage6_full_metadata_final_20260829`。
三个 run 的 xvlog/xelab/xsim exit code 均为 0，stderr 文件均为空，私有 xsim
runRoot 均已删除，检查时没有残留 Vivado/xsim/vvp 进程；Icarus 的 vectors/vvp
一次性目录也已清理。最后一个 stage-6 写 response 被固定延迟 3 周期，三个门均
完成 adapter/engine/memory abort drain。

同一源码随后以无 handoff 宏运行 `artifact_tensor_8x8_post_stage6_20260829`：
`C1_R1_MICROSTYLE_ARTIFACT_TENSOR_ENGINE_8X8_PASS stages=22 operands=896
results=836 final=64 stage_done=22`；并以 Icarus 回归了 stage-1 首像素、stage-1
完整 2×2、stage-2/3/6 full 及多开关优先级，均保持 PASS。

该小节证据闭合的是 8×8 缩放拓扑中 stage 0→6 的 production-bank 地址、算术、
residual-bank 选择、反复覆盖后的 provenance 和输出元数据；stage 7 的独立证据
见下节。不外推到 stage 8–21、完整 native 640×480 CNN、AXI
burst/multi-outstanding、共享 DDR QoS、100 MHz 时序或 15 fps。复现命令与停止
条件见 `STAGE4_6_HANDOFF_PREFLIGHT.md`。

### 2026-08-29：production parameter-bank 的 stage-7 full handoff

在 stage 6 的 `res1.expand1x1` 之后，本轮继续验证 `res1.depthwise3x3`：
2×2、C48→C48、6 个 C8 groups，adapter 从 bank0 读取 stage-6 写回的窗口，
再向 bank1 写出 24 个 output groups。每个 operand record 保留 9 个
SAME_REPLICATE tap，因此 stage-7 memory 计数是 216 reads / 24 writes；
`bank0_stage6_written_q` 与 `bank1_stage7_written_q` 分别锁定生产者来源和
本阶段写回，避免低地址覆盖后误读旧 stage 内容。

Icarus 与 detached Vivado/xsim 均通过，marker 为：

```text
C1_R1_STAGE7_FULL_8X8_PASS frame=8x8 stages=22 operands=132 results=164 source_writes=64 stage0_reads=144 stage0_writes=32 stage1_reads=72 stage1_inputs=8 stage1_pixels=4 stage1_writes=12 stage1_outputs=12 stage2_reads=12 stage2_inputs=12 stage2_pixels=4 stage2_writes=24 stage2_outputs=24 stage3_reads=216 stage3_inputs=24 stage3_pixels=4 stage3_writes=24 stage3_outputs=24 stage4_reads=24 stage4_inputs=24 stage4_pixels=4 stage4_writes=12 stage4_outputs=12 stage5_reads=24 stage5_main_reads=12 stage5_residual_reads=12 stage5_inputs=12 stage5_pixels=4 stage5_writes=12 stage5_outputs=12 stage6_reads=12 stage6_inputs=12 stage6_pixels=4 stage6_writes=24 stage6_outputs=24 stage7_reads=216 stage7_inputs=24 stage7_pixels=4 stage7_writes=24 stage7_outputs=24 stage_done=8 abort=1 abort_response_delay=3 first_group=0000080000000000 last_group=0300000001000000 boundary=SCALED_STAGE0_STAGE1_STAGE2_STAGE3_STAGE4_STAGE5_STAGE6_COMPLETE_PLUS_STAGE7_FULL_2X2_HANDOFF
```

对应 xsim run ID 为 `stage7_full_metadata_final_20260829`；xvlog/xelab/xsim
exit code 均为 0，marker 唯一，stderr 为空，私有 runRoot 和模拟器进程均已
清理。stage 6、stage 3 和默认首像素 Icarus 兼容回归也保持 PASS。

该证据将边界推进到 stage 0→7，但仍不外推到 stage 8–21、native 640×480
全网、AXI burst/multi-outstanding、共享 DDR QoS、100 MHz 时序或 15 fps；
复现命令、地址公式和存储卫生约束见 `STAGE7_HANDOFF_PREFLIGHT.md`。

为给可选 `FIXED_DESCRIPTOR_SIZE_LIMITS` 增加独立数学护栏，
`golden/test_descriptor_format.py` 还检查 8 MiB bank 下 8/16/24/32/40/48
bytes-per-group 的阈值等号、越界一位、代表性内部点和非法 group；本地结果为：

```text
C1_DESCRIPTOR_SIZE_LIMITS_PASS groups=6 boundary_checks=36
```

该检查不改变默认 RTL，也不等价于 Vivado/Efinity 时序闭合。

### 2026-08-28：真实 trained artifact 进入 portable SoC 8×8 全生命周期

继续使用现有 `tb_c1_r1_portable_soc_cache_ddr_bfm.sv`，新增默认关闭的
`C1_TRAINED_ARTIFACT`/`-TrainedArtifact` 分支。该分支从生成的
`descriptors.mem` 和 `parameter_arena.mem` 装载真实工件，保持生产 8 MiB/bank
地址合同；不改变默认零参数回归。detached Vivado/xsim 运行通过：

```text
C1_R1_PORTABLE_SOC_TRAINED_ARTIFACT_8X8_PASS descriptors=22 weight_ar=66 axi_r=2199 done=1 stage_mask=1fffff
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS frame=8x8 done=1 swaps=1 drops=0 descriptors=22 stage_mask=1fffff display_done=1
```

这证明真实参数确实经过 parameter loader/共享七客户端 AXI，并与 boardless
input/output DMA、tensor adapter、MicroStyle engine、display prefetch 和
ownership drain 一起完成 8×8 生命周期；它不是 Python 输入/输出逐像素
bit-exact 证明，也不是 native 640×480、15 fps 或 Ti60 实板 signoff。运行采用
detached worker，xvlog/xelab/xsim 结束后自动删除私有 runRoot，仅保留小型状态和
日志。

### 2026-08-28：native 640×480 artifact ABI preflight runner 修复

随后修复 `run_r1_microstyle_artifact_abi_xsim_detached.ps1` 的两个板前问题：
当 WMI 创建进程被策略拒绝时改用 `CREATE_BREAKAWAY_FROM_JOB` fallback；同时将
native ABI 向量复制到 disposable runRoot，避免 xsim 依赖工作目录外的相对路径，
并在成功/失败后清理完整仿真工程。新的 detached 运行通过：

```text
C1_R1_MICROSTYLE_ARTIFACT_ABI_PASS stages=22 param_bytes=16896 param_words=1056 param_payload_bytes=16379 nonzero_words=1030 param_reads=1030 cache_writes=1030 boundary=RTL_DECODER_SCHEDULER_ARENA_ONLY_NATIVE_640x480
C1_R1_PARAMETER_SCHEDULER_DIRECTED_PASS negative=6 validate_aborts=1 captured_configs=1
```

这只是 native descriptor/parameter scheduler 边界，不是 640×480 数据平面 CNN
长帧；后续仍需在受控周期/流量预算下验证 tensor adapter、共享 AXI、QoS 和
15 fps。

同日新增纯标准库静态护栏 `golden/test_native_artifact_abi.py`，从文件级再次核对
训练工件与 RTL ABI：

```text
C1_NATIVE_ARTIFACT_ABI_PASS native_geometry=640x480 descriptor_count=22 descriptor_bytes=1408 arena_bytes=16896 payload_bytes=16379 scheduler_read_words=1030 scheduler_last_word=1052 affine_values_checked=926 descriptor_mem_records=22 parameter_mem_words=1056 boundary=descriptor/parameter ABI only; native data-plane CNN remains unrun
```

该检查同时反向解析 `.mem` 镜像并验证对齐填充、signed18 multiplier、shift 范围和
manifest 元数据；不启动长帧仿真，也不改变默认 RTL 行为。

### 2026-08-28：native descriptor/parameter commit staged preflight

为避免把已有的 synthetic parameter leaf 误认为真实工件已进入 native 路径，新增
`sim/tb_c1_r1_native_artifact_preflight.sv`。该 TB 直接读取真实 native
`descriptors.mem`/`parameter_arena.mem`，逐项检查 22 个 descriptor 的 decoder
投影、层间 shape continuity、Conv/DW/1×1/Upsample/Residual/RGB 几何以及参数
偏移范围；随后用 production `c1_axi_parameter_loader` 和
`c1_r1_parameter_bank` 完成 16,896 B arena 的 AXI 传输和原子提交。AR/R 与 bank
回压均被刻意启用，且只保留少量边界读回，不产生大波形：

```text
C1_R1_NATIVE_ARTIFACT_PREFLIGHT_PASS frame=640x480 stages=22 descriptor_count=22 parameter_bytes=16896 parameter_words=1056 parameter_nonzero_words=1030 bursts=66 beats=1056 ar_stalls=23 r_stalls=242 generation=1 boundary=DESCRIPTOR_CONTINUITY_PLUS_PARAMETER_COMMIT_ONLY
```

对应 detached runner 为
`scripts/run_r1_native_artifact_preflight_xsim_detached.ps1`；`-CompileOnly` 只做
xvlog/xelab，普通运行再做上述有界 xsim。WMI 失败时使用
`CREATE_BREAKAWAY_FROM_JOB` fallback，worker 退出时删除 sibling vectors/runRoot。
该证据仍不覆盖 tensor 数据平面、native 逐像素 CNN、portable SoC 七客户端 QoS、
时序或 15 fps；下一阶段应先做首层/末层有限窗口，再评估是否值得启动长帧。

### 2026-08-29：production-bank stage-8…stage-21 handoff 收口

本轮把 8×8 scaled trained-artifact 的停止点从 stage-7 推进到完整 22-stage
链末端。测试台新增 stage-8…20 的 producer bitmap/地址/offset/响应计数，
对 stage-9 与 stage-13 的 residual bank 来源分别锁定为 stage-5 与 stage-9
写回；stage-11/15/18/20 使用 3×3 `SAME_REPLICATE` 的逐 tap 地址，stage-14/17
使用 upsample 的 floor 坐标，stage-21 检查 final RGB stream 的 raster/SOF/EOL/EOF。

Icarus runner 的 14 个终点全部通过，累计计数如下：

```text
stage8  156/176  done=9
stage9  168/188  done=10
stage10 180/212  done=11
stage11 204/236  done=12
stage12 228/248  done=13
stage13 240/260  done=14
stage14 288/308  done=15
stage15 336/356  done=16
stage16 384/388  done=17
stage17 512/516  done=18
stage18 640/644  done=19
stage19 768/708  done=20
stage20 832/772  done=21
stage21 896/836  final=64 done=22
```

14 行 marker 的紧凑留档见
`logs/stage1_handoff_runs/stage8_21_iverilog_regression_20260829.log`；不保存
Icarus vvp、波形或逐像素 stdout。

中间 stage 的最后写响应统一延迟 3 周期后执行 protocol-safe abort/drain；
stage-21 不写 tensor bank，64 个 RGB beat 正常完成，`abort=0`。复现命令为：

```powershell
Set-Location D:\contest\2026FPGA\yilingsi\case1
& .\scripts\run_iverilog_stage1_handoff.ps1 -FullStage8
& .\scripts\run_iverilog_stage1_handoff.ps1 -FullStage21
& .\scripts\run_r1_stage1_handoff_xsim_detached.ps1 -FullStage14 -RunId stage14_full_handoff_20260829
& .\scripts\run_r1_stage1_handoff_xsim_detached.ps1 -FullStage21 -RunId stage21_full_handoff_final_20260829
```

detached xsim 的 stage-14、stage-21 marker 均唯一，xvlog/xelab/xsim exit code
均为 0，stderr 为空；worker 完成后私有 runRoot、vectors、snapshot 和波形均已
删除。该结果闭合的是 scaled 8×8 production-bank handoff 语义，不是 native
640×480 full CNN、真实 DDR3/Efinity IP、100 MHz 时序或 15 fps。
