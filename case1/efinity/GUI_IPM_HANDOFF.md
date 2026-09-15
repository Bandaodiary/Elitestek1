# Case-1：一次性 Efinity IP Manager 交接清单

## 当前结论

截至 2026-08-29，RTL、golden、Icarus/XSIM、detached worker、Efinity
map/PNR 探针和 RISC-V 工具链 smoke 均可以在没有板卡、没有 GUI 的情况下独立
推进。下一道真正的板级边界不是 Verilog 编码，而是由 Efinity IP Manager
根据 Ti60F225I3 的官方 board/peri/pin 数据生成 Sapphire、时钟和 DDR3
接口。该步骤建议用户在 GUI 中做一次；生成物交回后，后续整板集成、仿真、
map、PNR、报告解析仍由脚本完成。

## GUI 中只需完成的一次性操作

1. 新建 Titanium 工程，器件选择 **Ti60F225**，封装/速度等级确认是
   **Ti60F225I3**（若 GUI 的 device 字段只显示 Ti60F225，保留 package/grade
   信息在工程属性中）。
2. 在 IP Catalog 中先生成一个最小 **Sapphire RV32** 控制面：单核、裸机
   RV32IMC（不启用 Linux/MMU/FPU），UART0、GPIO、timer/PLIC、片上 RAM，
   以及一个 APB user slave。建议先关闭 DDR/cache 生成控制面基线，再复制一份
   打开 cache/DDR 的候选配置，避免首轮同时引入太多变量。
3. APB user slave 预留一个 64 KiB 窗口；Case-1 本地寄存器仍按
   `0x000..0x2ff`（其中 ISP 为 `0x200..0x2ff`）解释。生成后不手工改写
   Sapphire 的地址对齐结果，以 `soc.h`/生成 XML 为准。
4. 对第二份候选配置启用外部内存 AXI；DDR3 controller 选择板上
   **MT41J128M16JT-125，x16，800 Mbps** 的官方器件/开发板模板。不要把
   三个 8 MiB tensor bank 或 framebuffer 放入 QSPI；它们应位于 DDR 地址区。
5. 生成所需时钟/PLL、reset、periphery assignment 和 pin assignment。先只
   保留 25/27/50 MHz 板载时钟、UART/LED/按键和 DDR3；MIPI/HDMI 可在控制面和
   DDR 冒烟通过后再加入，减少首次 PNR 的变量。
6. 生成时同时勾选 embedded software、example design 和 testbench（如果该
   IP 页面提供这些选项）。

## 请交回的最小文件集合

把 GUI 生成目录的**小型源文件**复制到
`case1/efinity/ti60_ipm_generated/`（不要复制 work/outflow/cache/波形）：

```text
<project>.xml                 # Efinity project XML
<project>.peri.xml             # peri/pin/clock/IO assignment
*.sdc                          # 生成的时钟约束
ip/<sapphire instance>/        # Sapphire RTL、*.define、wrapper
ip/<ddr instance>/             # DDR3 controller RTL/define（若启用）
embedded_sw/<sapphire>/        # soc.h、linker、startup、BSP/OpenOCD
<project>_devkit/              # 可选 example top/testbench
```

只需要文件本身或压缩包；无需上传大于几 MB 的 `work_*`、`outflow`、
`*.wlf`、`*.vcd`、`*.rpt` 数据库。若不确定哪些文件属于生成物，先把目录树和
文件名发来，我会筛选。

## 交回后由脚本自动完成

收到上述文件后，下一轮流程固定为：

```text
生成物结构检查 → Sapphire/APB seam 仿真
→ CPU UART/LED/APB 小程序编译
→ DDR BFM/缓存/Case-1 AXI 接口仿真
→ Efinity interface → map → pnr → STA/资源解析
→ 仅保留摘要和失败尾日志，自动清理临时目录
```

默认 RTL 继续使用 `PACKED_AFFINE_CACHE=0`；若完整 Ti60 前端仍触发已知的
Efinity 参数化 memory 访问违例，会在板级 wrapper 中显式选择
`PACKED_AFFINE_CACHE=1`，并用已通过的 channel16/fullchannel/CNN-top 探针做
回归。不会因为探针通过就宣称整板资源 sign-off。

## 仍然需要真实板卡的步骤

FTDI/JTAG 下载、UART 实测、DDR3 calibration/读写裕量、MIPI sensor 链路、
HDMI 时序和最终 15 fps 帧率只能在板卡上完成；这些不是当前 boardless
RTL 阶段的阻塞项。
