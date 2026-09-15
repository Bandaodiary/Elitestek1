# R2-C27：相机主机的物理 CDC 与 Ti60 布局布线审计

日期：2026-09-13。状态：本轮物理审计与修复原型验证完成，**整机 CDC 整改/签核未完成**；不改动正在原生 xsim 中运行的 C26 生产闭包，也不覆盖 R1/C18/C21/C22/C24。

后续[C28](R2_CAMERA_CDC_HARDENING_20260913.md)已将本轮识别的同步链保护和源控制寄存器化接入独立整机，并完成回归/网表连接/定向PNR验证。本文下方“未集成修复”保留为C27阶段时点；全量物理CDC/板级签核仍未完成。

## 1. 范围与判断边界

[C26](R2_CAMERA_HOST_INTEGRATION_20260913.md) 已有数字功能与 MAP 证据；本阶段检查跨域电路在真实综合、重定时和布线后是否仍符合设计合同。
新增 [C27 工程](../efinity/c1_ti60_r2_camera_cdc96.xml) 与 [约束](../efinity/c1_ti60_r2_camera_cdc96.sdc)，沿用同一 44 源生产闭包，仅更名 pin-reduced 探针。两个时钟为核心 6.666 ns、相机 13.468 ns。

这不是官方板级工程：没有实际 PLL、IO 时序、CSI/DDR PHY、Sapphire、HDMI 串化器及复位释放电路。约束成功匹配、工具完成 PNR、数字仿真通过，分别都不等于完整 CDC 或板级签核。

## 2. 已确认的综合与工具行为

- 完整 MAP `c27_camera_cdc96_map_20260913_a` 与 C26 一致：29,285 LUT4、20,639 FF、148 RAM、130 DSP。只保留 563 个相关 FF 块的过滤摘录，不保留整个综合网表。
- FIFO512 为 10-bit Gray 指针。但 Gray 最高位与 binary 最高位逻辑相同，实际源 FF 为 `wr_gray[0:8] + wr_bin[9]`、读方向同理；若只约束 `*_gray[*]` 会漏 1 bit。
- 本地 Efinity 文档允许 `get_pins` 列表，实例层级用 `/`，端口分隔用 `|`，例如 `u_host/u_system/u_ingress/u_fifo/wr_sync1[0]~FF|D`。没有采用未被文档支持的 Vivado `-datapath_only`。
- 小实验 `c27_cdc_attribute_map_20260913_c`：两种大小写属性均保留在 MAP，4+4 个带属性 FF 保留，无属性两组被合并为 2 FF，加源寄存器共 11 FF。**这只证明该实验中的属性保留/防合并，不能独自证明防重定时或亚稳态安全。**
- 小实验 `c27_cdc_attribute_pnr_20260913_b` 已完成 MAP/PNR/STA，定向 max-delay 仍出现在 setup 报告；hold-only false-path 并未把 setup 一起切掉。示例 skew 为 0.063 ns、1 ns 要求下余量 0.937 ns。这是工具语法/报告实验，不是整机 FIFO 结果。
- 先前 tiny PNR a 实际完成 PNR，但 `report_timing -file` 对绝对路径再次拼接 output_dir，导致两份报告未生成。改为相对文件名后 b 通过。`report_cdc/report_bus_skew` 的文件路径行为不同。旧失败状态保留。

## 3. 约束策略

不使用整对时钟的 `set_clock_groups -asynchronous` 或 blanket false-path。只对明确跨域端点设置 max-delay 和 hold-only false-path；同步链第一级至第二级仍是正常同步路径。

| 跨域对象 | 实际宽度 | 检查 |
| --- | ---: | --- |
| FIFO write Gray → core 第一级 | 10 | 5 ns max-delay + 1 ns bus skew |
| FIFO read Gray → camera 第一级 | 10 | 5 ns max-delay + 1 ns bus skew |
| request/done/bad/快照 request | 4 | 仅第一级端点的 5 ns max-delay |
| ack/enable/cancel/快照 ack | 4 | 仅第一级端点的 5 ns max-delay；组合控制另列问题 |
| source_tag → capture_tag | 32 | request/ack 保持协议 + 5 ns max-delay |
| source_code → failed_code/result_code | 3 → 6 | bad/ack 保持协议 + 5 ns max-delay |
| 最新值快照 | 75 实际位 | 81-bit RTL 中 6 个恒零扩展位剪除；request/ack 保持协议 + 5 ns max-delay |

[审计 Tcl](../efinity/c1_ti60_r2_camera_cdc96.audit.tcl) 逐组断言映射后 pin 数量，单独导出核心域、相机域和两个跨域方向的报告。`C27_AUDIT_PASS` 仅指报告提取/匹配执行完成，不表示报告内无违例。两时钟几何平均 Fmax 不用于核心频率声明。

