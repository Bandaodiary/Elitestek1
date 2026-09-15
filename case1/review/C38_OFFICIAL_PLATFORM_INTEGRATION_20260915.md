# C38：官方 Sapphire / DDR 与 C37 联合开发记录

日期：2026-09-15。当前是**逻辑联合资源工程**，不是可直接下载的完整板级工程。C37六项替代源、训练模型和已验收工程不修改；企业资料仅引用，不修改、不尝试解密受保护实现。

**终态更正（后续C39核验）：** 原`c38_soc_ddr_pnr_20260915a`在852.026秒后路由失败退出，报错为无法找到合法路由，不是超时；实际进程已退出、私有目录已清理。下文“PNR进行中”为当时历史记录。58,751 XLR是布局结果，没有最终布线/时序通过结论。[终态与资源优化方案](C39_RESOURCE_EXPLORATION_20260915.md)。

## 本阶段已建立的连接

`官方 Sapphire DDR-A → C37完整8位ID适配器 → C37 CPU/采集/CNN/显示共享总线 → 唯一官方DDR3控制器`

`Sapphire APB16 → C37 CSR/相机控制；C37 IRQ → Sapphire标量userInterruptA`

工程：[c1_ti60_c38_soc_ddr_resource.xml](../efinity/c1_ti60_c38_soc_ddr_resource.xml)，顶层：[同名SV](../efinity/c1_ti60_c38_soc_ddr_resource.sv)。官方来源为`08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo`活动`ip/soc/soc.v`及XML列出的DDR控制器源文件；不实例化旧视频framebuffer、memory_test、Axi_Mux或debug_top，不叠加第二套DDR。

独立[生成/来源检查器](../golden/c38_joint_sources.py)只读取官方公开端口头，生成明确的源文件清单及连线；[来源合同](C38_JOINT_SOURCE_CONTRACT.json)保存实际路径、端口数量及配置。默认检查当前文件与生成结果一致；生成模式输出apply_patch补丁而不直接覆盖文件。Efinity会去掉XML声明行，因此XML按完整元素/属性比较，其他生成文件保持全文一致。

## 关键边界与尚未验证的行为

| 边界 | 本版做法与限制 |
| --- | --- |
| CPU DDR接口 | 128位数据、8位ID完整进入既有C13适配器；不是直接截成控制器的4位ID |
| 控制器接口 | 128位数据、4位ID、28位物理地址；沿用256MiB板卡配置和ASYN_AXI_CLK=0 |
| CPU访问语义 | 仅普通非一致性DDR、对齐INCR；LOCK/REGION等非法访问由C13拒绝；CACHE/PROT/QOS不提供透明转发语义，未证明真实CPU/BSP运行完全符合该子集 |
| 地址范围 | C37固定arena及CPU已有256MiB范围检查；32→28位切片显式写出，并加入仿真越界断言。其他动态地址来源、故障场景及物理别名仍须板级合同审查 |
| BRESP | 修正原例程留空做法，真实DDR响应经C37返回Sapphire，不绑成功响应 |
| 时钟 | 首版CPU、C37、DDR用户逻辑共100MHz；DDR物理参考接口400MHz，相机入口70MHz。未沿用C37@150MHz的吞吐结论；后续150MHz计算域需要真正的跨域方案或重新验证CPU时序 |
| 启动 | DDR复位不依赖cal_done；校准状态同步后才放行CPU AR/AW/W及C37任务，不建立“CPU等校准、校准又等CPU”的复位环 |
| 复位 | 首版使用统一外部reset_n并分域同步释放；运行中CPU调试复位、DDR失锁及在途总线的协调恢复尚未验证 |
| 相机与显示 | 暴露C37的RGB48/VS/DE输入及逻辑显示请求/输出；未接CSI D-PHY、真实摄像头I2C、Debayer、像素域显示CDC或HDMI serializer |
| 帧节奏 | FRAME_DIVISOR=1沿用已测camera30采集设定；不能把约58.5fps企业源直接接入并宣称仍是30fps。真实传感器节奏及分频需另行锁定 |
| 其他CPU接口 | 32位external DDR ingress关闭；AXI-A、UART/SPI/I2C/GPIO/JTAG保留显式外部接口。AXI-A还需要板级默认错误响应或实际外设，不能悬空用于运行软件 |
| 引脚与时钟资源 | 尚未提供联合peri.xml、引脚、电压、PLL和Clock Mux规划，因此不是bitstream交付入口 |

## 实际执行与结果

