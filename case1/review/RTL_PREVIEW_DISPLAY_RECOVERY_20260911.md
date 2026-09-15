# 预览显示模式下的取消与 BRESP 恢复

## 本轮范围

组合验证上一轮真实预览显示接线与已有两种恢复路径，不修改生产 RTL。
runner 允许 `-PreviewDisplay` 与完整的 PreviewCancelRecovery 或
PreviewBrespRecovery 同时使用；仅失败/取消而没有完整恢复的模式仍拒绝
该组合，避免把没有成功视频输出的运行误当成显示验证。

两组都使用八客户端 queued W-ahead、registered fatal ticket、真实
MicroStyle 训练参数、彩色 RAW10 12×10 → 8×8 Resize、tensor burst refill
及 request handoff。整个运行不复位 DUT、不擦除 DDR；成功帧必须重新
产生完整的物理字节写覆盖，不能用首任务残留数据代替写回证据。

| 运行 | 第一任务 | 第二任务 |
| --- | --- | --- |
| review_preview_display_cancel_recovery_20260911 | 末 B 阻塞，软件取消，拒绝提前 START，排空 | 显式 START 后完整计算与预览/风格图显示 |
| review_preview_display_fault_recovery_20260911 | 末 B 延迟后 SLVERR，错误一次，零发布，排空 | APB 确认 IRQ 后完整计算与预览/风格图显示 |

独立 Python 检查同时要求恢复阶段协议和 `--require-preview-display`：
必须先取消/出错并排空，随后才成功；核对 64 个预览 DDR 像素、22 层 CNN、
风格图 DDR，以及实际显示接口的 64 个预览和 64 个风格化像素。

## 验证结果

两组均 complete / exit 0，且在强制要求对应恢复协议和预览显示的条件下
通过独立 Python golden：64 个 CNN 输入、22 层 836 个 C8 结果、64 个
预览 DDR 像素、64 个风格图 DDR 像素，以及实际显示的 64+64 个像素。
每组各通过 60 项负向变异检查。

软件取消组累计 1 aborted / 0 error / 1 done；SLVERR 组累计 1 error /
1 done，两组均有 2 次实际采集。共享 AXI 各为 943 AW / 1007 W / 943 B，
peak outstanding=2、W-ahead=16，已全部退休。

墙钟时间分别为 108.251/108.285 s；两进程并发运行，此数值不代表硬件
帧周期或两配置性能差异。xsim 通过 WMI 运行在 Windows Job 外，无波形，
两项临时仿真目录均已自动清理。保留小型日志用于追溯，没有保留完整仿真树。
本轮只扩展 runner 允许的测试组合，未改生产 RTL，也未重跑全量 162 配置。

## 证据边界

两组是“首任务取消或出错，随后一帧成功”，不是连续两个成功槽。
首任务没有发布有效显示帧，故不能证明“已有有效显示帧时发生错误仍保持
旧画面”的整机行为。两次采集使用同一颜色 fixture，也不能代替不同内容
的多帧错配检测。虽已有控制器旧帧保留测试，仍需整机双槽、不同图像内容、
换帧期间读排空与旧帧保留的组合验证。

没有运行新的 Efinity 资源/时序评估，不从小图测试推断原生 15 fps。
