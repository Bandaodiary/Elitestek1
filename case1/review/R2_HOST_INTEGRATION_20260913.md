# R2-C15：主机 APB3、CPU AXI 与中断的生产封装

日期：2026-09-13。独立候选入口：`rtl/r2/c1_r2_host_video_system.sv`。

本阶段已把原来位于 testbench/资源探针中的 CPU 适配层收入可复用生产顶层，补齐16位APB本地地址到R2V2控制器的连接和标量中断。保留C14调度、C13 CPU适配器、CNN计算及数值golden，未改在途原生仿真的源文件。小图完整系统、端到端窄字节访问、目标Ti60核心实现均已通过；16:31更新：C15自身原生六帧已收口，最慢15.3145fps@150MHz，仍未运行真实Sapphire或板测。

## 1. 联合结构

```text
c1_r2_host_video_system
├─ u_cpu_adapter    : 保留完整CPU ID、合法窄访问与响应屏障
├─ u_control_bridge: APB3本地窗口、只读诊断页、IRQ合并
│  └─ u_apb        : 复用 c1_sapphire_apb_master_adapter（16→8）
└─ u_system        : 保留 c1_r2_video_fresh_system
   ├─ R2V2 CSR / 帧所有权
   ├─ 真实采集 / CNN / 配对显示
   └─ 四主机共享AXI fabric → 外部DDR控制器接口
```

顶层显式连接所有CPU/AXI/APB端口，没有新建计算阵列或复制CNN执行实现。`WIDTH/HEIGHT`、帧FIFO与arena参数继续传入保留核心；CPU ID宽默认8位。外部物理DDR ID口为4位、当前规范化为ID0，上游CPU的完整ID由适配器恢复。

## 2. 主机窗口与中断合同

`paddr[15:0]` 是所选APB外设窗口内的**本地字节偏移**，不是CPU物理地址。具体Sapphire地址译码/BSP基址仍需核对。APB无PSTRB，软件必须使用对齐32位读写；不能由这个接口识别或保留上游byte/halfword store的意图。

| 本地偏移 | 功能 | 访问权限 |
| --- | --- | --- |
| `0x0000..0x00FF` | 保留R2V2 CSR，由原控制器逐项判定合法地址 | 沿用原ABI |
| `0x0100` | 主机扩展ID `0x52324831`，R2H1 | 只读 |
| `0x0104` | 主机扩展版本 `0x00010000` | 只读 |
| `0x0108` | bit0 CPU适配层busy；bit1 CPU协议故障；bit2核心IRQ | 只读 |
| 其他地址 | 本地PSLVERR，不转发到核心 | 拒绝 |

原R2V2 ID `0x52325632`、参数地址、帧格式和CSR偏移不变。R2H1是附加诊断页，不是对R2V2的替换。特别是`0x0208/0xFF08`不能截断成`0x0008`而误写RUN控制，`0x0130`不能误清`0x0030`的中断。

主机`irq = core_irq OR cpu_adapter_fault`，复位期间屏蔽。CPU协议故障是C13适配器的复位级电平，不是新增可清除事件：清R2V2 W1C或关闭核心IRQ mask都不能清掉它，只读诊断页也不能写零恢复。仍需协调系统reset。普通本地不支持命令的DECERR不自动等同于协议故障。

此处没有偷偷增加同步器：接口与视频核心共享时钟/复位合同。若实际Sapphire/APB/DDR/视频时钟不同，必须另做CDC和复位协调，不能直接连线并称板级集成完成。

## 3. 新增文件与职责

| 文件 | 职责 |
| --- | --- |
| `rtl/r2/c1_r2_host_control_bridge.sv` | APB页译码、复用16→8转换、只读诊断、IRQ合并 |
| `rtl/r2/c1_r2_host_video_system.sv` | 主机桥＋CPU适配器＋保留C14的生产封装 |
| `sim/tb_c1_r2_host_control_bridge.sv` | 真实R2V2 CSR连接下的地址/IRQ/复位检查 |
| `sim/tb_c1_r2_host_video_system.sv` | APB代理＋CPU流量代理＋真实采集/CNN/显示的完整数值回归 |
| `sim/tb_c1_r2_host_narrow_system.sv` | 视频关闭时，经实际host/fabric访问真实byte RAM的窄访问回归 |
| `golden/run_r2_host_{control,narrow}_probe.py` | 两组定向回归，私有目录自动清理 |
| `golden/run_r2_host_video_system_probe.py` | 多尺寸六帧与实际RAM破坏负对照 |
| `scripts/run_r2_host_video_xsim_detached.ps1` | 独立WMI隐藏xsim运行器，核验Windows Job隔离 |
| `efinity/c1_ti60_r2_host_video96.{sv,xml,sdc}` | 使用真实host顶层的可观测150MHz核心探针 |
| `software/include/c1_r2_host_video.h`、`software/src/c1_r2_host_video.c` | R2H1状态读取和带CPU故障预检查的R2V2控制API |
| `golden/compile_r2_host_driver_probe.py` | 新API与保留R2V2驱动的RV32编译/可重定位链接 |
| `golden/check_r2_host_video_evidence.py` | 独立检查控制、窄访存、联合CNN、驱动、物理实现及可选原生吞吐 |