1. `c38_soc_ddr_map_20260915a`在XML解析阶段失败，耗时0.915秒，未取得RTL资源结果。原因是生成XML中的`top_vhdl_arch`位于`top_module`之前，不符合工具要求；修正生成器与独立XML顺序，保留失败记录。[失败证据](../logs/efinity_resource_runs/c38_soc_ddr_map_20260915a/failure_focus.log)。
2. 修正后以Efinity自带`enf_proj.xsd`实际验证通过。一次Python检查因未安装lxml未执行；一次.NET检查因schema namespace未成功载入，不能作为有效验证。最终.NET校验使用明确namespace、`schema_count=1`和失败即停，才得到有效通过。
3. `c38_soc_ddr_map_20260915b`实际139.721秒完成，MAP通过并清理私有工程。真实worker30756（16:52:54.6382020）、efx_map11236（16:52:55.9855268）在运行时通过句柄检查：**Job=false、affinity=3、BelowNormal**；结束后均退出。[MAP摘要](../logs/efinity_resource_runs/c38_soc_ddr_map_20260915b/summary.json)。

| MAP结果 | 数值 | 解释 |
| --- | ---: | --- |
| LUT4 | 40,102 | 摘要字段`metrics.le`实际上来自LUT4计数，不是最终XLR |
| FF | 27,161 | 联合逻辑寄存器数量 |
| RAM | 187 | 含真实Sapphire、单DDR控制器及C37；不含CSI/HDMI等未实例化功能 |
| DSP原语 | 29×DSP48 + 96×DSP24 | 汇总脚本记为125；最终物理打包和占用须以PNR为准 |

不能把这组MAP与C37单独PNR的41,318 XLR直接相减，也不能把剩余69块RAM当作整板余量。当前已串行启动`c38_soc_ddr_pnr_20260915a`，布局布线及核心时序结果尚待核验。

### 联合布局阶段的资源警报

17:10读取的实际布局报告为**58,751 / 60,800 XLR（96.63%）**，187 RAM、125 DSP，尚不是最终布线签核。对应层次归因估计为C37 host 43,158 XLR、Sapphire 10,436.5 XLR、DDR 5,147.5 XLR、顶层9 XLR；工具的半整数是打包资源归因，不是半个物理单元。[保留的层次摘要](../logs/r2_c38_joint_placement_hierarchy_20260915a.log)。

这说明“仅核对CNN单体能放入Ti60”不足以支持全板可行性。当前只剩约2,049 XLR，CSI/Debayer/HDMI及实际CDC尚未加入，不能据此宣称整板可放下。后续应先审计C37 host内寄存器/FIFO/控制逻辑，再评估用官方IP生成流程裁剪Sapphire的不必要外设、缓存或调试配置；不修改受保护源码，不在无吞吐回归的情况下削减DDR在途深度。待选视频外壳的实际增量必须单独实测，不能把整套视频Demo资源直接相加。

本次真实worker30284及PNR37788运行中均已核验Job=false、affinity=3、BelowNormal，[句柄检查记录](../logs/r2_c38_pnr_process_audit_20260915a.log)。这些检查不代表热安全或任务最终完成。

## 接口短仿真：明确使用行为替身

[测试脚本](../golden/run_c38_joint_seam_probe.py)编译真实C38顶层及完整C37 RTL，仅将受保护Sapphire/DDR替换为公开端口一致的行为模块。它验证**接线与既有适配器组合**，不验证CPU执行指令、DDR PHY或校准算法。

[实际结果](../logs/r2_c38_joint_seam_20260915a.log)：9项检查通过，2读/2写；完整8位ID恢复、SLVERR/BRESP传回、校准前请求隔离、超256MiB地址本地拒绝、APB ID/尺寸/高位地址拒绝、标量IRQ接线通过。DDR替身允许AWREADY依赖WVALID；未加入“先AW握手才能WVALID”的新依赖。

另将**私有顶层实际连线**分别改成BRESP绑零、RID高位截断、绕过校准门控，三种错误都被对应断言检出。IRQ检查只验证线连接，不代表真实PLIC中断处理。未覆盖真实Sapphire的所有窄访存、burst、原子/独占或缓存维护。

短测首次受到沙箱临时目录ACL限制，尚未运行RTL；随后核验并删除所留下的指定空目录，在正常权限、两核/低优先级及单重任务互斥下完成。所有短测私有目录均在子进程退出后删除，无波形、未修改C37或企业源。

## 下一步验收顺序

1. 完成当前逻辑联合PNR，核对真实XLR/RAM/DSP与时序，确认是否需要进一步资源优化。
2. 选定一个官方视频版本的活动CSI/Debayer/HDMI来源，逐接口接入；裁掉旧framebuffer/DDR/重复调试器后再评估，不能叠加整套例程。
3. 联合规划PLL、Clock Mux、相机/显示/DDR时钟、复位、peri.xml与引脚；解决100/150MHz选择及显示CDC。联合资源通过不代表这些步骤通过。
4. 真实Sapphire BSP、DDR地址/缓存维护、CSR及中断启动测试；最后才进行摄像头、显示和CNN全链路板测。
