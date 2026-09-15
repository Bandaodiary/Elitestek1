# R2-C10：CPU 控制与四主机共享 AXI 子系统

日期：2026-09-13。保留 R1、C5～C9 执行 RTL。本阶段新增 APB 控制、四主机
AXI fabric 和组合入口，推进到可接平台的计算子系统，不宣称已接通板卡。

## 1. 架构与实际改动

```text
CPU APB4 ── job_control ── C9 完整 CNN 图核 ─┐
                                          │
采集 DMA 规范化 AXI 主口 ──────────────────┤
显示 DMA 规范化 AXI 主口 ──────────────────┼─ 四主机 fabric ─ DDR 控制器 AXI
CPU 数据规范化 AXI 主口 ───────────────────┘
job_control ── result/IRQ → CPU
            └─ publish ready/valid → 帧缓冲协调器/显示消费者
```

| 文件 | 职责 |
|---|---|
| `rtl/r2/c1_r2_apb_job_control.sv` | shadow 配置、START 快照、结果/发布保持、IRQ、提交时缓冲冲突检查、合作式 DISCARD |
| `rtl/r2/c1_r2_axi_fabric.sv` | 四主机读写仲裁、独立的物理债务统计、ID 错误锁定；复用 R1 读写 burst 仲裁器，不改其 RTL |
| `rtl/r2/c1_r2_shared_subsystem.sv` | 连接控制器、保留的 C9 图核及 fabric，提供三个外部主机入口 |
| `software/include/c1_r2_control.h`、`software/src/c1_r2_control.c` | 新 R2 ABI 的 freestanding C 驱动，不冒充 R1 ABI 兼容 |
| `sim/c1_r2_axi_traffic_agent.sv` | 仅仿真：真实发起读写事务的负载源，不是已实现的 CSI/HDMI/CPU DMA |
| `sim/tb_c1_r2_shared_subsystem.sv` | 实际 RAM、独立所有者/地址队列、全图 golden、三路背景流量、双帧交接及错误测试 |

CNN 仍是唯一的 96 MAC 阵列、六路量化、三行输入缓存与两页写回缓冲；没有复制计算核。
固定 MicroStyle24 算子图、模型、量化和 P2C8 布局不变。此入口不是旧 portable_soc 的默认替换。

## 2. 控制与总线合同

APB4：32 位数据、8 位本地地址、PSTRB；低字节地址、little endian。ID=`0x52324331`，
版本=`0x00010000`。未映射/只读写入、非法命令、不可启动时 START 给 PSLVERR。

| 地址 | 含义 |
|---|---|
| 00 / 04 / 08 | ID / ABI 版本 / 能力 |
| 10 | 命令：1 START，2 DISCARD，4 ACK_RESULT；互斥 |
| 14 | 状态：bit0 busy、1 pending、2 result_valid、3 error、4 discarded、5 publish_valid、6 can_start、7 fabric_error、8 capture 冲突、9 display 冲突 |
| 18 / 1C | IRQ 使能 / W1C 状态；bit0 完成、1 错误、2 丢弃；硬件事件置位优先 |
| 20 / 24 / 28 / 2C | 输入 / 三个连续 workspace 槽首地址 / 输出 / 参数地址 |
| 30 / 34 | 宽[10:0]、高[25:16]，其他位保留为零 / 软件 tag |
| 38 / 3C / 40 | 结果周期 / 结果 tag / active stage 与 CNN 读写在途数 |

START 原子锁存六个 shadow 字，之后 CPU 修改 shadow 不影响运行。CPU ACK 结果与显示端
接收 publication 独立；两者均结束后才能再次提交。最终 CNN 写响应完成后才能发布，
并不要求其他 DDR 主机全空闲。DISCARD 只禁止当前帧发布，仍完成整图和债务排空；
不是快速中止。idle DISCARD 为无害 no-op，避免读取状态到发命令之间自然完成引起总线异常。
普通 RESP 错误可排空后恢复；fabric/协议错误需系统协调排空与 reset。无无限制坏从机恢复或超时隔离承诺。

缓冲地址按 8 MiB 槽对齐，workspace 占三个连续槽，四类区域不重叠。捕获/显示 lease
检查只在提交时读取外部声明，不是硬件内存防火墙或完整帧缓冲分配器。协调器不得在运行中
新取得冲突 lease，必须保证输入已完成、参数有效以及 CPU cache 的 clean/invalidate。
驱动的 RISC-V `fence iorw,iorw` 只保证访问顺序，不执行 cache 维护。驱动用官方安装目录
GCC 交叉编译为 RV32IMAC/ILP32 对象并检查六个 API/7 处 fence；尚未在真实 RISC-V 核执行。

