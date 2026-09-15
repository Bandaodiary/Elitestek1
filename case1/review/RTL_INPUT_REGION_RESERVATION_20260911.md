# 捕获对已保留输入帧的物理区域保护

日期：2026-09-11。

## 生产 RTL 改进

仅保护 current/pending 显示图像仍会遗漏 READY_NN 和正在计算的输入帧。本轮将输入三槽的物理区域快照接入捕获预检：

- `c1_frame_manager` 新增输出 `input_owned_mask[2:0]`，表示输入槽是否为非 FREE；明确它只表示逻辑所有权，不表示取消后的 AXI 已退休。
- `c1_r1_soc_control` 在实际捕获 writer-start 接受边沿记录该槽的 base、stride、width、height 和 valid。快照独立于会在 abort 时清零的 capture 控制输出。
- 正常情况下，快照保持到 manager 将该槽释放为 FREE。取消时增加全局 input-region cancel-hold，等 capture writer、boardless runtime 和 capture cleanup 均结束后才允许释放已 FREE 的快照。
- 捕获启动检查新增第三组：候选写区域与另外两个已登记输入槽比较。只有一个其它槽有效时，将其作为两个读区域输入；读读别名允许，写读重叠仍拒绝。
- 当前分配给捕获的同一槽不与自己比较，保留 manager 合法 drop-oldest 重用语义；其它槽仍需检查。没有禁用 concurrent / continuous 模式。

因此 DMA 完成不会立即释放帧数据保护，取消也不会立即丢掉已接受事务的地址记录。返回错误沿用 capture config `0x31`。

## 验证

新增 `INPUT_REGION_CASE=1..4`，在直接/寄存故障广播两种配置下共 8 个用例：

| 模式 | 场景 | 结果 |
| --- | --- | --- |
| 1 | 第一帧 READY_NN，第二捕获基址为原图+16 | writer 启动前拒绝，精确 0x31/错误地址 |
| 2 | 第一帧 READY_NN，第二捕获使用独立区域 | 正常启动，不要求先运行 NN |
| 3 | 第一捕获活动时取消，writer busy 再保持 20 拍 | 已 FREE 的逻辑槽仍保留物理快照；排空后释放，同区域可无复位重用 |
| 4 | 第一帧已进入 NN processing，第二捕获基址为原图+16 | writer 启动前拒绝 |

控制器定向回归 74 配置通过。既有发布重试正常用例的精确检查次数因新增输入组而增加：COMMIT 发布合法重试由 3 次变为 5 次，VSYNC 合法重试由 2 次变为 3 次；这是新的检查阶段，不是放宽断言。

本轮全量最终输出 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=237`，退出码 0，新增用例包含在该次完整运行内。

xsim 交叉验证采用寄存故障广播：

- `input_region_ready_20260911`：模式 1，complete / exit 0，11.240 秒。
- `input_region_drain_20260911`：模式 3，complete / exit 0，9.252 秒。

两者使用 WMI detached runner，不绑定 Codex Windows Job，无波形。已确认对应 `case1/sim/soc_control_run_<id>` 目录不存在；仅保留合计 6993 字节文本记录。

## 接口与复现

`input_owned_mask` 为 frame manager 尾部新增输出。命名实例可不连接；使用 `.*` 的外部 testbench/封装应声明或显式连接该信号。仓库中已有 wildcard 测试已更新。

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -Python <python-path> -TestTop tb_c1_r1_soc_control
& case1/scripts/run_soc_control_xsim_detached.ps1 -RunId <new-id> `
  -RegisterFatalTicket -InputRegionCase 3
```

InputRegionCase 必须独立于其它 capture guard/swap 场景运行。

## 尚未完成

这是持续输入帧占用接入捕获写入口的一步，不是全系统隔离。processed、preview、tensor writer 对其它活动帧的检查和双入口原子申请仲裁仍未实现；输入表项在捕获后被软件重新映射时，NN 消费者与登记快照的一致性也仍需补强。

取消保留依据现有 boardless busy / capture cleanup 的排空契约，不是重新计数所有 AXI 事务。新增测试的 DMA 与 NN busy 是行为模型，不能替代真实整机取消排空数值验证。正常槽释放、drop-oldest 与显示替换的更全面跨区域组合，以及新增寄存器与预检开销的资源/时序评估还需继续。本轮未重跑真实 CNN 双帧 xsim。
