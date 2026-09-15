# Case-1 的 Efinity staging 区

这里仅保存板级工程的说明、参数记录和小型脚本；不要把 Efinity 的
`work/`、`outflow/`、P&R 数据库、波形或 bitstream 临时目录提交到本目录。
拿到确切的易灵思板卡型号、器件封装、DDR 类型、时钟和 pin 表后，再在这里
建立由 IP Manager 生成的工程，例如：

```text
case1/efinity/<board_project>/
  <project>.xml
  ip/                         # IP Manager 生成的 RTL
  embedded_sw/<sapphire>/    # BSP、soc.h、linker、OpenOCD 配置
  <board>_devkit/             # 可选 example design/testbench
```

当前目标板的可核验事实和 DDR/时钟预算见
[`TI60F225_BOARD_PROFILE.md`](TI60F225_BOARD_PROFILE.md)。截图确认的是
Ti60F225I3、DDR3 x16/800 Mbps、MIPI/HDMI 等板级能力；revision、pin map、DDR
controller/UI 时钟仍须由官方工程确认。

当进入一次性 IP Manager 操作时，按
[`GUI_IPM_HANDOFF.md`](GUI_IPM_HANDOFF.md) 收集生成物；该清单同时列出哪些
目录不应复制，以避免把 Efinity work/outflow 或仿真波形带入工程。

## 2026-08-29 隔离 map/PNR 结果

本机 Efinity 2026.1 已对同步 EBR 模板、64-MAC 资源代理、真实 dot/requant
叶、参数 scheduler 和小 IO DW wrapper 完成板卡无关 map/PNR。dot 叶占用 80/160 个物理 DSP
 （50%），DW wrapper 占用 28/160（17.5%），两者的 core-only final timing
 均通过 100 MHz；完整 `c1_r1_microstyle_engine`/CNN top 则在当前 Efinity
 前端触发 `libefx.dll` 访问违例，暂没有可信的 full-top 资源数字。详见
[`RESOURCE_MAP_RESULTS_20260829.md`](RESOURCE_MAP_RESULTS_20260829.md)。

默认 unpacked affine 尺寸阈值探针中，C8/full-weight 小 wrapper 可 map，
`MAX_CHANNELS=16/24/48` 及更大参数化数组会复现同一前端访问违例；单独将
`MAX_GROUPS_OVERRIDE=2` 的诊断 wrapper 可 map，说明 group 数本身不是充分条件。
可选 `PACKED_AFFINE_CACHE=1` 的 channel16/fullchannel wrapper 已 map+PNR
通过（final 396.040/321.027 MHz），但尚未替换生产默认参数，仍属于工具兼容性
候选，不是资源超限或 full-top sign-off。进一步的
`c1_ti60_cnn_top_packed_wrapper` 已保留 22-stage dispatcher/descriptor-cache 并
map+PNR 通过（final 435.540 MHz）；它仍是窄 stimulus 壳，资源计数不能外推到
板级。随后 `run_iverilog_stage1_handoff.ps1 -FullStage21 -PackedAffine` 与
detached xsim 同参数的 stage21/trained-artifact A/B 均 PASS（
`operands=896/results=836/final=64/stage_done=22/abort=0`）；packed 仍为可选
候选，默认 `PACKED_AFFINE_CACHE=0`，full-board sign-off 仍 OPEN。IP Manager 的
稳定 CLI 边界和首次 GUI 生成要求见
 [`CLI_IPM_AUDIT_20260829.md`](CLI_IPM_AUDIT_20260829.md)。

新增的 `c1_ti60_portable_soc_packed_wrapper` 将完整
`c1_r1_portable_soc`（8×8、小帧窄壳）也纳入 packed-affine map 探针。Efinity
map 在 180 s 内未发生已知 `libefx.dll` 访问违例，但完整层级未能在该上限内
完成，未执行 PNR、也没有资源数字；status/failure tail 见
`logs/efinity_resource_runs/2473d08f8fe948df8d0056aeef857761/`。该 wrapper
仅供前端复杂度/兼容性诊断，不是生产 top。

这些是隔离核心结果，不是整板 sign-off：DDR3/MIPI/HDMI/PLL、Sapphire、pin
和 peri 约束仍需由 IP Manager 生成的官方工程接入。所有大 work/outflow
仍放在 `%TEMP%` 并自动清理，仓库只保留小型 `status.json`/`summary.json`/尾日志。

## 推荐的生成顺序

1. 在 Efinity GUI 的 IP Catalog 中选择 **Sapphire RV32 / efx_soc**，先生成
   一个最小控制面实例：单核、UART0、一个 APB user slave、片上 RAM；第一轮
   可关闭 DDR/cache/AXI master，便于验证 CPU→APB→Case-1 CSR→IRQ。