外部三个 AXI 主口为规范化 128 位、16 字节全宽 beat、INCR、有序 ID0 接口，默认 fabric
FIFO 深度 8，CNN 自身读写各 4 outstanding。不能无适配连接任意 Sapphire/CPU 的多 ID、
32 位窄访存或独占事务；所选 CPU 总线、位宽转换、ID 保留及地址窗口仍需逐项对接。
支持 WVALID 与 AWREADY 独立；物理在途数只来自真实 AR/RLAST、AW/B，不把本地队列当物理并发。

## 3. 功能证据

主矩阵：4×4、12×12、32×32，各连续/随机背压，22 个正常或恢复帧、10 个错误/丢弃帧。
逐层读源必须来自实际前层 RTL 写回；第二帧输入来自 capture 主机实际写入的槽 6，
显示端读取上一 CNN 输出，CPU 交替写/读自己的区域并逐值核对。期望值只作 checker，
不用于初始化 CNN 中间层 RAM。补充无背景 32×32 双帧消融，及整段 W 先于 AW 压力回归。

五类错误：参数 RRESP、末层 B 错误、早期 DISCARD、末 B 被保持期间 DISCARD、错误 RID。
前四类后有无 reset 的正常恢复；错误 RID 在所有债务排空后系统 reset 再恢复。
APB 独立测试通过 47 项检查、4 次启动，含配置快照、提交冲突、结果/发布保持、IRQ W1C 竞争。
另对采集实际写完的 RAM 破坏数据或 producer 标签，验证 checker 不是跳过交接检查。

背景流量按真实 ready/valid 事务参与同一存储模型。独立队列检查物理 AR/AW 是否来自
最早已接纳的客户端描述符、R/B 是否只送给正确所有者；不是读取 DUT 自己的 owner 表来证明自己。
最终 B 额外保持 37 拍，期间禁止 publication。显示负载在 burst 边界限速，RREADY 及时接收，
相当于有预取缓冲的消费者，**不证明逐像素截止期限、FIFO 不欠载或物理 HDMI**。

## 4. 原生吞吐与资源

最终 `c10_xsim_native_20260913_b` 已通过，complete/exit0、1097.592秒，Job=false，私有工程删除。
首轮 a 结果相同但早于idle DISCARD修订，仅作探索证据。最终 640×480 共 22 节点、
21,043,200 有效标量对应结果一致，9,814,854 拍，150 MHz 折算
15.28 fps。相同 CNN 的 C9 单主机场景为 9,297,258 拍，增加 517,596 拍（5.57%）。
15 fps 只余 185,146 拍 / 1.234 ms，不能把这点余量视为板级保证。

测试条件：128 位共享读写服务每 2 核时钟最多一次，150 MHz 下上限 1.2 GB/s；
每物理 burst 20 拍命令延迟。背景每个 burst 16 个 128 位字：采集间隔 1041 拍，
显示 260 拍，CPU 4096 拍。分别约为 640×480 P2C8 的 15 fps 输入、60 fps 旧帧读取，
CPU 聚合约 9.375 MB/s；不是 1080p60 外设或 DDR PHY 的实际带宽测试。
有限采集帧在 CNN 完成后允许继续写完；报告周期是 CNN 作业，不含等下一帧、APB 调度和视频消隐。
最终原生只跑一帧，不把小图双帧交接当作原生多帧验证。

最终独立工程 `c10_shared_system96_i3_20260913_c`（269.256秒，complete/exit0）与
原始名称的成功运行 `c1_ti60_r2_shared96_i3_20260913_b` 结果一致。
Ti60F225 / I3 / 6.666 ns，map+PNR 完成：

| 项目 | C9 图核 | C10 带 APB/共享 fabric 探针 |
|---|---:|---:|
| XLR / 60,800 | 40,015 | 44,686（73.5%） |
| Memory Block / 256 | 160 | 162（63.28%） |
| DSP / 160 | 112 | 112（70%） |
| 最终 setup / hold ns | +0.732 / +0.089 | +0.482 / +0.089 |

增加 4,671 XLR、2 RAM、0 DSP，含外部端口的防裁剪装载/观察壳，不能全归因于 fabric。
补充保留的map层级显示：fabric本身1,030 LUT、715 FF、2 RAM、0 DSP；APB控制371 LUT、
352 FF；注意这是map LUT/FF口径，不等同于PNR XLR增量。全系统只有一个96-MAC计算阵列。
余 16,114 XLR、94 RAM、48 DSP；尚不含 Sapphire、DDR/CSI/HDMI IP、真正视频 DMA、
Resize、帧缓冲协调器或板级时钟/CDC。仍是核级估算，不是完整设计资源签核。

