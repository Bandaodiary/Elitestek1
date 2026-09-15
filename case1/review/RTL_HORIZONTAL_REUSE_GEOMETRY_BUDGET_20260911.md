# 水平窗口复用：几何回归、彩色双帧与原生预算

日期：2026-09-11。本轮未修改生产 RTL，扩展 testbench/回归和独立预算模型。

## 1. 更大与退化几何

adapter bench 新增 FRAME_W/FRAME_H/BANK_BYTES 参数，默认仍为原有 8×4、1024 B/bank。较大几何按最大 full-resolution C16 tensor 分配足够空间，测试 watchdog 随像素数扩展；这是测试容量/超时设置，不是性能验收门槛放宽。每笔请求仍检查地址范围、数据，所有 engine 窗口和最终输出均核对。

新几何均启用三级地址流水线和提前地址准备，对比水平复用开/关：

| 输入几何 | bank 字节数 | 稠密逻辑读 | 复用后逻辑读 | 减少 |
|---|---:|---:|---:|---:|
| 4×4 | 1024 | 905 | 647 | 258 |
| 12×8 | 1536 | 5430 | 2970 | 2460 |
| 20×12 | 3840 | 13575 | 6969 | 6606 |
| 32×16 | 8192 | 28960 | 14320 | 14640 |

覆盖内部特征图宽度 1、3、5 等情况，以及非二次幂 bank 间距。启用复用的配置还验证历史有效时取消、清除有效位、无硬件 reset 后重新跑完整任务。

adapter 定向 **33 配置通过**；随后当前完整 Icarus 套件 **653 配置通过，退出码 0**。该数量包含预期诊断配置，不表示所有可能参数组合已穷尽。

## 2. 彩色双帧整机

`horizontal_reuse_color_twoframe_20260911`：complete，退出码 0，270.277 秒。启用与上一轮相同的计算/缓存/packing 优化，并启用水平窗口复用；两个正常任务串行运行。

独立 golden：两幅不同彩色输入、1672 C8、128 DDR 像素和两路各 128 显示像素全部匹配；39 项日志负测试通过。两帧各减少 1488 次逻辑读，实际各 2132 次读/836 次写；任务周期分别为 48159、48176。本轮没有重新运行关闭开关的彩色对照，不据此计算新的优化百分比。

继续使用 WMI/breakaway 独立启动 xsim，已确认其专属临时工程目录不存在；不保存波形工程。

## 3. 与实测对齐的独立预算

`model/tensor_perf_model.py` 新增 `horizontal_window_read_budget()`，不改原有 DDR 理想性能模型的默认行为。新函数仅统计固定 22 阶段图的 adapter 逻辑读，不将水平复用收益再乘以理想 line-cache 命中系数。

模型与六种 RTL 实测几何 4×4、8×4、8×8、12×8、20×12、32×16 的稠密/复用读数完全一致。非法尺寸检查、原 tensor 性能模型测试、原 window-cache 性能模型测试均通过。

对 **640×480 的当前固定图**，分析预算为：

- 稠密阶段读：17376000 次。
- 水平复用后阶段读：8072160 次。
- 当前 adapter 请求/响应分开且不能同拍返回，因此仅串行读状态至少需要 16144320 拍。
- 即使改成理想流水线、每拍返回一个 C8，也至少需要 8072160 拍。

按 **100 MHz** 换算：

| 读通路假设 | 只计读所需时间下界 |
|---|---:|
| 当前串行请求/响应 | 161.4432 ms |
| 理想每拍一个 C8 | 80.7216 ms |
| 15 fps 总帧时间预算 | 66.6667 ms |

这些不是原生 RTL 仿真实测，也不包含 source/result 写、计算、配置、冲突或 DDR 停顿。它们是当前固定算法和接口吞吐的分析下界，不能当作实际帧时间预测。当前和理想单 C8 路径分别至少需要 242.1648/121.0824 MHz 才能容纳这些读，且尚无其他工作的余量；本轮没有证明这些频率可实现。

因此，100 MHz/15 fps 目标不能只靠增大 outstanding 实现。后续要同时考虑更宽的多 tap 返回、缓存数据直接组织成列/窗口、进一步融合或复用，或者有证据支持的模型/时钟选择。不能将更快的小图测试当作原生吞吐门槛已经关闭。

## 4. 复现

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/model/test_tensor_perf_model.py
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/model/test_window_cache_perf_model.py
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/golden/check_portable_soc_two_frame_trace.py case1/logs/portable_soc_cache_ddr_bfm_runs/horizontal_reuse_color_twoframe_20260911 --require-video --require-color --self-test
```

仍待完成：更高吞吐的上层数据接口、历史窗口存储物理映射、原生尺寸性能及实际时序。水平窗口复用保持默认关闭。
