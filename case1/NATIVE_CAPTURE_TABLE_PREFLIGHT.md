# Native 640×480 capture/table staged preflight

更新时间：2026-08-25。

这是 native 长帧系统化前置验证的第三个分阶段边界：直接实例化真实
`c1_r1_capture_subsystem`，不实例化 portable SoC、CNN、共享 AXI 仲裁器或
板卡 IP。测试把 642×482 RAW10 camera ingress 送入 R1 ISP，经过 frame-table
descriptor lookup 后启动真实 XRGB8888 writer，并用独立 AXI BFMs 检查三块
input slot 的地址和握手。

## 已通过运行

| 项目 | 值 |
|---|---|
| detached run | `c1_native_capture_table_paced_full_20260825` |
| marker | `C1_R1_NATIVE_CAPTURE_TABLE_PASS` |
| 输入/输出 | 642×482 RAW10 → 640×480 RGB/XRGB |
| 帧数 | 3 |
| RGB stream | `pixels=921600`, `sof=3`, `eol=1440`, `eof=3` |
| Gamma LUT | 1024 次 ready/valid 写入，identity `min(255,(i+2)>>2)` |
| frame table | `AR/R=3/3`，每项 16 B，含 base/stride/width/height |
| writer AXI | `AW/W/B=14400/230400/14400` |
| 回压 | table AR/R、writer AW/W/B 均有非零 stall/delay |
| slots | `0x00100000 / 0x0022c000 / 0x00358000` |
| Vivado/xsim | xvlog/xelab/xsim exit 0，三阶段 stderr 为空；结束后无残留进程 |

完整 marker（来自 `xsim.stdout.log`）：

```text
C1_R1_NATIVE_CAPTURE_TABLE_PASS frames=3 sensor=642x482 output=640x480
pixels=921600 sof=3 eol=1440 eof=3 gamma=1024 table_ar=3 table_r=3
aw=14400 w=230400 b=14400 table_ar_stalls=1 table_r_delays=5
aw_stalls=847 w_stalls=18835 b_delays=28787
slots=00100000/0022c000/00358000
```

## 复现

```powershell
& .\scripts\run_r1_native_capture_table_xsim_detached.ps1 `
  -RunId c1_native_capture_table_paced_full_20260825
```

只做 xvlog/xelab：

```powershell
& .\scripts\run_r1_native_capture_table_xsim_detached.ps1 `
  -RunId c1_native_capture_table_elab_paced_20260825 -CompileOnly
```

runner 用 `Win32_Process.Create` 建立 detached worker；Vivado/xsim 不附着在
当前 Codex Windows job。日志和 status 位于
`logs/native_capture_table_runs/<run-id>/`。

## 覆盖和边界

- 覆盖 camera-domain RAW10 FIFO、SOF/EOL/EOF、R1 ISP、可配置 Gamma、frame
  table 读回、XRGB writer，以及三帧 slot ownership/address isolation。
- BFM 检查 table AR 的 16-byte 对齐和 descriptor index、writer 的 16-byte
  对齐、4 KiB/行边界、AW/W/B 顺序、非零 AXI 回压和无 X WDATA。
- camera BFM 在 `camera_ready` 为低时插入 blanking；当前 frontend 把
  `camera_valid && !camera_ready` 定义为不可恢复 sensor overflow，因此这
  不是“标准 ready/valid 可任意保持”的性能测试。
- 这一步仍不包含 CSI/MIPI packet/CRC、真实 sensor PLL、portable SoC 的
  input frame reader、七客户端共享仲裁、CNN/tensor traffic、display QoS、
  trained artifact 数值对比、Efinity 综合或实体板调试。

## 失败基线

`c1_native_capture_table_full_20260825` 在未配置 Gamma LUT 且 camera valid
持续保持时失败：首帧中途触发 capture overflow/X 数据。该 run 被保留为
诊断证据，不计入 PASS 矩阵；修订后的测试先写入 Gamma，再按 sensor
blanking 发送，才形成上面的通过结果。

下一步是把已通过的 capture/table/writer 边界接回 portable SoC 的 input DMA
和七客户端 AXI fabric，再做 native 单帧/双帧 ownership、display underflow
和 QoS/带宽统计；在此之前不宣称 640×480 CNN 实时性能。
