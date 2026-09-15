# R2-C3：真实 DW 供数、残差与四算子共享执行器

日期：2026-09-13。保留 R1 整机和既有 R2 原型，不替换旧默认入口。
本阶段范围是行/tile 执行子系统，不是完整 CNN、CPU/DDR 接口或板级系统。

## 1. 架构与代码入口

新入口 `rtl/r2/c1_r2_cnn_row_engine.sv` 支持四类作业，仍只有一套
`c1_r2_compute6`＝96 路 INT8 乘加＋六路量化。没有为 DW 或残差再复制计算核。

| 文件 | 职责 |
|---|---|
| `c1_r2_cnn_row_engine.sv` | 锁定作业 owner、检查形状/地址/量化字段、选择供数、一级弹性请求寄存器、最终结果退休 |
| `c1_r2_pw_linear_feeder.sv` | 共用双 bank 特征 RAM，提供固定 PW16→8 或同尺度残差的六路操作数 |
| `c1_r2_spatial_feeder.sv` | 共用空间 RAM 和参数池，提供 RGB3×3 或 DW16/24/48；DW 三种 lane 映射使用常量布线 |
| `c1_r2_group_window_store.sv` | 三行×奇偶 bank 的 C8 特征存储、边界复制、连续两拍读取、两个预留窗口槽 |
| `c1_r2_compute6.sv`（既有、未改） | first 绑定的量化参数 FIFO、共享 MAC、量化和在途事务计数 |

数据路径为：host 装载选定 RAM/参数 → 作业锁存 → PW/残差供数或 RGB/DW 窗口供数
→ 一个请求寄存器 → 共享 compute6 → 六路 signed8 输出。最终输出握手前不释放 owner，
不允许重新装载或启动。输入 mode、size、channels、边界标志在 busy 期间变化无效。

只有两个存储池：PW/残差共用 16 RAM；RGB/DW 共用 48 RAM。它们尚不是统一动态
分配的 tile SRAM，也没有乒乓装载。不同算子共享空间池意味着切换前必须按需重装，
**不能假设 RGB 和 DW 的各自参数、或 PW 和残差的各自特征在相互覆盖后仍然保留**。

## 2. 算子规则及内部 ABI

| mode | 工作 | start_size | start_channels | out_index |
|---|---|---|---|---|
| 0 | PW1×1，Cin16→Cout8 | 1…1024 像素 | 16 | 展平输出标量的起点 |
| 1 | RGB3×3，Cin8→Cout3 | 1…1024 行宽 | 8 | 两输出像素中的第一个 x |
| 2 | DW3×3，Cin16/24/48 | 最大分别 1024/682/340 行宽 | 16/24/48 | `{0,x[9:0],C8_group[2:0],batch[1:0]}` |
| 3 | 同尺度 signed8 饱和加法后 ReLU | 1…8192 标量 | 忽略 | 展平标量起点 |

这是新的内部探针 ABI，不是 R1 的 CPU/APB ABI。PW/RGB 仍是上述固定通道形状，
不能由“四种 mode”推断所有卷积层已经支持。

### DW 映射

每次取同一 C8 组的 3×4 像素窗口，为两个相邻输出像素服务。每对像素/每 C8 组
有 16 个输出标量，用六 lane 分三批处理，局部标量起点为 0、6、12。
每标量只用九个乘法项，补齐到 16 个归约项。主算术单元与 PW/RGB 一致。

对 lane r，`local=batch*6+r`，像素为 `x+local/8`，通道为 `group*8+local%8`。
`local>=16` 或越过行尾时 mask=0。奇数宽最后一对的 batch2 是全零 mask，但仍有
一个输出事务，必要时携带 out_last；消费者必须消费该退休事件，不能因 mask=0 卡住。
DW tag **不是 HWC 线性地址**，后续输出打包器/张量 writer 必须显式转换。

偶数宽时，有效 lane 比为 16/18；同时每 lane 仅九个有效归约项，所以该 DW 映射
总有效乘法利用率为 50%。相对理想六路展平 DW 调度，向量数多 12.5%；不能把这些
填充成本隐藏成“96 MAC 满利用”。后续是否跨 C8 组拼批，需要与选择网络成本一起评估。

### 残差定点规则

`model/microstyle_quant.py` 的当前工件把残差两输入约束到相同尺度：先 signed16
相加、饱和到 signed8，再 ReLU。与 R1 的同尺度 `sat_add_s8` 规则一致。
新供数器每 128-bit 记录装八个 A 和八个 B，六路请求的前两项分别为 A、B，系数均为 1，
其余项为零；bias=0、mult=1、shift=0、ReLU=1。因此复用计算阵列即可精确实现。
不支持任意异尺度残差，也没有在此更改模型量化约定。

### 装载布局

- PW：沿用既有四个 32-bit word/像素和八输出通道权重/参数格式。
- 残差：`kind0, addr=record*4+word`；128-bit 记录低八字节为 A，高八字节为 B。
  其余 kind 在共享入口拒绝。
