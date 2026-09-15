# R2-C5：stride2 encoder 与虚拟上采样供数

日期：2026-09-13。仍保留 R1 和此前 R2 入口作为备用/对照。
本阶段补齐两个 encoder 的真实 SRAM 供数，并把 decoder 的最近邻上采样折叠到
DW 窗口地址映射。**算子行验证不是完整 CNN 串联、DMA 或整机帧率验证。**

## 1. 新结构与复用关系

新入口为 `rtl/r2/c1_r2_cnn_operator_engine.sv`。

| 文件 | 作用 |
|---|---|
| `c1_r2_cnn_operator_engine.sv` | 六种算子模式的作业 owner、形状/地址互锁、有效宽度和最终退休 |
| `c1_r2_spatial_operator_feeder.sv` | RGB/DW/encoder 共用空间供数入口、窗口和参数读口选择 |
| `c1_r2_mapped_window_store.sv` | 在原三行奇偶 bank 上加入虚拟2×坐标映射与行相位处理 |
| `c1_r2_encoder_feeder.sv` | 将一/两段C8窗口组装为Cin3/Cin12的密集3×3向量，调度2/7拍归约 |

继续复用 C4 的 `c1_r2_weight_store8`、`c1_r2_pw_banked_feeder` 和既有 compute6、
MAC、量化器、公共 SDP RAM。没有改这些旧源文件，也没有把旧默认 SoC 切换到 R2。

物理存储仍为公共权重64 RAM、PW/残差特征16 RAM、公共空间特征48 RAM。
encoder 不再例化一份空间 RAM 或计算阵列；其双槽组装缓冲为2×112字节寄存器，
用于在当前像素计算时组装下一像素。两个槽的预留计数包含尚未齐全的C8片段。

数据路径为：公共空间RAM → C8窗口 → RGB/DW直接供数或encoder密集组装 →
公共同步参数SRAM对齐 → 请求寄存器 → 唯一的96 MAC＋六路量化 → 最终结果。
任何路径都要等最后结果握手后才释放作业；外部配置在busy期间改变不影响当前作业。

## 2. Encoder 供数与定点规则

第一层为Cin3→Cout12、3×3 stride2，归约27项补齐32项，每六输出需要2拍。
第二层为Cin12→Cout24、3×3 stride2，归约108项补齐112项，每六输出需要7拍。

每个输出像素的输入中心为 `(2*x,2*y)`，横纵边界采用edge replication。
Cin3取一个C8窗口，只使用每像素前三字节；Cin12依次取两个C8窗口，只使用第二组的
前四字节。组装后按(HW)I密集排列，与同样重排的权重逐16项归约。输入C8 padding
和K末尾padding分别由RTL忽略/置零，不靠host恰好写零。

第一层每像素有两组六输出，第二层有四组，因此每像素分别需要4/28个MAC beat。
空间RAM每C8窗口两拍读取，一/两组分别需要2/4个RAM读周期；预取与双槽组装让
它们与4/28拍计算重叠。不同输出通道仍使用公共八bank权重，无新增MAC核。

组装器在第一段C8窗口到来时预留槽，在全部片段齐全前不允许计算读取该槽；
第二段必须与第一段的输入中心坐标相同。消费最后一个K/输出通道组时，旧payload
已锁进操作数寄存器，才允许槽释放并被新像素复用。

stage0接口接收signed8输入码，测试host按整数模型做`RGB_u8-128`；当前算子核
不负责从摄像头总线读取或执行系统级输入格式转换。

## 3. 虚拟最近邻2×上采样

mode2可启用`virtual_up2`。此时只装载原始宽度的三行特征，窗口坐标先在放大后
范围内裁剪，再映射为 `source_x = logical_x >> 1`。输出行通过`row_phase`区分：

| 放大后行相位 | 三个卷积tap对应的原始行 |
|---|---|
| 偶数行0 | 上一原始行、当前原始行、当前原始行 |
| 奇数行1 | 当前原始行、当前原始行、下一原始行 |

再根据原始图的top/bottom标志进行边界复制。不生成放大特征平面，也不要求host
把像素先复制两遍。本阶段验证的是这一真实地址/供数路径，不是已经实现DDR传输。

