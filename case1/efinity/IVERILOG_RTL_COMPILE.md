# Icarus 全 RTL 编译烟测

`case1/scripts/run_iverilog_rtl_compile.ps1` 用本机 Icarus Verilog 14（当前
安装根目录默认为 `D:\iverilog`）对 `case1/rtl` 下的全部 SystemVerilog 源码做
一次确定性的编译/顶层展开。它的用途是尽早发现包依赖、语法和顶层连接问题；
它不是帧级功能回归，也不替代 Vivado/xsim 的时序、AXI/QoS 或板卡验证。

## 运行

在仓库根目录执行：

```powershell
& .\case1\scripts\run_iverilog_rtl_compile.ps1
```

脚本使用 `-g2012 -s c1_r1_portable_soc`，不添加任何 `-D` 宏或 `-I` 包含目录。
四个 package 文件会先加入 response file，随后按完整路径排序加入其余 RTL：

1. `rtl/common/c1_fixed_pkg.sv`
2. `rtl/control/c1_descriptor_pkg.sv`
3. `rtl/control/c1_descriptor_decoder_pkg.sv`
4. `rtl/control/c1_frame_buffer_pkg.sv`

成功时输出 `C1_IVERILOG_RTL_COMPILE_PASS`，同时报告 source 数、退出码以及
`warning:`/`sorry:` 行数。当前基线为 127 个 `.sv` 源文件、退出码 0；常见提示是
Icarus 对 `always_*` 中 constant select 的兼容性提示，以及 `$fatal` 在
`always_ff` 中不可综合的提示。这些是仿真器告警，不等同于 Efinity 综合结论。

## 临时文件与边界

response file、诊断和 `.vvp` 都放在 `%TEMP%\c1_iverilog_rtl_compile_<guid>`，脚本
退出（包括失败）后自动删除，不会在 `case1/sim` 或 Efinity 工程目录留下大型
仿真树。确需保留编译产物时，显式指定一个受控目标：

```powershell
& .\case1\scripts\run_iverilog_rtl_compile.ps1 `
  -KeepVvp -VvpPath .\case1\outputs\local_only\c1_r1_portable_soc.vvp
```

## 能力边界

Icarus 可用于未加密、纯 Verilog/SystemVerilog 用户 RTL 的语法和轻量行为测试。
Efinity 生成的 Soft Sapphire 加密 RTL、器件原语、DDR/MIPI/HDMI IP 仍需 Efinity
提供的 simulator flow（或厂商支持的 Questa/ModelSim/Aldec）；本烟测不会尝试
展开这些 IP，也不会启动 Vivado、xsim、map、P&R 或板卡下载。
