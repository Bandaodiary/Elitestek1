# 128-bit burst 写多 outstanding seam

更新时间：2026-09-12。

## 当前接入进展

`c1_r1_portable_soc.TENSOR_WRITE_OUTSTANDING`现支持1/2/4，默认1。packed column
分支经`c1_tensor_mem_axi128_packing_bridge`选择新的
`c1_tensor_mem_axi128_ordered_write_client`（2/4槽），复用下述burst-level seam。
新前端自行确定动态批次长度，不要求软件预先声明每个descriptor；保持原C8请求/响应
ABI、重复地址物理写顺序、对齐/4 KiB边界和取消排空，不用多个无序packer直接拼接。

本轮还确认旧MLP只有AW提前，W仍与B共用head。新增默认关闭`PIPELINE_WRITE_DATA`，
让W在WLAST后独立前进；新前端开启此模式。payload仍到B退休才允许复用，本地错误
须由W游标跳过；物理outstanding改为真实AW/B计数，排除本地poison和孤立B。
三种slot数量2/3/4的独立测试均验证全部AW/W可在第一笔B返回前完成；SoC额外32拍B
压力模型中，四槽实际峰值4，64×48由827,478降至539,759拍（-34.77%）。相同queued
fabric默认延迟下则513,059→513,605（+0.11%），故默认1保持不变。原生15 fps及目标
资源/Fmax未验证，压力延迟不是板卡测量值。完整证据见`DEVELOPMENT_LOG.md`最新一节。

以下为原始seam设计及历史代理综合说明，不是本轮新架构的资源测量。

`c1_tensor_mem_axi128_write_burst_client` 仍然以逻辑 64-bit 请求为输入，且
一个 leaf 只允许一个 AW/W/B descriptor 在途。直接把它的参数
`MAX_OUTSTANDING` 改大并不能成立：每个 burst 的 payload、BRESP 和逻辑响应
都必须有独立的存储与退休顺序。为把问题从逻辑 packer 中隔离出来，新增
`rtl/dma/c1_axi128_write_mlp.sv` 作为 burst-level seam。

## 接口和行为

- `cmd_valid/cmd_ready` 接受对齐的起始地址和 `1..MAX_BEATS` 的 burst 长度；
  每个 command 随后由 `payload_valid/payload_last` 送入 128-bit beat 和 16-bit
  strobe。
- 每个 descriptor 的 payload 保存在有限 ring slot 中。payload 完成后，AW
  scheduler 可以继续发布后续 descriptor；W channel 仍严格按 descriptor 顺序
  发送，B 也只按 head descriptor 退休，因此不依赖 AXI ID。
- `MAX_OUTSTANDING=4` 时最多保留四个 descriptor，响应端返回 descriptor-level
  tag/address/length/error。早/晚 `payload_last`、`payload_flush`、孤立 B、W
  先于完成的 B 都有 sticky 诊断，不会发出非法 AW。
- 默认 payload 存储量为 `4×16×(128+16)` bit，约 1.1 KiB 加少量 metadata；
  proxy 综合显示 Vivado 将其映射为 LUT/FF 而非 BRAM，Ti60 上应改用显式
  EBR/SRAM wrapper 重新评估。

## 板前证据

detached xsim 在 AW/W/B 同时施加停顿，并让第二个有效 descriptor 返回 SLVERR：

```text
C1_AXI128_WRITE_MLP_PASS desc=6 aw=3 w=12 b=3 max_out=3
  aw_stall=18 w_stall=5 b_stall=49 errors=4
```

其中前三个 descriptor 真实发出三个四拍 AXI burst，后三个 descriptor 分别
覆盖 early-last、late-last 和 flush；四个错误按 tag 顺序返回。Artix-7
`xc7a200tsbg484-1`/100 MHz proxy 为 `5,882 LUT / 10,308 FF / 0 BRAM /
0 DSP / WNS +3.249 ns / TNS 0`。这些是结构代理，不是 Ti60 资源或 DDR
吞吐承诺。

复现入口：

```powershell
& .\scripts\run_axi128_write_mlp_xsim_detached.ps1
& .\scripts\run_axi128_write_mlp_proxy_synth_detached.ps1
```

两个 runner 通过 WMI 创建隐藏 worker，私有 xsim/Vivado 目录在 `finally` 中
删除，只保留小型 status、summary 和 critical excerpt。

## 原始接入计划（当前第1项已由新有序前端实现）

1. 在逻辑 64-bit write packer 后增加 descriptor assembler，把 pack2、4 KiB
   分割、partial strobe 和 logical response tag 编成该 seam 的 command/payload
   流；先在 8×8/64×48 小帧替换一个 tensor writer。
2. 将 adapter 的 generation/flush/abort/ownership 转换为“停止新 command、
   drain 已接受 payload、按 epoch 丢弃或报告旧 descriptor”的明确状态机；
   不能直接把 `payload_flush` 接到系统全局 abort。
3. 在真实七客户端 fabric 中先限制 `MAX_OUTSTANDING=2`，记录 AW wait、W
   payload issue、B latency 和 DDR QoS，再逐步尝试 4/8；若控制器允许乱序，
   改用 AXI ID + reorder/retirement table，而不是沿用当前 ID-less 合同。
4. 在 Efinity/Ti60 上比较 LUTRAM 与显式 M10K/EBR payload 存储。只有当写侧
   MLP 在 native 长帧中减少实际等待且没有挤压 CNN/DISPLAY 带宽时，才晋升为
   默认 SoC 配置。

该 seam 解决的是“一个 writer 的 descriptor 级等待”，不会减少 AXI payload
字节数，也不会自动提高共享 CNN FSM 的 MAC 利用率；15 fps 仍需与三行 cache、
读侧 fabric outstanding 以及并行 MAC scheduler 联合验收。
