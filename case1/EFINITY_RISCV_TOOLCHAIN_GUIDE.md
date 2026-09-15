# Case-1：Efinity 2026.1 与 RISC-V/Sapphire 本地开发指南

> 版本：2026-08-28。竞赛选题指南已明确赛题一～三使用 Ti60F225I3 的 Ti60F225 开发板（MIPI CSI-2、HDMI、DDR3、千兆以太网）。本文记录当前电脑上已验证的安装路径、命令行入口和与 Case-1 RTL 的集成边界；用户截图已给出 DDR 颗粒，但具体板卡 revision、DDR 控制器/拓扑配置、时钟树和引脚表仍须以随板官方工程为准，不据旧示例生成猜测性的 pin/LPF 约束。

## 1. 已安装并已验证的组件

| 组件 | 本机路径 | 当前检查结果 |
|---|---|---|
| Efinity IDE | `D:\ELS\Efinity\2026.1` | base `2026.1.132`，已应用 patch `2026.1.132.3.9`；`bin\efx_run.bat --help` 可运行 |
| Efinity RISC-V IDE | `D:\ELS\efinity-riscv-ide-2026.1\Efinity-RISCV-IDE` | `efinity-riscv-ide.exe`、`efinity-riscv-idec.exe` 存在 |
| RISC-V GCC | `D:\ELS\efinity-riscv-ide-2026.1\toolchain\bin` | xPack `riscv-none-elf-gcc` 13.4.0 |
| GDB | 同上 | 16.3（本地安装包） |
| OpenOCD | `D:\ELS\efinity-riscv-ide-2026.1\openocd\bin` | 0.11.0-dev（本地安装包） |
| QEMU | `D:\ELS\efinity-riscv-ide-2026.1\qemu` | `qemu-system-riscv32.exe`/`qemu-system-riscv64.exe` |
| Make/辅助工具 | `D:\ELS\efinity-riscv-ide-2026.1\build_tools\bin` | 本地 GNU Make 4.2.1 |
| Soft Sapphire IP | `D:\ELS\Efinity\2026.1\ipm\ip\efx_soc\efx_soc` | 含 Ti60F225 示例、BSP、OpenOCD 和生成脚本 |

