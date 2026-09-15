# R2：官方SoC/DDR接入与吞吐比较边界

日期：2026-09-14。本轮是活动源码、端口和时钟配置的静态核查，不是官方IP仿真、联合综合或板测。未修改企业资料。可重跑的[有界读取检查器](../golden/check_r2_official_ddr_contract.py)及[结果](../logs/r2_c32_official_ddr_contract_20260914_b.log)只读取所需配置和源码头部，不解密控制器。

## 1. 实际活动工程与不同接口

入口是企业08目录下 `09_Ti60F225_co_debug_demo/par/ddr_demo_ti60`。XML明确引用 `ip/soc/settings.json` 和 `soc.v`，顶层实例为 `soc u_sapphire_soc`，不是仅凭目录名推断。

| 接口 | 数据 / ID / 地址宽度 | 与当前R2的关系 |
|---|---|---|
| Sapphire `io_ddrA_*` | 128 / 8 / 32 bit | 原生DDR出口；数据/ID宽度与C31 `cpu_*`相符，优先从这里接入 |
| Sapphire `io_ddrMasters_0_*` | 32 / 4 / 32 bit | 供外部主机访问SoC共享DDR的入口；本例程顶层未连接，不能当作已有可用的128-bit入口 |
| Sapphire `axiA_*` | 32 / 8 / 32 bit | CPU外设AXI master，不是上面的外部DDR入口 |
| 官方DDR controller用户口 | 128 / 4 / 28 bit | 地址覆盖256MiB物理空间；不能直接截断CPU高地址和完整ID |
| Sapphire外接APB0 / 用户中断 | APB地址16、数据32；IRQ标量 | 与C31本地APB16/32基本对应，仍需地址映射、时钟/复位、写选通约定 |

直接证据：[soc端口](D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo/par/ddr_demo_ti60/ip/soc/soc.v)、[活动XML](D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo/par/ddr_demo_ti60/ddr_demo_ti60.xml)、[DDR参数](D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo/rtl/ddr3_controller/ddr3_parameter.vh)。

## 2. 100MHz与150MHz不能直接拼接

例程参数 `ASYN_AXI_CLK=0`，顶层据此选 `user_clk=core_clk`；CPU system/memory时钟也接user_clk。SDC给core_clk配置10ns，IP设置Frequency为100，因此这是**名义100MHz**的用户接口配置。SDC另有5ns的axi_clk，不能因为它存在就声称活动DDR用户接口是200MHz。

当前C31核心目标是6.666ns、约150MHz。把它整体降到100MHz会改变所有周期→秒的换算，也改变相机输入/Resize积压及显示服务条件，不能把它当作“免费接入”方案。

后续要选择并真实验证一种时钟组织：保留150MHz计算与100MHz DDR域，加入受验证的总线跨域；或者验证官方异步参数配置和Sapphire memory时钟组织，使桥接集中在合适位置。`ASYN_AXI_CLK`和`io_memoryClk`端口的存在仅提供候选入口，**不证明任意150/100MHz组合已经安全可用**。不得靠宽泛false-path掩盖跨域，也不能假定新增桥接不消耗RAM/PLL/逻辑。

证据：[user_clk选择](D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo/rtl/ddr3_example_top.v:248)、[实际时钟约束](D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo/par/ddr_demo_ti60/sdc/ddr3.sdc)、[IP设置](D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo/par/ddr_demo_ti60/ip/soc/settings.json)。这是配置事实，不是新联合工程时序通过。

## 3. 为什么不优先把整个R2缩到stock 32-bit入口

仅作明确条件下的读带宽上限比较：假设该32-bit入口运行100MHz，其读数据通道即使每拍有效，峰值也只有400,000,000 B/s。

当前图每次CNN实际读1,442,333个128-bit字，15fps对应346,159,920 B/s。若保持两幅640×480、RGBX32、60Hz DDR扫描读出，还需147,456,000 B/s。两者合计**493,615,920 B/s，仅读方向就超过上述400MB/s**；这没有把独立的AXI读、写通道错误相加成一个32-bit带宽上限。

这些是假设条件下的必要带宽，不是板测。官方外部入口时钟本轮未连接，不能断言它实际跑100MHz或不可能配置更高频；但简单采用32-bit/100MHz连接不满足现有整套读流量。保留128-bit主数据路径更符合当前CNN与显示架构，避免先引入明显的窄口瓶颈。复用官方RAW帧缓存往返DDR时，还必须把新增RAW读写另列预算，C31当前直接RGB源模型并未包含它。

## 4. 推荐的连接方向与必须补齐的验证

连接方向：Sapphire原生DDR128出口 → C31现有CPU归一化适配口 → C31共享AXI128 fabric → 时钟/地址边界适配 → 官方DDR128用户口。APB0及标量IRQ单独接控制面。这是集成方向，尚未生成联合top。

- **ID和地址**：CPU侧完整8-bit ID必须可恢复；物理28-bit地址必须先通过256MiB窗口检查。例程顶层直接使用4-bit ID和28-bit地址网线，不应原样复用于任意CPU请求。
- **写响应**：例程 `io_ddrA_b_payload_resp` 连接留空；联合top必须显式接回真实BRESP，不把写错误当作成功。
- **控制面**：官方APB0没有PSTRB。若采用完整32-bit访问约定，可以对C31提供全字写选通；窄软件访问是否被上游桥转换必须另验。跨域时，APB握手与IRQ保持/清除都需处理。
- **CPU实际访问形态**：当前完整主机的[内存BFM](../sim/c1_r2_axi_memory_bfm.sv:112)只接受16-byte对齐、ARSIZE/AWSIZE=4的访问；CPU交通源也是128-bit满宽测试。C13适配器的窄访问能力及共享仲裁器传递SIZE的源码，不等于实际Sapphire窄访问已通过整机验证。应先确认Sapphire导出DDR端口的实际形式；如存在更窄或非16-byte对齐访问，需用独立字节寻址BFM与真实主机回归补齐，不能删除约束检查后宣布兼容。
- **缓存、启动与复位**：CPU程序/参数加载、非一致性缓存维护、DDR校准就绪、跨域reset及错误排空仍是联合验收项。已有C只读API的交叉编译不等于真实Sapphire执行。

## 5. 不能由加密控制器推断AW等待策略

实际活动 `axi4_bus_ctl.v` 在端口声明后进入受保护内容。当前可读资料没有证明它的AWREADY等同于BFM的AW0或AW2，也没有证明Efinity能综合就意味着Icarus/xsim能仿真该模型。需厂商支持的模型/仿真器或板测来确认实际行为。

因此继续分别报告：同口径AW0常规吞吐、AW2整突发W先行压力正确性及其观察周期、最后的真实DDR性能。C31压力长跑不会中途改参数追求更高fps；C32提前写回候选也必须在相同模型条件下对照，不能把条件改变算作RTL优化收益。
