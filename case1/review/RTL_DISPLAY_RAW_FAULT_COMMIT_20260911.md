# 原始故障与显示槽提交的优先级修复

日期：2026-09-11。承接换帧取消竞争修复，检查寄存故障广播在 VSYNC 所有权提交边界的行为。

## 已复现问题

`REGISTER_FATAL_TICKET=1` 有意将故障广播延迟一拍。但原 `manager_display_vsync` 不检查原始 `fatal_now`。显示预取错误与 VSYNC 同时出现时，帧管理器尚未看到取消，仍会提交发生错误的新帧。直接故障广播模式因取消当拍生效而没有这一现象。

在未修复生产代码上，新增测试观察到直接广播场景通过，随后寄存广播场景失败：

```text
C1_SOC_PENDING_SWAP_ERROR_PASS preview=0 ticket=0 errors=1 swaps=1 retained_slot=0
FATAL: uncommitted pair escaped cancellation on VSYNC
```

不是仅根据代码推断，也不是通过强制修改内部状态制造的结果。测试使用真实控制器和帧管理器，先完成并显示第一帧，再完成第二任务并将其预取置为 primed，在真实换帧请求边沿注入显示错误。

## 生产修复

将 `manager_display_vsync` 的组合计算移到 `fatal_now` 分类之后，并增加 `!fatal_now` 限定。这样：

- 原始故障立即禁止**新的**显示槽提交，不等待寄存取消广播。
- 故障 ticket 的时序、错误码/地址快照和清理机制保持不变。
- 上一拍已经提交的槽仍通过 `manager_display_swap` 完成 current 元数据更新；不追溯撤销已提交所有权。
- 不能把该保护写成取消所有 swap 事件，否则会再次造成显示槽与 current 元数据分离。

本轮未增加状态寄存器或修改 CSR/AXI 接口。但原始故障进入换帧准入逻辑，存在组合路径变化，尚未进行物理时序测量，不宣称时序改善。

## 验证范围

新增 8 配置：故障发生在第二槽提交前/后 × 原图/Resize 预览显示 × 直接/寄存故障广播。

- 提交前故障：累计 2 次任务，只有 1 次 swap；槽 1 未发布，保持槽 0。
- 提交后故障：累计 2 次任务、2 次 swap；保持已经提交的槽 1 和新元数据。
- 新旧地址及 stride 不同，拒绝旧地址/新槽或混合快照。
- 两种场景都保持排空 8 拍，不准新预取；之后核对恢复请求属于应保留的帧，且是 repeat 而非 new。
- 故障路径不发送软件 ABORT；检查恰好 1 次错误、错误码 `0x70`，错误地址为出错的新显示预取地址（原图 `0x00400000`，预览 `0x00500000`）。

控制器定向 **26 配置通过**。全量 **186 配置通过**（原 178 + 新增 8），退出码 0，最终标记为 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=186`。该次回归的唯一 VVP 和向量目录已由脚本清理，完成后检查均不存在。
queued-write 顶层 133 源文件编译通过：0 errors / 608 工具诊断。

## 独立 xsim 交叉验证

| 运行 ID | 场景 | 结果 |
|---|---|---|
| `review_pending_swap_error_20260911` | 预览/寄存广播，提交前故障 | complete / exit 0，9.266 s |
| `review_committed_swap_error_20260911` | 预览/寄存广播，提交后故障 | complete / exit 0，8.237 s |

两组实际日志中的唯一对应 ERROR_PASS 标记已核对。通过 WMI 独立隐藏 worker 启动，Vivado 不属于 Codex Windows Job；两组仿真临时目录完成后均不存在，保留小型日志及状态文件。

`run_soc_control_xsim_detached.ps1` 增加 `-SwapErrorCollision`，只允许与边界模式 2/3 组合，并要求对应故障验证标记；不会仅凭原软件取消测试的 PASS 宣称故障场景通过。

## 未覆盖边界

此处捕获、计算、显示预取及排空仍为行为客户端，未验证物理 DDR 故障或最终 HDMI 像素。完整 SoC 的不同内容双成功帧 golden、实际读写故障与换帧的组合、原生尺寸吞吐和物理资源/时序仍待闭合。
