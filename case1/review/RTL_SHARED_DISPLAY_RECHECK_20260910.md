# 共享 DDR 下的真实计算/显示并发复测

日期：2026-09-10。本轮不修改生产 RTL，使用现有完整便携 SoC 的单 DDR BFM，补上“独立双显示源不能证明共享仲裁效果”的覆盖缺口。

## 配置与证据

[最终运行状态](../logs/portable_soc_cache_ddr_bfm_runs/review_shared64_concurrent_20260910/status.json)：complete / exit 0，工具墙钟 393.087 s。参数：

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 `
  -Frame 64x48 -TwoFrame -DisplayResponseFifo -ConcurrentDisplayPrefetch `
  -FabricReadResponseSkid -SharedQosMonitor
```

这是已有零参数生命周期测试：实际运行 engine、tensor、采集、显示、CSR 与共享 AXI，不是训练参数的视觉质量验证，也没有 Sapphire CPU master。采用 64×48 而非 8×8，使计算活动实际跨越合法显示需求窗口，保留“必须观察到显示 AR 与 job 重叠”的断言。

最终结果：

- done=2、swap=2、drop=0、44 个 descriptor。
- `C1_CONCURRENT_DISPLAY_OVERLAP_PASS ar_during_job=96`，证明本次合法显示请求与计算确有重叠。不同于此前尺寸修复后 overlap=0 的失败 8×8 用例。
- underflow=0、protocol=0、monitor overflow=0。
- AXI AW/W/B=80448/83328/80448，AR/R=96981/105308。
- 新图预取完成 2 次，预取总完成 4 次；监控结果经 APB 读回一致。

## 性能并未闭合

deadline_miss=2，配置阈值为 1000000 core cycles。最近一帧监控区间为 6925262 cycles，在该测试 100 MHz core 下约 69.25 ms。这个计数包含系统/显示提交边界等待，不是独立 CNN 推理耗时；测试尺寸也仅为 64×48，不能外推 native FPS。

本次显示客户端 4/5 的最大 AR 等待均为 86 cycles。它是本次 BFM 服务条件下的观测最大值，不是任意 DDR 刷新、CPU 争用或 burst 组合下的最坏时延保证。

客户端 6（tensor）累计 96384 次 AR、80256 次 AW，每笔均为一拍；大量短事务仍是后续优化的重点。显示并发通过仅证明当前 opt-in 方案存在有效工作场景，不能据此默认打开所有配置，或断言宽度放大后仍零欠载。

## 范围与后续

本轮补上了真实共享 fabric 的有效重叠证据，但并未完成持续帧压力、native 全网络数值、15 fps、CPU 共享内存及物理实现签核。下一步需要拆分计算、访存和显示提交等待时间，并用同一工作负载比较缓存/burst 配置，避免把监控总周期全归因于 MAC。

worker 始终脱离当前 Windows Job；等待期间仅检查指定进程、状态及少量日志尾部。运行结束后确认临时目录不存在，无波形保留，只有小型状态与日志。
