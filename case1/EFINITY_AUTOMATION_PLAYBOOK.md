# Efinity 2026.1 工程开发、仿真与资源评估方法

适用对象：在同一台Windows电脑上负责其他赛题的开发会话。本文提取赛题一实际使用过的方法，不要求其他赛题采用赛题一的CNN架构。整理日期：2026-09-15；依据本机安装文件、工程XML和已完成运行的脚本/小型记录。没有为撰写本文重新启动EDA。

## 1. 先明确工作边界

Efinity GUI并不是每一步都必须操作。RTL编辑、显式源表生成、IP参数校验与生成、软件构建、综合、布局布线、STA、报告提取和回归通常可以脚本完成。实际摄像头、DDR PHY、HDMI物理接口、PLL及管脚配置仍依赖正确的板卡资料；能生成一个资源探针，不等于已经生成可下载运行的板级工程。

本工程将工作分成三个层级：纯RTL模块/子系统仿真，真实CPU/DDR源参与的资源与相关时序探针，完整板级集成。测试替身只能证明其接口范围，不能把行为CPU的总线访问说成官方CPU已经执行程序，也不能把行为DDR说成PHY训练通过。

## 2. 本机工具与环境

| 工具 | 本机入口 | 用途 |
|---|---|---|
| Efinity | `D:\ELS\Efinity\2026.1` | 基础版2026.1.132，已安装补丁2026.1.132.3.9 |
| Efinity Python | `python311\bin\python.exe` | 调用官方运行器、IP Manager API |
| Efinity运行器 | `scripts\efx_run.py`；外层`bin\efx_run.bat` | map、pnr、sta等flow |
| RISC-V IDE | `D:\ELS\efinity-riscv-ide-2026.1` | Eclipse IDE、BSP与调试环境 |
| 官方GCC | 上述目录`toolchain\bin\riscv-none-elf-gcc.exe` | 本机13.4.0；ISA必须匹配生成CPU |
| Icarus | `D:\iverilog\bin\iverilog.exe`、`vvp.exe` | 可支持的开放RTL模块与行为模型仿真 |
| Vivado xsim | `D:\vivado\vivado\Vivado\2023.1\bin` | 便携SystemVerilog系统回归，不替代受保护厂商IP仿真 |

GUI可用用户已经验证的`D:\ELS\Efinity\2026.1\bin\setup.bat --run`启动。命令行不能假设GUI或另一个cmd里的环境会自动带到PowerShell。`efx_run.bat`实际转发到Efinity内置Python和`efx_run.py`；直接使用该Python时必须设置`PYTHONHOME`，否则可能报`No module named encodings`。

下面环境设置只能在工具worker自身内生效，不能依赖WMI继承前台会话刚刚修改的环境：

```powershell
$efinityRoot = 'D:\ELS\Efinity\2026.1'
$efinityUnix = $efinityRoot.Replace('\','/')
$env:EFINITY_HOME = $efinityUnix
$env:PYTHONHOME = Join-Path $efinityRoot 'python311'
$env:EFXPT_HOME = "$efinityUnix/pt"
$env:EFXPGM_HOME = "$efinityUnix/pgm"
$env:EFXDBG_HOME = "$efinityUnix/debugger"
$env:EFXIPM_HOME = "$efinityUnix/ipm"
$env:EFXSVF_HOME = "$efinityUnix/debugger/svf_player"
$env:EFXSERDESDBG_HOME = "$efinityUnix/debugger/serdes_debug_tool"
$env:PATH = "$efinityRoot\python311\bin;$efinityRoot\bin;$efinityRoot\scripts;$env:PATH"
```

当前已测runner还设置用户INI位置等环境，迁移时应读完整runner，而不是把本段当成所有flow的完整环境模板。不要重新定义`HOME`或`CODEX_HOME`。

## 3. 用显式工程源表代替目录通配

工程至少包含顶层、明确的设计文件列表、器件/速度等级、时序约束和必要的IP配置。当前纯host工程示例为[XML](efinity/c1_ti60_c39_host_onehot.xml)、[顶层](efinity/c1_ti60_c39_host_onehot.sv)、[SDC](efinity/c1_ti60_c39_host_onehot.sdc)。器件为`Titanium / Ti60F225`，XML里的`timing_model`为`I3`。旧探针可能使用C4，不可混用其时序结论。

源表中每个同名模块只出现一次。赛题一多个历史目录故意保留同名替代实现，当前通过[49源选择器](golden/c39_onehot_sources.py)选取，不是把`rtl/`全部导入。其他赛题应建立自己的源闭包，显式区分设计源、testbench、行为替身、厂商生成IP和include路径。

XML的`design_file`、SDC引用、include和RAM初始化路径都要核对。原工作区不少XML使用绝对路径；移动工程必须重新生成或重定位到新目录，不能让GUI悄悄继续编译旧目录源码。相对路径应相对于XML所在目录解释。

