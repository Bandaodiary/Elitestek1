# Tensor 结果写请求与提交解耦

日期：2026-09-10。此次实际修改生产 RTL，但新模式默认关闭；它为后续 AXI 写打包提供必要的上游并发，不是已完成 AXI 写打包。

> 后续进展：文末已追加实际 AXI 写打包候选及集成验证。上文保留“仅上游解耦”阶段的历史测量；打包分支现已接入，但默认仍关闭，尚未取得任务周期加速。

## 原因与接口合同

此前 adapter 每接受一组 C8 输出，都执行 WRITE_REQ→WRITE_RSP，等待真实写响应后才接收下一组。直接替换为等待两组数据的打包模块可能死锁；提前返回“成功”则会丢失真实 B 错误反馈和下一阶段的数据可见性保证。

新增 `PIPELINED_RESULT_WRITES=0/1`，追加在 adapter 与 portable SoC 的参数列表末尾，默认值与原有状态编码不变。模式开启时：

- 同一输出像素内的非末组，写请求被接受后即可继续接收下一组结果。
- 4-bit 计数器分别记录请求接受和真实响应退休，同周期发生时计数不变；只统计结果写，不混入采集写或读请求。
- 末组写之后等待计数归零，再读下一像素或切换 stage/cache 配置。每像素最多 8 个组，当前 48 通道模型实际最多 6 个。
- 响应错误保持 ERR_MEMORY=0x07；已呈现、尚未接受的请求不得撤回，随后在错误状态继续接收所有已接受写的响应。
- abort 也保留正在呈现的请求，并在全部响应排空后确认结束和恢复启动能力。

新增仿真断言检查并发上界、写请求/响应重叠的合法范围，以及读、换阶段、done/aborted/start-ready 不得越过提交屏障。下游必须按请求顺序、每请求返回恰好一个响应；该模式不支持无序响应或无响应 posted write。

## 修改入口

- `rtl/cnn/c1_r1_microstyle_tensor_adapter.sv`：计数、组内并发、提交屏障、错误/取消排空。
- `rtl/top/c1_r1_portable_soc.sv`：透传开关。尚未替换 tensor AXI 客户端。
- `sim/tb_c1_r1_microstyle_tensor_adapter.sv`：可配置深度的有序响应队列，以及并发写错误/取消测试。
- `sim/tb_c1_r1_portable_soc_cache_ddr_bfm.sv` 与 detached runner：增加 `-PipelinedResultWrites` 集成测试开关。
- `scripts/run_iverilog_review_fixes.ps1`：增加四个新模式配置，另支持 `-TestTop` 精确筛选本地定向回归。

## 验证结果

最终完整 Icarus 回归：`C1_REVIEW_FIXES_REGRESSION_PASS configurations=90`，exit 0。

| Adapter 配置 | 实测最大未完成请求 | 结果 |
|---|---:|---|
| 新模式，响应队列深度 8 | 6 | 22 阶段操作数/结果检查、错误/取消排空通过 |
| 新模式，深度 2 | 2 | 同上，覆盖容量限制下回压 |
| 新模式，深度 1 | 1 | 22 阶段检查通过，兼容单请求下游 |
| 新模式，地址与像素索引流水，深度 8 | 5 | 22 阶段检查、错误/取消排空通过 |

每次完整网络测试保留 448 个输入操作数、32 个最终像素及 memory 内容检查。额外的两类排空测试在至少两笔写未退休、后续写请求已呈现时，阻塞该请求 12 周期，分别触发 abort 与真实响应错误；要求请求保持、不能提前完成、计数归零且能重启。深度 1 不运行“至少两笔”的场景。

这是逻辑有序内存 BFM，不是 AXI packing 实测。BFM 的存储写入仍发生在请求接受边沿，但明确禁止任何读请求在响应队列非空时被接受；因此不能用提前可见的数据掩盖读越过提交屏障。

## 完整 SoC 小图复测与性能边界

`review_pipelined_writes_trained_20260910` complete / exit 0。8×8 训练参数、burst refill、显示 response FIFO、fabric read skid，再开启本次新模式：22 descriptors、66 weight AR、done/swap=1/1、drop=0。

