# 系统性能归因与修复后回归

日期：2026-09-10。此次增加 testbench 观测，不改变生产 RTL 的默认参数，不把观测用计数器带入综合。

## 计数边界

`tb_c1_r1_portable_soc_cache_ddr_bfm.sv` 在 boardless start 握手后开始计数，到 boardless done 或控制错误事件结束；不计 start 所在边沿，计入结束边沿。显示 swap/new-done 使用同一个 core 周期坐标单独记录，不强行归入“当前 job”，因为上一帧显示可以与下一帧计算重叠。

bridge busy 内的 adapter→engine valid/ready 分成四个互斥桶：

| 桶 | valid/ready | 含义 |
|---|---|---|
| feed | 1/1 | 接受一个输入操作数组 |
| input_wait | 0/1 | engine 可接收，adapter 尚无有效输入 |
| engine_hold | 1/0 | adapter 有有效输入，engine 暂不接收 |
| neither | 0/0 | 双方都未呈现可传输条件，包括阶段控制等 |

四桶之和必须等于 bridge busy 周期，仿真中检查此不变量。这不是 MAC 活跃/空闲计数：尤其不能把 engine_hold 全归因于计算，也不能把 input_wait 全归因于外部 DDR。

另记录 tensor **逻辑接口**的读写请求数、请求/响应回压，以及结果接口回压。这些计数与上面四桶重叠，不能相加计算总时延；逻辑请求数不等于外部 AXI 事务数，缓存命中也会消耗逻辑请求。

runner 保留少量 `C1_PERF_` 行和日志尾部，运行结束自动删除临时仿真工程；不保存逐像素日志或波形。

## 已完成验证

- 修复后 Icarus 统一回归重新运行：`C1_REVIEW_FIXES_REGRESSION_PASS configurations=86`，exit 0。
- 训练参数 8×8 完整便携 SoC：`review_perf_trained_20260910`，complete / exit 0，22 descriptors、66 weight AR、done=1、swap=1、drop=0。
- 此配置的完整 22 阶段任务耗时 66772 core cycles（测试时钟 100 MHz，即 0.66772 ms）。bridge=65819；feed/input_wait/engine_hold/neither=896/36913/12591/15419，四桶和一致。
- 逻辑 tensor 读/写=3620/836；请求回压=128、响应回压=0、结果回压=1758 cycles。
- 任务 done 在 cycle 70424，首次 swap 在 1732508，新图预取 done 在 2026332。可见该小图配置中的系统/显示等待远长于计算任务，不能拿完整监控窗口作为 CNN 推理耗时。

以上是缩小图像测试，不代表 native 全网络吞吐。训练参数 SoC 用例也不能替代独立 full-network golden 的逐数值检查。

## Burst refill 对照

`review_perf_trained_burst_20260910` 同样 complete / exit 0；与基线唯一运行开关差异是 `-TensorBurstRefill`。两者均启用显示 response FIFO 与 fabric read response skid。

| 观测量 | 基线 | Burst refill |
|---|---:|---:|
| 任务周期 | 66772 | 52786 |
| 输入操作数握手 | 896 | 896 |
| 输入等待周期 | 36913 | 23530 |
| 逻辑 tensor 读/写请求 | 3620/836 | 3620/836 |
| 全系统 AXI AR/R | 1119/2199 | 749/1995 |
| 逻辑请求回压周期 | 128 | 1945 |
| 结果回压周期 | 1758 | 1154 |
| 显示 swap/new-done 周期 | 1732508/2026332 | 1732508/2026332 |

这个具体小图工作负载任务周期减少 20.95%（约 1.265× 任务加速），但显示交付时间完全相同。请求回压上升并不等于总性能下降；必须同时观察总周期及事务量。也不能将 AXI AR 的下降全解释为 burst 长度增加：该选项切换了完整 cache/refill 分支。

此证据支持继续评估 burst refill，而非立即修改生产默认值。需要在相同 64×48/native 工作负载、错误恢复及资源约束下进一步对照。

## 64×48 共享 DDR 复测完成

`review_perf_shared64_20260910`：complete / exit 0，381.909 s 墙钟；与此前共享 DDR 用例同配置（TwoFrame、DisplayResponseFifo、ConcurrentDisplayPrefetch、FabricReadResponseSkid、SharedQosMonitor）。本次没有开启 tensor burst refill，亦不是训练参数数值用例。

| 观测量 | Job 1 | Job 2 |
|---|---:|---:|
| 计算任务周期 | 2538954 | 2539621 |
| bridge 周期 | 2537987 | 2538653 |
| feed | 43008 | 43008 |
| input_wait | 1883269 | 1883927 |
| engine_hold | 10778 | 10775 |
| neither | 600932 | 600943 |
| 逻辑 tensor 读/写 | 173760/40128 | 173760/40128 |
| 结果回压周期 | 85190 | 85198 |

两帧 done/swap=2/2、drop=0、44 descriptors、underflow=0、protocol=0、monitor overflow=0；显示 AR 与计算重叠 96 次。AXI 事务量及最终 QoS 数值与此前无性能观测的相同配置一致，未改变激励和协议行为。

