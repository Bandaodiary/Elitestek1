# 分叉前帧行标志检查

日期：2026-09-11。承接坐标检查，将同一 Resize → preview/CNN 接口的
SOF/EOL/EOF 校验前移到两消费者分叉之前。

## 复现

旧 preview DMA 仅在下游 XRGB writer 消费像素时检查标志，此时 fork 的
另一分支可能已经把错误标志送给 CNN。新增测试先于生产改动运行，缺失
首像素 SOF 时触发 `CNN token mismatch n=0`（时间 4185000），证实泄漏。

## 修复契约

`c1_r1_preview_dma.sv` 基于 start 锁存的尺寸与正常握手推进的期望坐标，
同时检查：SOF 当且仅当 (0,0)，EOL 当且仅当行末，EOF 当且仅当最后一行行末。
标志与坐标错误统一为 `raster_bad`。错误输入握手一次以设置 sticky error，
但不产生 fork 输入 VALID，不进入 CNN 或预览 writer；等待上层取消。
正常输入、现有 pending token 及已提交 AXI 事务的规则不变。

旧取消测试原本要求错误 SOF token 仍在 CNN 上等待；该预期改为错误 token
不得出现在 CNN，源接受计数为 1。另有 BRESP 错误遇到已存在的停顿 CNN EOF
测试继续检查 VALID/载荷不撤回，因此并未放松“已有有效承诺保持稳定”的要求。
底层通用 writer 的标志错误检查仍保留，供非 preview DMA 调用路径使用。

## 定向证据

默认与受限地址区间分别运行 15/18 个任务。新增六场景分别在像素
0/1/2/7/3/7 注入缺 SOF、重复 SOF、提前 EOL、缺 EOL、提前 EOF、缺 EOF。
每次均要求：源接收数=错误索引+1，CNN 消费数=错误索引，error=1，busy=1，
AW/W=0。取消后完成并保留错误，随后无复位正常帧成功。

这些短帧在错误前未形成完整写 burst，因此 AW/W 为零；不据此宣称长帧
出错时不会存在已提交写入。原取消矩阵另行验证 AW/W/B 停顿及排空，8 个
任务通过，实测 AW/W/CNN 停顿计数 55/27/34。两类测试不能合并表述为
“已验证长帧任意位置的标志错误与所有 AXI 状态组合”。

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_r1_preview_dma -Python <python.exe>
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_r1_preview_dma_cancel -Python <python.exe>
```

runner 对两种主测试配置强制要求 `C1_PREVIEW_MARKER_GUARD_PASS`。
修复后重新执行全量回归，142 配置全部通过；queued-write 整机编译为
131 sources、0 errors、608 条工具诊断，不宣称零警告。本轮仅使用 Icarus，
临时编译文件与生成向量由 runner 清理，没有 Vivado 临时工程或波形。
本轮新增定向测试为单行帧；多行错误矩阵、整机第三预览分区/所有权/总线
与显示选择仍未完成。未改变默认区域参数，没有新增 Efinity 时序或吞吐结论。
