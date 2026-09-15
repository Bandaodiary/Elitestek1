# Sapphire/RISC-V 软件基线

2026-09-15：官方Lite S2的当前驱动构建入口见[c39_s2_probe](c39_s2_probe/README.md)。当前R2V2/R2H1/R2C2三个驱动的全部六API已用真实S2 BSP、`rv32im_zicsr_zifencei/ilp32`编译并无GC链接通过，未执行CPU/MMIO。旧`efinity_smoke`使用早期C1 ABI且默认`rv32imc`，不作为当前S2联合工程入口。

2026-09-14新增C31 [R2C2能力查询头文件](include/c1_r2_rgb2_camera.h)及[实现](src/c1_r2_rgb2_camera.c)，对应独立双像素主机的0x80/0xA8..0xBC只读页，明确49位记录/最多双像素/整帧除数，拒绝把旧R2C1标量FIFO单位当新单位。主机C测试通过256除数和9错误情况；不代表Sapphire BSP、PLIC/cache维护或实际CPU运行已完成。其他软件基线保留。

板前软件目标固定为单核 `RV32IMC` 裸机控制程序：不使用 Linux、MMU 或 FPU，CPU 不进入逐像素/逐 MAC 数据路径。最终在 Efinity 中建议选择最小 Sapphire 子系统，只保留启动存储、UART、I2C、GPIO、timer、PLIC、DDR 访问和 APB3 外设窗口。

## 软件职责

CPU 负责：

1. 通过 I2C 初始化 SC431，并配置曝光、增益、输出模式和 Bayer/ROI 相位；
2. 把 functional/final 模型的 `parameter_arena.bin`、`descriptors.bin` 和 3入2出 framebuffer table 写入 DDR；
3. 在 DDR 中保留 8 MiB 对齐、连续 24 MiB 的 tensor arena；
4. 用 `c1_accel_configure()` 写表地址、分辨率、stride、descriptor/weight/tensor base 和 display mode；
5. 开启中断并发出 START；
6. 在 done/error/capture-drop/display-underflow 中断中读取统计、abort/cleanup 后恢复；
7. 通过 UART 菜单切换风格、四种显示模式、OSD 与 ISP shadow 配置。

`include/c1_accel.h` 与 `src/c1_accel.c` 对应 `rtl/control/c1_apb_csr.sv`。它们不依赖 Sapphire BSP，可先在主机单元测试/APB BFM 中复用；拿到 Efinity 后再补基地址、启动代码、链接脚本、PLIC/I2C/UART 驱动和 cache 维护。

## START 快照与 tensor arena

`0x098 C1_REG_TENSOR_BASE` 保存三 bank tensor arena 起址：

```text
bank0 = base + 0 MiB
bank1 = base + 8 MiB
bank2 = base + 16 MiB
total = 24 MiB external DDR
```

它必须 8 MiB 对齐，且 `base + 24 MiB` 不能溢出当前 32-bit AXI 地址空间。24 MiB 是外部 DDR 保留区，不是 FPGA 片上 RAM。

软件应先完成所有 shadow 写，再调用返回 `bool` 的 `c1_accel_start()`。该 API 发现 STATUS busy 时返回 false；合法启动前先 W1C 清除旧 DONE/ERROR，再写 `CONTROL.START`。硬件在 START 接受时原子锁存 framebuffer table、width/height、format、descriptor base/count、weight base、tensor base 和运行策略；busy 时再次 START 返回 `PSLVERR` 且不产生副作用。任务期间修改 CSR 只影响下一次 START，不能改变已启动任务。

DONE/ERROR IRQ 是 foreground terminal 通知，不保证 abort、display flush、tensor response 或已提交 AXI transaction 已全部排空。ISR 可以先读取/记录 terminal，但在释放或复用本 job 的 framebuffer、descriptor、parameter、tensor arena 前，必须调用 `c1_accel_wait_idle(device, poll_limit)` 并确认返回 true，即 STATUS.BUSY 已为 0；超出 poll limit 返回 false，不能强行回收内存。

### 共享 AXI QoS 观测窗口

当 `c1_r1_portable_soc` 以 `ENABLE_SHARED_QOS_MONITOR=1` 编译时，QoS monitor 将共享 AXI 七客户端的计数器汇总到 APB live 只读窗口 `0x108..0x12c`。软件可用 `c1_accel_read_qos()` 一次读出状态、帧数、最近帧周期、deadline/underflow/protocol 事件、读写忙周期和读写 owner hold 最大值；`CONTROL[5]` 的 W1C 清除同时清除这些 QoS 累计值和旧版 processed-frame/busy 统计。monitor 未编译时，同一地址窗口稳定返回 0，避免固件探测产生未定义值。