对stage15，原始160宽/C24直接供给320宽DW；stage18原始320宽/C16供给640宽DW。
与预先放大后再加载相比，同一三行测试的特征装载字数减半；垂直方向也可按原始行
装载，但全图行缓存轮换、跨行复用和DMA节省量尚未实测。

## 4. 接口及几何约束

mode扩为3位，这是新的内部算子接口，不是R1的CPU/APB ABI。

| mode | 工作 | start_size语义 | Cin/Cout |
|---|---|---|---|
| 0 | 通用PW | 输入像素数，沿用C4容量限制 | Cin16/24/48，Cout8/16/24/48 |
| 1 | RGB3×3 | 输入/输出行宽，最大1024 | Cin8→Cout3 |
| 2，up2=0 | 普通DW | 输入/输出行宽 | C16/24/48，最大1024/682/340 |
| 2，up2=1 | 虚拟2×后的DW | **原始输入行宽**，输出宽度为其两倍 | C16/C24最大512，C48最大340 |
| 3 | 同尺度残差 | 1…8192标量 | 保持C4规则 |
| 4 | 第一层encoder | 原始输入行宽，1…1024；输出`ceil(width/2)` | 必须Cin3、Cout12 |
| 5 | 第二层encoder | 同上 | 必须Cin12、Cout24 |

模式6/7拒绝。virtual_up2只允许mode2；row_phase在非虚拟模式下无作用。
虚拟模式按原始宽度检查每bank容量，同时把输出宽度限制在1024内。

row_top/row_bottom均描述**装载的原始中心行**是否在原始图边界。encoder最后输出行
不一定row_bottom：例如原始高度12，最后中心行是10，下方行11仍然有效，不能复制行10。
虚拟模式的原始中心行为`output_y/2`，相位为`output_y%2`，两者不能混淆。

特征地址沿用C4三行C8格式；encoder Cin3/12分别用1/2组。权重仍按公共八bank格式
加载，encoder4仅K16=0…1、通道0…11，encoder5为K16=0…6、通道0…23。
对应bias/affine地址也按输出通道限制。输入padding故意写非零，权重K末尾padding同样写非零。

encoder输出tag与PW一致，表示展平输出标量起点，每向量mask为六位全1。
DW仍使用`{0,x,C8_group,batch}`，RGB仍使用首像素x。通用writer仍需转换不同tag，
不能直接把它们全部当作线性DDR地址。

## 5. 验证证据与已发现问题

入口`golden/run_r2_operator_probe.py`，TB为`sim/tb_c1_r2_cnn_operator_engine.sv`。
已通过187作业×连续/背压，每配置167,635输出向量、925,169有效标量，其中367,360
来自真实训练工件。保留全部114个C4作业，新增两个encoder以及48个虚拟上采样DW作业。

新训练测试用640×12图像，encoder分别验证6/3条原生宽度输出行；虚拟stage15/18
分别验证6/12行，覆盖两种相位及真实非平凡纵向邻居。随机测试包含1/2/3/7、奇数宽度、
最大输入宽度、饱和/ties-away、Cin3/12填充、C48虚拟输出680宽和C24虚拟输出1024宽。
参考端直接按OIHW卷积；虚拟路径只在参考端显式repeat后卷积，RTL收到的始终是未扩展特征。

TB独立比较完整映射窗口、encoder的全部112字节组装payload及参数SRAM返回；
核对每作业实际窗口/特征/权重读取、MAC beat、输出数据/tag/mask/last和精确周期。
八种在途reset包括原C4四种、encoder部分K、Cin12部分C8片段、满encoder槽、虚拟窗口
第二次读取待发。46类非法命令检查形状、模式、up2组合、通道/K地址和参数字段。

首轮a日志在第一个encoder的周期检查停止：数值和1297拍总周期正确，但测试台
输出间隔断言遗漏新encoder分支，仍按一拍/向量判断。实际间隔应为2/7拍，已仅修正
TB，未改RTL数据通路。失败日志保留；b重跑的连续/背压两配置均最终通过。

每配置还检查1,743,597次参数bank返回、47,666个完整窗口、3,956个encoder窗口；
两配置均完成158次模式变化、八种在途reset与46类非法命令。背压配置记录194,296拍
输出阻塞，仍逐项一致。独立证据gate通过，并拒绝九种故意篡改/缺项的日志证据；
原始结果见`logs/r2_operator_probe_20260913_b.log`，gate见
`logs/r2_operator_evidence_gate_20260913.log`。

