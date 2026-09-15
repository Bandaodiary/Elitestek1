# 取消后的共享总线排空屏障

日期：2026-09-11。

## 已复现的边界缺口

此前输入/输出区域记录的取消 hold 主要等待 capture writer、boardless job 和捕获清理。定向反例保持共享写总线 busy，而让这些叶子模块完成：旧实现出现 `busy=1 input=000 output=00`，即系统仍忙但区域记录已释放。

这是生命周期记录与共享事务状态不一致的实测证据，不等于已经观察到物理内存被覆盖：旧实现对某些写 fabric 配置另有 BUSY 门控。本轮同时补齐此前未接入 controller 的共享读排空信号。

## 修复

- `c1_r1_soc_control.sv` 新增可选 `FENCE_FABRIC_DRAIN`，portable SoC 固定启用。
- 复用取消 hold：除原有叶子模块外，还等待 parameter/表项取消、显示预取/flush 和共享读写 quiescent。hold 期间计入前台 BUSY，并保留待释放的输入/输出记录。
- hold 期间不再创建新的后台显示预取命令；已发出的 AXI 请求仍由原有取消/排空协议处理，不强行撤回 AR/AW/W VALID。
- 排空后恢复旧显示帧的后台预取。正常后台读并不永久计入前台 BUSY，避免一帧任务完成后软件仍无法配置下一任务。
- portable SoC 给 controller 的 quiescent 还要求客户端无待接受 AR/AW/W：原始 fabric quiescent 仅为内部 busy 的反值，在 idle 仲裁边沿仍可能有客户端请求。补强后的条件为 `read_quiescent && !any_ARVALID` 以及 `write_quiescent && !any_AWVALID && !any_WVALID`。原始 fabric 监测接口语义未改。

独立 controller 的新增参数默认关闭；启用者必须提供包含共享缓冲/事务的准确 quiescent 信号。不能把这两个输入简单绑高后宣称完成共享排空。

## 定向验证

- 先增加反例、再修改生产 RTL，旧实现实际报错：`shared drain released ownership early mode=2 busy=1 input=000 output=00`。
- Controller 共 168 配置通过，其中新增八配置：只读尾包、只写尾包、读写分阶段退休，以及有当前显示帧时的停止/恢复后台服务，分别覆盖原始与注册故障票据模式。
- 最后一个场景还验证取消屏障消失后，普通后台读不会单独拉高前台 BUSY。
- 14 个 portable SoC smoke 配置验证待接受 AR/AW/W 对 quiescent 的补强。该测试仅在两个时钟沿之间强制客户端 VALID，确认组合接口后立即释放，不把它作为真实 AXI 传输证据。

## 全量与真实 AXI 验证

屏障初版（尚未补充待接受请求）分别通过 `shared_drain_read_20260911`、`shared_drain_write_20260911` 两个独立 xsim 运行，状态 complete/退出码 0。最终版本另以 `shared_drain_offers_read_20260911` 和 `shared_drain_offers_write_20260911` 复验，不把初版结果冒充最终版证据。

一次全量回归在 `tb_c1_r1_compute_ingress` 处退出失败；当次尾部输出筛选未保留具体失败正文，原因未确认。该模块定向重跑通过，随后最终版本全量回归也通过，额外连续十次定向运行全部通过。本轮没有改动其生产 RTL，尚不将这次失败称为已定位或已修复；保留记录供后续回归稳定性审计。

最终全量退出码 0：`C1_REVIEW_FIXES_REGRESSION_PASS configurations=396`。

最终两个 xsim 均 complete/退出码 0：

- `shared_drain_offers_read_20260911`，109.126 秒：tensor read owner 6 的四个待返回 beat 被保持 64 周期；取消期间没有重新分配/启动，随后无复位恢复。
- `shared_drain_offers_write_20260911`，109.170 秒：两个待退休写事务被保持 64 周期；取消排空时 AW/B 为 20/20，恢复结束累计 AW/B 为 874/874。

两次最终运行都通过独立 `check_portable_soc_numerical_trace.py --require-video --require-queued-write`：各 64 个 CNN 输入、22 层/836 个 C8 结果、64 个 DDR 输出像素，以及原图 120 像素/处理图 64 像素显示核对。此次恢复 fixture 是灰度 12×10→8×8，不是彩色双帧；不能沿用此前彩色双帧或 53 项日志反例的说法。

四次运行均使用 WMI 脱离 Codex Windows Job，临时工程目录经检查全部不存在；四组各七个文本文件，合计 223,539 字节。无波形、无综合；Icarus 临时文件由脚本清理。

## 仍需审计

本次屏障针对取消路径；正常 VSYNC 释放旧帧与旧显示读事务退休的关系仍需单独核验。叶子模块的 busy 必须覆盖其尚未呈现在共享 AXI 端口上的内部请求，外围桥也必须准确报告其事务状态。CPU/外部写入仍不在该准入机制范围内。未运行综合，不声明资源、Fmax 或 15 fps 达标。
