# 当前 RTL 的原生尺寸分项复测

日期：2026-09-10。当前工作树复测，明确区分完整 DMA 帧与局部真实 CNN 算术，不将两项合并成完整 CNN 帧通过。

## 三帧完整 DMA 回环

[运行状态](../logs/native_dma_loopback_runs/review_dma3_native_20260910/status.json) 为 complete / exit 0。真实输入 reader、帧 writer、表项读取及共享读仲裁经过三个独立 640×480 槽位；testbench 对实际写回的内存逐像素读回检查，不只检查请求计数。

结果：三帧共 921600 pixels，14400 输入 AR、230400 输入 R、14400 输出 AW/B、230400 输出 W，三次表项读取。包含 585856 个 stream stall、97816 个 W stall、57240 个 B delay 的覆盖计数。PASS 中的历史字段 `frame_pixels=921600` 实际表示三帧合计，不是单帧像素数。工具耗时 17.324 s，不是硬件帧处理时间。

这项验证覆盖近期帧写入和 skid bridge 修改在原生 DMA 流程中的组合，但没有运行 CNN、CSI 或实际 DDR PHY，也不证明 15 fps。

## 原生输入 + 首行 16 个真实 stage-0 算术输出

[运行状态](../logs/native_first_window_engine_preflight_runs/review_native16_arith_20260910/status.json) 为 complete / exit 0。640×480 源图完成 307200 次写入，随后取 144 个窗口读、16 个 engine input，核对 32 个 C8 结果和 32 次实际输出写回后安全 abort。

32 个结果对应首行 16 个像素、每像素两组输出。`stages=22` 是加载的配置数量，不代表全部阶段执行完成。本测试的真实范围为 native source ingest + finite stage-0 arithmetic。

## Golden 常量检查补强

`golden/test_native_stage0_window.py --pixels 16` 已用当前参数重新执行原生输入的 stage-0 整数卷积，对首行 16 个像素通过。

原测试只比较 Python 内部常量，本轮增加 `check_rtl_constants`：直接读取实际 SV testbench 的两个 16 项 case 表，要求索引完整且唯一，并逐项比较 32 个值，防止 Python 常量正确但 RTL 常量过期。已在内存中将一个 RTL 常量改坏一位，检查器成功拒绝；没有改动磁盘上的 SV。

复现：

```powershell
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe case1/golden/test_native_stage0_window.py --pixels 16
```

## 临时目录与限制

两个仿真均通过既有 breakaway 启动机制脱离当前 Windows Job，未开启波形。首窗口 runner 自动清理完成。旧 DMA runner 缺少 finally，本轮删除它生成的约 0.46 MiB 编译临时目录（可重新仿真生成），未删除其他运行；已补父目录/目录名校验和 finally 清理。脚本语法检查通过，清理功能正在重新完整运行核验。

清理补丁的完整复跑 [review_dma3_cleanup_20260910](../logs/native_dma_loopback_runs/review_dma3_cleanup_20260910/status.json) 已通过，exit 0、16.316 s，三帧计数与首次一致；worker 已退出，实际 `run_directory` 不存在，确认 finally 自动清理生效。

本轮没有修改生产 RTL。完整 native CNN 的各层数值、持续显示/多主机服务与目标吞吐仍未闭合。