2. Deliverables 同时勾选 embedded software、example design 和 testbench。
   不要手工拼接 `KEY=VALUE` 参数；IP Manager 会解析 `ip_component.xml` 的
   默认值和依赖关系，再调用安装目录中的 generator 与 `sw_script.py`。
3. 把生成的 `embedded_sw/<sapphire>` 导入 RISC-V IDE，先编译 UART/LED 或
   APB 读写小程序，再替换为 Case-1 驱动。软件必须使用这次生成的 `soc.h`、
   startup、linker 和 `-march/-mabi`，不能继续使用 smoke 工程的占位地址。
4. 在生成的 testbench 中跑 CPU 启动和 APB 回归；再把
   `rtl/vendor/c1_sapphire_apb_master_adapter.sv` 与
   `rtl/vendor/c1_sapphire_irq_adapter.sv` 接入同一边界。
5. 只有板卡 wrapper、DDR/时钟/引脚齐全后，才运行 Efinity `interface` →
   `map` → `pnr`/`sta_tclsh` → `compile`。`compile` 默认包含综合、P&R 和
   bitstream，不能在板卡信息不全时误运行。

## 本机生成入口（仅记录，不在当前阶段直接生成）

Efinity 2026.1 的 Python 环境要求先设置 `PYTHONHOME`；直接从 PowerShell
调用 bundled `python.exe` 而没有该变量会报 `No module named encodings`。
如果确实需要脚本化生成，应在一次性子进程中设置环境，并由 IP Manager
提供完整参数集：

```powershell
$ef = 'D:\ELS\Efinity\2026.1'
$env:PYTHONHOME = "$ef\python311"
$env:PATH = "$ef\python311\bin;$ef\bin;$ef\scripts;" + $env:PATH
& "$ef\python311\bin\python.exe" `
  "$ef\ipm\ip\efx_soc\efx_soc\generator\soc_gen.py" --help
& "$ef\python311\bin\python.exe" `
  "$ef\ipm\ip\efx_soc\efx_soc\embedded_sw\sw_script.py" --help
```

两个入口的帮助已在本机通过；真正生成时不要只传几个自选参数，因为生成器
会直接索引一整套由 IPXACT 解析出的参数（地址、DDR、缓存、调试、外设等）。
建议优先使用 GUI IP Manager，输出放在专用目录，并在每次 map/P&R 后清理
临时 work/output。

特别注意：`sw_script.py` 会复制整套 BSP/standalone/FreeRTOS 示例并按参数改写
linker、OpenOCD 和调试文件；它还会清理生成 IP 输出中的中间软件目录。不要对
安装目录或唯一的 IP 输出目录直接重跑。若将来必须自动化，应先把 IP Manager
输出复制到一个可删除的 staging 目录，再调用该脚本，并只把所需的 `bsp`、
`soc.h`、linker、OpenOCD 配置和应用源码纳入 Case-1 工程。

## IDE 启动

使用隔离 workspace 的脚本：

```powershell
& .\case1\scripts\launch_efinity_riscv_ide.ps1
```

它只启动 GUI，不调用 `efinity-riscv-idec.exe`（后者不是无副作用的 help/CLI
工具），也不会启动 Vivado、xsim 或 OpenOCD。需要命令行工具链检查时使用：

```powershell
& .\case1\scripts\verify_efinity_toolchain.ps1 -BuildSmoke
```

## Icarus/GTKWave 互操作（按需启用）

本机已安装 `D:\iverilog\bin` 下的 Icarus 14.0 (devel) 和 GTKWave 3.3.128。
板前只需运行：

```powershell
& .\case1\scripts\run_iverilog_smoke.ps1
& .\case1\scripts\run_iverilog_smoke.ps1 -TrySapphireAdapter
```

脚本只编译一个很小的 Verilog-2005 smoke，并可选择验证现有 APB/IRQ seam；所有
工作文件位于 `%TEMP%`，默认自动删除。它不改写 Efinity 生成目录，也不启动
Vivado/xsim。Icarus 14 本身可以直接编译部分 SystemVerilog（本脚本的 seam
smoke 已验证），但 Efinity 通用 `efx_run_sim.py` 在发现 `.sv`/VHDL 时会在调用
编译器前拒绝该 flow，因此 `efx_run --flow rtlsim/mapsim` 的备用后端仍限定为
未加密、纯 Verilog 用户逻辑；Soft Sapphire 加密 RTL 仍需 ModelSim/Questa/Aldec，
不能用 Icarus 直接仿真。Efinity 通用 flow 若要试跑，必须把
`work_sim`/`outflow` 放到本目录之外的 disposable 工程，并在结束后删除。
