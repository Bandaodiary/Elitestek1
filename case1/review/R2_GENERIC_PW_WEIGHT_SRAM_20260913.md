# R2-C4：通用 PW 与共享权重 SRAM

日期：2026-09-13。持续目标仍是保留旧 RTL 备用基线并重构 CNN 执行架构。
本阶段完成模型全部 PW 形状的 SRAM 供数，以及 PW/RGB/DW 参数存储共享。
**不是完整 22-stage 图执行、DMA 集成或 15 fps 验收。**

## 1. 结构变化与入口

新入口 `rtl/r2/c1_r2_cnn_tile_engine.sv`。旧 R1、C2/C3 入口及其测试均保留，
没有更改 `c1_r2_compute6`、MAC、量化器或公共 RAM RTL。

| 模块 | 功能 | 本轮物理资源边界 |
|---|---|---|
| `c1_r2_cnn_tile_engine.sv` | 作业 owner、形状/装载互锁、共享参数读口选择、请求寄存器与最终退休 | 不含 CPU/AXI |
| `c1_r2_weight_store8.sv` | 八 bank 的同步权重读取，统一 bias/量化参数及其读流水 | 64 RAM、0 DSP |
| `c1_r2_pw_banked_feeder.sv` | PW 多 K 归约、跨像素六标量映射、Cin24 尾项屏蔽；兼容同尺度残差 | 特征池 16 RAM、0 DSP |
| `c1_r2_spatial_banked_feeder.sv` | DW/RGB 的窗口操作数与公共参数 SRAM 返回对齐；不再保存私有参数 | 空间池 48 RAM、0 DSP |
| `c1_r2_group_window_store.sv`（既有） | C8 三行窗口、奇偶 bank、边界复制、两槽预留 | 已包含在空间池中，不能重复计数 |
| `c1_r2_compute6.sv`（既有） | 一套 96 MAC＋六路量化、first 绑定参数 FIFO、在途事务计数 | 108 DSP、0 RAM |

供数器发起特征和权重读取 → 同步 SRAM 返回 → 六路操作数/参数对齐 → 请求寄存器
→ 共享 compute6 → 输出。权重端始终只有一个 owner；busy 时禁止装载和新作业。
其中空间供数器增加一级弹性操作数流水，将窗口数据与权重返回对齐，稳态不增加气泡。

当前是**两个特征池＋一个公共参数池**，不是三个模式各存一套权重，也不是所有
tile 存储已统一分配。跨模式切换通常覆盖公共权重、bias 和量化参数，下一作业必须
重装所需内容；reset 不清 RAM/参数，只清消费者和在途控制。调用者负责初始化所有有效项。

## 2. PW 调度和支持范围

PW 支持 Cin∈{16,24,48}、Cout∈{8,16,24,48} 共 12 种组合；其中模型实际使用
24→48、48→24、24→16、16→8。输出仍按 HWC 展平顺序，每事务最多六个标量，
不为每个像素单独补齐到六通道，因此保留 16→8 原来的跨像素 packing 效率。

归约长度按 `ceil(Cin/16)` 分为 1/2/3 拍，只有第一拍初始化 bias、绑定量化配置，
最后一拍输出累加结果。Cin24 的第二拍仅八项有效；host 对额外输入及权重字节故意
写非零毒值，RTL 将额外输入八项强制置零，而不是依赖软件补零碰巧正确。

### 为什么八 bank 能服务六 lane

权重 bank 为 `输出通道 % 8`，bank 内选通道组及 K16 分块。
六个连续输出标量在当前 Cout 均为 8 的倍数的条件下，即使跨越像素边界也仍落入
六个不同 bank。各 bank 独立选择当前/下一 C8 通道组，低三位选择返回数据。
特征按像素奇偶放两个 bank，每拍同时取得可能用到的相邻两个像素的同一 K16 分块。

例如 Cout16、起始通道 12 的六输出为当前像素通道12…15和下一像素通道0…1；
权重 bank 依次为4、5、6、7、0、1，前四 lane 和后两 lane 使用不同像素的特征。
TB 的最终数值参考直接按实际 Cin 的标量点积计算，不依赖这套 bank 公式。

### 参数容量与限制

| mode | start_size | start_channels | start_outputs |
|---|---|---|---|
| 0 PW | Cin16 最大1024像素，Cin24 最大512，Cin48 最大340 | 16/24/48 | 8/16/24/48 |
| 1 RGB3×3 | 最大1024行宽 | 8 | 忽略，实际输出3通道 |
| 2 DW3×3 | C16/C24/C48 最大1024/682/340行宽 | 16/24/48 | 忽略，输出与输入通道相同 |
| 3 同尺度残差 | 1…8192标量 | 忽略 | 忽略 |

