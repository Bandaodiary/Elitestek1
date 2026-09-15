# R2-C9：128位AXI行DMA与完整CNN图核

## 阶段范围与当前结论

本阶段保持R1、C5/C6/C7/C8源码和入口不变，将C8完整MicroStyle24图核接入真正的
AXI4五通道主机接口。默认128位数据、16拍burst、读写各最多4笔物理事务在途，
固定ID=0、同方向响应按序。没有增加整行/整burst数据缓存，也没有复制计算阵列。

代码、独立DMA、四尺寸完整图矩阵和原生640×480 xsim已通过，最终版本Efinity核级
150MHz map+PNR通过。真实AXI图核实测9,297,258拍，150MHz折算16.13fps，仍达到
本阶段共享1.2GB/s、每物理burst延迟20拍模型下的15fps门限；不是整机或板测结果。
W先于AW的完整图压力回归、真实RAM污染负测试及最终证据门禁均已通过。
本阶段C9完成；整体CNN重构的CPU/多主DDR/视频集成仍未完成。

## 新增文件及关系

```text
start/运行时地址与尺寸
        ↓
c1_r2_microstyle_axi_graph                 C9：AXI包装和故障隔离
  ├─ c1_r2_microstyle_pingpong_graph      C8：原计算/缓存/双页调度保持不变
  │    ├─ tensor_stream_loader → bulk engine → 唯一96-MAC＋6路量化
  │    └─ tensor_pingpong_writer         两页结果RAM、计算/写回重叠
  ├─ c1_r2_axi_row_read                  行 → AR burst队列 → R弹性寄存器
  └─ c1_r2_axi_row_write                 行 → AW/W独立游标 → 所有B屏障
        ↓
128-bit AXI4主机 →【待接：多主仲裁/CPU/DDR控制器/视频】
```

| 文件 | 职责与关键边界 |
| --- | --- |
| `rtl/r2/c1_r2_axi_row_read.sv` | 将一个逻辑行拆为合法INCR burst；登记ARLEN、顺序收R、一拍128位弹性缓存；行尾必须等所有已声明burst排空 |
| `rtl/r2/c1_r2_axi_row_write.sv` | AW、W、B分别推进；AW握手计入物理债务，B退休释放credit；不等待旧B才发送下一burst的W |
| `rtl/r2/c1_r2_microstyle_axi_graph.sv` | 复用C8图核，提供AXI sideband、busy/done、物理在途计数；协议故障后的未发送本地页以错误方式退休 |
| `sim/c1_r2_axi_memory_bfm.sv` | 非综合AXI从机模型；独立AR/W/B队列、共享读写服务预算、每物理burst延迟、有限故障注入 |
| `sim/tb_c1_r2_axi_row_dma.sv` | 独立地址/数据模式与事务守恒，跨页/背压/故障/恢复检查 |
| `sim/tb_c1_r2_microstyle_axi_graph.sv` | 真正层间RAM交接、Python逐字golden、producer所有权、22节点提交及最终B屏障 |
| `golden/run_r2_axi_probe.py` | 临时向量与Icarus运行，失败返回错误，结束删除本轮目录 |
| `golden/check_r2_axi_evidence.py` | 小型日志和物理结果检查；包含损坏证据的反向测试，不替代仿真 |
| `scripts/run_r2_axi_xsim_detached.ps1` | WMI独立worker；验证不属于Windows Job，再启动Vivado；不保留波形/快照 |
| `efinity/c1_ti60_r2_axi96.{sv,xml,sdc}` | 17个源文件的Ti60核级观测工程；6.666ns约束，不是板卡引脚工程 |

## 接口与错误合同

- 逻辑行首地址16字节对齐，长度1…65535个128位字，不能越过32位地址空间；
  实际图核沿用C8运行时尺寸及8MiB基址/区间不重叠限制。
- 每个burst取剩余长度、配置最大长度、当前4KiB页剩余长度中的最小值。
  支持`BURST_BEATS=1…256`、`OUTSTANDING=1…16`；本轮验证1/3/4槽而非宣称全部参数已测。
- 两个方向ID均为0，SIZE=4、BURST=INCR；LOCK/CACHE/PROT/QOS输出0。
  不支持跨ID乱序重排，不是CPU/摄像头/显示的多主仲裁器，也不提供缓存一致性。
- `read_outstanding`是实际AR握手减已退休物理R burst；`write_outstanding`是实际
  AW握手减已接受B。writer两页所有权、待发送描述符与物理AXI credit不能混为一谈。
- W描述符在AW被呈现时保留，不能等AWREADY才允许WVALID；支持整个W burst先于AW
  握手完成，B仍只能在AW/W均完成后接受。此依赖要求来自
  [Arm AMBA AXI规范A3握手依赖](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)。
- 普通RRESP/BRESP错误：继续完成该行全部声明的物理事务，向图核报告错误，不发布
  失败帧，排空后可无复位运行下一帧。
