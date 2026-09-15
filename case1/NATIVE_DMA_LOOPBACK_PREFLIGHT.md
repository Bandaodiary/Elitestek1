# Native 640×480 read→write DMA loopback preflight

更新时间：2026-08-25。

本阶段把 native 尺寸的两个方向闭合成一条可回读的板卡无关数据路径：真实
frame-table reader 和 XRGB frame reader 从三个输入 slot 读出像素，经过真实
两主机 read arbiter 后，XRGB writer 再经写通道 skid bridge 和同一类型的
serial arbiter 写入三个独立 output slot。测试台最后从 associative DDR BFM
逐像素读回并比较坐标/帧标记，形成“读→流→写→回读”的闭环。

```text
frame-table reader ─┐
                    ├─ c1_axi2_serial_arbiter_128 (read) ─┐
XRGB frame reader ──┘                                      │
                                                           ├─ XRGB writer
                                                           │    │
                                                           │    └─ c1_axi_write_skid_bridge
                                                           │         │
                                                           └─ c1_axi2_serial_arbiter_128 (write)
                                                                │
                                                            DDR BFM
```

测试台的输入/输出地址严格分离：

| 区域 | slot 0 | slot 1 | slot 2 | 单 slot 大小 |
|---|---:|---:|---:|---:|
| 输入 XRGB8888 | `0x00100000` | `0x0022c000` | `0x00358000` | `0x12c000` |
| 输出 XRGB8888 | `0x00600000` | `0x0072c000` | `0x00858000` | `0x12c000` |

## 已通过运行

| 项目 | 值 |
|---|---|
| detached run | `c1_native_dma_loopback_final2_20260825` |
| marker | `C1_R1_NATIVE_DMA_LOOPBACK_PASS` |
| 帧数/尺寸 | 3 × 640×480 XRGB8888 |
| 闭环像素 | `frames=3`, `frame_pixels=921600` |
| table read | `table_ar=3`, `table_r=3` |
| input read | `input_ar=14400`, `input_r=230400` |
| output write | `output_aw=14400`, `output_w=230400`, `output_b=14400` |
| read-side backpressure | `read_ar_stalls=625`, `read_r_stalls=1233856`, `read_gaps=29256` |
| stream backpressure | `stream_stalls=585856` |
| write-side backpressure | `aw_stalls=1055`, `w_stalls=67961`, `b_delays=57240` |
| input slots | `0x00100000 / 0x0022c000 / 0x00358000` |
| output slots | `0x00600000 / 0x0072c000 / 0x00858000` |
| Vivado/xsim | xvlog/xelab/xsim exit 0，stderr 为空；结束后无残留进程 |

完整 marker：

```text
C1_R1_NATIVE_DMA_LOOPBACK_PASS frames=3 frame_pixels=921600
table_ar=3 table_r=3 input_ar=14400 input_r=230400
output_aw=14400 output_w=230400 output_b=14400
read_ar_stalls=625 read_r_stalls=1233856 read_gaps=29256
stream_stalls=585856 aw_stalls=1055 w_stalls=67961 b_delays=57240
input_slots=00100000/0022c000/00358000
output_slots=00600000/0072c000/00858000
```

## 复现

```powershell
& .\scripts\run_r1_native_dma_loopback_xsim_detached.ps1 `
  -RunId c1_native_dma_loopback_final2_20260825
```

只做 xvlog/xelab：

```powershell
& .\scripts\run_r1_native_dma_loopback_xsim_detached.ps1 `
  -RunId c1_native_dma_loopback_shell_elab3_20260825 -CompileOnly
```

runner 通过 `Win32_Process.Create` 创建 detached worker；每个 run 的日志和
`status.json` 位于 `logs/native_dma_loopback_runs/<run-id>/`，不会把
Vivado/xsim 绑定到当前 Codex shell 的 Windows Job。

## 这次实现的 RTL 要点

- 新增 `c1_axi_write_skid_bridge`：单项 AW/W/B 缓冲，只有 AW 已提交后才接收
  W，B 在上游 READY 前保持，隔离 writer 与串行仲裁器的 READY/VALID 状态边界；
- `c1_axi2_serial_arbiter_128` 写状态机把 AW、每个 W（含 WLAST）和 B 的下游
  握手先登记、下一拍再转移状态，避免组合 master/arbiter 边界在同一仿真 delta
  内丢失握手；独立 arbiter regression 仍通过；
- loopback TB 在 BFM/连接边界使用反相时钟采样的注册化 READY/VALID shell，
  仅用于消除 xsim 同一 delta 的 testbench 竞态，不是待综合的数据通路，也不
  改变板上模块的 AXI 协议要求；
- DDR BFM 按完整 128-bit line 地址建立 associative store，并对输入/输出 slot
  做非重叠和逐像素坐标/marker 检查；AR/AW、R/W/B 的停顿均独立随机化。

## 覆盖范围与边界

该专项证明 native 640×480 的 frame-table、read DMA、stream backpressure、
write DMA、AXI serial arbitration 和 slot 隔离可以在无板条件下组成闭环。它
没有接入 `c1_r1_portable_soc` 的 boardless job/descriptor dispatcher、七客户
端共享 fabric、真实 CNN/tensor traffic、display prefetch、CSI/MIPI、Efinity
DDR IP 或 15 fps QoS；因此它是 native DMA 集成门，不是完整赛题一端到端性能
结论。下一步应把此闭环接回 boardless frame job，再以七客户端 fabric 运行
capture、input/output DMA、tensor/CNN 与 display 的长帧竞争，测量 HOL、QoS、
abort/drain 和 watchdog。