与此前相同配置但关闭并发写的 `review_perf_trained_burst_20260910` 比较：

| 观测量 | 关闭并发写 | 开启并发写 |
|---|---:|---:|
| 任务周期 | 52786 | 53127 |
| 结果回压周期 | 1154 | 348 |
| 逻辑请求回压周期 | 1945 | 2944 |
| AXI AW/W/B | 852/868/852 | 852/868/852 |

结果接口的回压减轻，但计算任务总周期略增约 0.65%，**本轮不是吞吐加速签核**。原因边界是后端普通写仍单笔执行，新模式还增加了显式末组排空检查；目前没有写事务合并。不得默认启用，也不得将单独 adapter 的六笔并发外推为当前 SoC 的六笔 AXI outstanding。

下一阶段应接入真正的写打包路径，保持每组真实响应及阶段 drain，验证独立 AXI memory 提交结果、4 KiB 边界、写错误和取消，再比较同负载周期/事务数。原生全网络、持续显示、15 fps 和物理资源/时序均未因本轮通过而完成。

本次 xsim worker 已完成，临时 run 目录已删除；Icarus 使用的唯一临时镜像和生成向量也由 runner 清理，无波形保留。

## 追加：实际 AXI 写打包集成

新增 `rtl/dma/c1_tensor_mem_axi128_packing_bridge.sv`，关闭时直接实例化旧桥；开启时普通读保留旧单拍路径，写使用既有 write burst client。请求 FIFO=8、最多 4 个 AXI beats/事务、响应 FIFO=8、凑包超时=8 cycles；保留叶模块的 4 KiB 分拆与真实 B 后逐笔响应。读必须等待此前全部逻辑写响应被接收，不支持 posted write 或乱序响应。

`c1_tensor_window_cache_burst_axi_client` 同时增加默认关闭的 `ENABLE_PACKED_WRITES`。批内只允许连续写追加，读/缓存访问不得混入；原一位 bridge owner 占用状态扩展为计数，最后一个响应退休且没有同拍新请求时才释放 owner。维护信号阻止后续新请求，但保留维护边沿前已经呈现的请求并排空。取消不撤销已接受的写，写错误也不提供内存回滚。

便携 SoC 提供 `ENABLE_TENSOR_PACKED_WRITES`，runner 对应 `-TensorPackedWrites`，要求 `-TensorBurstRefill`。本轮测试还启用 `-PipelinedResultWrites`。默认开关均未改成 1。

### 证据

- Icarus 完整回归仍为 90 配置，exit 0。它主要验证已有默认路径和 adapter，并不包含下面新增的 xsim cache-owner 场景。
- `review_packed_pair_owner_v2_20260910` 与 `review_packed_pair_beat_20260910`：logical/beat 两种 refill 响应 FIFO 均通过四种场景（OKAY/SLVERR × 无维护/同时 abort+flush）。每场景两笔相邻逻辑写合成 **1 AW + 1 W + 1 B**；检查实际 WDATA 两半、全 WSTRB、AW 地址 0x1ff0，并检查两笔有序逻辑完成。
- 响应回压 12 周期期间不允许提前确认维护；第一笔逻辑响应后 owner 仍保留，第二笔后才可释放；错误必须传给两个逻辑响应。
- 初次 packed 用例暴露旧测试 helper 依赖 owner 驻留时间、而非实际请求握手来撤下 VALID 的问题。并发接口下这会重复提交请求。已修正 helper，保留严格事务数检查；修正后 legacy 回归 `review_packed_pair_legacy_v2_20260910` 同样通过。
- `review_packed_writes_trained_20260910`：8×8 训练参数 SoC complete / exit 0，22 descriptors、66 weight AR、done/swap=1/1、drop=0。
- `review_packed_writes_recovery_20260910`：完整 SoC 显示错误/重启 complete / exit 0，injected/errors=1/1、done=2、44 descriptors。

