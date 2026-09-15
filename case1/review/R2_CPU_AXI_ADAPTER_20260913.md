# R2-C13：普通 DDR CPU AXI 适配与 C12 联合验证

日期：2026-09-13。C12 及以前的生产 RTL 均保留；本阶段新增独立适配模块，没有替换旧 CPU 或重新生成厂商 IP。

## 当前结论

新适配层与保留 C12 的 CNN/视频/fabric 已通过小图完整数值验证和目标 Ti60 I3 150MHz 实现。联合核心为 **45,842 XLR、172 RAM、112 DSP**，比 C12 增加 325 XLR，不增加块 RAM 或 DSP。原生六帧现已独立完成：四个完整负载间隔最慢 **15.3145fps@150MHz**，最小周期余量 2.0535%，详见第6节；这不是移用 C12 的数值。

这仍不是官方 Sapphire 实例的执行验证，也不是通用透明 AXI 桥、缓存一致性互连或完整板级工程。

## 1. 为什么不能直接截断 CPU ID

核对企业文件：
`D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo/par/ddr_demo_ti60/ip/soc/soc.v`。

- `io_ddrA_*` 的实际数据为 128-bit，读/写 ID 为 8-bit；AXI address 为 32-bit，具有 SIZE/LEN/BURST/LOCK/REGION 等侧带。
- `io_apbSlave_0_*` 实际为 16-bit 地址、32-bit 数据、无 PSTRB 的 CPU 发起 APB 口。
- `userInterruptA` 是标量输入，不应按历史假设连接成任意宽向量。
- 当前 C12 fabric 的 CPU 口不携带 ID，物理 DDR 侧归一化为 ID0；原生 CPU 背景源也只验证了全宽 INCR 数据。直接截低位或将 RID/BID 常量返回会丢失上游事务身份。

上述源码中的 AXI-A 与 DDR-A 不是同一个窗口。检索到 AXI-A 的 `BURST=INCR/LOCK=0` 常量，**不能据此推断 DDR-A 的所有访问也都满足该限制**；DDR-A 经内部桥/仲裁/upsizer 转接，其实际配置和软件访问行为仍需核验。

## 2. 新模块与合同

新增 `rtl/r2/c1_r2_cpu_axi_adapter.sv`：

- 默认保存完整 8-bit ID，参数允许 1～16 位；读、写各只接纳一笔在途事务，两个方向可独立并行。强制同方向有序是合法的节流选择，但可能降低 CPU 的内存级并行度。
- 128-bit 数据不重排。支持对齐的 INCR 访问，SIZE=0～4（1/2/4/8/16 B），1～256 beat，不跨 4 KiB，默认地址范围 `[0,0x10000000)`。窄写按地址低位对应字节 lane，可部分或零 WSTRB；不把 32-bit CPU 访问误当成覆盖整个 128-bit 字。
- 启动时快照 ID、地址、长度和大小；CPU 后续修改命令总线不会改变正在运行的事务。读返回有一级保持寄存器，RID/RDATA/RRESP/RLAST 在等待期间共同保持。
- W 可以在下游 AW 接受前传递，不通过“必须先 AWREADY”制造与合法从机的死锁。B 只在所有 W 已送出、真实 AW 和 B 完成条件满足后返回；旧 ID 到响应消费前不能复用。
- 不支持 LOCK/独占、非零 REGION、非 INCR、未对齐、非法 SIZE、越窗/跨 4KiB。此类命令不发下游 AXI，按上游长度完成本地 DECERR；写命令仍消费自己的 W 数据，不能提前给成功 B。
- 普通 SLVERR/DECERR 可排空后接下一笔。异常 RLAST、逻辑 WLAST、越 lane 的 WSTRB、过早 B，以及普通访问收到 EXOKAY 时置 `protocol_error`，停止新接纳，完成可界定的已拥有数据/响应后要求协调系统复位。提前 WLAST 的缺失尾部用 **零 WSTRB** 排空，不覆写尾部；提前 RLAST 的缺失尾部给零数据/SLVERR。没有任意不响应从机的自动超时恢复承诺。

**重要限制：** CACHE/PROT/QOS 不在当前规范化接口中传递，本模块只适用于无保护/副作用语义要求的普通、非一致性 DDR 路径；不能用于 MMIO、安全隔离或带独占语义的透明转发。调用方须确认所选 Sapphire/BSP 确实只需支持的访问子集，未支持的行为不能通过“绑零”伪装成功。如果实际配置需要其他语义，应扩展互连或保留官方相应路径，不能宣称目前已经全面兼容。

