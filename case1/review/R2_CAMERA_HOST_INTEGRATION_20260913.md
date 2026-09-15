# R2-C26：不可回压相机接入 ROI、Resize 与 CNN 主机

日期：2026-09-13。保留 R1、C18、C21、C22、C24 备用基线。本文对应独立 C26 候选，不替换默认板级 top。

2026-09-14补记：原生长仿真`c26_camera_host_xsim_native_sixframe_20260913_a`已在原隔离进程下完成，9,903.078秒、Job=false、临时工程清理。[独立门禁](../logs/r2_c26_native_gate_20260914_a.log)核验13个1080p源帧/13采集、6正确CNN/12,902,400显示像素；完成周期14,056,074/23,725,120/33,467,326/43,243,992/53,025,120/62,818,876，最慢间隔9,793,756，150MHz/既定DDR模型约15.31588fps。下文“原生在途/未证明”按最初时点保留；该新结果不证明物理CDC/板测，也不能直接向C29/C30继承。

后续状态见[C27物理CDC审计](R2_CAMERA_PHYSICAL_CDC_20260913.md)：同一冻结功能闭包的新探针已完成43,577 XLR/148 RAM/130 DSP及核心150MHz级+0.365/+0.026ns验证，但发现同步链重定时/组合控制跨域待整改，CDC分类器也有内部断言。下文“未PNR”保留为C26阶段原始时点，不能把C27寄存器时序通过理解为C26物理CDC或板测签核。

## 1. 本阶段设计

新增完整入口 [c1_r2_camera_host_system.sv](../rtl/r2/c1_r2_camera_host_system.sv)，内部使用
[c1_r2_video_camera_system.sv](../rtl/r2/c1_r2_video_camera_system.sv)。
生产闭包由 41 源变为 44 源：替换 C24 的两个顶层封装，加入 C25 相机入口、双时钟 FIFO 和已有最新值快照模块；CNN 算子、权重、执行计划、Resize/Capture、AXI 仲裁与 CPU 桥均保留。

```text
独立 cam_clk：不可回压 RGB → 完整源帧标记检查 → 固定 ROI → 双时钟 FIFO
                                                            ↓
核心 clk：帧池预约 → Resize → RGBX Capture → DDR 实际 B 响应排空
           ↑                                   ↓
           └──── 相机入口最终结果/帧池发布 READY ──┘
                         ↓
               C22 CNN → raw/styled 配对显示

CPU AXI 适配器、CNN、Capture、Scanout → 原四主机 AXI fabric → 外部 DDR 接口
CPU APB → 原控制桥/中断 + 新只读相机统计页
```

默认：1920×1080 RGB 源，ROI `(240,0,1440,1080)`，缩放至 640×480，入口 FIFO 深度 512。
ROI 后的图像才进入独立双线性 golden 和原整数 DAG golden；测试不把预期特征灌入实际 DDR。
Q16 step/phase 由静态源/ROI/目标尺寸生成，保留半像素中心与原舍入规则。配置目前是 RTL 参数，**不是 CPU 可动态配置 ROI**。

## 2. 关键完成与错误合同

- 内部 Capture 的 `writer_done` 只通知相机入口，不能直接发布帧池 READY。
- 只有 `camera_result_valid && camera_result_admitted` 才完成已预约的 lease；同时要求 Capture 写事务、Resize 与相机入口全部排空。
- 接纳前源错误仍更新 CPU 错误统计与 IRQ，但不能向帧池发送不存在的完成事件。
- 已接纳帧的源错误/取消保留真实 AXI B 排空；失败 tag 不进入 CNN 或显示 FRONT。取消不能通过提前复用缓冲区“完成”。
- 相机源没有 ready，不因 CNN、DDR 或 FIFO 等待而改变 SOF 节奏。忙时跳过整帧的底层合同仍来自 C25；这不保证任意 DDR 延迟下零丢帧。
- `camera_seen/skipped/peak` 经 81-bit 最新值快照跨域。它是可合并的遥测，不是无损事件队列，不能用来驱动所有权。
- 两个时钟域需要协调复位，且两个时钟都必须运行并采到复位。数字仿真不证明亚稳态或物理 bundled-data/Gray 时序。

完整系统的相机错误码沿用 C25：1 标记错误、2 溢出、3 超时、4 取消、5 源错误、6 下游失败。

## 3. CPU 寄存器扩展

本地 APB16 地址，原 R2V2/R2H1 标识与已有控制寄存器不变。新增 `0x0080–0x00BF` 只读相机页；所有写、未定义/非对齐地址报错，不能因高位截断产生镜像地址。