配套更新了 standalone runner、proxy Tcl 与 Efinity portable SoC XML 的源文件依赖。XML 实际解析通过，88 个 design_file 路径均存在且无重复；**没有因此重跑或宣称 Efinity 综合/时序通过**。

### 性能结果及边界

同一 8×8 训练参数、burst refill、并发结果写的配置，仅增开写打包：

| 指标 | 普通写桥 | 写打包桥 |
|---|---:|---:|
| 任务周期 | 53127 | 56627 |
| AXI AW/B | 852/852 | 708/708 |
| AXI W beats | 868 | 774 |
| 结果回压周期 | 348 | 120 |
| 逻辑 tensor 读/写 | 3620/836 | 3620/836 |

实际写事务减少约 16.9%，写数据拍减少约 10.8%，但任务周期增加约 6.6%。新路径引入队列及凑包等待；在当前短延迟 BFM 下减少事务尚未转化为总周期优势，不应将周期变化全部归因于单个因素，也不应默认启用此候选。

下一步需要用真实 adapter+独立 AXI memory 的逐数值读回、跨 4 KiB 和更多后端延迟场景验证，再比较凑包边界/超时策略。当前新增 pair 测试位于 4 KiB 边界前一拍，不等于新增了跨边界组合验证；叶模块既有边界测试不能替代整个组合签核。尚未完成原生全网络、持续显示、15 fps、CPU 争用和物理实现。

## 追加：打包桥独立物理内存与跨页验证

新增 `sim/tb_c1_tensor_packing_memory.sv`，直接实例化生产 packing bridge（包含真实 write burst client 和旧读桥）。独立 8192-byte 物理内存仅由已接受的 AXI AW/W/WSTRB 更新，读 RDATA 从该物理内存生成；另一份参考内存只由逻辑写请求更新，二者没有共享过程写入器。

本次新增覆盖：

- 12 个连续 64-bit 写从 0x0ff8 开始，先写上半 lane，跨越 0x1000，再超过一个四拍 burst 的容量。BFM 对每次 AW 严查不跨 4 KiB、长度和对齐，并检查实际 WLAST 与 AWLEN 一致。
- AW-first 与 **整个 W burst 先于 AW** 两种服务顺序；W-first 下 AWREADY 等 WLAST 被接受才放行，验证真实通道独立性。AW/W/AR 有周期性回压并逐周期检查 stalled payload/VALID 稳定。
- 读请求在 12 个写响应尚未排空时提前呈现并持续保持，要求此前不能 READY，也不能出现 AR；最后一个逻辑写完成后才可读回。
- 重复同一地址的不同数据、部分且重叠的 WSTRB，检查字节更新顺序与未使能字节保持。
- 未对齐写必须本地报错且不产生 AW；一个合并事务的 SLVERR 必须返回两个逻辑错误响应。BFM 在报错前已提交数据，后续读回不假设错误意味着回滚。
- 最终逐字节比较全部 8192 bytes，而非只比较返回计数或请求镜像。

两个配置均通过：`C1_PACKING_MEMORY_PASS w_first=0/1 aw=6 w=10 b=6 reads=17 bytes=8192`。包含 18 个逻辑写请求，其中一个本地拒绝；其余合并为 6 个物理事务，所有 B 已退休。完整 Icarus 回归通过 **92 配置**；最后追加总线保持断言后又单独复跑这两个配置通过。

本轮不修改生产 RTL、不调整凑包超时，不提供新的性能提升结论。上述证据补上了 **packing bridge 自身**的跨页和独立存储读回；它不含真实 CNN engine、tensor adapter 或缓存 owner，因此仍需将该类内存提交检查提升到完整组合。下一步再处理按批结束标记/超时的凑包策略与不同 DDR 延迟下的周期对照。

本轮只运行 Icarus；临时镜像与生成向量由现有 runner 的 finally 清理，没有 Vivado 工程或波形文件。

## 追加：真实 adapter 与打包桥的独立提交组合

