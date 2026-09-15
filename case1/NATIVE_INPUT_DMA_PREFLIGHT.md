# Native 640×480 input-DMA/table/arbiter staged preflight

更新时间：2026-08-25。

本阶段把 native read-side 从“独立 reader”推进到真实共享边界：

```text
frame-table reader (master 0) ─┐
                               ├─ c1_axi2_serial_arbiter_128 ─ AXI128 DDR BFM
XRGB frame reader (master 1) ──┘
```

不实例化 CNN、tensor、display、CSI 或板卡 vendor IP。table lookup 在前一
个 slot 的 raster read 期间保持请求，验证 ID-less arbiter 在完整 R burst
期间锁定 owner，随后再切换到 table/下一 slot。

## 已通过运行

| 项目 | 值 |
|---|---|
| detached run | `c1_native_input_dma_full_20260825` |
| marker | `C1_R1_NATIVE_INPUT_DMA_PASS` |
| 帧数/尺寸 | 3 × 640×480 XRGB8888 |
| 像素回读 | `frame_pixels=921600`（每 slot 307,200） |
| table client | `AR/R=3/3` |
| frame-reader client | `AR/R=14400/230400`（每帧 4,800/76,800） |
| shared AXI | `AR/R=14403/230403` |
| backpressure | `ar_stalls=714`, `r_stalls=692267`, `r_gaps=34898`, `output_stalls=44623` |
| slots | `0x00100000 / 0x0022c000 / 0x00358000` |
| Vivado/xsim | xvlog/xelab/xsim exit 0，stderr 为空；结束后无残留进程 |

完整 marker：

```text
C1_R1_NATIVE_INPUT_DMA_PASS frames=3 frame_pixels=921600
table_ar=3 table_r=3 frame_ar=14400 frame_r=230400
shared_ar=14403 shared_r=230403 ar_stalls=714
r_stalls=692267 r_gaps=34898 output_stalls=44623
slots=00100000/0022c000/00358000
```

## 复现

```powershell
& .\scripts\run_r1_native_input_dma_xsim_detached.ps1 `
  -RunId c1_native_input_dma_full_20260825
```

只做 xvlog/xelab：

```powershell
& .\scripts\run_r1_native_input_dma_xsim_detached.ps1 `
  -RunId c1_native_input_dma_elab_fix2_20260825 -CompileOnly
```

runner 使用 `Win32_Process.Create` 创建 detached worker，日志和 status 位于
`logs/native_input_dma_runs/<run-id>/`。

## 覆盖范围

- 真实 `c1_axi_frame_buffer_table_reader`：每项 16 B，校验 base/stride/width/
  height 和高地址错误语义；
- 真实 `c1_axi_xrgb_frame_reader`：640×480 逐像素 RGB、坐标、SOF/EOL/EOF，
  16-byte 对齐、4 KiB/行边界、最多 16-beat burst；
- 真实 `c1_axi2_serial_arbiter_128`：table 与 frame 两个 read master 的
  transaction locking、owner 切换和 stalled AR/R payload 保持；
- deterministic DDR BFM：随机化式周期 AR stall、R gap、RREADY 反压和
  raster sink stall，且检查所有计数守恒和 slot 隔离。

## 明确边界

该专项只覆盖“两主机 read-side DMA + table ownership”边界。它没有验证
`c1_r1_boardless_frame_system` 的 job frontend、descriptor/config dispatcher、
compute shell、output writer，也没有接入 portable SoC 的七客户端 AXI fabric
（client 0…6）、CNN/tensor traffic、display QoS、trained artifact 或 15 fps。
下一阶段应把已通过的 input reader/table 与真实 output writer 和 boardless
job/frame ownership 组合，再放入七客户端 fabric 做 native 读写竞争、HOL/QoS、
abort/drain 和长帧 watchdog 测量。
