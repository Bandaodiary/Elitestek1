# Native 640×480 boardless job preflight

更新时间：2026-08-25。

这是把 `c1_r1_boardless_frame_system` 从小尺寸集成回归推进到 native
640×480 的板卡无关的闭环。测试台没有实例化厂商 DDR/CSI/CNN IP，而是把
top 的全部外部接口接到可重复的 SystemVerilog BFM：

```text
software job command
      │
      ▼
c1_r1_boardless_frame_system
  ├─ table reader + descriptor preflight ──┐
  ├─ input XRGB DMA ───────────────────────┼─ ID-less AXI read BFM
  ├─ resize/centered-C8 ingress ──┐        │
  │                               │        └─ associative DDR model
  ├─ external CNN C8 echo ────────┘
  └─ centered-C8/RGB egress → output XRGB DMA ── AXI write BFM
```

## 通过证据

Detached runner：

```powershell
& .\scripts\run_r1_native_boardless_job_xsim_detached.ps1 `
  -RunId native_boardless_job_hold_full_20260825
```

展开检查：`native_boardless_job_hold_elab_20260825`，marker 为
`C1_R1_NATIVE_BOARDLESS_JOB_ELAB_PASS frame=640x480`。

全仿真检查：`native_boardless_job_hold_full_20260825`，xvlog/xelab/xsim exit 0，
三个 stderr 文件均为空，worker 结束后没有残留 Vivado/xsim 进程。完整
marker 如下：

```text
C1_R1_NATIVE_BOARDLESS_JOB_PASS frame=640x480 stages=22 cnn_in=307200 cnn_out=307200 table_ar=2 descriptor_ar=22 input_ar=4800 input_r=76800 output_aw=4800 output_w=76800 output_b=4800 ar_stalls=565 r_gaps=114547 aw_stalls=646 w_stalls=5211 b_delays=6489 stage_stalls=6 cnn_in_stalls=204951 cnn_out_stalls=80192 output_pixels=307200
```

关键检查项：

- 两张 frame table 各完成一次 AR/R，22 个 512-bit descriptor 完整转移，且
  第一个 CNN beat 只能在 `stage_dispatch_complete` 后握手；
- 输入 DMA 完成 `4,800` 个 AR、`76,800` 个 R beat，覆盖一帧 640×480 XRGB8888；
- 外部 CNN echo 完成 `307,200` 个 C8 输入/输出 beat，保留坐标以及 SOF/EOL/EOF；
- 输出 DMA 完成 `4,800/76,800/4,800` 个 AW/W/B，写回的 associative DDR
  逐像素检查通过，输出像素数为 `307,200`；
- AXI AR/AW/W、R gap、B delay、stage dispatch 和 CNN output backpressure
  均被实际覆盖，且终止时 AXI 已 drain。

地址布局采用与 native DMA 预检相同的非重叠 frame arena：

| 区域 | 地址 |
|---|---:|
| input table | `0x0008_0000` |
| output table | `0x0009_0000` |
| descriptor base | `0x000A_0000` |
| input frame | `0x0010_0000` |
| output frame | `0x0060_0000` |
| frame slot bytes | `0x0012_C000` |

测试输入使用固定 XRGB 像素 `0x00_21_83_D7`。固定图案用于把验证重点放在
DMA/resize/C8/写回的完整覆盖；并不替代后续 Python golden 图像集上的画质
验证。

## BFM 时序边界

AXI slave 的 `ARREADY/AWREADY/WREADY` 只在 `negedge clk` 更新，使其在后续
上升沿保持稳定。这个 opposite-edge shell 仅用于 Vivado xsim 的
同一-delta 竞态隔离，等价于仿真中的 vendor-facing registered shell；它不
增加待综合数据通路，也不放宽 RTL 的 ready/valid 协议。R/B response 仍由
正常时钟边沿产生，并按 ID-less、单 outstanding burst 规则返回。

runner 使用 `Win32_Process.Create` 启动隐藏 worker；因此 Vivado/xsim 不绑定
当前 Codex Windows Job。每次运行的 stdout/stderr 与 `status.json` 位于：

```text
case1/logs/native_boardless_job_runs/<run-id>/
```

## 边界与下一步

本预检已经证明：native frame-table、22-stage descriptor barrier、真实
input/output DMA、resize/centered-C8 两侧以及外部 CNN ready/valid seam 可以
在无板条件下组成一帧闭环。它仍然没有接入真实 CNN 运算、CSI/MIPI RAW10、
Efinity DDR IP、七客户 QoS 长时间竞争或板卡时钟/复位/引脚约束。拿到板卡后
应优先替换 AXI BFM 为 Efinity DDR wrapper，并保持本 TB 的地址、burst、marker
和 drain 断言作为硬件 bring-up 对照；随后再把真实 CNN traffic 和多客户共享
fabric 加回去测量 15 fps 的吞吐与 HOL/abort 行为。

## 2026-08-29 native 重跑记录

在受管桌面上重跑时，WMI 创建 worker 被拒绝；runner 已改为自动调用
`start_detached_process.ps1` 的 `CREATE_BREAKAWAY_FROM_JOB` fallback。新的
640×480 full run `76927b77e5b14cc998e43951d162bae8` 通过，当前 marker 为：

```text
C1_R1_NATIVE_BOARDLESS_JOB_PASS frame=640x480 stages=22 cnn_in=307200 cnn_out=307200 table_ar=2 descriptor_ar=22 input_ar=4800 input_r=76800 output_aw=4800 output_w=76800 output_b=4800 ar_stalls=517 r_gaps=115167 aw_stalls=697 w_stalls=5216 b_delays=6691 stage_stalls=3 cnn_in_stalls=224913 cnn_out_stalls=80451 output_pixels=307200
```

`xvlog/xelab/xsim` 均退出 0，stderr 为空；worker 完成后删除了
`sim/native_boardless_job_run_<run-id>`。另以 `-CompileOnly` 完成了完整
`c1_r1_portable_soc` 640×480 的 `xvlog+xelab` 展开（run
`09850789d6ba4d2180fa5831cf6f26dc`），但没有启动无界的真实 portable-SoC
长帧数据面。上述 gate 仍不覆盖训练 CNN、DDR3 IP、QoS 长时间竞争和 15 fps。