新增 `sim/tb_c1_adapter_packing_memory.sv`，复用原 22-stage adapter 操作数/结果检查器，将 adapter 的内存响应接到真实 packing bridge 和独立 AXI 物理内存。原 `base.memory` 仍只作为逻辑请求参考，实际读 RDATA 来自物理内存，物理内存只由 AXI AW/W/WSTRB 更新。

AW-first/W-first 两配置均通过：

```text
C1_ADAPTER_PACKING_MEMORY_PASS w_first=0/1 frames=1 bytes=3072 logical_writes=419 aw=219 w=273 b=219 reads=1810
C1_ADAPTER_PACKING_ERROR_PASS requests=1 responses=1
C1_ADAPTER_PIPELINED_WRITES_PASS max_pending=6 drained=1
```

完整帧结束时比较全部 384 个 C8 存储字（3072 bytes），并要求 adapter 写计数、逻辑响应队列、物理 AW/W/B 全部排空。419 个逻辑写与 AXI 计数为该检查时刻的累计值，包含之前的取消测试，不应误称为纯单帧事务统计。后续原有内存错误/重启及配置 generation 错误用例继续运行到最终 PASS。

测试互连对每个逻辑请求增加两周期准入延迟，以产生真实 READY 回压；放行后的 VALID 保持到实际接受，不是只强制拉低 READY 却让下游偷偷接收请求。该固定测试延迟不属于生产 RTL，也不用于证明性能提升。

错误注入在逻辑请求接受时锁存，在物理事务提交时再次断言已生效，要求恰好一个错误响应传回。初次组合因原单请求模型的覆盖假设和跨层注入控制未正确跟随事务而失败；保留原覆盖检查，补真实准入回压，将跨层控制改用四态 logic，并在 AXI 提交处增加校验后通过。没有用跳过错误断言的方式取得 PASS。

范围说明：此组合含真实 tensor adapter，但 **engine 仍是行为模型，不含行缓存/缓存 owner**。新增 `RUN_WRITE_DRAIN_SCENARIOS` 仅供组合测试选择；此组合关闭了原测试中直接操纵逻辑 BFM 的额外“多写挂起时强制阻塞下一写”场景，因为该控制不等于阻塞实际 AXI 桥。原四种 adapter 独立配置仍默认执行这些场景，未移除其覆盖。现有取消、内存错误、重启流程在组合中仍执行。

最终完整 Icarus 回归 **94 配置通过，exit 0**。本轮不改生产 RTL，不更改凑包超时或默认配置；仍需补缓存 owner 组合、真实 engine 数值及吞吐评估。本轮没有启动 Vivado，没有波形/仿真工程保留，Icarus 临时产物由 runner 清理。

## 追加：有序批结束标记减少凑包等待

本轮实际修改 RTL，新增默认关闭的结束标记路径：

1. adapter 的 `mem_req_end` 随请求发布：结果写采用当前像素的 group-last，source 写采用单请求批；请求受阻时结束位也必须保持，已纳入原稳定性断言。
2. portable SoC 的 `USE_TENSOR_WRITE_END` 经 burst cache client 和 packing bridge 传给 write burst client；runner 对应 `-TensorWriteEnd`，要求写打包分支已启用。
3. 叶模块 `USE_REQUEST_END` 开启时，将 `req_end` 与地址/数据/字节使能一起存入请求 FIFO。只有该条请求真正被 builder 消费后，才结束它所属的批，禁止把已排队的下一批拼进去。
4. 标记不是 posted acknowledgement，不绕过 B，也不是即时 `req_flush`。缺少结束标记的批仍靠既有超时有限排空，覆盖取消导致最后一组未出现的情况。

全部新参数默认 0；端口和参数均追加，旧具名实例保持关闭行为。为原 `.*` 连接的 early-W 测试补接常零 `req_end`，避免新增端口导致该旧测试编译失败。

### 验证

独立物理内存测试扩展为 AW-first/W-first × 标记关闭/开启四配置。开启配置额外检查两个相邻请求各自带结束标记时，必须形成两个事务；同时保留故意缺失标记的超时排空、4 KiB、字节使能、写错误、读屏障与全内存比较。其多出来的两笔测试事务不是性能退化统计。