- RGB/DW 特征：`addr=(row<<12)|((x&1)<<11)|((((x>>1)*groups+group)<<1))|word`，
  row=0/1/2，word=0/1。这与旧独立 RGB 探针地址布局不同，golden 装载端已显式转换。
- RGB 权重：O(HW)I 顺序，每输出通道 80 字节（有效 72），`kind1 addr=c*20+word`。
- DW 权重：每通道九个 tap，补到 12 字节，`kind1 addr=c*3+word`；补齐字节故意写非零，RTL 必须忽略。
- kind2 为通道 bias，kind3 为 `{reserved[6:0],ReLU,shift[5:0],signed_mult[17:0]}`；
  reserved 必须零，shift≤47。PW/RGB/DW 参数通道上限分别为 8/3/48。

原始特征按 HWC 的 C8 分组装载，不装预展开的九 tap/16 项 MAC 向量。
三行边界及横向边界均由 RTL 复制，golden 对越界物理行写入故意不同的值。

## 3. 发现并修复的问题

第一轮 `r2_cnn_row_probe_20260913_a.log` 在 C48/W341 的随机向量失败，未作为 PASS。
原先按 `width*groups<=2048` 检查总容量，忽略了奇偶 bank 的不均衡。
W341/C48 时偶 bank 需要 `ceil(341/2)*6=1026` 项，超过单 bank 的 1024 项，产生地址别名。

修正为单 bank 条件 `ceil(width/2)*groups<=1024`，C48 最大合法宽度为 340。
顶层和供数器硬件握手、窗口断言、Python 地址生成与预算检查同步修正。
测试覆盖 339/340、拒绝 341，并覆盖 C24 的 681/682、拒绝 683，C16 的 1024/拒绝 1025。
模型实际的 C48/W160 不受该限制影响。

修正后 b 回归通过，但首版物理结果为 37,537 XLR（61.74%）。为减少 DW 的一般
动态位选择，将三种实际批次映射显式展开为固定布线，再做三选一；不增加缓存、计算核或拍数。
最终 c 回归与 b 物理运行通过，省 520 XLR（1.39%），收益不大，不能据此认定动态
gather 是主要面积根因。寄存器化参数池及后续通用 PW 的容量/读口成本仍需审查。

## 4. 功能与周期证据

入口 `golden/run_r2_cnn_row_probe.py`，TB 为 `sim/tb_c1_r2_cnn_row_engine.sv`。
连续/长背压各 65 作业：PW 13、RGB 13、DW 25、残差 14；各 46,362 个输出向量，
255,937 个有效标量，其中 119,040 个由真实训练工件的整数 golden 校核。
训练测试使用 640×4 图像的实际中间特征，覆盖 stage3/7/11/15/18/19/20 和 stage5/9/13。
这是原生宽度条带及随机边界，不是 640×480 整网 RTL 测试。

独立参考直接按 OIHW 标量循环计算 DW，再与整数模型结果交叉检查；不复刻 RTL 批次算法。
TB 另外核对每个完整 96 字节 SRAM 窗口（包括保持周期），每配置消费 13,352 个窗口。
覆盖 54 次模式变化、忙时 load/start 和所有 live 配置扰动、signed32 模溢出、signed18
正负极值、正负 ties-away、饱和/ReLU、44 个全零 mask 事务、满窗口槽同拍替换。

18 种非法输入拒绝；三种在途复位分别在第二拍 RAM 读取待发、RGB 部分 K 归约、
长背压填满窗口/计算流水时进行。reset 后不得残留输出/请求/owner，RAM 和参数不清空，
重启同一已装载作业。此处的 reset 只适用于核内，不替代外部 AXI 债务排空协议。

最终日志为 `logs/r2_cnn_row_probe_20260913_c.log`；修改前功能通过的 b 日志保留。
两版共 130 条作业日程记录逐条相同。最终背压配置累计 50,037 个输出阻塞拍，满窗口槽
同拍 pop/push 13,278 次；这些是被实际执行的覆盖，不是参数设置推定的覆盖。
`golden/check_r2_cnn_row_evidence.py` 核验作业数、标量数、训练层集合、窗口读工作量、
尾 mask、周期、复位/非法输入、物理层级和约束，并拒绝八种日志破坏。日志负测试不是 RTL 故障注入。

| 作业 | 无背压 start 至最后结果握手 | 稳态 |
|---|---:|---|
| PW，640×Cin16→Cout8 | 867 拍 | 一向量/拍 |
| RGB，640×Cin8→Cout3 | 1,615 拍 | 每五拍一个双像素向量 |
| DW，640×C16 | 1,935 拍 | 一向量/拍 |
| DW，320×C24 | 1,455 拍 | 一向量/拍 |
| DW，160×C48 | 1,455 拍 | 一向量/拍 |
| 残差，3,840 标量 | 653 拍 | 一向量/拍 |

PW/残差公式为 `ceil(输出标量/6)+13`，RGB 为 `5*ceil(width/2)+15`，DW 为
`3*ceil(width/2)*(channels/8)+15`。每窗口恰好两拍同步 RAM 读取，窗口预留及预取
没有引入额外稳态气泡。PW 相比 C2 多一拍请求寄存器；RGB 的窗口返回节省一拍，抵消
新增请求寄存器后仍为 1,615 拍。**全部周期均排除 host 装载、DDR 等待及结果写回。**