- RLAST/RID/BID和输入行framing错误：粘滞`protocol_error`，禁止下一帧直到SYSTEM reset。
  已由DMA拥有的行继续排空；还仅由C8拥有、未交给DMA的页在包装层本地消费并报错，
  不再向被锁住的总线发新行，防止第二页永远等待`cmd_ready`。
- 测试的早RLAST会结束那个物理burst，DMA用错误零值补齐其缺字后排空后续burst；
  缺RLAST测试仍严格返回ARLEN+1拍。**任意多余R、从机永不响应、独立CPU取消、局部
  reset面对仍存活的DDR端点均不在已闭合恢复合同内**；没有硬件看门狗。
- 最后一个W完成不代表帧完成。仅在全部B及读债务排空后才允许stage20/21提交，
  并保持done直到done_ready。失败帧可能已局部写入DDR，系统仍需禁止显示发布该缓冲。

## 功能证据

最终RTL的独立DMA矩阵：普通从机、AWREADY等待WVALID、整段W先于AW三类各10组配置，
合计30组、828次行用例；包含0xff0起始640字、1/15/16/17/255/256/257字、32位地址
顶端、零长度/非对齐/溢出、随机背压、响应保持、环形游标环绕、RESP错误后无复位
恢复、协议错误锁定与SYSTEM reset恢复。配置为16拍burst的1/3/4槽，以及1/256拍的4槽，
连续与背压各一次；日志`r2_axi_dma_{matrix,awwait,wbeforeaw}_20260913_b.log`。

完整图的预期输入只在比较器中使用；memory初始化只包括输入RGB与训练参数。
19个实际写回节点随后从真正RTL写入的RAM取数。两个不同输入图，逐字比较地址、
stage、数据、WSTRB与producer所有权。参数2333个128位字；无修改模型、分辨率或量化。

四尺寸最终矩阵（4×4、12×12、32×32、640×12，连续/背压各一次）通过34个正常/恢复帧、
18个错误帧；2,606,288有效标量对应的179,156个128位正常写字一致。
12×12每配置为2个不同输入正常帧＋9次故障后完整重跑，不能将它们都算独立模型。
32宽实际写峰值2笔、640宽实测4笔；小图最大1笔，不能把配置4当作所有场景都达到4。
日志`logs/r2_axi_graph_matrix_20260913_b.log`，已通过数据量与提交/恢复记录检查。

整段W在AW前完成的12×12完整图压力回归进一步通过22正常/恢复帧、18错误帧，
217,008有效标量对应16,632写字一致。连续与背压各做两种实际RAM污染（数据和producer
所有权），共4次均在stage1拒绝，证明比较器没有替代真实层间RAM供数。
合计小图/原生宽度56正常帧、36错误帧；再加原生帧共57正常帧、23,866,496有效标量。
日志`r2_axi_graph_wbeforeaw_20260913_b.log`、`r2_axi_handoff_negative_20260913_b.log`。
最终`r2_axi_evidence_final_20260913.log`包含全部门禁通过及8种损坏证据被拒绝；
门禁成功不改变前述DDR PHY/任意协议损坏/CPU取消等未完成边界。

9类完整图故障：首参数RRESP、首特征RRESP、stage20特征RRESP、首BRESP、最终BRESP、
早RLAST、缺RLAST、错误RID、双页在途时错误BID。最后两类末层RESP错误必须仅有20个
提交；其余故障不提交stage0。普通错误后无reset重跑，协议故障先证明锁定，再SYSTEM
reset重跑。stage20末字后额外保持最终B 37拍，检查无提前发布。

## 性能与资源

AXI模型对**每个物理burst**收取20拍初始读/写响应延迟；共享R产生与W接收最多每2个
核时钟服务一个128位字，150MHz折算1.2GB/s。R弹性寄存器持有数据不重复计费。
此模型不是Ti60 DDR测量：不包含刷新、row miss、读写转向、相机/显示/CPU争用。
testbench以10ns时钟推进事件；性能使用实测周期及单独通过P&R的150MHz折算，
不把testbench绝对仿真时间冒充板级运行时间。
因此结果只能证明该确定服务模型下的AXI图核能力，不能直接宣称整机达到15fps。

原生640×480最终运行：`c9_xsim_native_20260913_b`，complete/exit0，972.838秒，
`worker_in_windows_job=false`，快照/向量私有目录已不存在。完整19个写回节点、
21,043,200个有效标量对应结果逐字一致，22节点提交。实测如下：

| 原生单帧指标 | 实测 |
| --- | ---: |
| frame_cycles | 9,297,258 |
| 150MHz折算fps | 16.133789 |
| 150MHz折算延迟 | 61.98172 ms |
| 距15fps的周期余量 | 702,742拍，约4.685 ms |
| 实际AR / AW / B | 94,950 / 89,400 / 89,400 |
| 实际R / W 128位字 | 1,519,133 / 1,430,400 |
| producer特征读字 | 1,516,800 |
| 物理读 / 写在途峰值 | 4 / 4 |
| 计算期间实际W握手字数 | 1,423,440 |
| 末字后保持最终B | 37拍，未提前发布 |

