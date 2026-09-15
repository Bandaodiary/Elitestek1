# 多行预览与栅格故障取消组合验证

日期：2026-09-11。本轮新增验证，不修改生产 RTL。

## 弥补的缺口

之前坐标/标志定向测试主要是单行帧，不能证明正常换行、行间 padding、
或先有成功写入再发生栅格错误时的行为。本轮新增独立
`sim/tb_c1_r1_preview_multiline.sv`，实例化真实 preview DMA、fork 和 XRGB
writer，不以行为替身代替被验证模块。

固定配置：4×3 pixels，XRGB 每像素 4 bytes，stride=32 bytes，区域
`[0x1000,0x1050)`。每行一个 16-byte AXI beat，三行地址分别为
0x1000/0x1020/0x1040，最后一行恰好结束于区域上界。逐笔检查 AW 地址、
LEN/SIZE/BURST、WSTRB/WLAST 和完整像素值，验证未写入行间 padding。
逐个检查 CNN 的完整 64-bit 数据、x/y 和三个标志；AW/W/CNN 施加不同背压。

## 已完成九个任务

| 任务 | 注入位置 | 预期已写完整行数 |
|---|---|---:|
| 正常三行 | 无故障 | 3 |
| 错 x | 第二行首像素，全局索引 4 | 1 |
| 错 y | 第二行首像素，索引 4 | 1 |
| 重复 SOF | 第二行首像素，索引 4 | 1 |
| 提前 EOL | 第二行索引 5 | 1 |
| 缺失 EOL | 第二行末，索引 7 | 1 |
| 提前 EOF | 第二行末，索引 7 | 1 |
| 缺失 EOF | 第三行末，索引 11 | 2 |
| 无复位恢复 | 正常三行 | 3 |

每个错误任务检查源接收数=错误索引+1，CNN 接收数=错误索引，错误 token
未进入 CNN，error=1 且停止接收；显式取消后只退休错误前已提交的完整行。
部分行被丢弃，不会错误补写。每次检查 AW=W=B=预期已写行数，终止通知
只出现一次。start 后立即改坏实时 base/stride/width/height，验证使用快照。

第二行首像素的三类错误还与真实 AXI B 阻塞组合：先确认第一行 AW/W 均
握手且 B=0，取消后再阻塞 B **24 cycles**；期间必须 busy、不可 START、
不可 DONE。释放 B 后才完成取消，避免把“拒绝坏 token”误当作“可以立即
释放 DDR 所有权”。最后正常帧无需复位即完成。

## 结果与复现

定向运行通过，exit=0：

`C1_PREVIEW_MULTILINE_PASS jobs=9 normal=2 raster_faults=7 held_B_cancel=3 hold_cycles=24 rows=3 stride=32 snapshot=1 no_reset=1`

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_r1_preview_multiline -Python <python.exe>
```

该 testbench 已加入全量 runner，并要求专属 PASS 标志。本轮只执行新增
1 配置，不把上一轮 142 配置全量结果当作本轮重跑结果；生产 RTL 没有变化。
没有启动 Vivado 或生成波形，Icarus runner 自动清理临时编译文件和向量。

这是三行小帧的定向组合验证，不是任意图像/随机故障形式证明，也不是整机
第三预览帧管理验证。下一架构环节仍需把 preview DMA/runtime join 与真实
frame ownership、共享写总线和显示选择连接；不能据此声称第三路已经可用。
