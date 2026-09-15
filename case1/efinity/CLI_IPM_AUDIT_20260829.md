# Efinity 2026.1 CLI/IP Manager audit

本机安装可独立脚本化完成 Efinity 的 RTL flow；IP Manager 的“参数选择/生成”没有独立的 documented batch 命令，但其 GUI 内部支持命令行参数和 gRPC backend。

## 可脚本化

```bat
D:\ELS\Efinity\2026.1\bin\efx_run.bat <project.xml> --prj -f map
D:\ELS\Efinity\2026.1\bin\efx_run.bat <project.xml> --prj -f pnr
D:\ELS\Efinity\2026.1\bin\efx_run.bat <project.xml> --prj -f full
```

`efx_run.py` 2026.1 支持 `map/interface/pnr/compile/program/rtlsim/mapsim/pnrsim/full`，并支持 `--output_dir`、`--work_dir`、`--timeout`、`--map_opts`、`--pnr_opts`、`--flist`、`--family`、`--device`、`--timing_model`。因此 RTL 编译、综合、PNR、STA、仿真、报告解析可放入 detached worker；当前 runner 的做法是合适的。

工程 XML 的关键 Ti60 参数为：`family=Titanium`、`device=Ti60F225`、`timing_model=C4`。官方示例还提供 `*.peri.xml`，包含 GPIO/clock/periphery assignment；它不能由只有 RTL+SDC 的代理工程自动推导。

IP Manager 生成结果以 `settings.json` 为输入，生成 `<module>.v/.vhd`、`<module>_tmpl.v`、`<module>.define`，并可生成 devkit example、testbench 和（2025.2+）OOC 文件。GUI 主程序本身接受：

```text
--project_path --settings_json --action {new,reconfigure,import,browse}
--device --family --project_name --peri_xml_file_path --project_xml
```

## 需要 GUI 或用户确认

- 首次选择 Sapphire RV32/Sapphire HPB SoC、DDR3 controller、PLL、MIPI/CSI2/HDMI、AXI/APB 等 IP 的参数，建议在 GUI IP Configuration Wizard 中完成；参数约束和 board example 选择由 GUI 驱动。
- 首次创建/修改 `settings.json`、选择 devkit example、确认 `peri.xml` 关联，建议 GUI 完成一次。
- GUI 生成一次后，可将 `settings.json`、生成 RTL、`*.define`、OOC 文件和 example XML 纳入版本控制；后续同参数重生成/升级理论上可由 IPM gRPC backend 调用，但该接口是内部实现，不宜作为稳定竞赛脚本接口。
- 下载 bitstream、FT4232/USB-JTAG、UART、DDR calibration、MIPI/HDMI 实物链路和板级 pin/peri 调试仍需要板卡/GUI 或命令行 programmer 配合；无板卡时只能验证 map/PNR/core timing。

## Ti60F225 资源边界

- 片上方向性总量约 60K LE、160 DSP、256 个 memory blocks（约 2.6 Mbit）；实际可用量需扣除 Sapphire、PLL、DDR/MIPI/HDMI periphery 和 routing margin。
- 已测 `c1_dot8x8_requant_core`：物理 DSP 80/160（50%），final core-only Fmax 189.7 MHz；不应再复制多个同类 core。
- DW 小 IO wrapper：物理 DSP 28/160（17.5%）；逻辑 DSP 与物理 DSP 可能因 Ti60 fracturable DSP packing 不一致。
- DDR3 板上为 MT41J128M16，256 MB、x16、最高 800 Mbps；三组 8 MiB tensor bank 与 framebuffer 应放外部 DDR，QSPI 8 MB 不能承载完整 tensor arena。
- 裸宽 tensor/weight 端口直接 PNR 会触发 `AutoPinIOResourceExhaustion`；必须使用真实 board wrapper/peri assignment 或小 IO core proxy。

结论：拿不到板卡前，父任务可以独立完成 RTL、golden、Icarus/xsim、Efinity map/PNR proxy、资源报告和软件镜像构建脚本；至少一次 IP Manager GUI 操作需要用户确认官方 SoC/DDR/PHY 参数并生成 board-specific artifacts。不要盲目把 IPM 私有 gRPC 当成长期稳定 CLI。

## channel16 wrapper map 崩溃分析

`c1_ti60_engine_channel16_wrapper` 的失败发生在 `efx_map.exe`/`libefx.dll`/`libvfc_database.dll`，没有 HDL 编译错误；同一 engine 的小尺寸和 fullweight（MAX_CHANNELS=8）探针可以 map，说明更像 Efinity 2026.1 前端对“第二个 C8 group”相关动态 memory 表达式的数据库缺陷，而不是算术 RTL 功能错误。

从 MAX_CHANNELS=8 到 16 同时变化的敏感点是 `MAX_GROUPS=1→2`、`DW_WEIGHT_DEPTH=9→18` 及 bias/multiplier/shift cache 深度；conv weight 深度变化并非必要因素（fullweight 已使用 72 tiles 并通过）。优先怀疑：`dw_weight_bank[dw_bank_gen*DW_WEIGHT_DEPTH + variable]`、`dw_group_tile_mem[cache_tile_tap*MAX_GROUPS + variable][variable part-select]`，以及 parameterized affine arrays 的 variable index。

最小兼容性修复顺序：

1. 在仿真宏之外屏蔽 `c1_s8_dot8_accum.sv` 的 `$error`（例如 `ifndef SYNTHESIS`）；它不是崩溃根因，但应消除 synthesis warning。
2. 对 probe 先把 `DW_WEIGHT_DEPTH` 和 affine cache extent 固定到架构最大值，用 `MAX_CHANNELS` guard 保持有效区间；若通过，再逐项恢复参数化，以定位触发点。
3. 将 `dw_group_tile_mem` 的“unpacked variable index + variable part-select”改成固定宽度 packed word，并用 sequential registered read/case mux；不要在同一个 `always_comb` 中深度索引和动态 part-select。
4. 若仍失败，将 lane/group memory 拆成 generate 产生的独立 bank module，每个 bank 使用同步单端口 RAM 模板；避免 Efinity 前端跨层推断参数化二维数组。

这些是 probe-level 最小改法；不要直接扩大生产 RTL 的所有 memory，因为可能改变资源和时序。channel16/fullchannel 的 map crash 已达到“停止盲试、做最小化二分探针”的条件。