总数据流量仍47,192,528 B/帧。比C8的9,289,054拍仅增加8,204拍（约0.0883%）；
但两个模型的延迟计费粒度不同，C8为每逻辑行，C9为每物理burst，不能声称测试条件
完全相同后做纯模块消融。该结果证明多burst流水有效隐藏了本模型的大部分协议开销。
保存的独立原生/物理门禁为`logs/r2_axi_native_physical_gate_20260913_b.log`。

| Ti60 I3核级指标 | C8基线 | C9最终b |
| --- | ---: | ---: |
| XLR / 60,800 | 38,819 | 40,015 |
| Memory Block / 256 | 160 | 160 |
| DSP / 160 | 112 | 112 |
| 最终setup slack / ns | +0.540 | +0.732 |
| 最终hold slack / ns | +0.031 | +0.089 |
| 最终period / ns | 6.126 | 5.934 |

最终证据`logs/efinity_resource_runs/c1_ti60_r2_axi96_i3_20260913_b/`：map+PNR/exit0，
311.36秒。XLR增加1,196（约3.08%），没有新增RAM/DSP；剩余20,785 XLR、96 RAM、48 DSP。
这些剩余量不能直接保证能再放入企业视频例程与Sapphire；完整共享存储/视频外壳的资源、
时钟与RAM复用仍需单独评估。中间post-place的负hold不是最终结果，最终route后hold为正。
观测壳没有物理AXI I/O delay约束，不是DDR PHY/整机时序签核。

## 调试记录与清理

1. 首次独立testbench误用了SystemVerilog保留字`checker`作为块名，编译报错；改名后通过。
2. 首次集成编译中Icarus拒绝先使用后声明的局部拒绝状态；只调整C9声明/使用顺序。
3. 小图故障分析补入协议锁定后的本地页退休，定向BID错误实际覆盖第二页被拒绝，未改C8。
4. 复查发现初版WVALID等待AW接收可能与合法从机互相等待；改为AW呈现即保留W元数据，
   新增AW依赖W和整段W在AW前完成的两组独立压力矩阵，均通过。
5. 原生a在修正前已启动，主动终止了精确归属的xsim子进程树，未终止其他工具。
   worker退出后私有目录有残留；已确认无进程占用并删除138,204,248字节可再生成文件，
   保留日志，并将原先停留在running的状态明确订正为cancelled，不当作成功证据。
   C9运行器增加有限清理重试及失败状态保存；没有修改C8运行器。
6. Efinity a为修正前探索结果，不用于最终结论；最终只引用b。图矩阵a亦是探索日志，
   最终门禁只读取明确的b日志，避免源修改期间不同快照混为一组证据。

最终清理检查`logs/r2_axi_cleanup_20260913.json`：所有C9 simulator私有目录和本轮Efinity
私有目录均为0。检查时仅保留43个小型文本文件，共448,494字节（不含cleanup JSON自身）。
只删除本阶段自有临时目录，不碰其他赛题、旧基线、模型工件或用户文件；不生成文件校验摘要。

## 复现和下一步

```powershell
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B -u case1/golden/run_r2_axi_probe.py --unit
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B -u case1/golden/run_r2_axi_probe.py --unit --aw-wait-w 1
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B -u case1/golden/run_r2_axi_probe.py --unit --aw-wait-w 2
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B -u case1/golden/run_r2_axi_probe.py
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B -u case1/golden/run_r2_axi_probe.py --shapes 12x12 --aw-wait-w 2
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B -u case1/golden/run_r2_axi_probe.py --shapes 12x12 --negative-only
./case1/scripts/run_r2_axi_xsim_detached.ps1 -RunId unique_c9_native -FrameWidth 640 -FrameHeight 480
./case1/scripts/run_efinity_ti60_resource_map_detached.ps1 -DesignName c1_ti60_r2_axi96 -RunId unique_c9_pnr -ProjectInPlace -RunPnr -TimeoutSeconds 600
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B case1/golden/check_r2_axi_evidence.py --native-run c9_xsim_native_20260913_b --pnr-run c1_ti60_r2_axi96_i3_20260913_b
```

后续C10应接共享DDR仲裁和CPU控制生命周期，首先用真实AXI相机写/显示读流量复测。
P2C8特征/输入输出布局与旧视频XRGB布局不相同，必须明确转换端点；ID=0主机接多主系统
需由互联保证响应归属。还需错误帧不发布、缓冲所有权、cache维护、IRQ/软件驱动与取消
屏障。之后才是Sapphire/企业DDR与视频IP工程合并及板级时序/实际相机HDMI调试。