`c1_r2h_control()`不能替代完整启动流程：训练参数上传、CPU cache clean/invalidate、arena保留、平台就绪、PLIC handler与故障复位仍由平台/BSP完成。预检查与硬件后续故障之间仍可能竞争；驱动不提供原子启停或cache维护承诺。

## 4. 验证结果与开发记录

1. 生成新封装时，辅助端口提取逻辑误删了向量宽度的左方括号，被生成前的名字合法性检查拒绝；未生成错误RTL或运行EDA。修正提取逻辑后，生产host顶层41份源文件编译通过：`logs/r2_host_system_compile_20260913_a.log`。
2. `logs/r2_host_control_20260913_a.log`：2,451项检查、541次访问，其中520次预期拒绝。覆盖254个高地址页、只读/保留/未对齐访问、长SETUP无写副作用、背靠背APB、核心完成计数、IRQ合并、W1C同拍set-wins和reset。CPU故障在该**桥级**测试中是可控电平输入；不是CPU实际异常执行证据。
3. `logs/r2_host_video_system_sixframe_20260913_a.log`：8×8、32×32，各等待0/1，4配置24次完整CNN、36,736个配对显示像素通过。每配置13项host窗口检查＋原9项核心APB流程；实际CPU完整ID完成数与真实读写beat数一致，最后结果显示及所有债务排空后结束。
4. `c15_host_video_xsim_12x12_20260913_a`：12×12、随机等待＋全部W先于AW，6次CNN及配对显示通过，27.485秒，Job=false，私有工程已清理。五次CNN启动间隔空等均2拍。
5. `logs/r2_host_video_system_negative_20260913_a.log`：4个实际RAM破坏用例被CNN/显示检查器检出，未用golden直接回填系统输入或中间层RAM。
6. `logs/r2_host_narrow_20260913_a.log`：等待0/1×普通AW/全部W先于AW，4配置256次任务＝192正常＋64本地拒绝。8位ID、SIZE=0..4、1/3/16/256beat、非零byte lane、部分/零WSTRB、独立读写并发及响应保持，通过实际生产host和四主机fabric；64KiB实际RAM最后逐字节与独立reference一致。**视频在该组测试中关闭**，没有宣称已验证“窄CPU＋视频并发”或共享fabric对所有畸形响应的恢复；这些边界不能借用C13单模块异常测试替代。
7. `logs/r2_host_driver_link_20260913_a.log`：RV32IMAC/ILP32，5个函数、9处fence、无未解析符号，编译/可重定位链接通过。目标文件已清理；没有CPU硬件执行或cache维护证据。
8. `logs/r2_c15_gate_20260913_b.log`：上述证据与目标器件实现均通过独立检查，并拒绝10种被破坏的覆盖信息。此前a版门禁记录未覆盖新增端到端窄访问，保留而不覆盖。

## 5. Ti60 I3核心实现

`c15_host_video96_i3_20260913_a`：complete/exit0，353.951秒。

| 指标 | C14探针 | C15主机封装探针 |
| --- | ---: | ---: |
| XLR / 60,800 | 45,937 | 45,817 |
| RAM / 256 | 172 | 172 |
| DSP / 160 | 112 | 112 |
| 150MHz setup / ns | +0.210 | +0.263 |
| hold / ns | +0.026 | +0.026 |

层级检查确认host、control bridge、CPU适配层、保留C14系统、帧调度与CNN都实际存在，阵列仍为96个EFX_DSP24＋16个EFX_DSP48。最终周期6.403ns，仅签核6.666ns约束；不据报告Fmax提高系统工作频率。

不能把少120 XLR解释成“新增桥有负面积”：C14探针保留可变PSTRB，C15实际APB3将写strobe固定为全字，且封装层级/布局发生变化，优化器可做不同化简。这不是整板资源/时序签核，尚未计真实CPU、DDR PHY、ISP/Resize、MIPI/HDMI、CDC及完整IO约束。

## 6. 与企业Sapphire连接前仍需完成

