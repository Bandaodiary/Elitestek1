# R2-C2：共享CNN计算阵列与作业隔离

后续维护说明（2026-09-13 C10阶段）：C10曾误用本阶段probe/runner名称及EDA运行a目录。
执行RTL/TB和历史golden日志未变；窄观察壳/runner已重建，并独立重验于
`c2_shared_restore_i3_20260913_a`。新证据为 `r2_c2_restored_evidence_20260913_a.log`。
下文数值保留历史快照，不将新观测壳23,363XLR/40RAM/108DSP替换为旧数值；旧a目录混存
失败状态与历史成功摘要，禁止作为当前PASS。详细说明见[R2-C10报告](R2_SHARED_AXI_SYSTEM_20260913.md)。

日期：2026-09-13。目标继续为保留现有RTL备用基线并重构CNN执行架构。
本轮从“两个独立代表层原型”推进到**同一个执行器中的PW/RGB切换**；不是整网完成。

## 1. 已完成的结构变化

新入口为`rtl/r2/c1_r2_shared_row_engine.sv`。原R1、旧默认整机、原PW/RGB独立
原型及其仿真证据均未修改或删除，不通过大规模复制工程来保存基线。

| 新模块 | 作用 | 不包含的内容 |
|---|---|---|
| `c1_r2_compute6.sv` | 一套96路MAC、六路量化、first绑定的参数FIFO与在途事务计数 | SRAM窗口/CPU/AXI |
| `c1_r2_pw16x8_feeder.sv` | 从原PW原型抽取真实双bank供数和参数选择 | 不实例化MAC或量化器 |
| `c1_r2_rgb3x3_feeder.sv` | 从原RGB原型抽取三行窗口、边界及五拍归约调度 | 不实例化MAC或量化器 |
| `c1_r2_shared_row_engine.sv` | 锁存算子owner，选择供数，拒绝非法/忙时命令，等最后结果退休 | 通用描述符、DMA、残差、全图日程 |

模式0是固定Cin16/Cout8的1×1 PW；模式1是固定Cin8/Cout3的3×3 RGB。模式2/3
在硬件上拒绝，不是假装已经实现DW或其他算子。供数器输出统一的first/last、tag、
mask、六路A/B/bias和六组multiplier/shift/ReLU，未来算子可接同一计算边界。

两套特征RAM目前仍分开：PW为16 RAM，RGB为24 RAM。**共享了计算，而不是已经
统一tile SRAM分配**；保留两套私有存储是当前实现边界，后续需由统一存储计划收敛。

## 2. 为什么需要参数FIFO

不同事务可能连续入阵列，PW六路输出的通道组合也逐拍改变。不能把当前供数器的
live量化参数直接接到若干拍以后返回的累加结果上。本轮引入浅FIFO：

1. 接纳first时保存该事务的六组量化配置，FIFO容量不足时只阻止新的first；已开始
   的归约仍可继续，以免等参数队列时把当前事务卡死。
2. MAC最后一拍完成并交给量化器时弹出对应配置。仿真核对FIFO中的tag/mask与
   MAC输出相同；非first的live配置不参与量化。
3. 单独统计从first接纳到最终量化输出消费的事务数，避免配置FIFO已经弹空就
   提前宣称整个计算单元空闲。局部reset清配置队列、部分归约与量化流水。

默认深度8，实测连续模式峰值使用6条；不含等待CPU/DDR的描述符队列含义。
数据以显式浅寄存器实现，最终Efinity中该FIFO没有占用块RAM。tag/mask的FIFO副本
主要用于仿真匹配断言，综合可裁剪；不能将完整逻辑记录位数直接当作最终FF数。

作业owner在start握手时锁存，直到最后结果被接收才释放。此期间改变外部mode、
size、边界标志、尝试load/start均不能影响当前作业。finish只在最终输出握手时
发给对应供数器，而不是在最后一次RAM读取或最后一次MAC发射时提前发出。

## 3. 功能验证

入口`golden/run_r2_shared_probe.py`；结果`logs/r2_shared_probe_20260913_a.log`。

### 共享执行器：2种模式的28个交替作业

无背压/长背压各运行28个作业、9,019个向量、54,054个有效标量，其中28,160个
标量来自640×4真实训练golden的stage19/20。每次完整运行切换模式27次，不复位
切换PW/RGB，并在最后加两次不重装任何数据/参数的缓存作业。

验证源于既有PW/RGB的同一套特征/权重/期望值，包括1/2/3/639/641/1024尺寸、
量化/尾mask/边界等。每个输出的mode/index/mask/data/last都核对，输出背压保持，
每作业MAC握手数和无背压周期精确检查；忙时持续改变mode并同时尝试重启/写参数。

