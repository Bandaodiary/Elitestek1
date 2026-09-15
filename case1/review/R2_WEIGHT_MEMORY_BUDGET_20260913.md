# R2-C20：实际平台容量审计与六路权重存储

日期：2026-09-13。状态：独立存储组件完成 RTL 数值、Icarus/xsim 与 Ti60 I3 map+PNR 验证；**尚未接入完整 CNN，不是板级资源闭合或新的帧率结果**。R1、C18 生产源与在途原生仿真保留。

本轮最终记录：[r2_c20_gate_20260913_a.log](../logs/r2_c20_gate_20260913_a.log)。

## 1. 为什么转向存储组织

C18 完整主机/视频/共享 AXI 探针占用 46,531 XLR、172 RAM、112 DSP，但它不包含实际 Sapphire、DDR 控制器/PHY、CSI、ISP/Resize 和板级 CDC。不能把剩余 84 块 RAM 当作集成平台后的余量。

重新读取企业原始 hierarchical_stats 第一张表，得到以下子树总量；不是把多个分析文档中的估计相加：

| 实际报告中的子树 | XLR | RAM | DSP | 来源 |
| --- | ---: | ---: | ---: | --- |
| `u_sapphire_soc` | 8,672 | 43 | 4 | SoC co-debug，行 142 |
| `u_ddr3_top` | 5,377 | 22 | 0 | 同一 SoC 工程，行 20 |
| `inst_efx_csi2_rx` | 2,932 | 36 | 0 | SC431 视频 v1，行 78 |
| `debayer_top` | 380 | 4 | 0 | 同一视频工程，行 41 |

原始文件：

- [SoC 层次资源报告](D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo/par/ddr_demo_ti60/outflow/ddr_demo_ti60-hierarchical_stats.rpt:142)
- [视频 v1 层次资源报告](D:/contest/Ti60F225_DemoBoard_v4/10_Ti60f225_sc431hai2hdmi_demo/Ti60f225_sc431hai2hdmi_v1/outflow/ti60f225_oob-hierarchical_stats.rpt:78)
- [C18 自身实现摘要](../logs/efinity_resource_runs/c18_planned_host96_i3_20260913_a/summary.json)

只计 C18＋SoC 的 CPU/DDR＋CSI，RAM 已为 `172+43+22+36=273`，超过 Ti60 的 256 块；加 Debayer 为 277。选的是 SoC 那一套 DDR，**不再叠加视频工程的另一套 DDR/缓存**；也没有加入视频 DSI 或 SoC 调试器。

对应 XLR 粗和为 `46531+8672+5377+2932+380=63892`，也高于 60,800。跨工程 packing、探针 I/O、自带控制/缓存的可替代部分尚未联合优化，因此这不是“联合实现一定占 63,892”的测量，但足以否定“原有核心资源通过就等于整板可放下”。DSP 粗和 116/160，相比 RAM/逻辑不是本轮最紧的项。PLL/Clock Mux 也不能直接拼接两个例程配置。

## 2. 被否定的第一种方案：两银行真双口共用

原 `c1_r2_weight_store8` 有 32 个 `64×32` 的 SDP RAM，每个映射为两块，总计 **64 RAM**。分配的逻辑容量 8 KiB，合法的 48 个通道×8 个 K16 段实际可寻址权重为 6 KiB；主要限制是并行读带宽，不是数据总量。

初步尝试把偶/奇银行共用一个 `128×32` 真双口 RAM，借用“加载与计算读取互斥”的旧合同。Icarus 与旧实现/独立模型一致，但 Efinity `c20_weight_tdp_i3_20260913_a` 报 **EFX-0680：RE/WE 控制不兼容**，未生成可实现网表。