| 偏移 | 只读含义 |
| --- | --- |
| 0x80 | `0x52324331`，R2C1 相机扩展标识 |
| 0x84 | bit0 核心入口 busy；bit1 快照有效；bit2 快照源 busy |
| 0x88 / 0x8C | 源 SOF 总数 / 跳过帧数的最新快照 |
| 0x90 | FIFO RAM 历史峰值；不计额外预取寄存器 |
| 0x94 / 0x98 / 0x9C | 核心最终结果数 / 失败数 / 未接纳结果数 |
| 0xA0 / 0xA4 | 最后结果 tag；bit0 admitted、bit1 failed、bit5:2 code |
| 0xA8 / 0xAC | 高16位高度、低16位宽度：完整源 / ROI |
| 0xB0 / 0xB4 | 高16位 ROI Y、低16位 ROI X；FIFO 深度 |

单个 81-bit 快照自洽；CPU 多次 APB 读取并非整个寄存器组的原子快照。需要软件原子读取协议时应另设计 latch/sequence，不能把逐寄存器读误当一个时刻。
已有 IRQ bit1 承载相机坏帧，bit2 承载入口溢出。取消目前仍为核心域 RTL 输入。

## 4. 验证记录与边界

独立 Python golden 使用两个确定性 RGB 合成图，先裁剪再双线性缩放；tag0 使用图0，后续 tag 使用图1。没有声称所有帧像素均不同，也没有重新证明模型的比赛视觉质量。

已完成的 C26 证据：

- 生产闭包 Icarus 编译：44 源，见 `logs/r2_camera_host_compile_20260913_a.log`。
- 原 22 节点图，8×8/32×32 × AXI 背压0/1：24 次正确 CNN，36,736 正确显示像素，138,448 完整源像素；入口最高 RAM 水位 42。见 `logs/r2_camera_host_matrix_20260913_a.log`。
- 8 项实际 RAM 破坏负控全部检出，涵盖输入数据及结果所有权；不是修改 expected 来模拟失败。见 `logs/r2_camera_host_negative_20260913_a.log`。
- Vivado xsim：`c26_camera_host_xsim_12x12_20260913_a`，31.802 秒，6 次 CNN/20 次相机采集/4,320 正确显示像素；独立相机时钟、背压1、AW等待W模式2、CPU负载并存。44 项相机页检查与13项旧主机 APB 检查通过。Job=false，私有工程已删除。

最终独立运行器与证据门禁均已完成：[r2_c26_gate_20260913_b.log](../logs/r2_c26_gate_20260913_b.log)。18节点图变体`c26_camera_variant_20260913_e`为536.934秒，4配置24次CNN、31,872正确显示像素、117,552源像素；四类完整主机故障`c26_camera_faults_20260913_g`为286.092秒，8配置8个预期坏源帧、48次正确CNN、40个故障后新任务。两个worker均Job=false，私有目录已删除。18节点变体未重新训练，不声称视觉质量。
四类故障为 SOF 源错（未接纳）、已有真实 Capture B 债务时源错/核心取消（保持 B 64 拍）、帧池已预约但子描述符尚未接纳时取消；均要求无复位的新 CNN 任务恢复。
首次故障 a 的 pending 注入早了一拍，修正为等待真实预约握手后再取消；它是 TB 失败，不是已证实的生产 RTL 缺陷。
四类故障的c运行已实际完成8配置、48次正确CNN、40个错误后新任务，独立数值/来源检查通过；其运行器把正常`error_irq=1`误匹配成ERROR，故保留failed状态而不当作最终门禁。
后续variant b/c/d与fault d/e/f也完成实际RTL测试，但运行器验收错误。最初怀疑输出落盘竞态，补WaitForExit及自行持有ReadToEndAsync任务后仍复现；**最终根因是大小写不敏感的`-notmatch '_VECTORS'`把CLEAN行中的`temporary_vectors`也过滤了**。对同一份完整日志，旧过滤后CLEAN计数为0，改为`-cnotmatch '^C1_R2_CAMERA_HOST_SYSTEM_VECTORS '`后为1，8条实际PASS保持不变，已直接复现。输出竞态并未得到证实，此前判断撤回；更稳健的显式stdout/stderr读取仍保留。所有历史failed状态不篡改，最终用修正过滤器的variant e/fault g重跑。

回归入口：

```powershell
# RunId 每次必须唯一；只调用外层，不手动调用 Worker。
./case1/scripts/run_r2_camera_regression_detached.ps1 -TestKind variant -RunId UNIQUE_VARIANT
./case1/scripts/run_r2_camera_regression_detached.ps1 -TestKind faults -RunId UNIQUE_FAULTS
./case1/scripts/run_r2_camera_host_xsim_detached.ps1 -RunId UNIQUE_SMALL -Stalls 1 -AwWaitW 2
```

新 [证据检查器](../golden/check_r2_camera_host_evidence.py) 核对源闭包、逐源 SOF 与最终完成、CNN 实际流量、像素计数、坏帧隔离、APB、xsim 隔离/清理和 MAP；不继承 C18 的摄像头请求时间线或帧率。
门禁a的证据变异自测检出检查器缺口：坏帧最终结果码与失败观察记录未交叉核对。补充tag/admitted/code/cycle一致性及B保持统计一致性后，原始RTL日志无需重跑，门禁b通过，6项证据篡改全部拒绝。日志过滤误删CLEAN也有独立回归保护。