## 5. 调试与证据管理修复

首轮 probe 声明混用了带初始化/不带初始化的 wire，Efinity 解析拒绝；拆开声明后通过。
空闲 DISCARD 改为 no-op；首轮 native a 早于该修正，最终 native b 使用修订后 RTL。
W-before-AW 压力测试最初报 display wrote memory：观察器在物理 AW 尚未握手时使用未建立的
physical owner。改为核验保持 AW 与独立已接纳描述符后取得 W owner，不虚增物理债务。
仅修改仿真观察器，正常路径及生产 RTL 不变；失败 `r2_c10_wbeforeaw_20260913_a.log` 保留。

本轮误用了 C2 的 `shared96` probe 与 `run_r2_shared_probe.py` 名称。C2 执行 RTL/TB 和历史
golden 日志未变，但窄观察壳/脚本入口被覆盖，旧 Efinity a 的失败状态与历史成功摘要混存。
不将该目录重新标成 PASS。已拆分 C10 为 `shared_system96` / `run_r2_shared_system_probe.py`，
重建 C2 入口并以独立 `c2_shared_restore_i3_20260913_a` 重验；不声称逐字恢复旧观察壳。
C2 重验 56 作业与 4 种算术 FIFO 配置通过，40 RAM/108 DSP 保持；恢复的算术测试沿用真实
训练层的累加向量，量化压力参数独立再生成，不声称逐字复现已覆盖的旧量化向量生成器。
新观察壳的 XLR=23,363，
setup/hold=+1.002/+0.078 ns，不能覆盖历史 23,259 XLR 的原始数值。
Efinity 启动器与 worker 已拒绝已有 RunId/私有目录，负向调用确认拒绝且未启动新工具。
首轮最终证据门禁还正确拒绝了缺少fabric层级的摘要：原采集器只保留前80行层级，末尾兄弟
模块被大量RAM实例挤出。新增最多24行关键总线层级摘要、未放宽数量检查；以独立C10工程
重新map+PNR后门禁通过，不读取/上传大型EDA数据库。失败门禁日志保留。
详细说明位于混存目录 `NAME_COLLISION_NOTICE.md`。

## 6. 复现与下一步

```powershell
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B -u case1/golden/run_r2_shared_system_probe.py --apb-only
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B -u case1/golden/run_r2_shared_system_probe.py --shapes 4x4,12x12,32x32
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B -u case1/golden/run_r2_shared_system_probe.py --shapes 12x12 --aw-wait-w 2
& D:/miniconda/miniconda/envs/p300_task3_bci3/python.exe -B -u case1/golden/run_r2_shared_system_probe.py --shapes 4x4 --handoff-negative
./case1/scripts/run_r2_shared_xsim_detached.ps1 -RunId UNIQUE_NEW_C10_RUN
./case1/scripts/run_efinity_ti60_resource_map_detached.ps1 -DesignName c1_ti60_r2_shared_system96 -RunId UNIQUE_NEW_C10_PNR -ProjectInPlace -RunPnr -TimeoutSeconds 600
```

Vivado 只通过 WMI 外层，worker 检查不在 Windows Job 中。无波形，私有向量/仿真数据库与
EDA 工程由运行器结束时清理；只保留有界文本。最终门禁为
`logs/r2_c10_evidence_final_20260913.log`，确认38个小图正常/恢复帧、20错误/丢弃帧，
加1原生帧共21,744,640有效标量对应结果；4真实RAM负测试和7损坏记录负测试均通过。
清理与进程闭环用 `scripts/check_r2_shared_system_closure.ps1`，记录
`logs/r2_c10_cleanup_20260913.json`；不删除RTL、模型、失败日志或其他任务文件。
最终确认3个WMI仿真运行及3个成功EDA运行均退出、相关私有目录剩余0；混存失败运行的
私有目录也不存在。保留61个文本共449,424字节（约439 KiB，含C2恢复，不含既有混存历史
目录和cleanup JSON自身）。独立命名后4×4 xsim smoke再次通过，12,672拍，17.799秒完成，
Job=false；未把这次短回归计入上述原生或完整矩阵的有效标量总数。

下一阶段优先：把官方例程实际 DDR/Sapphire 接口约束带入适配，建立可综合采集/显示 DMA
和缓冲 lease 状态机，按所需显示分辨率做 FIFO 水位/欠载与持续多帧竞争验证。随后整体
Efinity IP、时钟、CDC 和资源评估，再上板。若该真实负载不能维持 15 fps，应优化按截止期限
的 DDR 调度/带宽与计算访存复用，而非减少背景流量后宣称达标。当前阶段不是整机完成。