Efinity GUI 可以用用户现有的 `bin\setup.bat --run` 启动。命令行 flow 则由 `efx_run.bat` 转到 Efinity 自带的 Python 运行器；官方 CLI 文档列出了 `map`、`interface`、`pnr`、`compile`、`rtlsim`、`mapsim`、`pnrsim`、`full` 和 `sta_tclsh` 等 flow。[Efinity Command-Line Interface User Guide](https://www.efinixinc.com/docs/efinity-command-line-v1.0.pdf)

用户提供的 Ti60F225I3 板卡参数（DDR3 x16/800 Mbps、25/27/50 MHz 时钟、MIPI/HDMI、FT4232HL 等）及带宽/容量推导见 [`efinity/TI60F225_BOARD_PROFILE.md`](efinity/TI60F225_BOARD_PROFILE.md)。这些是板级输入和预算，不改变生成 IP 的参数语义；实际 pin、DDR UI 时钟和地址映射仍以随板工程/IP Manager 输出为准。

## 2. Efinity 命令行的最小工作方式

`setup.bat` 在子进程中修改环境变量，所以脚本中建议用一次性 `cmd /c call ... && ...`，不要假定它会修改当前 PowerShell 会话：

```powershell
$efinityHome = 'D:\ELS\Efinity\2026.1'
$projectDir  = 'D:\contest\2026FPGA\yilingsi\case1\efinity\<board_project>'
$projectXml  = Join-Path $projectDir '<project>.xml'
$outDir      = Join-Path $projectDir 'out'
$workDir     = Join-Path $projectDir 'work'

$line = "call `"$efinityHome\bin\setup.bat`" && " +
        "cd /d `"$projectDir`" && " +
        "`"$efinityHome\bin\efx_run.bat`" `"$projectXml`" --prj " +
        "--flow map --output_dir `"$outDir`" --work_dir `"$workDir`""
cmd.exe /d /s /c $line
```

建议的 flow 顺序是：

1. `interface`：让工具生成/检查接口约束；
2. `map`：只做综合，快速检查语法、器件资源和 RAM/DSP 推断；
3. `pnr`：执行布局布线和时序；
4. `compile`：按 Efinity 工程配置完成综合、布局布线和 bitstream；
5. `rtlsim`/`mapsim`/`pnrsim`：分别做 RTL、综合后或 P&R 后仿真；
6. `sta_tclsh`：在有真实时钟/引脚约束后做静态时序分析。

虽然目标器件和截图中的 DDR 颗粒已知为 Ti60F225I3/`MT41J128M16JT-125`，板卡资料（revision、DDR 控制器/IP、时钟和 pin 表）尚未齐全时，仍只建议先做 `map` 或 IP 自带 testbench；不要把本地 Ti60 示例工程的旧约束直接当成当前板卡约束。`D:\ELS\Efinity\2026.1\ipm\ip\efx_soc\efx_soc\fpga\fpga_ti\soc.xml` 是本地 Ti60F225 示例（保留了旧版本生成时间），应视为“结构参考”，而不是当前 Case-1 的最终工程。

## 3. RISC-V IDE、软件编译和仿真

### 3.1 GUI 与脚本环境

直接启动 GUI：

```powershell
Start-Process `
  -FilePath 'D:\ELS\efinity-riscv-ide-2026.1\Efinity-RISCV-IDE\efinity-riscv-ide.exe' `
  -WorkingDirectory 'D:\ELS\efinity-riscv-ide-2026.1\Efinity-RISCV-IDE'
```

更推荐使用仓库内的隔离 workspace 启动器；它通过 Eclipse 的 `-data` 选项
把索引和 IDE 临时状态放到 `D:\contest\2026FPGA\efinity_workspace`，并只
设置非交互式工具链环境：

```powershell
& .\scripts\launch_efinity_riscv_ide.ps1
```

`efinity-riscv-idec.exe` 不是一个可安全用于 `--help` 的命令行编译器；它会
启动并驻留 IDE 进程。软件构建应在 IDE 的 Makefile 工程中进行，或直接使用
生成 BSP 中的 Makefile 和本地 `riscv-none-elf-*` 工具。

IDE 是基于 Eclipse/Ashling RiscFree 的 Efinix 定制环境，承担源文件编辑、Makefile 工程、BSP、编译和 OpenOCD 调试；官方页面说明安装包同时提供硬件 RTL/testbench、BSP、链接脚本、头文件、OpenOCD 配置和示例软件。[Efinity RISC-V Embedded Software IDE](https://www.efinixinc.com/products-efinity-riscv-ide.html)

对于自动化构建，建议显式设置环境，不调用会询问 FreeRTOS 路径的交互式 setup。该 IDE 的 `setup.bat` 还会把当前目录写入 `RISCV_TOOLS_HOME`，所以若确实调用它，必须先 `cd /d D:\ELS\efinity-riscv-ide-2026.1`；裸机脚本可直接使用下面的显式 PATH 方式：

```powershell
$riscvIde = 'D:\ELS\efinity-riscv-ide-2026.1'
$env:PATH = "$riscvIde\toolchain\bin;$riscvIde\build_tools\bin;$riscvIde\openocd\bin;$env:PATH"
$env:BSP  = 'efinix/EfxSapphireSoC'

riscv-none-elf-gcc --version
riscv-none-elf-objcopy --version
make --version
```

Efinity bundled Python 还需要 `PYTHONHOME=<EfinityHome>\python311`。未设置时
直接调用 `python.exe` 可能在初始化阶段报 `No module named encodings`；这不是
IP 本身的 RTL 错误。脚本化 IP 生成入口为：

```text
D:\ELS\Efinity\2026.1\ipm\ip\efx_soc\efx_soc\generator\soc_gen.py
D:\ELS\Efinity\2026.1\ipm\ip\efx_soc\efx_soc\embedded_sw\sw_script.py
```

两者都应由 IP Manager 传入完整的 IPXACT 解析参数，不能手工只填写
`SOC_MODE/DDR/Cache` 等少数键；详见 [`efinity/README.md`](efinity/README.md)。

本地 GCC 含 multilib；Case-1 选择 RV32 Soft Sapphire 时，软件编译参数应以生成 BSP 为准，通常可从 `-march=rv32imac -mabi=ilp32` 起步。不要把 RV64 编译选项用于 RV32 BSP；硬件核、`soc.h`、链接脚本和启动代码必须成套匹配。

QEMU 可执行文件位于 `$riscvIde\qemu`（不是 `qemu\bin`），例如：

```powershell
& "$riscvIde\qemu\qemu-system-riscv32.exe" --version
```

安装包中的 `examples\qemu32-baremetal.zip` 是旧版兼容示例，里面的 launch
配置仍可能把 GDB 写成 `riscv-none-embed-gdb.exe`；本机 2026.1.0.7 实际提供的
前缀是 `riscv-none-elf-*`。若在 IDE 中导入该示例，请把 Debugger 的 GDB
executable 改为
`D:\ELS\efinity-riscv-ide-2026.1\toolchain\bin\riscv-none-elf-gdb.exe`，
或直接使用本目录的 Makefile/命令行构建。该示例是通用 QEMU/spike 裸机环境，
不能证明 Sapphire 的 APB、DDR 或 Case-1 CNN 数据通路已经仿真通过。

工作区应放在 RTL 树之外或单独目录（例如 `D:\contest\2026FPGA\efinity_workspace`），以免 Eclipse 索引、编译中间物和 Case-1 RTL 混在一起。

可用 `scripts/verify_efinity_toolchain.ps1` 做不启动 Vivado 的板前检查；它只
检查版本和路径，`-BuildSmoke` 才会构建上述小工程，`-CleanSmokeAfter` 会在
检查后移除其 `build/`：

```powershell
& .\scripts\verify_efinity_toolchain.ps1 -BuildSmoke
```

### 3.2 生成的 BSP 与首次软件构建

正确顺序是先在 Efinity IP Manager 中生成 Sapphire 实例和 example design，再把生成的 embedded-software 工程导入 RISC-V IDE。生成目录通常包含：

- IP RTL、`<ip>_define.vh`、模板文件和 `settings.json`；
- `embedded_sw` 下的 BSP、`soc.h`、链接脚本、启动代码、OpenOCD/launch 配置；
- Ti60 example design 的 `project.xml`/顶层/SDC 和 testbench。

IDE 中可导入 **Efinix Makefile Project** 或生成的 BSP 工程；构建产物通常为 `.elf`、`.hex`、`.map`。`.hex` 是片上 RAM/固件初始化的输入，不是 FPGA bitstream；bitstream 仍由 Efinity `compile`/program flow 生成。Sapphire 用户指南给出了 Windows 安装、QEMU、串口终端、CSR/外设视图及 OpenOCD 调试流程。[Sapphire User Guide v6.0](https://www.efinixinc.com/docs/riscv-sapphire-ug-v6.0.pdf)

RISC-V 软件在无板阶段可先做两层验证：

1. 用 GCC/Make 编译寄存器读写、描述符生成、DDR 缓冲区布局和中断处理；
2. 用生成的 QEMU 32-bit bare-metal 示例验证启动、异常、轮询/中断状态机。QEMU 不能替代自定义 CNN 数据通路、真实 DDR 仲裁或视频/相机时序验证。

Efinity 自带 Sapphire `run.py`/`rtlsim` flow 面向 ModelSim/Questa、Aldec（未指定
时可能回退到 Icarus），没有 Vivado xsim 选项；因此它不能直接复用当前 xsim
runner。官方 testbench 应单独放在可丢弃目录中，Case-1 的 xsim 继续使用
`scripts/*_detached.ps1`，两类仿真不要共用 work/output。

### 3.2.1 Icarus/GTKWave 的后续互操作边界

本机当前 `D:\iverilog\bin` 已安装 Icarus Verilog **14.0 (devel)** 与 GTKWave
3.3.128；工程提供一个有界入口：

```powershell
& .\scripts\run_iverilog_smoke.ps1
& .\scripts\run_iverilog_smoke.ps1 -TrySapphireAdapter
```

如果刚修改过 Windows 的系统 `Path`，请新开一个 PowerShell/命令提示符（已运行
的 Codex/终端不会自动继承新环境变量）；工程脚本仍会优先解析
`D:\iverilog\bin`，所以不依赖当前会话是否已刷新 PATH。

脚本会在 `%TEMP%` 下创建一次性目录，先编译纯 Verilog-2005 小 DUT，再探测
SystemVerilog 选项；`-TrySapphireAdapter` 会额外编译/运行现有
`c1_sapphire_apb_master_adapter` + IRQ seam，并检查
`C1_SAPPHIRE_APB_ADAPTER_PASS`。默认不保留 VCD/工作树；只有显式加
`-KeepVcd` 才复制一个几百字节的 smoke 波形，`-OpenGtkWave` 可在此基础上启动
GTKWave。该脚本不启动 Efinity、Vivado、xsim、IP Manager 或 P&R。

Icarus 适合后续 Efinity 通用 `efx_run ... --flow rtlsim/mapsim` 中的**未加密、
纯 Verilog 用户 RTL**。Soft Sapphire IP Manager 生成的 `EfxCPUSp*.v` 包含
ModelSim/Aldec 专用的 `` `protected`` 加密 envelope，Sapphire 自带 testbench
只接受 ModelSim/Questa 或 Aldec；因此不能把“安装了 Icarus”理解为可以直接
仿真加密 Sapphire CPU。当前 Case-1 主线仍是 SystemVerilog，继续用 Vivado
xsim（或将来可用的 Questa/ModelSim）做功能回归；Icarus 仅在生成的 Efinity
工程明确为纯 Verilog、且不依赖加密 IP 时启用。

如需手工验证通用 Efinity flow，应在仓库外的 disposable 目录运行。下面是在
PowerShell 中把两个 `.bat` 串在一次性 `cmd.exe` 子进程里的写法（不要把
`call` 当作 PowerShell 命令直接执行）：

```powershell
$sandbox = 'D:\temp\efinity_plain_rtlsim'  # 先创建并确认这是可删除目录
$line = 'call "D:\ELS\Efinity\2026.1\bin\setup.bat" && ' +
        'cd /d "' + $sandbox + '" && ' +
        'call "D:\ELS\Efinity\2026.1\bin\efx_run.bat" <project>.xml ' +
        '--flow rtlsim --output_dir outflow --work_dir work_sim ' +
        '--dir <plain_verilog_dir> --tb <tb.v>'
cmd.exe /d /s /c $line
```

只使用 `rtlsim`/`mapsim`，不要在板卡资料未齐时调用 `compile/full`；Efinity
不会自动清理 `work_sim`/`outflow`，完成后应删除这两个精确目录。官方本地
说明也明确 Icarus flow 不支持 SystemVerilog、不能解密 IP Manager 代码。

### 3.3 已完成的 boardless Makefile smoke

`software/efinity_smoke/` 是一个刻意保持很小的 Makefile 工程，用来在生成
板级 Sapphire BSP 之前检查本机编译器、RVC 和 soft-float 链接链。已执行：

```powershell
make -C .\case1\software\efinity_smoke clean all
```

构建成功，`build/` 生成 ELF、HEX、BIN、MAP、反汇编和三个目标文件，共 8 个文件、
`35,952 B`（约 `35.1 KiB`）；`c1_efinity_smoke.elf` 为 ELF32 RISC-V，
属性为 `RVC`、`soft-float ABI`，架构为 `rv32imc`（默认
`-march=rv32imc -mabi=ilp32`）。该结果证明的是工具链/编译/链接产物可生成，
不是实际 Sapphire CPU 启动或 APB 访问 PASS；当前 `main.c` 只做无副作用的
CSR probe/status poll，未启动 CNN。

该工程**不是最终 BSP 应用**。IP Manager 生成 Soft Sapphire 实例后，应将：

1. 生成 BSP 的 `startup.S` 和 linker script 替换本目录的最小 `startup.S`/
   `linker.ld`；
2. 保持生成硬件、`soc.h`、启动代码、链接脚本和 `-march/-mabi` 成套匹配；
3. 从生成 BSP 的 `soc.h`/address map 设置 `C1_ACCEL_MMIO_BASE`，不要继续使用
   smoke 工程中的占位地址 `0xf8100000`；
4. 仅复用 `main.c`/`c1_accel.c` 的驱动逻辑，并把最终 `.elf/.hex` 交给生成
   工程的片上 RAM 初始化或下载流程。

smoke Makefile 支持 `SOC_INCLUDE`、`SOC_HEADER` 和
`C1_ACCEL_MMIO_BASE` 覆盖；例如可在不改源文件的情况下注入生成的
`soc.h`：

```powershell
make -C .\case1\software\efinity_smoke clean all `
  SOC_INCLUDE='D:\path\to\generated\bsp\include' SOC_HEADER=soc.h
```

若 `soc.h` 定义 `IO_APB_SLAVE_0_INPUT`（旧版生成器）或
`IO_APB_SLAVE_0_CTRL`（新版命名），它会作为默认 MMIO 基址；显式的
`C1_ACCEL_MMIO_BASE=0x...` 优先级更高。写入板卡前必须以本次 IP Manager
生成的 address map 为准。

本次 housekeeping 修复将 `../src/c1_accel.c` 显式编译为 `build/c1_accel.o`，
避免旧的模式规则把新目标文件落到 `build/../src`，因此 `make clean` 能完整移除
本次构建生成的对象文件。若旧版本曾在旧路径留下对象，需另行做一次性清理；
`build/` 是可随时由 `make clean` 删除的中间产物，不应与生成的 BSP 或 Efinity
bitstream 混为一谈。

## 4. Soft Sapphire 的选择与 Ti60 适配结论

当前目标若是 Ti60，应优先选择 **Soft Sapphire RV32**，而不是默认假设使用硬化/高性能 Sapphire。官方高性能 Sapphire 支持列表包含 Ti85/Ti135/Ti165/Ti240/Ti375 等 Titanium 器件，没有 Ti60；这不是“硬核一定不能用”的绝对证明，但足以要求拿到官方 board/IP 版本确认前不要采用它。[High-performance Sapphire device support](https://www.efinixinc.com/docs-html/rv32-sapphire-hpb-ds/topics/riscv-saxon-efx-features-sapphire-hpb.html)

Soft Sapphire 的官方特性包括 RV32、1–4 个 VexRiscv 核、可选 cache、片上 RAM、APB 外设、AXI3/AXI4（最高 512 bit）和 custom instruction；因此可以把它当作控制平面 CPU，让 CNN/tensor 数据通路留在当前手写 RTL 中。[Sapphire RV32 data sheet](https://www.efinixinc.com/docs-html/rv32-sapphire-ds/topics/riscv-saxon-efx-features-sapphire.html)

本地 IP 目录已经包含 `fpga\fpga_ti\soc.xml`、`top_soc.v`、`hbram_top.v`、`constraints_*.sdc` 和 Ti60F225 example generator，可用于检查生成接口。生成器的输入应由 IP Manager 产生，不要手改其输出；重新生成时让软件端 `soc.h`、链接脚本和硬件地址保持一致。官方地址映射文档也明确建议使用生成的符号定义，而不是在软件里硬编码地址。[Sapphire address map](https://www.efinixinc.com/docs-html/rv32-sapphire-ds/topics/riscv-address-map-sapphire.html)

## 5. 与当前 Case-1 RTL 的连接方式

### 5.1 推荐的控制/数据分工

```text
Soft Sapphire RV32
  ├─ APB master ──> c1_sapphire_apb_master_adapter ──> c1_r1_portable_soc APB slave
  │                  (控制寄存器/状态，含 PSTRB/地址宽度保护)
  ├─ IRQ <──────── c1_sapphire_irq_adapter <──────── c1_r1_portable_soc irq
  └─ 软件管理 DDR 中的 descriptor/framebuffer/tensor buffer

Case-1 fabric
  ├─ CNN/tensor/window cache（保持现有 RTL）
  ├─ AXI4-128 memory master ──> 板级 DDR controller/interconnect
  └─ camera/video 由板级 wrapper 接入
```

CPU 只负责寄存器、描述符、缓冲区和中断；不要让 CPU 参与每个像素的 MAC。当前 `c1_r1_portable_soc` 的 `m_axi_*` 是面向 DDR 的无 ID AXI4-128 数据主端口，不能在没有仲裁、数据宽度转换和时钟域处理的情况下直接“接到 CPU AXI”。若 Sapphire 的 AXI 与 accelerator/DDR 不同宽或不同频率，应在板级 wrapper 放 AXI interconnect/width converter/clock bridge，并明确谁拥有 DDR 的读写通道。

还要区分 Sapphire 的两类内存访问：生成的 `SYSTEM_DDR_BMB` 是 CPU 的外部内存
窗口，而 `SYSTEM_AXI_A_BMB`/用户 AXI master 是面向用户逻辑的 I/O 窗口；它们
不是同一组端口。若 CPU 需要填写 Case-1 的 descriptor/frame/tensor DDR 区域，
应让 CPU 的 DDR master 与 Case-1 的 AXI4-128 master 通过板级 DDR
interconnect/arbiter 共享控制器，并为缓存一致性制定规则（最简单的首版是关闭
该区域的 D-cache 或在启动/完成边界显式 flush/invalidate）。若 CPU 只运行在
OCR 而由外部 DMA/JTAG 填充 DDR，则必须把这个限制写入软件 ABI；不能假定 CPU
通过用户 AXI master 自动看到 Case-1 的 DDR。地址窗口和缓存/非缓存属性应始终
取本次生成的 `soc.h`，不要复制旧示例地址。[Sapphire address map](https://www.efinixinc.com/docs-html/rv32-sapphire-ds/topics/riscv-address-map-sapphire.html)

APB 连接也必须遵守时钟域边界：当前从设备在 `core_clk`，若 Sapphire 使用另一时钟，需要合法 APB bridge；不能把异步 APB 信号直接相连。`irq` 先接到 Sapphire 的一个外部中断输入，软件再通过 `soc.h` 的符号和 Case-1 头文件访问寄存器。

### 5.1.1 Soft Sapphire APB/IRQ adapter seam（已通过板前回归）

`rtl/vendor/c1_sapphire_apb_master_adapter.sv` 是生成 Soft Sapphire APB
端口与 Case-1 APB 从端之间的唯一连接点。Sapphire 生成的
`io_apbSlave_0_*` 命名从 CPU 视角看是 master-facing 输出；adapter 将其映射为
`c1_psel/penable/pwrite/paddr/pwdata`，并把 `c1_prdata/pready/pslverr` 返回
CPU。生成端没有 `PSTRB`，所以 `WRITE_PSTRB=4'hf` 时所有写事务都以完整
32-bit word 送入 `c1_pstrb`，读事务固定送 `4'h0`；这与当前 Case-1 软件 ABI
一致。未来若 BSP 发出 byte write，应只在该 seam 增加 byte-enable 合并规则，
不要修改 portable SoC CSR。

默认 `SAPPHIRE_ADDR_W=C1_ADDR_W=12` 时地址直接映射；若板级 BSP 使用更宽窗口，
adapter 只在高位全零时转发，非零高位访问本地以 `PREADY=1/PSLVERR=1` 完成，
并屏蔽 `c1_psel`，从而不会触发 Case-1 CSR side effect。
这里的直接映射假定生成 APB `PADDR` 与 Case-1 一样是**字节偏移**；拿到实际
IPXACT/`soc.h` 后必须确认地址单位。若某个版本把 PADDR 表示为 word index，
只在该 seam 增加左移/对齐转换，不要改动 Case-1 CSR 偏移 ABI。

`rtl/vendor/c1_sapphire_irq_adapter.sv` 将 Case-1 的单根**电平** IRQ 映射到
`sapphire_user_interrupt[7:0]` 中由 `USER_INTERRUPT_INDEX`（0..7，默认 0）
选择的一位。本设计的 `c1_apb_csr` 在软件清除 IRQ 状态前保持电平，因此应直接
接 Sapphire PLIC 用户中断输入，不需要 pulse stretcher；若 CPU 与
`core_clk` 不同，板级 wrapper 仍须提供合法 CDC。

板前 detached xsim 入口为：

```powershell
& .\scripts\run_sapphire_apb_adapter_xsim_detached.ps1
```

通过 marker：

```text
C1_SAPPHIRE_APB_ADAPTER_PASS writes=2 read=c1a00001 irq=00 upper_error=1
```

TB 验证了完整字写入、读回/读 strobe、宽地址错误隔离与恢复，以及 index=3 时
one-hot IRQ `8'h08`；runner 结束后只保留有界日志/status，
不保留 xsim 工作目录。该 gate 证明 seam 协议，不等于已生成板卡 BSP 或 Ti60
P&R。

### 5.2 不修改生成 IP 的原则

建议目录分层：

```text
case1/
  rtl/                 # 手写、板无关 RTL（当前主线）
  software/            # Case-1 驱动、描述符和测试程序
  efinity/<board>/     # IP Manager 生成的工程（拿到板卡后建立）
  generated/sapphire/  # 生成 IP/BSP 的只读快照或脚本输出
```

生成的 `settings.json`、`*_define.vh`、BSP 和 OpenOCD 文件不应直接编辑；需要修改核配置时回到 IP Manager 重新生成，并把参数记录在工程脚本中。

## 6. 无板卡阶段的可执行计划

### 阶段 A：现在即可完成

1. 保持 Vivado/xsim 的 `c1_r1_portable_soc` 回归作为板无关 golden reference。
2. 编译并单元测试 `software/include/c1_accel.h`、描述符打包、地址对齐、启动/完成/错误/IRQ 状态机；可用一个很小的 fake `soc.h` 做主机测试。
3. 在 Efinity IP Manager 生成一个**只含 Soft Sapphire + 片上 RAM + LED/APB loopback** 的 Ti60F225 example design；先跑 `map`，确认 IP、器件和工具版本无误，不接未知 DDR/相机引脚。
4. 导入 BSP 到 RISC-V IDE，生成 `.elf/.hex/.map`，在 QEMU 或 IP 自带 testbench 验证启动和 APB 访问。
5. 写一个板级 wrapper 草图，只声明 APB/IRQ/AXI/时钟边界，不填 pin 约束；把当前 accelerator 作为独立 RTL 模块接入仿真顶层。
6. 当前已完成 `run_sapphire_apb_adapter_xsim_detached.ps1` 的 vendor seam gate；拿到生成的 Sapphire 顶层后，只需把其 `io_apbSlave_0_*` 和 PLIC user-interrupt 端口替换到同一 adapter，不要绕过 PSTRB/地址保护层。

### 阶段 B：拿到板卡资料后

1. 从官方工程确认 Ti60 的 package、DDR/HBRAM 控制器、时钟、复位、UART/JTAG、相机和视频接口。
2. 用 IP Manager 重新生成与该板卡匹配的 Sapphire/DDR/PLL；将生成的 project XML 和 SDC 纳入 Efinity 工程。
3. 先做 memory test、color-bar、camera RAW10 pattern、CPU APB/IRQ，再接完整 accelerator；每一步都保留一个可启动 bitstream。
4. 用 `pnr`/`sta_tclsh` 检查真实时序，再测 30 帧 QoS、underflow、deadline 和 15 fps；只有此时才把 proxy 中的 100 MHz/14 ns 数字替换为板上真实时钟。

## 7. 目前明确的边界和风险

- 本地 Soft Sapphire 资源表是厂商参考值，不能替代 Case-1 在 2026.1、具体 Ti60 封装和最终约束下的实测；当前 CNN/tensor、AXI client、视频/相机 wrapper 的资源必须合并后再评估。
- Ti60 example 的旧 `soc.xml` 可帮助理解文件组织，但不能证明它与补丁后的 2026.1 IP 参数完全一致；应在 IP Manager 中重新生成。
- Efinity 的推荐设计实践要求一起生成 RISC-V block、soft logic、PLL、GPIO 和 pin assignment，并把未使用接口接到已知状态；因此最终板级工程不能只复制一个 CPU RTL 文件。[Recommended Sapphire design practice](https://www.efinixinc.com/docs-html/rv32-sapphire-hpb-ug/topics/riscv-recommended-design-practice-hpb.html)
- 当前阶段不运行大规模 Efinity P&R，也不把生成的 work/output 目录放入 Git；Efinity 输出目录应放在专用目录，仿真/综合结束后按阶段清理。

## 8. 下一步建议

下一步最有价值的无板工作是把已通过 synthetic-port gate 的 adapter 接到 IP Manager
实际生成的 Ti60F225 Soft Sapphire example：RISC-V IDE 编译最小程序，在生成的
testbench 中经 `c1_sapphire_apb_master_adapter` 写/读 Case-1 的
`ID/VERSION/CAPABILITY` 和一个无副作用控制寄存器，再经
`c1_sapphire_irq_adapter` 触发并清除 PLIC 中断。完成该闭环后，再把完整 AXI/DDR
数据通路接入；这样可以把“生成 BSP/CPU 端口问题”和“CNN/DDR 时序问题”分开定位。