Efinity 的 max-delay 会计入发射/捕获时钟延迟，故还必须检查实际 Data Path Delay，不能只看正 slack。Gray skew 要与源端最短更新间隔比较；bundled-data 要结合最早实际捕获时间证明，而不是把多位数据当逐位两级同步器。

## 4. 新发现的问题与对照实验

1. C26 的 `enable` 与 `source_cancel` 在进入相机域第一级前存在组合逻辑。当前约束不能阻止组合毛刺；后续应在新候选中注册源控制并验证取消/禁用语义，不在长仿真途中修改 C26。
2. 完整 MAP 出现 `rd_sync2[8]~FF_rt_0/1`，其 D 接到组合 `sub_27/n1`，不是单纯 `rd_sync1`。这是必须追踪的同步链重定时问题，不能因保留了原名第二级和 `ASYNC_REG` 字样就放行。
3. [FIFO 大小写对照](../efinity/c1_ti60_cdc_fifo_attribute_probe.sv) 的 `c27_fifo_attribute_map_20260913_a` 中，两种写法都出现第二级重定时派生 FF。因此**仅改为小写不是修复**。
4. [syn_keep 对照](../efinity/c1_ti60_cdc_fifo_keep_probe.sv) 的 `c27_fifo_keep_map_20260913_a` 中，两条链都不再出现该派生 FF；但同一设计内可能共享组合逻辑，不能只凭该对照宣称因果。追加 [独立单 FIFO 根模块](../efinity/c1_ti60_cdc_fifo_single.sv)，分别综合 plain/keep：`c27_fifo_single_plain_map_20260913_a` 有 3 个同步链派生 FF，`c27_fifo_single_keep_map_20260913_a` 为 0；两者 40 个主同步 FF 的 D/Q 与源/目的时钟均由连接检查器逐位核验。
5. [实际 LUT 摘录](../logs/c27_gray_retiming_cone_20260913.log) 证实派生 FF 前的 XOR/XNOR 直接使用 `rd_sync1[7:9]`：Gray-to-binary 部分运算被移到第二级之前。该路径用于写域水位计算，不能把可能尚未解析的第一级多位值拿来组合解码。它不是仅仅改名或无害的网表显示差异；已有数字仿真不能覆盖这种亚稳态风险。
6. `syn_keep` 原型相对原 FIFO 只有模块名和属性不同，RTL 主体逐字比较相同；[独立仿真](../logs/c27_fifo_guard_regression_20260913_a.log) 覆盖深度 2/4/32/512/1024 × 两组异步时钟，10 配置、30 轮复位、32,442 数据字通过，含容量 D+1、满、输出保持和排空检查。未修改 C26 的生产 FIFO，也没有宣称原型已整机集成。

[C27证据检查器](../golden/check_r2_camera_physical_cdc.py) 已通过源闭包、定向约束、真实 FF 连接、独立属性对照、数字回归与清理检查；主动删除 MSB 同步 FF、改变第二级 D 连接两种证据负控均被拒绝。初次检查器假设 XML 探针在最后一行、generate 名称用 `/`，与实际不符；改为按准确路径筛选和真实 `g_plain.u_ingress` 名称后通过，未改动生产 RTL。

## 5. 整机 PNR 实测与尚未通过的分类报告

- 整机 a 的 PNR runner 已返回成功，14 组 post-route 引脚匹配全部正确；随后 `report_cdc -details` 在 Efinity 2026.1.132.3.9 中触发 `Internal Assertion: IsValid()`。这不是已定位的 RTL 数值错误，也不能称 CDC 已通过。旧 worker 在提取最终资源前失败并按规则清理私有目录，因此不捏造 a 的 XLR/时序数值。
- 修正运行器后，新的 `c27_camera_cdc96_pnr_20260913_b` 在 433.976 秒结束，MAP/PNR 与必需时序提取完成。按时钟方向限制后的 `report_cdc` 仍在 camera→core 方向触发相同内部断言；明确记录 `complete=false`、退出码 1 和 `_CDC_REPORT_UNAVAILABLE`。工具运行 complete 仅表示这次分阶段流程结束，不表示分类器成功。

| 实测项目 | 结果 |
| --- | --- |
| 完整 pin-reduced C27 探针 | **43,577 / 60,800 XLR；148 / 256 RAM；130 / 160 DSP** |
| 核心域 6.666 ns | setup **+0.365 ns**；hold **+0.026 ns** |
| 相机域 13.468 ns | setup +5.653 ns；hold +0.092 ns |
| camera→core | 127 个唯一寄存器端点，最差 max-delay slack +3.783 ns，最大实际数据延迟 1.026 ns |
| core→camera | 14 个唯一寄存器端点，最差 max-delay slack +2.697 ns，最大实际数据延迟 2.236 ns |
| write Gray 慢角 skew | 0.025 ns，要求 1 ns，余量 +0.975 ns |
| read Gray 慢角 skew | 0.031 ns，要求 1 ns，余量 +0.969 ns |