进一步核实发现，Ti60 SDP 最高 20 位/端口，而 TDP 最高 10 位/端口。即使修好推断，32 位 TDP 仍需四块，两个原 32 位 SDP 也是四块，不能靠简单合并声称减半。可核对本地 `sim_models/verilog/efx_ram10.v` 与 `efx_dpram10.v` 头部，或官方 [Ti60 数据手册](https://www.efinixinc.com/docs/titanium60-ds-v3.2.pdf)。

因此该分支停止推广，文件 `c1_r2_weight_pair_ram.sv`、`c1_r2_weight_store8_tdp.sv` 标记为 **REJECTED**，只保留失败原因和试验，不加入任何生产源闭包。“有望 32 块”的最初判断已撤回。

## 3. 已实现的替代方案：六份完整表＋混合位宽

实际阵列每拍最多消费六组 128 位权重。旧方案按 `Cout%8` 分成八个浅银行，再由各 feeder 选择六组。新独立候选按六个计算通道保存六份完整权重表，每份一个独立同步读口，所有加载广播写入。

这样复制了逻辑数据，但让每个物理 RAM 的深度得到利用：

- 普通版本：六份表，每份四个 `512×32` SDP，实测 **48 RAM**。
- 混合位宽版本：每个 32 位加载字拆为六个 5 位片和一个 2 位片；读口一次读出连续四字的对应片，即 `5→20`、末片 `2→8`。每份七块，六份实测 **42 RAM**。
- 仍支持任意顺序单独更新四个 32 位字，不要求先拼齐 128 位，不引入读改写或新的加载等待。
- 保留一拍同步读、read_en=0 时输出保持、复位不清 SRAM，复位时屏蔽加载/读取。参数加载不能与读同拍；上层仍须在使用前完成本层参数加载。
- Bias/affine 暂时保持旧八银行实现，其源码块与旧版直接对照一致；没有把它们移除后冒充资源节省。

新增 [c1_r2_weight_store6.sv](../rtl/r2/c1_r2_weight_store6.sv) 与 [c1_r2_weight_asym_ram.sv](../rtl/r2/c1_r2_weight_asym_ram.sv)，没有实例化厂商原语；混合位宽由 Efinity 从可仿真的 RTL 推断。`PACKED=0/1` 选择两版。物理总 RAM 容量与逻辑有效字节不是同一指标。

外部 `load_kind/load_addr/load_data` 保持旧格式。新的读侧不是八银行接口的即插即用替代：六个 9 位地址各为 `{channel[2:0],channel[5:3],K16[2:0]}`，等于该向量原加载地址的 `[10:2]`；返回六个 lane 对齐的 128 位向量。Bias/affine 仍接受旧 `read_addr[47:0]`。

## 4. 验证与资源对照

### 数值、持有和非法输入

最终 Icarus：[r2_weight_replica_unit_20260913_d.log](../logs/r2_weight_replica_unit_20260913_d.log)。两版分别通过：

- 六份表的每个合法位置完整读取；每次六路可读不同通道/段，不依赖“相邻六通道”限制。
- 逐一更新全部 1,536 个合法 32 位字，立即检查六份副本和同向量其余三字未被覆盖。
- 1,000 组随机读取，穿插 334 次随机权重更新、91 次 bias 更新、77 次 affine 更新。
- 每版共 2,920 次读、3,670 次加载、70,080 个返回权重字核对、11 次带读写输入的复位、2,064 次输出保持检查。旧模块继续对全部八个逻辑银行进行独立核对；新六路返回对照独立逻辑数组。
- 每版七个非法输入负对照：加载/读取冲突、权重 group 越界、affine 通道越界、shift 越界、旧 affine 读组越界、保留字段非零、新 lane 读组越界。负对照中关闭旧模块访问，避免由旧断言抢先报错冒充新模块拒绝。

最初 a/b 调试运行因 Icarus 对嵌套 generate 的模块端口切片绑定不正确，出现新输出 X；展平索引后 c 通过，d 增加了穷举与逐字立即读回。未修改原生产 RAM。其后 xsim 也通过同一 d 测试，未仅凭 Icarus 通过就归因于硬件正确。

Vivado 独立运行：

| RunId | 版本 | 秒 | Job 内 | 私有工程残留 |
| --- | --- | ---: | --- | --- |
| `c20_weight_replica_xsim_word_20260913_a` | 普通六份 | 8.525 | false | 无 |
| `c20_weight_replica_xsim_packed_20260913_a` | 混合位宽 | 8.562 | false | 无 |

两份 xsim 的完整测试计数与 Icarus 一致；不重复计成更多独立场景。没有波形。这里是 RTL 仿真加映射/布局布线证据，不是 post-route 门级功能仿真或形式等价证明。

### Efinity 2026.1.132.3.9、Ti60F225 I3

各探针加载、地址和观测均由运行时顶层输入控制，所有权重均可观察；没有常量参数/常量输出剪枝。共同约束 core_clk=6.666 ns。

| RunId | RAM | XLR | DSP | 内部 setup/hold slack（ns） |
| --- | ---: | ---: | ---: | --- |
| `c20_weight_sdp_i3_20260913_a` | 64 | 6,080 | 0 | +5.155 / +0.157 |
| `c20_weight_replica_i3_20260913_a` | 48 | 5,724 | 0 | +5.173 / +0.157 |
| `c20_weight_replica_packed_i3_20260913_a` | 42 | 5,756 | 0 | +5.317 / +0.157 |

上述是**独立参数存储＋观测选择器**，不是完整 CNN/主机 PNR；探针未施加板级输入输出延迟，不能将工具给出的最大内部频率转称系统 Fmax。六路版的读侧地址/输出接口与八银行版不同；表中逻辑差额也不能直接从完整系统 XLR 中扣除。

混合位宽权重 RAM 实际下降 22 块（34.375%）。普通六路版少 16 块。没有改变模型精度、权重值、量化公式或 96 MAC 数量，也**没有本轮整机周期/FPS 提升证据**。

## 5. 下一步如何接回主线

先做独立的资源优化执行器分支，保留 C18；不能直接把模块名替换就认为兼容。

| feeder | 每个 lane 应读取的输出通道 | K16 段 |
| --- | --- | --- |
| PW | `(issue_channel+lane) % Cout` | 当前 `issue_k` |
| Encoder Cin3/Cin12 | `channel_base+lane` | 当前 `k_q` |
| RGB | `lane % 3`，两像素共享权重 | 当前 `beat_q` |
| DW | `window_group*8+(batch*6+lane)%8` | 0；`batch*6+lane>=16` 的末批 lane 必须屏蔽 |

需要调整 PW、encoder、spatial feeder 的请求侧地址及返回侧 lane 对齐，同时保留 metadata/反压一拍对齐和旧 affine 选择，不能把请求地址用成延迟后的地址。然后验证所有受支持算子/尺寸、跨输出通道边界、DW 尾批、随机背压、参数重新加载、错误排空与复位。完整原22项/18项图 golden、主机局部和 Ti60 PNR 通过后，再建立该分支原生多帧证据。

即使集成后原样保留 22 块节省，估计核心 RAM 为 `172-64+42=150`；加入当前 CPU/DDR/CSI/Debayer 为 **255/256**，还没算 Resize、CDC FIFO 与板级连接。**这仍不是可交付的板级余量。** 下一项应审计 PW/residual 与 spatial 的特征存储是否能在现有互斥生命周期下共享，以及企业 CSI/CPU 配置能否在满足实际需求时缩减；不能只继续堆加并行度。

PW 特征池当前为 16 RAM，spatial 为 48 RAM，但其读口组织不同（PW 两路 128 位，spatial 三行×两路 64 位），不能简单共用一块同名数组。共享还需证明切层/行缓存有效性与写回期间的所有权，资源数字仅是定位依据，不是已经实现的收益。

## 6. 复现与保留范围

运行 `golden/run_r2_weight_replica_probe.py`，然后分别用 `scripts/run_r2_weight_replica_xsim_detached.ps1 -RunId <唯一ID> -Packed 0/1` 交叉验证。Efinity 使用既有 `run_efinity_ti60_resource_map_detached.ps1` 外层，设计名为 `c1_ti60_r2_weight_sdp`、`c1_ti60_r2_weight_replica`、`c1_ti60_r2_weight_replica_packed`，带 `-ProjectInPlace -RunPnr -TimeoutSeconds 600`；禁止直接进入 Worker 或复用 RunId。

`check_r2_weight_memory_evidence.py`读取小型日志与企业资源表关键行，检查数值覆盖、14个负对照、五个证据变异拒绝、旧 affine 源块一致、C18 源闭包仍选旧权重、两种 xsim 的 Job/清理、三个 PNR 及失败 TDP 记录。它明确输出 `board_fit_proved=0`、`new_system_fps_proved=0`。

四次 Efinity（含失败）私有目录均已删除，只留合计 196,700 B 小报告；两次 xsim 合计 7,421 B，小型 Icarus 临时目录退出即清理。本轮新增约 200 KiB 运行证据，不保留大型仿真/综合临时文件。C18 的原生 worker 28960 仍沿用 16:36:49 启动的同一进程；17:51 已完成三次 CNN、正在第四次，原目录不属于清理范围。尚不能由部分帧宣布 C18 六帧通过。

17:59 收口检查：C20 门禁再次通过，11 个相关文档链接存在，C18 原有四个 wrapper/probe 直接对照、32 文件闭包和两份生成包复核通过。C18 原 worker 的启动时间仍为 16:36:49.1467368、Job=false，已完成四次 CNN，正在第五次；未重新启动。
