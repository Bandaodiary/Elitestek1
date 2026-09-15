# SoC 列读取消恢复与双帧验证

日期：2026-09-11。

## 本轮改动

本轮没有修改生产 RTL，重点关闭上一轮列读 SoC 的动态验证缺口。

- `run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1` 允许 `InflightReadAbort` 使用新列读路径，仍要求 ConcurrentCapture、QueuedWriteFabric、SourceGeometry 等原有前置条件。
- testbench 在真实共享 AXI fabric 上按实际补行客户端选择取消时机。旧标量 burst 路径为 6，新列读路径为 `AXI_CLIENT_COLUMN`；本次无预览配置为 7。
- 修复取消完成日志中遗留的固定 `owner=6`，运行器必须同时看到实际 owner 的唯一排空和重启标记。
- golden 检查器增加 `--require-read-abort`，同时自动识别已有取消标记。检查请求有真实多拍债务、冻结 64 拍、排空/恢复顺序、前后债务与 owner 一致、captures=3、done=1、reset=0，并强制核验恢复后的显示数据。
- 增加 13 项取消证据破坏测试：丢失排空/重启/全部证据、重复标记、错误 owner、零债务、债务不匹配、过短冻结、使用复位、顺序颠倒、重复配置及错误客户端数量。

## 在途列读取取消

最终运行 `soc_column_read_abort_20260911_final`，状态 complete、退出码 0。配置为列读＋水平复用＋训练参数＋彩色 12×10 输入缩放到 8×8＋queued write fabric＋并发采集。

冻结实际客户端 7 的 4-beat AXI 补行响应，随后通过真实 APB 发取消。在 64 拍冻结期间，检查系统持续忙、AXI 读取仍有所有权、R/AR 计数不前进、没有新的捕获/神经网络启动，也不提前出现张量取消完成。提前重新 START 被拒绝。释放响应后，读写全部排空，且未取消任务不得错误报告 DONE。

之后不复位重新配置并采集第三帧，恢复任务通过独立 integer golden：

- 64 个 CNN 输入、22 阶段、836 个 C8 结果、64 个物理 DDR 输出像素。
- 120 个原图显示像素、64 个风格图显示像素。
- 恢复任务 512 个列请求全部退休；596 个标量读、836 个写事务。
- 写队列 AW/B=938/938、W beats=1006、peak outstanding=2、ahead=32（整个测试的统计，不是单帧写带宽）。

上述 golden 与取消证据检查通过，13 项新增破坏测试全部被拒绝。已有普通单帧数值检查的负测试也重跑通过。

探索运行 `soc_column_read_abort_20260911_a` 虽然仿真结束成功，但仍打印了错误的最终 owner=6；新检查器正确拒绝该日志。它不作为最终恢复证据，不在原日志上修改编号冒充重新验证。

## 连续双帧

运行 `soc_column_twoframe_20260911_a` 状态 complete、退出码 0。两帧采用不同源数据，无复位连续运行，分别完成全部计算、DDR 写回和显示；不是让同一张静态帧重复通过。

独立双帧 checker：

```
C1_TWO_FRAME_GOLDEN_PASS frames=2 inputs=128 C8_results=1672 DDR_pixels=128 independent_source=1
C1_TWO_FRAME_VIDEO_GOLDEN_PASS frames=2 raw_pixels=128 styled_pixels=128
C1_TWO_FRAME_COLOR_GOLDEN_PASS frames=2 independent_RGGB_planes=1
C1_TWO_FRAME_NEGATIVE_PASS cases=39
```

两个成功计算 job 分别为 42,727 和 42,725 拍；每帧 512 列请求/512 退休、596 标量读、836 写事务。这里是计算区间，不是摄像头/显示端到端帧周期。

## 运行方式与未完成项

所有 xsim 通过现有 WMI 隐藏 worker 脱离 Codex Windows job。三次运行的临时工程目录均已确认不存在，只保留小型状态及所需数值追踪。未运行综合、布局布线或完整 Icarus 套件。

新列读 SoC 的**选定在途读取消恢复配置**与**选定串行双帧配置**现有证据支持通过。不扩展为所有故障/并发组合通过：标量在途写取消、不同 RRESP/BRESP 注入、预览真实流量并发、packed writes/写流水及其他性能选项交叉仍待验证。仍默认关闭列读选项，原生分辨率 15 fps 与 Efinity 资源/时序仍未证明。
