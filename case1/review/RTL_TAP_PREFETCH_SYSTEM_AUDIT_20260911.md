# 地址预计算整机对照：功能通过，当前缓存路径收益为零

> 后续：本文件保留第一版的零收益证据。第二版已前移准备并得到整机 10.16% 周期改善，见 [准备前移验证](RTL_EARLY_TAP_PREFETCH_20260911.md)。

日期：2026-09-11。此次不是新的生产数据通路修改，而是上一轮可选优化的整机验证与收益审计。

## 结论

`PREFETCH_NEXT_TAP_ADDRESS` 的第一版在带 burst line cache 的当前整机场景没有周期收益。不能将 adapter 慢响应 BFM 中 9.66%～12.91% 的结果当作本系统加速比例，也不应因此开启默认参数。

两组仅切换预计算开关，均启用三级地址计算流水线、DW 权重缓存、MAC 预取重叠、结果写流水化、tensor packing/end、queued write fabric 和 burst refill。真实参数、12×10 输入缩至 8×8、并发采集及 RAW 错误/APB 恢复场景相同。

| 项目 | 关闭预计算 | 开启预计算 |
|---|---:|---:|
| 成功恢复任务周期 | 77681 | 77681 |
| 预计算完成路径 | 0 | 0 |
| 退回原地址状态 | 2688 | 2688 |
| 逻辑 tensor 读 / 写 | 3620 / 836 | 3620 / 836 |
| 请求背压周期 | 1915 | 1915 |
| 整个测试 AXI AW / W / B | 628 / 770 / 628 | 628 / 770 / 628 |

AXI 统计覆盖整个测试，任务周期和 tensor 计数仅覆盖成功任务，不混用口径。此基线增加了三级地址流水线，不能用未启用该流水线的历史 65670 周期结果当作本开关的关闭对照。

## 功能与恢复证据

- `tap_prefetch_off_system_20260911`：退出码 0，121.348 秒。
- `tap_prefetch_on_system_20260911`：退出码 0，120.285 秒。
- 两者均通过独立 Python 整数模型检查：22 阶段、836 个 C8 结果、64 个最终 DDR 像素；显示原图 120 像素、风格图 64 像素正确。
- APB 软件恢复、RAW idle timeout 4096、故障后最终写响应延迟 64 周期、源停止确认延迟 32 周期期间的 ownership 保持，以及无 reset 恢复全部通过。
- 两次运行都使用原有 WMI/breakaway detached 启动器，结束后专属仿真目录已清理，仅保留状态及小型 trace/摘要。

检查命令（将 RUN 换为上面任一运行名）：

```powershell
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/golden/check_portable_soc_numerical_trace.py case1/logs/portable_soc_cache_ddr_bfm_runs/RUN --require-apb-recovery --require-late-source-ack
```

## 为什么单元有效、整机无效

adapter 的第一版仅在读请求已被接纳后启动下一地址计算。cache 前端则可能先 claim 请求并等待 refill，直到 tap 可以接纳才对上游握手；cache-hit 的握手后返回也很快。因而外部 DDR 的慢服务不等于 adapter 握手后的长等待。这一接口差异与本次零命中计数相符。

当前三个 arithmetic 步骤再加完成地址寄存器，需要较长的握手后间隔才能命中；本场景每次都来不及。扩大 FIFO 或增加响应延迟来使测试命中，不是有效优化。

## 下一步修改方向与约束

1. 将预计算启动点提前到当前地址锁存/读请求等待阶段；`request_addr_q` 和完整 cache sideband 继续由独立寄存器保持，绝不修改已呈现请求。
2. 连续 tap 快路径也必须及时启动后续地址准备，避免仅每个窗口第一笔受益；正确处理 tap 7→8、窗口/输入 group/阶段边界。
3. 评估最终地址表达式直接在响应收回边界锁存是否可以省去独立完成等待，而不越过既有算术流水边界。任何此类改变都须重新做单元取消/错误和整机数值回归。
4. 若实际 cache-hit 仍不能覆盖地址计算，需继续设计上层读调度并行化；不能把预计算兼容通过当作吞吐目标完成。

本轮增加 runner 的 `-PrefetchNextTapAddress`，传播到编译配置；bench 检查真实 adapter 三个参数并输出 `C1_NUM_TAP_ADDRESS_OPTIONS`。runner 要求该证据标记，性能监视器另输出每任务 prepared/fallback 计数，避免以后出现“开关存在但未生效”的无证据收益声明。