完整141个寄存器跨域端点的身份、唯一性和`Max Delay Path 5.000 ns`均由检查器核验；实际数据延迟另要求小于5 ns。Gray报告覆盖每方向全部10位；报告中比较条数可能是9（省去唯一参考位）或10（最小延迟并列），不能把条数9误当漏位。hold-only例外使hold bus-skew报告无路径，**没有宣称该报告证明了所有工艺角的偏斜**。

原生报告给出核心分析最大频率158.705 MHz；两时钟几何平均周期7.017 ns不代表核心周期。这里只采用目标频率与逐域余量，不把分析Fmax直接提升为整机工作频率。源/目的组合控制毛刺、同步链重定时、非寄存器/未约束外部接口及复位协议问题仍不能由上述正slack排除。

若按此前官方必要平台粗加17,361 XLR / 105 RAM / 4 DSP，则为 **60,938 XLR / 253 RAM / 134 DSP**，XLR较器件标称容量超138，RAM仅余3块。此为分模块粗加、不是实际联合编译：共享/优化可能降低资源，新增桥接/时钟/接口也可能增加资源。因此仍需资源收缩，不能据单个探针71.67%逻辑占用就宣称完整板级平台可装下。

最终检查记录：[r2_c27_gate_20260913_f.log](../logs/r2_c27_gate_20260913_f.log)。门禁b/c是检查器对PowerShell UTF-16 BOM/CRLF处理问题，e是对skew参考位比较条数的错误假设；已按实际编码、实际bit集合修正，旧失败记录保留，生产RTL和工具结果未为通过检查而改动。

C26 原生六帧仍在途：`c26_camera_host_xsim_native_sixframe_20260913_a`。最近观察已完成3次CNN、8次采集，第三CNN为9,742,204周期、22节点/实际DDR数据通过。仍需完整六帧结果，不能外推或沿用C21/C22的15.3145 fps。

## 6. 下一阶段的具体改动边界

1. 建立独立新候选，在FIFO同步链加入已验证的保护属性，同时保护其他两级控制同步器；整机MAP逐连接审计，防止优化把组合逻辑移到同步完成之前。原C26仍保留。
2. 将enable/cancel跨域前的源控制寄存器化；明确新增一拍延迟，重跑取消、禁用、源尾部、B债务和无复位恢复回归，不能只跑正常像素。
3. 在新候选上重做PNR/Gray/bundled-data检查；将CDC分类器最小复现整理给工具支持方。若使用其他检查方法，必须保留这项工具限制而不隐去。
4. 消化C26完整六帧结果，再结合真实官方2像素/valid视频接口和单一DDR/时钟平台推进容量优化与板级集成。不要将本轮CDC工作表述为CNN吞吐提升。

## 7. 可复现入口与临时文件

```powershell
# 每次使用新的 RunId；仅调用外层 WMI 运行器。
./case1/scripts/run_efinity_ti60_resource_map_detached.ps1 -DesignName c1_ti60_r2_camera_cdc96 -RunId UNIQUE -ProjectInPlace -RunPnr -CdcAudit -TimeoutSeconds 3600
# 已保存报告的只读核验，不启动综合/仿真：
python -B case1/golden/check_r2_camera_physical_cdc.py --pnr-run c27_camera_cdc96_pnr_20260913_b
```

运行器为 `-CdcAudit` 保留少量 CDC FF 摘录、受大小限制的报告和最终资源摘要；默认其他工程流程不变。结束后自动删除其精确私有综合/布局布线目录。不读取/上传完整网表、布线数据库或波形；正在运行的 C26 xsim 目录保留到运行结束，由原运行器清理。

[清理核验](../logs/r2_c27_cleanup_20260913.json)：12 个 C27 Efinity 运行均终结，全部私有目录已自动删除，合计只保留 3,315,768 字节（约3.16 MiB）必要文本；FIFO回归临时编译目录也已删除。C26原生worker的PID与精确启动时间再次一致、Job=false，仍在运行且其目录未动。本轮没有手动删除用户文件。

本地参考依据：Efinity 2026.1 安装目录 `doc/topics/` 下 `syn-attr-async_reg.html`、`syn-attr-keep.html`、`syn-retiming.html`、`constraint-set-bus-skew.html`、`constraint_setmaxdelay-setmindelay.html`、`constraint-set-false-path.html`、`constraint-object-specifiers.html`、`tcl-report-bus-skew.html`、`tcl-report-timing-command.html`、`constraint-report-sdc.html`。依据本机文档和实际工具结果，不依赖外部网页流量。