APB 边界可复用现有 `c1_sapphire_apb_master_adapter`，配置 Sapphire 地址16位、C12地址8位，并拒绝非零高位；当前驱动按32位整字写，写 PSTRB 可固定为15。但这一16→8具体连线及实际 CPU/BSP 执行尚未纳入本阶段联合顶层。

## 3. 真实联合方式与文件

| 文件 | 作用 |
| --- | --- |
| `rtl/r2/c1_r2_cpu_axi_adapter.sv` | 新 CPU 正常 DDR 边界 |
| `sim/tb_c1_r2_cpu_axi_adapter.sv` | 独立 byte RAM、不同 ID/窄访存/错误及排空检查 |
| `sim/tb_c1_r2_cpu_video_system.sv` | CPU流量源→新适配层→实际 C12 CPU client，与采集/CNN/显示共同竞争 DDR |
| `golden/run_r2_cpu_axi_adapter_probe.py` | 独立12配置回归，临时目录自动清理 |
| `golden/run_r2_cpu_video_system_probe.py` | 联合多帧 Icarus 回归，数值 golden 保持原样 |
| `scripts/run_r2_cpu_video_xsim_detached.ps1` | WMI 脱离式联合 xsim，核验不在 Windows Job 中 |
| `efinity/c1_ti60_r2_cpu_video96.{sv,xml,sdc}` | C12＋适配层的150MHz可观测缩减引脚核心探针 |
| `golden/check_r2_cpu_video_evidence.py` | 独立检查数值、CPU ID/beat守恒、清理、目标器件实现及原生性能 |

当前联合测试的 CPU 源仍是 AXI 行为代理，不是厂商软核。每笔请求使用变化的完整8位 ID，逐次检查读/写返回身份，包含高位和回绕；CNN 输入仍必须来自实际采集 W，后续层读取实际前级写回，Python 中间结果只供比较。联合系统 CPU 负载仍为全宽事务；窄访问目前是适配模块级 byte RAM 证据，不能冒称已通过实际 DDR PHY 或整个视频系统的窄访存回归。

## 4. 验证与调试记录

1. 首轮 `r2_cpu_axi_adapter_smoke_20260913_a/b.log` 在全宽多拍读的第一拍报错。进一步记录显示实际 RAM 与 reference 一致，返回却提前变成第二拍数据。根因是新读保持寄存器误用了阻塞赋值，导致同拍消费旧 beat/接收新 beat 时仿真数据与控制竞态。改为非阻塞赋值后 c 轮通过。
2. 最终 `r2_cpu_axi_adapter_matrix_20260913_b.log`：等待0/1×普通AW/完整W先于AW×ID宽4/8/12，共12配置、882次读写任务。包括192个本地拒绝、90个协议异常、24个普通响应错误，其余576个正常任务；不能将882全部称为正常运行。全部实际 byte RAM 最终内容逐字节一致，覆盖独立读写并发、窄 lane、部分/零 strobe、256 beat、响应保持及reset恢复。
3. `r2_cpu_video_system_sixframe_20260913_a.log`：8×8、32×32 各普通/随机等待，共24次完整CNN，36,736个有效显示像素检查通过。CPU ID完成数×16必须与实际CPU读/写beat数一致。
4. `c13_cpu_video_xsim_12x12_20260913_a`：随机等待＋完整W先于AW，六次CNN和配对显示通过；帧间启动等待均2拍。worker Job=false，24.971秒，私有工程已清理。
5. 独立门禁 `logs/r2_c13_gate_20260913_b.log` 已核验上述结果、物理实现，并拒绝5种破坏过的证据（假RAM、漏最大burst、错ID宽、截断返回ID覆盖、去掉适配层标记）。

新探针在提交工具前发现机械生成使 top 名多出 `host_`，已修正后再启动 Efinity；不是成功综合后的手工改报告。CPU适配层完整读写/ID/限制字段均由host寄存器加载或可观察，避免常量裁剪后低估成本。

## 5. Ti60 I3 实现

`c13_cpu_video96_i3_20260913_a` 已 complete/exit0，339.244秒。