非法模式2/3、宽度0/1025、越界权重地址、shift63共6类命令在硬件握手处拒绝。
此外先检查确实处在未完成RGB归约，再复位；另在长背压填满流水后复位。复位后
共享队列、owner与供数器都清空，已装载参数/RAM保留并可重启。

共享后无背压周期未增加：640像素PW为866拍，RGB为1,615拍。长背压测试累计
13,565个输出阻塞拍；此数不是DMA等待周期。全部28作业按期望顺序返回。

### 共享算术边界：4种配置

参数FIFO深度8/2分别做连续/背压测试，每配置17,421输入beat、11,701输出事务，
复用69,120个真实DW/PW/RGB中间标量及180个随机归约事务的累加golden，并核对
最终signed8量化值。**DW在这里只验证算术接口，不含真实DW SRAM供数**。

非first的multiplier故意改为无关值、shift改为63；仍必须使用first时的合法参数。
覆盖不同K、signed32模溢出、signed18极值/正负/零、ReLU、mask和局部部分事务复位。

默认深度8、无背压：17,421个输入恰好连续17,421拍接纳，II=1。深度2是压力配置，
不是性能默认：无背压输入跨度38,123拍，满队列同拍pop/push发生11,619次；背压下
发生11,166次。这证明FIFO满时的替换边界被执行，也说明过小队列确实会损失吞吐。

另以7种内存中的日志破坏测试证据检查器会拒绝错误，不把这些称为RTL故障注入。
最终gate：`logs/r2_shared_evidence_gate_20260913.log`。

## 4. Efinity实际资源

工程`efinity/c1_ti60_r2_shared96.xml`，运行标识`c1_ti60_r2_shared96_i3_20260913_a`。
Ti60F225、I3、6.666ns约束，map＋PNR通过，运行约113.6秒。

| 项目 | 实测 |
|---|---:|
| DSP | 108/160，67.5% |
| Memory Block | 40/256，15.62% |
| XLR | 23,259/60,800，38.25% |
| map FF | 10,831 |
| 150MHz setup余量 | 0.806ns |
| hold余量 | 0.089ns |
| 内部路径估计Fmax | 170.648MHz |

层级审计确认只有一个u_compute、一个96-DSP MAC、一个12-DSP量化器，两个供数器
各自0 DSP。原独立PW/RGB探针各108 DSP，直接并排的预算216会超Ti60；本工程
实际合并后仍108 DSP。这不是在新综合中测出了一个216-DSP“旧整机”。

共享输入选择与参数FIFO增加了控制/数据路径开销，内部估计频率低于此前独立原型，
但仍满足当前150MHz核级约束。后续并入更多算子/总线不能直接沿用此余量保证。
本工程没有CPU、DDR、视频、PLL或I/O delay约束，不是完整板级签核。

## 5. 接口与剩余任务

mode只在idle加载/启动时选择目标，start_size在PW表示像素数，在RGB表示行宽，
均1..1024。地址与参数字布局沿用各独立原型；非法地址/affine字段在共享层拒绝。
输出out_index在PW为flattened scalar base，在RGB为首像素x，out_mode区分解释。
它是R2内部调试接口，不是已经接好的R1 APB/CPU ABI。

当前可以统一复用算术，但还不能提交完整CNN任务：

- DW真实Cin16/24/48供数、PW通道/形状推广和残差路径尚未加入共享mode。
- DW→PW/残差融合、统一tile地址/存储计划、输入复用、部分和、宽口refill、输出
  packer、乒乓读算写调度尚未完成；load仍为32bit且与作业互斥。
- 尚未接回旧CPU/AXI事务边界与取消排空，尚无完整22层R2、原生多帧/DDR竞争
  性能或整板资源证据。没有新的整网fps，也没有15fps达标承诺。

下一步以该共享边界为入口接入DW及残差，不继续叠加完整独立计算核；同时审定
通道组/空间块的缓存节拍，避免RGB两拍窗口方案直接拖慢DW。R1继续可作备用和对照。

## 6. 复现、清理

```powershell
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B -u case1/golden/run_r2_shared_probe.py
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B case1/golden/check_r2_shared_evidence.py
./case1/scripts/run_efinity_ti60_resource_map_detached.ps1 -DesignName c1_ti60_r2_shared96 -RunId my_shared96 -ProjectInPlace -RunPnr -TimeoutSeconds 600
./case1/scripts/check_r2_shared_closure.ps1
```

只用外层WMI脱离运行器；本轮未调用Vivado。唯一EDA worker已退出、私有工程已
清理，Icarus全部临时向量/映像删除，无波形。保留EDA文本64,930B、仿真文本8,471B，
合计约0.070MiB，另有小型gate/closure；未清理无关旧文件。
闭环证据：`logs/r2_shared_closure_20260913.log`。
