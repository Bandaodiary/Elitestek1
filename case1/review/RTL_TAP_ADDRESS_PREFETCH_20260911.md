# Tensor tap 地址预计算优化

日期：2026-09-11。生产 RTL 已修改，默认关闭。本轮使用 Icarus 定向回归，没有运行 Vivado、综合或板测。

## 1. 问题与改动

现有 tensor adapter 在收回一个 3×3 tap 后，才计算下一个 tap 的地址。启用流水化地址计算时，这额外占用两拍；再启用独立 pixel-index 加法级则占用三拍。等待 DDR/cache 响应期间，地址计算寄存器却没有工作。

新增 `PREFETCH_NEXT_TAP_ADDRESS`，附加在 adapter 和 portable SoC 参数列表末尾，默认 0。需同时启用 `PIPELINED_TENSOR_ADDRESS` 才生效。仅预计算同一窗口的下一 tap，不预先发请求，不改变默认单 read outstanding、严格有序返回和非同拍返回合同。

工作过程：

1. 当前读请求真正握手后，将下一 tap 的钳位坐标、bank、width、groups 放入空闲地址流水线寄存器；正在等待握手的请求绝不改变。
2. `ST_READ_RSP` 等待期间依次计算 row/pixel-index 和最终地址；新增三位阶段寄存器及一个 32 位完成地址寄存器。既有地址上下文寄存器复用，最终综合的算术共享情况仍需验证。
3. 正常响应到达且预计算完成，写入当前 tap 数据并直接进入下一 `ST_READ_REQ`。否则走原有地址状态，不等待预计算完成。
4. 每次响应和新窗口入口清除准备状态。读错误、abort 仍使用原有排空与隔离流程，没有新增的 speculative 请求需要取消。

地址预计算与缓存 tap 多 outstanding 是不同能力；本改动不减少读请求数，也不声称解决整个吞吐瓶颈。

## 2. 验证与结果

`tb_c1_r1_microstyle_tensor_adapter`：19 配置通过，退出码 0。包含原有配置、预计算开关与两种地址流水线交叉、随机/零/8 周期读延迟、与结果写流水化组合，以及未开启地址流水线时的无作用兼容模式。完整正常任务覆盖 8×4 输入、22 阶段，逐个检查窗口、残差、上采样和最终流；这是 adapter 配合 engine BFM 的调度测试，不是训练模型的全系统数值验证。

正常任务周期观察：

| 地址流水线 | BFM 附加读延迟 | 关闭 | 开启 | 周期减少 |
|---|---:|---:|---:|---:|
| 两级 | 8 | 28719 | 25944 | 9.66% |
| 三级 | 8 | 30910 | 26919 | 12.91% |
| 两级 | 0 | 14295 | 14295 | 0 |
| 三级 | 0 | 16585 | 16585 | 0 |

附加读延迟为 8 时，1344 次非末 tap 转换全部命中预计算；为 0 时全部回退。随机延迟配置也覆盖两条路径。其他 ready/engine 等停顿仍来自随时钟推进的伪随机序列，因此周期差是该测试场景的整体观察，不应将其全部归因为精确的地址状态拍数，也不能外推到原生图或 15 fps。

取消/故障测试在预计算 phase 1、3、4 注入 abort；三级模式额外覆盖 phase 2。旧响应保持至少 6 个检查周期，要求 busy 不提前释放、无新 memory/engine 请求，放行后在有界时间内排空。phase 4 注入读错误，检查 `ERR_MEMORY=0x07`、无额外请求、可重新接纳任务。各场景间不复位，后续场景实际重新启动并加载配置。

测试开发过程中修正了两处 bench 问题：错误码期望误写为 0x05，以及 abort 撤销当拍立即读取组合 start_ready 的 delta-cycle 竞争；未据此修改生产错误码或放宽排空检查。修正后完整重跑通过。

`tb_c1_r1_portable_soc_smoke`：23 配置通过，退出码 0；新增开关传递到真实 `u_tensor_adapter` 的结构检查。此 smoke 不产生计算流量，不能替代整机动态验证。

复现：

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_r1_microstyle_tensor_adapter -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_r1_portable_soc_smoke -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
```

runner 保留非零退出、fatal 和必需标记检查；VVP/生成向量按既有 finally 清理策略处理，不生成波形。

## 3. 后续门槛

在默认开启前，还需将开关纳入带缓存的整机真实参数数值/恢复回归，并观察实际 cache-hit 延迟能否覆盖地址流水线；当前可能只有慢响应显著受益。多上层 tap outstanding 仍需要独立的请求/响应索引、容量预留和取消排空设计，不能用本优化代替。物理资源和时序影响尚未测量。