PW 容量条件为 `ceil(pixels/2)*ceil(Cin/16)<=512`，按**单个奇偶 bank**而非总字节数判断。
当前仅支持表内 PW 形状；并不意味着任意 CNN 卷积、异尺度残差或 encoder 已可执行。

## 3. 新装载布局与输出合同

这仍是 R2 内部接口，不是 R1 APB/CPU ABI。新增 `start_outputs[5:0]`，仅 PW 使用。

- PW 特征：`addr=((pixel%2)<<11)|(((pixel/2)*Kchunks+K16)<<2)|word32`，每块16字节。
  Cin24 实际存两块32字节；Cin48 存三块48字节。
- 残差特征：同上但 Kchunks=1；128-bit 记录低八字节 A、高八字节 B。仍做同尺度
  signed8 饱和加后 ReLU，kind1/2/3 装载在残差 mode 拒绝。
- RGB/DW 特征：沿用 C3 的三行 C8 分组地址和边界规则。
- 公共权重：`kind1 addr={bank[2:0],channel_group[2:0],K16[2:0],word32[1:0]}`。
  每个通道的每 K16 有四个 32-bit word。PW 最多 K16=2；RGB最多4；DW仅0、低九字节有效。
- 公共 bias/affine：kind2/3 的地址均为线性输出通道号。PW/DW最大47，RGB最大2；
  affine 仍是 `{reserved[6:0],ReLU,shift[5:0],signed_mult[17:0]}`，reserved=0、shift≤47。

权重每 bank 有64个128-bit逻辑位置，以32个32-bit SDP RAM实例实现；bias和affine
按48通道保留浅寄存器，八 bank 的参数输出也在读取边沿锁存。没有继续复制完整 PW/DW 参数池。
功能支持最大的 PW48→48 权重为2304个有效字节；整个权重池逻辑容量8KiB，并非全部被有效系数填满。

PW/残差 out_index 是展平标量起点；RGB 是首像素 x；DW 仍是 C3 的
`{0,x[9:0],C8_group[2:0],batch[1:0]}`，不是线性 HWC 地址。DW 全零 mask 的尾事务
仍须消费以退休作业。下阶段的输出打包/张量 writer 不能忽略这些差异。

## 4. 功能验证

入口 `golden/run_r2_cnn_tile_probe.py`，TB 为 `sim/tb_c1_r2_cnn_tile_engine.sv`。
结果为 `logs/r2_cnn_tile_probe_20260913_a.log`，连续和长背压两种配置均通过。

每配置114个作业：PW62、RGB13、DW25、残差14；69,827个输出向量、396,681个有效
标量，其中163,840来自真实训练工件的整数 golden。沿用全部C3作业，新增模型实际
stage2/4/6/8/10/12/16 的原生宽度条带，以及12种PW组合和最大容量/奇数边界随机测试。
原生训练输入仍为640×4图像；各层输入由 Python 提供真实中间结果，不是 RTL 层间串联。

每配置还独立检查690,509次参数 bank 返回，逐项核对权重、bias和affine是否匹配
前一拍读取地址；比较13,352个完整空间窗口，验证78次模式切换与44个全零mask事务。
完整输出同时核对mode/index/mask/data/last，每作业单独核对特征读取、权重读取及MAC beat数量。

覆盖 busy 时不断改变 mode/Cin/Cout/size/边界，同时尝试load/start，不能改写在途所有权；
24类非法形状/地址/参数字段被硬件握手拒绝。四类在途reset包含PW多K部分归约、
窗口第二次读取待发、RGB部分归约和长背压填满流水。reset后同一已装载作业可恢复，
不残留旧输出。这里的reset不代表已实现外部AXI取消债务排空。

最终背压配置累计82,807个输出阻塞拍，满窗口槽同拍替换13,278次。检查器另拒绝
八种破坏后的日志；这是证据检查器负测试，不是RTL故障注入。

## 5. 周期与预算

| 行作业 | start至最后结果握手 | MAC读取/归约拍 |
|---|---:|---:|
| PW24→48，160像素 | 2,573 | 2,560 |
| PW48→24，160像素 | 1,933 | 1,920 |
| PW24→16，320像素 | 1,721 | 1,708 |
| PW16→8，640像素 | 867 | 854 |
| RGB Cin8→3，640像素 | 1,616 | 1,600 |
| DW C16，640像素 | 1,936 | 1,920 |
| DW C24/C48，320/160像素 | 1,456 | 1,440 |
| 残差3,840标量 | 653 | 640 |

