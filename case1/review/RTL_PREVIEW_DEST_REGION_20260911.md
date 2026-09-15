# 预览写入区域保护

日期：2026-09-11。

## 架构缺口与实现

预览 DMA 原有 preflight 只保证尺寸、对齐、stride 及 32-bit 地址不溢出，
不能阻止一个几何合法的预览配置写进相邻采集帧或 tensor 地址区。

现在 `c1_axi_xrgb_frame_writer` 增加静态参数 `DEST_REGION_BEGIN` 和
`DEST_REGION_END`，均为 33-bit，定义允许的字节半开区间 `[BEGIN, END)`。
`c1_r1_preview_dma` 同名参数传给真实 writer，默认 `[0, 2^32)`，兼容原行为。
将来顶层应把该区间设置成独立预览 arena，不能继续使用默认值宣称已隔离。

复用原有四周期 preflight 的寄存 extent，在 CHECK 阶段拒绝：

- 空/反向区域或 END 超过 2^32；
- 帧基址小于 BEGIN；
- `base + (height-1)*stride + width*4` 的 exclusive end 大于 END。

合法帧可恰好结束于 END；原 32-bit 溢出检查保留。拒绝时完成并报错，
不接受源像素，不向 CNN 输出数据，不发起 AXI 写；未增加正常流的逐像素
比较逻辑或额外 preflight 周期。配置仍在 start 时锁存，运行中改变输入
不能影响已通过检查的地址。此处采用完整帧包围区间，包含行间 padding，
不是逐行寻找可共享空洞的分配器。

## 定向验证

扩展已有真实 preview DMA/AXI writer 测试，在 `[0x1000,0x1020)` 区域下：

- 原 8×1、32-byte 帧恰好填满区域，完整 CNN/物理 DDR 数据比较通过；
- 基址 `0x0FF0`、基址 `0x1010` 且帧尾越界、2 行且 stride=64 三种配置
  均拒绝，源接收/CNN 输出/AW/W 计数为零；
- 原晚 B、CNN EOF 停顿、取消、BRESP 错误、非法宽度与无复位重启保留；
- start 后立即将输入地址改为 `0xDEAD0000`，验证使用快照而非实时输入。

默认与区域保护两配置定向测试均通过。全量回归新增保护配置后，重新运行
142 配置全部通过。queued-write 整机 Icarus 编译为 131 sources、0 errors、
608 条工具诊断（并非零警告）。Icarus runner 自动清理临时编译文件和测试
向量，本轮没有启动 Vivado 或生成波形。静态空/反向/超过地址空间的区域分支已实现，但本轮
未单独注入这些 elaboration 参数，不宣称其具备同等动态覆盖。

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_r1_preview_dma -Python <python.exe>
```

## 仍需完成

这是地址区域边界，不是动态所有权或安全隔离系统：不解决显示仍在读取、
上一帧在途 B 未退休、多个 master 共享同一 arena 或错误顶层分区的问题。
第三预览缓冲仍需与 frame manager、任务准入、共享写总线和显示选择联合
接线；只能在该集成完成后声称整机具有第三路预览。未改变生产默认配置，
未进行 Efinity 资源/时序评估，也不产生新的 15 fps 结论。