| 地址 | 名称 | 说明 |
|---|---|---|
| `0x108` | `QOS_STATUS` | bit0=enabled，bit1=frame_active，bit2=counter overflow，bit3=出现 display underflow，bit4=出现 deadline miss，bit5=出现 AXI protocol error |
| `0x10c` | `QOS_FRAME_COUNT` | 已完成 QoS 观测窗口数 |
| `0x110` | `QOS_LAST_FRAME` | 最近一次窗口周期（core clocks） |
| `0x114` | `QOS_DEADLINE` | deadline miss 累计数 |
| `0x118` | `QOS_UNDERFLOW` | display underflow 累计数 |
| `0x11c` | `QOS_READ_BUSY` | 读通道 busy 周期累计 |
| `0x120` | `QOS_WRITE_BUSY` | 写通道 busy 周期累计 |
| `0x124` | `QOS_R_OWNER_MAX` | 读 owner hold 最大周期 |
| `0x128` | `QOS_W_OWNER_MAX` | 写 owner hold 最大周期 |
| `0x12c` | `QOS_PROTOCOL` | AXI 协议错误累计数 |

这里的“帧”边界是 `boardless_start` 到**带新帧标签的 display prefetch 完成**：它覆盖新 pair 的 AXI/FIFO/line-store 排空，而不是 VSYNC 可见性提交。`display_swap_event` 是独立的 pixel-domain ownership commit，当前架构允许它与后台 prefetch overlap；因此软件若要衡量可见延迟，应另行记录 swap/VSYNC，而不能把 `QOS_LAST_FRAME` 当作显示换帧时间。计数器是 live read-only 值，多寄存器读取期间可能继续变化；若需要严格原子快照，应在后续版本加入冻结/锁存命令。

当前 portable build 的 `SHARED_QOS_COUNTER_W` 默认是 24，故
`SHARED_QOS_DEADLINE_CYCLES` 送入 monitor 时有效宽度也是 24 bit；超过
16,777,215 个 core clocks 的 deadline 需提高 counter 参数并重新做资源/时序
评估，不能把 32-bit CSR 读回宽度误认为 32-bit 比较范围。

`c1_accel_configure()` 同样在 busy 时拒绝，并固定要求 640×480、22 descriptors。它检查 input table metadata、output table metadata、descriptor 区、16,896 B parameter arena 和 24 MiB tensor arena 五个区域合法且两两不重叠；具体三输入/双输出 frame payload 仍必须由分配器根据五个 table entry 另行验证，不能把 metadata 检查误当作 payload ownership 检查。

`c1_r1_portable_soc` 为 correctness-first 顺序 tensor baseline 将 watchdog 默认放宽到 1,000,000,000 clocks；这只是防止测试永久挂死，不是实时目标。优化版必须按实际 deadline 重设；100 MHz/15 fps 的帧预算只有 6,666,667 clocks。

板前性能基线现由 `../model/tensor_perf_model.py` 和 `../model/window_cache_perf_model.py` 固化：当前 descriptor/adapter 语义为 21,388,800 个 64-bit 请求、342,220,800 B/frame；理想化 packing/cache/outstanding 候选可降到 47,547,744 B/frame，3-row line/window 模型在 64×48 上把 145,152 个 3×3 tap 请求降为 19,584 个完整行 external words，但 64-MAC 纯算术下界仍为 6,691,200 cycle。`../rtl/dma/c1_tensor_mem_path_seam.sv` 的 legacy/performance 两分支 xsim run `7a447dba98be413d9e36c9f20bee443d` 与 proxy synth run `ca3e6b438d7e471bb39a083fc31746de` 已验证可插拔 ABI 和 `flush_done/quiescent`；seam/packer 仍未接入 SoC，软件不能据此提前把 watchdog 改成 15 fps 预算。

训练工件的 detached RTL ABI 回归已经验证 22 个 descriptor，并由真实 parameter scheduler 完成 1,030 个注册 128-bit arena reads/cache writes（逻辑 payload 16,379 B，arena image 16,896 B）；其 marker 明确为 `RTL_DECODER_SCHEDULER_ARENA_ONLY_NATIVE_640x480`，没有声称真实 engine 已完成 640×480 算术帧。七客户端 arbiter 的独立压力回归也已通过，但不替代 capture/display/tensor 长帧系统测试。

## ABI 与数据格式