第二个任务 start/done 为 cycle 3856049/6395670，新图预取完成在 10781311。因此此前 **69.25 ms** 的窗口可以进一步分为：任务 **25.39621 ms**，随后到新图显示预取完成 **43.85641 ms**。后者还包含显示时序及预取工作，不应简单标成“纯等待”或“纯 DDR 时间”。配置的 1000000-cycle deadline 仍违约两次；这是测试所设阈值，不是自动按 15 fps 设置的阈值。

当前输入等待桶占 bridge 周期约 74%，支持下一步优先按阶段拆分 adapter 取窗、缓存补给、计算反压及地址状态机，而不是仅凭 MAC 数量扩大并行度。此处为基线记录；同配置 64×48 burst 对照已在下节追加，native 全网络/15 fps 仍未签核。

三次 xsim 的 worker 均已退出，临时 run 目录均不存在。64×48 本次仅保留 7 个小型日志/状态文件，共 18270 bytes，没有保留波形或仿真工程。

## 64×48 Burst refill 同负载对照

`review_perf_shared64_burst_20260910` complete / exit 0。与 `review_perf_shared64_20260910` 相比仅增加 `-TensorBurstRefill`，同为零参数生命周期工作负载、64×48 双帧共享 DDR。两者各帧的 43008 个输入操作数组、173760/40128 个逻辑读/写请求一致。

| 指标 | 基线 | Burst refill |
|---|---:|---:|
| Job 1 周期 | 2538954 | 1805251 |
| Job 2 周期 | 2539621 | 1805288 |
| Job 2 输入等待周期 | 1883927 | 1173705 |
| Job 2 结果回压周期 | 85198 | 61085 |
| 全系统 AXI AR/R | 96981/105308 | 60261/85724 |
| 全系统 AXI AW/W/B | 80448/83328/80448 | 80448/83328/80448 |
| 最近帧 QoS 周期 | 6925262 | 6925262 |
| done/swap/drop | 2/2/0 | 2/2/0 |
| underflow/protocol/overflow | 0/0/0 | 0/0/0 |
| 与计算重叠的显示 AR | 96 | 96 |

Job 2 计算任务从 25.39621 ms 降为 18.05288 ms，周期减少 **28.92%**，约 **1.407×** 任务加速。两帧显示 swap/new-done 的绝对周期完全相同；因此它改善了计算裕量，但没有改善该测试的最终显示交付时间。两个配置均有 2 次测试阈值 deadline miss，不能宣称已达 15 fps。

源码边界解释：该分支为可缓存 tap 提供行补给 burst，普通读写仍走 one-beat bridge，adapter 仍逐个逻辑请求推进。因此 AW/W/B 不变符合当前结构；下一步应针对普通 tensor 写入的打包、请求/完成解耦与阶段 drain 建立等价性验证，而不是认为补给 burst 已解决所有 DDR 短事务问题。

此处仍保留生产默认 `ENABLE_TENSOR_BURST_REFILL=0`。候选通过了这组双帧并发测试，不代表任意 DDR 延迟/CPU 争用、完整 native 数值或资源/时序签核。burst 运行的 worker 已退出，临时目录不存在，仅保留 7 个日志/状态文件，共 18320 bytes。

## Burst 分支维护边界追加验证

检查 `c1_tensor_window_cache_burst_axi_client` 的 owner/fence 连接后，补充缓存 miss 已预约 burst owner、但上游 tap 尚未接收时的**同时 abort + flush**用例。两者均为单周期脉冲，随后将重放的逻辑响应回压 12 周期，要求响应保持、两个完成信号不得提前出现；放行后各完成一次并最终 quiescent，继续观察 12 周期不得重复完成。

`tb_c1_tensor_window_cache_burst_axi_client.sv` 的原有单 abort/flush、cache hit、bypass 读写和回压用例保留。新增用例在 logical/beat 两种响应 FIFO 下均通过：

- `review_burst_dual_fence_20260910`：complete / exit 0。
- `review_burst_dual_fence_beat_20260910`：complete / exit 0。
- 两者均出现 `C1_TENSOR_CACHE_DUAL_FENCE_PASS held_response_cycles=12 abort=1 flush=1`；完整用例各 337 周期，flush/abort 完成总数 3/4。

另用完整 SoC 的 `-TensorBurstRefill -DisplayFaultRecovery -DisplayResponseFifo -FabricReadResponseSkid` 运行 8×8 故障/重启流程：`review_burst_display_recovery_20260910` complete / exit 0，注入 1 次错误、报告 1 次控制错误，最终 done=2、44 descriptors。该错误是显示故障，不代表对 burst refill 的全部 RRESP/畸形 RLAST 故障做了系统验证。

本次没有发现上述维护 join 必须修改的生产逻辑；只加强测试，不为了产生 RTL diff 改写已满足合同的状态机。独立 runner 的 WMI 启动在本机被拒，已增加现有 breakaway helper 回退（失败则停止，绝不转成绑定 Job 的仿真），并增加清理路径校验。修改后的 runner 实际启动 beat FIFO 测试通过，三个上述临时目录均已清理。