收尾按Efinity XML中的全部11个源文件执行Icarus `-DSYNTHESIS -tnull`结构编译，
退出码0、无诊断，见`logs/r2_operator_synthesis_compile_20260913.log`（空日志）。
这是可综合分支的结构检查，不代替前述功能回归或下述Efinity物理结果。

各层的输入仍由Python提供真实中间特征；即使覆盖了全部19个计算节点，也不等于
19层RTL输出已经直接串成整网。stage21显示格式转换、图调度、DMA、帧发布仍不在本测试内。

## 6. 周期及预算

| 原生宽度行 | 输入宽→输出宽 | 不含装载/写回的周期 |
|---|---|---:|
| encoder Cin3→12 | 640→320 | 1,297 |
| encoder Cin12→24 | 320→160 | 4,499 |
| 虚拟DW C24 | 160→320 | 1,456 |
| 虚拟DW C16 | 320→640 | 1,936 |

encoder每行公式分别为`ceil(width/2)*2*2+17`和`ceil(width/2)*4*7+19`。
虚拟DW为`原始width*(channels/8)*3+16`。其它C4算子的周期和稳态吞吐保持不变。
新增encoder组装不增加稳态气泡；在参数/消费者背压时会正确停顿。

`golden/r2_operator_schedule_budget.py`以19个计算节点的行公式及行间重启间隔估计
原生640×480为6,119,861拍。virtual节点折叠到DW，最终显示转换暂按融合假设计零。
按150MHz与15fps的10,000,000拍限额比较尚余3,880,139拍，但缺少装载/写回、DDR争用、
图调度和系统验证，脚本明确返回`measured_frame_fps=None`；不能据此发布实测fps。

## 7. Ti60物理结果

工程`efinity/c1_ti60_r2_operator96.xml`，运行`c1_ti60_r2_operator96_i3_20260913_a`。
Ti60F225 I3、6.666ns核级约束，map+PNR完成，约223.7秒。

| 项目 | C4 | C5 |
|---|---:|---:|
| XLR | 27,752 | 33,476/60,800（55.06%） |
| FF | 12,929 | 14,845 |
| map LUT | 18,816 | 23,419 |
| RAM | 128 | 128/256（50%） |
| DSP | 108 | 108/160（67.5%） |
| 150MHz setup/hold余量 | 1.110/0.089ns | 1.015/0.090ns |

新增encoder和坐标映射增加5,724 XLR、1,916 FF，没有新增RAM/DSP。
层级中encoder组装器自身为0 RAM/0 DSP，仍只有一个compute（108 DSP），其下MAC96、
量化12；空间存储48、线性16、参数64 RAM。核内路径估计Fmax为176.960MHz。

未加入CPU、DDR PHY、视频/PLL或I/O延迟约束；核级通过不能替代整个板级系统签核。
剩余27,324 XLR、128 RAM、52 DSP也不等于这些平台模块已被证明放得下。

## 8. 后续主线与复现

下一主线应从独立算子行验证转向**真实层间数据交接**：先将encoder0→encoder1→
残差块等输出写入统一张量布局，再由RTL调度后续算子读取，补上最终显示格式转换。
随后接宽口DMA、读写重叠和取消排空，复用R1的CPU/DDR/视频基础做完整22-stage及原生验证。
不得继续把Python提供各层输入的独立测试当作整网执行器。

```powershell
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe -B -u case1/golden/run_r2_operator_probe.py
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe -B case1/golden/check_r2_operator_evidence.py
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe -B case1/golden/r2_operator_schedule_budget.py
./case1/scripts/run_efinity_ti60_resource_map_detached.ps1 -DesignName c1_ti60_r2_operator96 -RunId UNIQUE_NEW_ID -ProjectInPlace -RunPnr -TimeoutSeconds 600
./case1/scripts/check_r2_operator_closure.ps1
```

运行使用一次性Icarus目录，不生成波形；Efinity通过WMI脱离当前Windows Job，
完成后由worker清理私有目录。最终仿真、负例、周期及物理证据gate均通过；
`logs/r2_operator_closure_20260913.log`确认worker已退出，EDA私有目录和本轮仿真
临时目录均不存在。只保留78,508字节EDA摘要及159,298字节仿真日志（包含首轮失败
证据），合计237,806字节，约232KiB；不含源代码、报告及额外gate文本。
