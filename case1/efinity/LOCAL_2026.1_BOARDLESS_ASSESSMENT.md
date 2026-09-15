# Ti60F225I3 / Efinity 2026.1 本机板前评估

检查日期：2026-08-29。本文只记录本机可复核的工具和源码边界，不代表已完成
Ti60 综合、布局布线或 bitstream 签核。

## 结论

- 本机存在 `D:\ELS\Efinity\2026.1`，可作为后续 Efinity 2026.1 CLI/GUI 根目录。
  当前仓库没有可直接打开的 Ti60 工程、官方 board wrapper、`.pin/.cst/.sdc` 或
  生成的 Sapphire/DDR/MIPI IP 输出，因此现在不能做可信的 full-top boardless
  `interface → map → pnr → sta/compile`。
- 可以做的 boardless 工作包括纯 RTL 小单元/Seam、Efinity map/PNR 叶级演练和
  厂商 IP Manager 的隔离生成演练；本轮已实测同步 EBR、64-MAC proxy、真实
  dot/requant 叶与小 IO DW wrapper。结果和限制见
  [`RESOURCE_MAP_RESULTS_20260829.md`](RESOURCE_MAP_RESULTS_20260829.md)。
  现有 Vivado proxy 报告仍只能作为结构参考，不能换算为 Ti60 LE、EBR 或 DSP
  利用率。
- 器件方向性预算来自 `TI60F225_BOARD_PROFILE.md`：约 60K LE、160 DSP、2.6 Mbit
  embedded memory；必须以 Ti60F225I3 的 Efinity map 报告为准。现有 full-top
  proxy 约 47.5K LUT、34.8K FF、32 BRAM tile、81–85 DSP，尚未包含 Sapphire、
  DDR、PLL、视频/高速 IP，不能据此判定可装入。

## IP/约束边界

- DDR3 `MT41J128M16JT-125` 为板级物理 x16、800 MT/s；Case-1 的 AXI128 只是用户
  侧接口假设。控制器/PHY、UI 时钟、校准/refresh、AXI 地址映射必须由 Efinity
  IP 或随板参考工程提供，不能用 RTL stub 替代。
- MIPI D-PHY/CSI-2（最高 4 lane、1.5 Gbps）属于 Efinity/板卡 IP 边界；当前
  `c1_camera_vendor_adapter_stub.sv` 仅是解包后的 ready/valid 语义，不含 PHY、
  lane 对齐、CRC 或传感器 I2C。
- PLL、HDMI PHY/TMDS、DDR reset/calibration 和 pin electrical constraints 同样
  属于板级工程；25/27/50 MHz 只能视为候选输入，不能猜测其 bank 或 PLL 归属。
- 现有 RTL 的 core/pixel/camera 时钟 CDC 与 AXI seam 可先做 boardless 验证；
  最终时钟、false-path/CDC 例外必须依官方 IP 生成约束落地。

## 推荐的最小可行验证顺序

1. 用 Efinity IP Manager 生成 Sapphire 单核 + APB + UART + 片上 RAM 的最小工程。
2. 在该官方工程内先做 Ti60 `interface/map`，确认器件资源和时钟约束入口。
3. 独立加入 DDR IP 短 burst memory test，再加入视频/MIPI IP，最后接 Case-1 小帧。
4. 每层把 `work/outflow` 放在临时目录；不提交生成数据库、波形或 bitstream。

当前判断：**隔离核心的 Ti60 map/PNR 已有可复核证据；完整 Case-1 Ti60
boardless compile/synthesis 仍未通过（engine/top 在 Efinity 前端崩溃），也不可
从隔离数字推出 DDR/MIPI/PLL/板级时序结论。**

本轮新增的细分边界也已确认：参数 scheduler map/PNR 通过（1/160 DSP、
236.855 MHz core-only final Fmax）；裸 descriptor decoder 的 map 通过但 PNR
因宽 IO 未分配而失败，和原始 DW core 的现象一致。二者都支持“先用官方
peri/pin wrapper 收敛接口，再评价板级 PNR”的工程顺序。