- 本地生成`09_Ti60F225_co_debug_demo/.../ip/soc/soc.v`确认为DDR-A 128-bit数据/8-bit ID、16-bit APB地址且无PSTRB、标量`userInterruptA`。这些宽度吻合不等于已验证实际事务、地址映射或CPU执行。
- 新host保留C13普通非一致性DDR子集：只接受对齐INCR，拒绝独占/非零REGION/非法范围等；CACHE/PROT/QOS语义未透明传递。必须检查实际DDR-A/BSP行为，不能把AXI-A的常量信号当作DDR-A保证，或把未支持侧带绑零伪装成功。
- 核验实际APB窗口基址和至少`0x10C`字节范围；CSR使用32位整字访问。原16位地址不能盲截低8位。
- 规划实际CPU启动/栈/heap与96MiB arena的互斥；参数和视频buffer所有权必须遵守现有合同。
- 确定CPU/APB/DDR/视频时钟关系、reset和cache策略；IRQ为电平源，连接实际PLIC并实现处理流程。致命DDR路径故障后不保证CPU仍可从DDR取指并执行IRQ handler，外部协调复位仍需设计。
- 实际Sapphire/BSP运行、DDR PHY、摄像头/ISP/Resize、HDMI和板测仍未完成。当前代理证明不能替代这些内容。

## 7. 原生吞吐与下一步

后续C19更新：实际DONE计数核验发现旧时间线将绝对完成时刻早算1拍，现已校正；相邻完成间隔及15.3145fps结论不变，最新验收为`logs/r2_c15_native_gate_20260913_b.log`。原idle间隔2拍改为1拍，硬件及每帧frame_cycles均未变化。详见[C19记录](R2_HOST_ERROR_RECOVERY_20260913.md)。

16:31最终更新：`c15_host_video_xsim_native_sixframe_20260913_a` complete/exit0，6,727.183秒，Job=false，私有工程已清理。`r2_c15_native_gate_20260913_a.log`同时核验C15自身PNR、六帧及新鲜度：帧执行9,292,245/9,651,148/9,728,218/9,754,650/9,790,342/9,794,648拍，四个完整负载完成间隔9,728,220/9,754,652/9,790,344/9,794,650拍，最慢15.3145fps@150MHz，余量2.0535%。13采集、21双图显示、12,902,400正确像素，欠载0；CPU读125,968/写125,984 beat、峰值8/8。六次tag0/1/3/5/7/9均为当时最新完成，采集完成到启动年龄与C14一致。整体时间线因APB初始化偏移24拍，不能把两个版本的绝对cycle混用。此时旧C13/C14/C15原生均结束；下列为历史进度。后续计划化联合候选另见[C18记录](R2_PLANNED_HOST_INTEGRATION_20260913.md)，C15生产源码保持不变。

C12原生六帧于本轮结束，`r2_c12_sixframe_gate_20260913_a.log`确认四个完整间隔最慢15.3145fps@150MHz，最小周期余量2.0535%；13次采集/21次双图显示无欠载，临时工程已清理。这仍是C12有限行为模型证据，不是板测或C15性能。

后续15:25更新：C13原生六帧也已独立结束并清理，`r2_c13_native_gate_20260913_a.log`确认加入CPU DDR适配器后四个完整间隔仍相同、最慢15.3145fps。该结果不是实际Sapphire执行，也不能代替含新鲜度修复/APB主机封装的C15原生结果。当前只剩C14/C15两组原生在途。

16:00更新：C14原生也已结束，`r2_c14_native_gate_20260913_b.log`独立确认相同最坏FPS且六次均选中当时最新完成帧；其私有目录已清理。现在仅C15原生继续原进程，不能由C14通过直接宣布C15完成。

确认C12原进程结束并清理后，14:37才启动`c15_host_video_xsim_native_sixframe_20260913_a`，worker37736，14:38已在xsim，Job=false；C13/C14继续原有运行，在途大工程总数仍为3。新运行使用640×480/六次CNN/30fps采集/720p60双图/相同CPU竞争及共享1.2GB/s、burst延迟20拍模型。

下一步审计三个在途版本的最终结果与四个全负载间隔。旧版本FPS不能归为C15；启动时增加的APB检查也会改变负载相位，不能只因计算RTL相同便省略联合性能验证。结束并自动清理后执行：

```powershell
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B -u case1/golden/check_r2_host_video_evidence.py --native-run c15_host_video_xsim_native_sixframe_20260913_a --pnr-run c15_host_video96_i3_20260913_a --require-15fps
```

## 8. 文件清理与工作边界

不输出波形。模块/系统Icarus以及驱动目标文件用独立临时目录，退出即清理；完成的小图xsim和C盘EDA数据库已清理，仅分别保留42,870 B和113,274 B文本。14:38的C13/C14/C15原生在途记录见`logs/r2_c15_partial_cleanup_20260913.json`；15:25新快照`logs/r2_c16_partial_cleanup_20260913.json`确认C13已清理，仅C14/C15仍在使用，不是清理目标。R1及C12/C13/C14源码不被新封装覆盖，默认整机入口也未被擅自替换。