真实 adapter+独立 AXI memory 组合也扩展为四配置，22 阶段全部 3072 bytes 比较通过，真实错误传递与重启检查通过。开启标记时 AW/W-first 两配置在帧完成检查处分别为 220/219 AW、均为 273 W；不同 BFM 服务相位会影响凑包结果，不承诺任意时序下事务数完全相同。

完整 Icarus 回归 **98 配置通过**。最后为输出增加 end_marker 标签后，四个 adapter 组合配置又定向复跑通过。

- `review_write_end_trained_20260910`：complete / exit 0，训练参数 8×8 SoC，22 descriptors、66 weight AR、done/swap=1/1、drop=0。
- `review_write_end_recovery_20260910`：complete / exit 0，完整 SoC 显示故障恢复，injected/errors=1/1、done=2、44 descriptors。

### 同负载周期对照

均为 8×8 训练参数、burst refill、并发结果写、显示 response FIFO 和 fabric read skid：

| 配置 | 任务周期 | AXI AW/W/B |
|---|---:|---:|
| 未打包普通写桥 | 53127 | 852/868/852 |
| 写打包，靠超时结束 | 56627 | 708/774/708 |
| 写打包，有序结束标记 | 53802 | 708/774/708 |

结束标记相对原打包候选减少 2825 cycles，约 **4.99%**，且这次物理事务数不变。但仍比未打包普通写桥慢约 **1.27%**，因此不默认启用，也不宣称已优于基线或达成 15 fps。需要进一步比较真实 DDR 延迟/大图工作负载，并继续补真实 engine、缓存 owner 与独立数值内存的完整组合。

本轮两个 xsim worker 均已退出，临时 run 目录不存在；Icarus 临时镜像/向量亦由 runner 清理，无波形保留。

## 追加：写响应延迟的同负载敏感性对照

本轮不改生产 RTL。测试 BFM 新增 `B_RESPONSE_DELAY`，在 AW/W 已接收并提交物理内存后插入指定的等待计数再呈现 BVALID。该值不是从 AW 握手量起的完整 AXI 延迟，更不是实际 DDR 参数；其余协议状态转换还会消耗周期。

同一 8×4、22-stage adapter 工作负载，在相同 AW-first BFM、两周期逻辑请求准入延迟和真实物理内存检查下，对比普通桥与带结束标记的打包桥。两者都开启 adapter 的并发结果写功能；普通桥自然只能接受一笔，打包桥最多观察到六笔。`job_cycles` 从该任务 start 握手计至 adapter done，包含配置/输入/处理阶段，不含之前的取消测试。

| B_RESPONSE_DELAY | 普通桥周期 | 打包＋结束标记周期 | 打包相对变化 |
|---:|---:|---:|---:|
| 0 | 17099 | 17311 | 增加 1.24% |
| 12 | 22090 | 19996 | 减少 9.48% |
| 64 | 43909 | 31224 | 减少 28.89% |

每个组合都保留 3072-byte 独立物理内存比较、原 22-stage 操作数检查、真实写错误传递和重启检查，没有为得到性能数字跳过正确性断言。另保留 W-first 及不使用结束标记的已有配置。

该结果支持保留打包候选：减少事务在较高写完成开销下可以转化成周期收益，低延迟时队列/凑包控制仍可能得不偿失。但它**不证明实际板卡处于哪一档，不给出通用收益阈值，也不能换算 native fps**。此组合不含行缓存、真实 CNN engine、共享 DDR 仲裁和 CPU；其周期绝不能与前述 8×8 完整 SoC 的 53802 cycles 直接相除比较。

最终完整 Icarus 回归 **103 配置通过**。补充测试参数合法性检查后，9 个 adapter 对照配置和 4 个独立打包桥配置再次定向通过。未启动 Vivado，没有大型工程/波形产物；临时镜像与向量由现有 runner 清理。

下一阶段仍优先补真实 engine/缓存/打包写组合的数据一致性，再在同一完整 SoC 工作负载下评估更接近目标系统的服务延迟和竞争流量。生产默认开关不变。