PW公式为 `ceil(pixels*Cout/6)*ceil(Cin/16)+13`。权重读与特征读并行，每拍可发射
一拍归约；不需要每向量额外读取bias或停顿等待参数。空间路径因同步权重对齐比C3
增加一拍启动/排空延迟，稳态RGB仍每五拍两像素、DW仍一向量/拍；PW/残差周期不变。
全部周期排除host装载、DDR等待和结果写回。

`golden/r2_tile_schedule_budget.py` 把17个已支持阶段的行周期、填充及必要行间重启
计入原生640×480估计，其他encoder/view仍采用理想假设，混合估计为6,113,143拍。
以150MHz假设比较15fps的10,000,000拍限额，还余3,886,857拍，但尚未计入DMA、
多主争用、图调度和实际encoder/view供数。因此 `measured_frame_fps=None`，不能作为
“已达到24fps”或“已达到15fps”的证明，更不能认为已跑过原生全帧RTL。

## 6. Efinity：面积下降，RAM成本高于预估

工程 `efinity/c1_ti60_r2_tile96.xml`，Ti60F225 I3、6.666ns核级约束。
`c1_ti60_r2_tile96_i3_20260913_a` 完成map+PNR，约186秒。

| 指标 | C3最终 | C4本轮 |
|---|---:|---:|
| XLR | 37,017 | 27,752 / 60,800（45.64%） |
| FF | 17,367 | 12,929 |
| map LUT | 22,661 | 18,816 |
| DSP | 108 | 108 / 160（67.5%） |
| Memory Block | 64 | 128 / 256（50%） |
| 150MHz setup余量 | 1.099ns | 1.110ns |
| hold余量 | 0.071ns | 0.089ns |

扩展PW功能后XLR反而下降9,265（25.03%），FF下降4,438；权重转SRAM并统一参数池
实现了实际逻辑资源收益。核内路径估计Fmax为179.986MHz，目标仍取约150MHz。

但RAM不能按最初的96块预估交付：本次映射中，**每个32×64的权重SDP实例实际用两块RAM**，
32实例共64块，加16+48特征块，总计128。这里记录实测映射，不未经审计推断厂商RAM的
所有原语模式/最大位宽。没有把预算不符解释成通过预定RAM目标；最终采用的是明确的
“约9.3k XLR换64 RAM，并扩展PW形状”的取舍。

当前尚余33,048 XLR、128 RAM、52 DSP，但不能直接断言Sapphire/DDR/视频全系统已经
放得下。高端口带宽的权重银行浪费部分容量，后续若系统RAM紧张，应评估推断/原语布局、
权重预取与较窄缓存，而不是盲目继续加bank或把企业高RAM占用视频工程原样拼接。

原资源摘要只保留40条层级，32个权重RAM子实例使空间/计算核被截断。因此将运行器
的有界上限改为80，并以 `…20260913_b` **仅补跑map**，约47秒；没有重复PNR。
两次map的FF/LUT/RAM/DSP统计一致，b完整层级证明公共权重64RAM、线性16RAM、
空间48RAM，compute0RAM/108DSP，MAC96DSP、量化12DSP。a仍是唯一PNR证据。
该脚本变化仅扩大少量摘要保存范围，不改综合开关或RTL。

本工程不含CPU、DDR PHY、视频/PLL及板级I/O延迟约束，不能当作完整系统时序签核。

## 7. 剩余主线和复现

下一步应补齐两个encoder的3×3 stride2供数，以及decoder虚拟上采样映射。
随后完成算子间真实数据交接、DW tag打包、图调度、宽口DMA与装载/计算/写回重叠，
再接既有R1的CPU/DDR/视频平台并运行完整22-stage及原生640×480验证。
当前权重地址中已有三位K16字段，但不能据此声称encoder供数已实现。

```powershell
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe -B -u case1/golden/run_r2_cnn_tile_probe.py
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe -B case1/golden/check_r2_tile_evidence.py
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe -B case1/golden/r2_tile_schedule_budget.py
./case1/scripts/run_efinity_ti60_resource_map_detached.ps1 -DesignName c1_ti60_r2_tile96 -RunId UNIQUE_NEW_ID -ProjectInPlace -RunPnr -TimeoutSeconds 600
./case1/scripts/check_r2_tile_closure.ps1
```

最终gate见 `logs/r2_tile_evidence_gate_20260913.log`，清理见 `logs/r2_tile_closure_20260913.log`。
两个WMI worker均已退出，EDA私有目录和本轮Icarus临时目录均不存在，不生成或保留波形。
两次EDA摘要136,592字节，仿真日志56,038字节，合计约0.184MiB（另有几KB gate/预算文本）。