## 5. Efinity 物理证据

工程 `efinity/c1_ti60_r2_cnn96.xml`，Ti60F225 I3、6.666 ns 核级约束。

| 版本/RunId 后缀 | DSP | RAM | XLR | FF | setup/hold 余量 |
|---|---:|---:|---:|---:|---|
| 动态选择，`…20260913_a` | 108 | 64 | 37,537 | 17,367 | 1.075/0.071 ns |
| 固定 DW 映射，`…20260913_b` | 108 | 64 | 37,017 | 17,367 | 1.099/0.071 ns |

完整 RunId 前缀为 `c1_ti60_r2_cnn96_i3_`。只使用 WMI 脱离式运行器，不启动 Vivado。
层级检查要求只有一个 compute（108 DSP）、一个 MAC（96 DSP）、一个量化器（12 DSP），
两个 feeder 均为 0 DSP，线性池/空间池分别 16/48 RAM。
没有 CPU、DDR PHY、视频接口、PLL 或 I/O delay 约束，核内时序通过不能当作板级签核。

两次 map+PNR 运行分别约 230.8/235.2 秒。最终使用 DSP 108/160（67.5%）、
RAM 64/256（25%）、XLR 37,017/60,800（60.88%）；map LUT=22,661、FF=17,367，
核内路径估计 Fmax=179.630 MHz。默认目标仍为约 150 MHz，不以 Fmax 估计外推系统 fps。
相对 C2 的 23,259 XLR/40 RAM，支持完整 DW 通道和残差的 C3 多 13,758 XLR/24 RAM；
剩余 23,783 XLR 不能直接当作 CPU/DDR/视频已能放下的证明。资源合并仍是后续重要门槛。

## 6. 更新的预算和剩余工作

`golden/r2_cnn_schedule_budget.py` 将已验证算子的行级填充及启动/排空计入原生调度预算，
其余尚未实现算子仍暂用 R2-A 理想值；因此它是**不同完成程度的混合估计**。
640×480 从原 5,805,600 理想拍更新为 6,098,030 拍：包含 DW C8 填充损失、残差
六路而非旧八路线性预算，以及已实现行执行器的开销。单行周期之和为 6,095,640 拍，
另加这些已实现阶段内的 2,390 拍行间重启间隔：最后结果握手当拍尚不能接受下一次 start。

按假设的 150 MHz，15 fps 的每帧限额为 10,000,000 拍，预算还余 3,901,970 拍。
这不是端到端余量保证：装载/写回、DDR 多主争用、描述符开销、通用 PW/encoder 真实
供数成本尚未计入；upsample/view elision 仍只是原预算假设。脚本明确返回
`measured_frame_fps=None`。目前仍不能发布新的整网实测 fps。

下一主线应是：

1. 支持网络中的其他 PW 通道形状，尤其 24→48、48→24、24→16；保持单阵列，同时审查参数的 RAM/寄存器分工、多 K 供数和参数容量，避免继续线性扩大寄存器池。
2. 支持 encoder 的 3×3 stride2 和虚拟上采样地址生成，使 stage0/1/15/18 的真实输入可以自动连续供给。
3. 实现 DW tag 到 HWC/C8 的输出打包、片上 DW→PW 交接，以及统一 tile/行存储计划；现有 host 逐行重装不能作为高吞吐部署方案。
4. 接宽口 DMA、装载/计算/写回重叠、背压与取消排空，再连接 R1 的 CPU/DDR/视频平台。
5. 做完整 22-stage 小图和原生 640×480 测量，以及含 Sapphire/视频平台的 Ti60 资源及时序评估。

## 7. 复现和清理

```powershell
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe -B -u case1/golden/run_r2_cnn_row_probe.py
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe -B case1/golden/check_r2_cnn_row_evidence.py
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe -B case1/golden/r2_cnn_schedule_budget.py
./case1/scripts/run_efinity_ti60_resource_map_detached.ps1 -DesignName c1_ti60_r2_cnn96 -RunId UNIQUE_NEW_ID -ProjectInPlace -RunPnr -TimeoutSeconds 600
./case1/scripts/check_r2_cnn_closure.ps1
```

仿真使用一次性目录，测试向量和 vvp 在退出时删除，不生成波形。EDA 私有临时目录由
WMI worker 的 finally 清理；结束后另查 worker 退出与目录不存在。保留失败原因、简短
仿真日志、资源/时序摘要及检查器日志；最终清理统计见 closure 日志。

`logs/r2_cnn_evidence_gate_20260913.log` 各 gate 通过；
`logs/r2_cnn_closure_20260913.log` 确认两次 worker 已退出、两个 EDA 私有目录和本轮
模拟器临时目录均不存在。两次 EDA 保留文本 130,803 字节，三次仿真日志合计 59,352
字节，总约 0.181 MiB（不含几 KB 检查器/预算文本）。没有保留波形、vvp 或大工程。