## 5. Ti60 资源

[C26 工程](../efinity/c1_ti60_r2_camera_host96.xml) 的实际 Efinity MAP 为
`c26_camera_host96_map_20260913_a`，133.481 秒，结果与私有工程清理已核验：

| 范围 | LUT4 | 寄存器 | RAM | DSP |
| --- | ---: | ---: | ---: | ---: |
| 完整 C26 pin-reduced 主机探针 | 29,285 | 20,639 | 148 | 130 |
| 其中相机入口/FIFO | 277 | 403 | 2 | 0 |
| 其中遥测快照 | 53 | 158 | 0 | 0 |

Resize 仍为12 RAM/18 DSP，Capture writer仍为5 RAM；CNN层次122 RAM/112 DSP。
MAP 的 LUT4/寄存器不能相加冒充 PNR XLR；本轮**没有 C26 PNR/Fmax/物理 CDC 签核**。
静态 ROI/Q16 会剪除部分动态配置逻辑，不能直接用两个不同探针的 LUT 差值断言整机面积节省。

此前官方必要平台核验为 17,361 XLR/105 RAM/4 DSP；仅按 RAM/DSP 粗加，C26＋平台为 **253/256 RAM、134/160 DSP**，只剩3 RAM。尚未包括最终接口适配、CDC约束结果或完整联合实现。
C24 PNR 与官方逻辑粗加已略超60,800 XLR；C26只有MAP，不能说逻辑已闭合。需要减少平台重复缓存/非必要功能，或继续缩减内部存储，并且只保留一套DDR控制器和统一时钟规划。

## 6. 持续吞吐与下一步

C21、C22 独立原生六帧长仿真均在本阶段完成：实际完成间隔完全一致，满负载最差9,794,650周期，按各自已通过的150MHz物理时序约 **15.3145 fps**。其吞吐余量仅2.05%；证据分别为 `logs/r2_c21_native_gate_20260913_a.log` 和 `logs/r2_c22_native_gate_20260913_a.log`。
这是压缩权重/特征存储后未退化的证据，不是新加速，也不是 C26/板测帧率。

C26 原生入口已改用完整 1920×1080 不可回压源，实际时钟周期为13.468ns/6.666ns，SOF间隔2,475,000相机周期。折合核心相邻接纳约5,000,495或5,000,496周期，不能沿用C18严格5,000,000周期的检查。
尚须用这条完整新源链路证明原生容量和持续 CNN 吞吐；不以小图外推、不以两帧前端测试代替六帧整机并发。

原生在途运行：`c26_camera_host_xsim_native_sixframe_20260913_a`，WMI worker 27900，启动时间`2026-09-13T21:47:55.2853211+08:00`，Job=false；每步骤执行上限14,400秒，不因观察超时重启。
首帧实际Capture在核心周期4,802,251完成76,800个128-bit写beat，最终入口结果同拍成功；CNN于4,802,252启动。第二源SOF为相机周期2,475,031，仍保持2,475,000相机周期固定间隔。
截至首帧CNN完成：22层提交、1,442,333读beat/1,353,600写beat逐项golden通过，CNN计数9,253,821周期；实际完成周期由START＋计数＋1重建为14,056,074，下一任务tag1于14,056,075开始。第二次完整Capture也成功（周期9,802,961）。这些是原生单帧及在途证据，尚无六帧结果或C26持续帧率结论。

后续主线：完成 C26 原生联合结果 → Gray/bundled-data 物理约束和完整资源闭合 → 官方2像素/周期 ISP 输出适配、Sapphire/DDR/HDMI实际平台集成。官方 v1 Debayer 是2像素/周期输出，本入口是1 RGB/valid，不能直接连接。
真实 CPU 程序、CSI/DDR/HDMI PHY、板级时序/显示及模型视觉质量仍待验证；整体 CNN 执行架构重构目标保持未完成。

## 7. 过程与文件清理

中断前 variant a 仅完成3/4配置，faults b 仅完成部分配置；已核实 Python/vvp 进程不存在，随后删除两处明确私有目录，共37,015,723字节（约35.3MiB），保留原日志。它们不计入最终通过证据。
新增独立 [Icarus 运行器](../scripts/run_r2_camera_regression_detached.ps1) 把向量/编译产物限制在自己的私有父目录，WMI worker 验证 Job=false，正常/失败均清理私有文件。Vivado仍使用独立WMI运行器；所有仿真不生成波形，只保留必要文本。

最终[清理审计](../logs/r2_c26_cleanup_20260913.json)确认本轮12个独立工具运行中11个已终结且私有目录不存在；仅保留正在运行的原生xsim私有目录，未清理或重启它。C26现有必要日志/元数据文本共1,005,778字节（约0.96MiB，不含仍在运行的临时工程）。8份入口/报告文档的本地链接亦已检查。