## 4. 常用flow与实际调用方式

本机实际MAP调用采用“工程名称 + `--prj` + `-f map`”，在工程XML所在目录执行。以下是worker内的调用形态，不建议把长运行直接挂在当前会话的Job里：

```powershell
$edaPython = Join-Path $efinityRoot 'python311\bin\python.exe'
$edaRunner = Join-Path $efinityRoot 'scripts\efx_run.py'
$designName = 'c1_ti60_c39_host_onehot'
$projectDir = 'D:\contest\2026FPGA\yilingsi\case1\efinity'
$outputDir = 'D:\contest\2026FPGA\yilingsi\case1\tmp\example_run\out'
$workDir = 'D:\contest\2026FPGA\yilingsi\case1\tmp\example_run\work'
Push-Location $projectDir
try {
    & $edaPython $edaRunner $designName --prj -f map `
        --family Titanium --device Ti60F225 `
        --output_dir $outputDir --work_dir $workDir --timeout 900 `
        --map_opts "root=$designName"
    if ($LASTEXITCODE -ne 0) { throw 'Efinity map failed' }
} finally { Pop-Location }
```

这里的D盘例子需要在worker内先建立本次独占目录，且不覆盖既有结果。PNR将`-f map`改成`-f pnr`，使用同一次MAP的输出目录和工作目录；不要拿另一版RTL的MAP结果做PNR。STA使用`-f sta_tclsh --tcl_script <审计脚本>`。`interface`、仿真和bitstream相关flow应先查看安装版本的`efx_run.py`帮助以及板级工程配置，不凭其他版本经验臆造参数。

对本项目，优先调用已经具备隔离、预算、提取和清理功能的入口：

```powershell
# 从工程工作区根目录执行；RunId必须是新的，不能重复覆盖。
& .\case1\scripts\run_efinity_ti60_resource_map_detached.ps1 `
    -DesignName c1_ti60_c39_host_onehot `
    -RunId manual_host_map_01 -TimeoutSeconds 900

# map之后同一worker接续pnr；这里仍是无板资源探针。
& .\case1\scripts\run_efinity_ti60_resource_map_detached.ps1 `
    -DesignName c1_ti60_c39_host_onehot `
    -RunId manual_host_pnr_01 -TimeoutSeconds 900 -RunPnr
```

返回值是worker PID与状态路径，不是完成证明。读`logs/efinity_resource_runs/<RunId>/status.json`，等待真实worker和子进程结束，再检查退出码、结果及私有目录清理。`-ProjectInPlace`用于确实依赖工程目录布局的场合，使用前读脚本确认路径影响；`-CdcAudit`要求该设计对应的`.audit.tcl`存在，不能把别人的层级名称直接套入。

## 5. 长任务脱离Windows Job

`Start-Process`本身不保证逃离当前会话的Windows Job；仅用`start /b`也不构成证明。当前做法是前台只通过`Win32_Process.Create`启动隐藏PowerShell worker，实际EDA进程由该worker创建；WMI不可用时使用[原生breakaway助手](scripts/start_detached_process.ps1)。本机已有运行记录明确保存`worker_in_windows_job=false`和子进程对应字段。

设计一个可复用runner时，应保存：run-id、worker PID、精确启动时间、子进程PID/启动时间、是否属于Job、当前step、退出码、资源预算、清理结果。进程身份以PID加启动时间核对，不能只看PID，因为系统会复用PID。

同一时刻只运行一个重型EDA任务。当前预算为两逻辑核、BelowNormal、至少8GiB可用内存，工具本身也限制线程。日志长时间没新增但原进程仍活着，不代表异常；先核对CPU时间、当前阶段和实际进程，再决定。观察超时不是任务超时，更不是重启授权。失败必须保留原run-id证据，修复后才使用新的run-id。

## 6. 临时文件、流量与失败证据

现有资源runner默认使用系统`TEMP`下的独占目录，结束后自动清理。这可能位于C盘；若其他赛题希望全部放D盘，应在其worker内显式配置独占scratch根，而不是只修改前台`TEMP`。正式XML、RTL、IP设置、BSP不能放在将递归删除的临时目录里。

平时只读状态JSON、末尾少量日志、目标模块资源行和最终STA表。不要把数百MB的vvp、mem、波形、checkpoint或映射数据库整体传回会话。需要审查映射后CDC时，仅提取相应同步FF、指定端点及路径小报告；编译源追溯可读取vvp有界文件名表，不读取其主体。

清理前必须验证真实子进程已经退出，并将准确绝对目录限制在本次私有scratch内。只移除本次可重建中间物，保留成功/失败退出码、精简原始输出、参数和结果。禁止对workspace根、系统TEMP根或未解析的通配路径递归删除。本轮C39的长xsim、量化和窗口私有目录均已按此策略清理，无波形。

## 7. 官方IP生成：先校验完整参数

当前安装的Sapphire包位于`ipm/ip/efx_soc/efx_soc`，版本3.4.1；企业Demo内CPU为3.3.0。CPU裁剪对照应使用同一版本重新生成S0/S1/S2，避免把版本变化算成优化收益。

[实际生成脚本](golden/c39_sapphire_config.py)使用内置Python和官方`efx_ipmgr.api_v2`。工作顺序是限定IP搜索目录，读取IP-XACT的VLNV，加载官方实例设置，解析全部参数，调用`validate_params`，保存实际校验结果，再调用`generate_ip`。本项目校验的是152项完整参数，不能只填几个cache/DDR开关后绕过官方校验。

```powershell
# 需在已设置Efinity环境、受预算约束的独立worker中执行。
& $edaPython .\case1\golden\c39_sapphire_config.py `
    --profile s2 --run-id s2_example_validate_01

# --generate才请求真实IP生成；每个run-id必须全新。
& $edaPython .\case1\golden\c39_sapphire_config.py `
    --profile s2 --run-id s2_example_generate_01 --generate