| 指标 | C12 | C13 |
| --- | ---: | ---: |
| XLR / 60,800 | 45,517 | 45,842 |
| RAM / 256 | 172 | 172 |
| DSP / 160 | 112 | 112 |
| 150MHz setup / ns | +0.556 | +0.487 |
| hold / ns | +0.026 | +0.026 |

单一计算阵列仍为96个EFX_DSP24＋16个EFX_DSP48。C13最终周期报告6.179ns；这里只签核6.666ns约束下的核心探针，不将其最大频率当作新的板卡工作频率。未包含实际Sapphire、DDR PHY、ISP/Resize、MIPI/HDMI、CDC、完整IO约束；剩余器件资源不能当作整板最终余量。

## 6. 原生运行和后续

C12六帧 `c12_rgbx_xsim_native_sixframe_20260913_a` 后续已完整通过，四个连续全负载间隔最慢9,794,650拍＝15.3145fps，约2.05%最小余量，证据`r2_c12_sixframe_gate_20260913_a.log`。这是保留C12的对照，不能替代C13原生结果；早期三帧的15.4191fps仅有一个全负载间隔。

`c13_cpu_video_xsim_native_sixframe_20260913_a` 已 complete/exit0，耗时 6,550.980 秒，worker Job=false，私有仿真目录已自动删除。使用新适配层后的同等30fps采集、720p60双图、CPU竞争与共享1.2GB/s/每burst20拍延迟模型。六次 CNN、最后结果显示和全部债务排空后，独立执行 `check_r2_cpu_video_evidence.py --native-run c13_cpu_video_xsim_native_sixframe_20260913_a --pnr-run c13_cpu_video96_i3_20260913_a --require-15fps` 通过，证据 `logs/r2_c13_native_gate_20260913_a.log`。

- 第三至第六次的四个完整负载完成间隔为 9,728,220 / 9,754,652 / 9,790,344 / 9,794,650 拍，全部≤10M拍；最慢15.3144829fps，余量205,350拍＝1.369ms＝2.0535%。没有用平均值、首帧或最快间隔替代最坏间隔。
- 13次采集、6次CNN/132次层提交、21次双图显示、12,902,400个正确显示像素；欠载和显示丢失均0。CPU读/写分别125,968/125,984 beat，完成7,873/7,874个16beat事务，恢复8-bit ID；共享峰值在途读/写各8笔。
- 六帧周期与保留C12相同，是本次独立仿真所得。只覆盖有限的四个完整负载间隔，CPU仍为流量代理而非真实Sapphire执行；CPU窄访问、异常、缓存和BSP的其他证据不能由本次满宽竞争测试替代。
- C13仍保留旧输入回收策略；新鲜度修复在C14，C13通过不意味着该策略问题自动消失。

下一步还包括：核验实际Sapphire/BSP输出的事务子集、缓存clean/invalidate和参数上传、DDR地址窗口/CDC及整板集成。APB16位本地窗口和标量IRQ已另在C15生产封装实现并做代理验证，不等于实际CPU/PLIC执行。现阶段不能声明官方CPU已实际运行，也不能声明整个比赛系统已完成。

13:39清理快照 `logs/r2_c13_partial_cleanup_20260913.json`：已完成的C13小图xsim私有目录及C盘Efinity私有数据库均不存在；小图运行仅保留41,737 B文本。C12/C13两组原生六帧仍分别在自己的D盘临时目录使用中，均不得删除或因观察超时重启。

以上是13:39的历史快照。15:25更新见 `logs/r2_c16_partial_cleanup_20260913.json`：C13原生私有目录已经不存在，仅保留56,299 B文本；当前原生在途为C14/C15两组，继续保留。

### 长仿真新发现：采集回收优先级影响新鲜度

C12六帧运行中，tag4在22,285,135周期采集完成（槽`0x0C000000`），tag5在27,285,475周期完成（槽`0x08000000`）。30,000,023周期，tag6采集回收了tag5的同一槽，而tag4仍处于READY；第四次CNN在30,956,753周期选中了tag4。代码`c1_r2_video_rgbx_leases.sv`当前按槽号选择可回收READY，没有避开`latest_i`。

这不是数值或配对错误，也没有造成帧间空等，但说明可能丢弃最新已完成输入、留下较旧输入，额外增加约一帧采集周期的图像年龄。后续应在有其他READY可回收时保留最新READY，并增加专门测试；不能只凭“NN选择剩余READY中最新”便声称全链总是保留最新输入。当前正在取证的C12/C13生产RTL保持冻结，尚未修正该策略。