`include/c1_descriptor.h` 与 `DESCRIPTOR_FORMAT.md` 固定 64-byte/16-word、22-stage descriptor ABI；Python 的 `golden/descriptor_format.py` 与 RTL package 使用同一 word 顺序。

当前 functional artifact 的 tensor offset/row-stride 字段为 0，原始语义是“专用 streaming stage 图不逐层落 DDR”。现有顺序 `c1_r1_microstyle_tensor_adapter` 为板前 correctness baseline，按照冻结的 22-stage 拓扑和三 bank schedule 推导物理 tensor 地址；它**没有**把这些零字段误当作真实 DDR 绝对地址。若未来改成通用可编程 tensor schedule，应升级 descriptor ABI/导出器并显式填写非零 offset/stride。

`include/c1_frame_buffer.h` 与 `FRAME_BUFFER_FORMAT.md` 固定 16-byte framebuffer entry：64-bit base、32-bit stride、16-bit width/height；输入表 3 项、输出表 2 项，每项一次 AXI128 读取。

framebuffer DMA 只接受 `C1_PIXEL_XRGB8888_DDR`：逻辑字 `0x00RRGGBB`，little-endian DDR 字节为 `BB GG RR 00`；stride 至少 `width×4` 且 16-byte 对齐。模块间 RGB24 stream 与 NHWC-C8 tensor 不是 DDR framebuffer 格式。

现有 AXI 地址宽度为 32 bit。软件接口虽然用 `uint64_t` 接受 table/descriptor/weight/tensor 地址以便 ABI 扩展，但配置函数会拒绝高 32 bit 非零；若最终 DDR 地址更宽，必须同时升级 CSR、DMA/adapter 和软件校验。

## ISP 与显示寄存器

`include/c1_isp_config_regs.h` 对应 `rtl/control/c1_apb_isp_config.sv` 的 `0x200..0x268`：先写 Bayer/ROI、四黑电平、AWB、CCM/offset shadow，再发 COMMIT；硬件在 ISP ready 时原子接收。Gamma 是 address/data/WRITE 单项队列，软件必须等待 busy 清零。

`DISPLAY_MODE` 定义为：

| 值/位 | 效果 |
|---|---|
| `0` | 风格图 640×480 居中 |
| `1` | 原图 640×480 居中 |
| `2` | 左原图、右风格图 640×480 分屏 |
| `3` | reserved/fail-black |
| bit 7 | 叠加十六进制状态/告警 OSD |

显示模式和 OSD 在 pixel-domain frame boundary 更新，避免帧中撕裂。

`continuous=false` 时每次 START 只允许接纳首帧，之后 capture frontend 静默清理 camera FIFO 到 EOF；`continuous=true` 时持续开放 admission。`drop_oldest` 只在没有 FREE input buffer 时决定是否回收最旧 `READY_NN`，不会覆盖 CAPTURING/PROCESSING/DISPLAY 所有权。

## 建议固件启动顺序

```text
clock/reset -> UART -> DDR memory test -> SC431 I2C
-> reserve/clear framebuffer and 24 MiB tensor arena
-> copy parameter_arena.bin/descriptors.bin -> configure ISP and APB CSR
-> enable IRQ -> camera stream on -> accelerator START
```

参数 loader 会将 16,896 B arena 装入 active/shadow bank；软件不要在任务运行中覆盖 active 参数来源或已分配 tensor/framebuffer 区。abort 后必须等 STATUS idle/cleanup 完成再复用对应 DDR 区。

## 主机测试与未完成项

在 `case1` 目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_software_host_test.ps1
```

当前输出为：

```text
C1_SOFTWARE_HOST_TEST_PASS registers=76 descriptor=64 framebuffer=16 isp=0x200..0x268 qos=0x108..0x12c
```

测试覆盖 probe、PSTRB 语义的寄存器镜像、64-bit 拆分、XRGB stride/格式、32-bit 地址上限、8 MiB 对齐/24 MiB tensor arena、五个配置区域的溢出/重叠、busy/尺寸/22层拒绝、START 前清旧 terminal、busy START 返回 false、`c1_accel_wait_idle()` 的成功/超时、abort、IRQ、display mode、descriptor/framebuffer C ABI 和 ISP 宏。runner 检查唯一 marker；当前仓库未保存独立 host status/stdout 日志。

尚未声称能直接生成 Sapphire 固件：BSP、启动/链接脚本、PLIC/I2C/UART、DDR cache/coherency、实际 APB base 和中断号必须由最终 Efinity 工程生成并在板上验证。