```

该脚本的`VENDOR_SETTINGS`目前绑定本机官方Demo设置路径，迁移到其他赛题前应替换为该赛题获准使用的官方设置，并审查其参数。不要直接编辑厂商受保护RTL，不要修改安装包。生成IP、BSP、启动代码、链接脚本及公开端口合同应成套保留在本地；是否允许再分发由厂商许可决定，发布仓库默认不携带厂商载荷。

曾遇到的实际问题：内置Python缺`PYTHONHOME`；Java从`JAVA_TOOL_OPTIONS`向stderr打印提示被IPM当失败；生成对象未设置已校验参数导致保存的`conf`为空。解决分别为明确环境、私有Java launcher使用正常命令参数限核/内存、通过已解析参数保存实例设置。不能靠吞掉stderr或手工填写成功状态解决。

## 8. Sapphire与现有RTL连接

把CPU控制面和加速器数据面分开：CPU通过APB配置寄存器/状态/IRQ，CPU DDR主口与采集、CNN、显示等数据主机通过明确适配/仲裁访问唯一DDR控制器。审查地址位宽、ID保存/恢复、burst长度、AW/W独立握手、BRESP/RRESP错误、校准完成门控，以及CPU/DDR用户时钟关系。

当前S2是统一100MHz的Lite配置；不能套用Standard版本独立memoryClk的连接，也不能照抄其他实例的端口前缀。公开端口检查见[c39_sapphire_port_audit.py](golden/c39_sapphire_port_audit.py)，平台约束见[c39_sapphire_platform_contract.py](golden/c39_sapphire_platform_contract.py)。当前联合资源探针见[XML](efinity/c1_ti60_c39_joint_s2_onehot_cdc.xml)与[生成/连接规则](golden/c39_joint_projects.py)。这些需要本地官方CPU和DDR源，不是仓库单独下载就能完成的板级bitstream工程。

## 9. RISC-V软件构建和调试分界

`efinity-riscv-idec.exe --help`可能启动并驻留IDE，不应当作轻量编译器探测。自动构建直接用官方GCC/Make及匹配BSP即可；GUI用于工程浏览、断点和实际调试时再开。

本项目S2为RV32IM加CSR/fence相关指令，不支持压缩C或FPU。旧样例的`rv32imac`不能直接沿用。需要同时审查`-march`、`-mabi=ilp32`、链接地址、stack、boot ROM、`soc.h`频率、APB窗口及IRQ编号。

当前[软件probe说明](software/c39_s2_probe/README.md)、[全API构建器](golden/c39_s2_driver_build.py)验证了六个现有驱动API，包含实际反汇编ISA检查与不兼容C/F编译负例。它们没有在CPU上执行，不能证明启动、PLIC中断、缓存维护或DDR初始化已经成功。QEMU通用RISC-V程序通过也不能代替自定义Sapphire及加速器总线联调。

## 10. 选择仿真工具时看IP模型，而不是只看工具安装

| 对象 | 可先使用的方式 | 不能据此宣称 |
|---|---|---|
| 开放SystemVerilog算法/AXI/帧控制 | Icarus或xsim，匹配实际语言特性 | 厂商物理IP已验证 |
| 含官方行为模型的IP例程 | 按该IP生成的仿真脚本和支持的模拟器执行 | Icarus必然支持全部加密/语言模型 |
| 受保护Sapphire或特定DDR/MIPI模型 | 查看该版本官方支持与许可，必要时ModelSim/Questa/Aldec | xsim或Icarus可无条件替代 |
| DDR PHY、MIPI D-PHY、HDMI串行器 | Efinity接口工程及实际板卡验证 | 行为源/内存模型通过等于物理链路通过 |

本项目的系统xsim使用真实加速器RTL、行为摄像头输入、带延迟的AXI内存和CPU总线访问模型。9项联合接口检查使用实际host连接加行为CPU/DDR。真实官方CPU/DDR源另参与Efinity资源探针；这两个证据层级必须分开。

## 11. 时序与CDC审查

先检查所有真实时钟周期、关系和复位同步，再按协议约束跨域。异步FIFO需检查两级同步、Gray位数、实际端点覆盖与bus skew；稳定数据束应说明握手期间保持条件。不要用整组false path隐藏错误路径，也不要把没有匹配到pin的约束当成生效。

赛题一使用实际映射后寄存器/连接、两个方向端点和逐路径延迟审计：[检查器](golden/c39_joint_cdc_evidence.py)。当前联合56同步FF、127+14端点、Gray skew 0.066/0.042ns通过，但完整`report_cdc`曾触发工具内部断言失败，不能因此写“全系统CDC通过”。其他赛题必须重建自己的层级/端点清单，不能只修改一个计数使检查变绿。

资源读取应采用最终PNR表及最终STA表，不能把post-place负hold、最终hold、geomean、核心Fmax混用。[最终时序解析器](scripts/efinity_final_timing.ps1)保留这些区别。历史长模块名截断曾造成MAP根行漏FF和RAM误记0，修复时应返回缺失而不是默认为0，并对照实际保留根行；历史原始summary不覆盖。

## 12. 如何进行公平优化对照

每次只改变可说明的RTL或平台参数，冻结器件/速度等级、源闭包、模型、容量、时钟、约束、种子和流量条件。先数值/协议等价，再MAP筛选，有收益才PNR，候选获胜后补完整系统回归。失效候选和无收益结果要保留。

C39示例：量化六lane叶级3,706→2,700 XLR，纯host整体41,318→40,476 XLR，不能相加；单独量化替换曾使host MAP变差。Sapphire同版裁剪减少4,364 LUT4/3,488 FF/22 RAM，是另一层级的MAP对照。真实S2联合51,900 XLR不是把CPU和host叶级报告算术相加得出。

纯host六帧最差6,433,652周期，在标称150MHz下约23.315fps；100MHz联合系统尚无相同吞吐实测。显示刷新率、处理帧率、采集帧率、仿真墙钟耗时必须分别报告。资源探针与camera30仿真的FRAME_DIVISOR也应逐项核实，不把参数不同的运行混成一个默认配置。

## 13. 给其他赛题会话的最小交接包

交接内容应包括：本机工具路径和版本、项目XML/SDC/顶层、确切源闭包、官方IP设置与本地重建方法、BSP/ISA/地址合同、可重跑的短测入口、隔离runner、最近一次小型终态记录，以及明确的板级缺项。不要交接整份`.Xil`、`xsim.dir`、波形或临时综合数据库。

推荐执行顺序：理解并核对自己的源与接口→有界数值/协议短测→官方IP参数生成及公开端口检查→独立MAP→同一次PNR/STA→逐端点CDC→完整系统流量回归→GUI检查接口/PLL/管脚→实际板测。某一步失败就保留证据并定位，不通过删除门槛、改状态文件或用旧PASS替代新运行来继续。

## 14. 本机可复用入口索引

| 文件 | 可以借鉴的内容 | 迁移注意 |
|---|---|---|
| [资源runner](scripts/run_efinity_ti60_resource_map_detached.ps1) | WMI/breakaway、MAP/PNR/STA、提取、清理 | 工程路径、目标器件、报告解析、临时根需审查 |
| [隔离启动助手](scripts/start_detached_process.ps1) | 原生Windows breakaway | 不能把普通Start-Process当同等替代 |
| [IP生成器](golden/c39_sapphire_config.py) | 官方参数校验与隔离生成 | 输入settings/VLNV/版本必须绑定自己的实例 |
| [联合平台合同](golden/c39_sapphire_platform_contract.py) | 时钟、校准、公开端口、ISA | 不复制赛题一固定寄存器/IRQ地址 |
| [C39短测runner](scripts/run_c39_datapath_detached.ps1) | 隔离、预算、依赖队列、真实退出 | 测试集合和PASS门槛属于赛题一 |
| [最终时序解析](scripts/efinity_final_timing.ps1) | 提取最终STA | 版本变化要用真实报告重新测试解析器 |
| [最终验收示例](review/C39_THREE_OBJECTIVES_FINAL_ACCEPTANCE_20260915.md) | 分层证据与尚未验证项 | 是方法参考，不是其他赛题的完成证明 |

本方法文档不附带厂商安装包或IP载荷，也不修改其他赛题工程。发布版本可能排除原始工具日志；需要追溯完整本机记录时使用本地开发树，不伪造缺失日志。
