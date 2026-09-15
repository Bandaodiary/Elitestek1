# 预览接入后的取消恢复与描述符屏障重置修复

日期：2026-09-11。

## 新的组合验证与发现

在真实 boardless 预览路径上连续运行正常帧、取消帧、恢复帧，不复位。
取消场景先接受预览三笔 AW、六个 W beat，收到前两个 B 后阻塞最后 B，
发出 abort 并连续 24 cycles 提出新任务；检查 busy 保持、start_ready 为零、
无任何终止通知。解除阻塞后等待取消完成，再运行恢复帧并核对处理后输出
和全部 24 个预览像素。CNN 仍为 boardless testbench 的行为 loopback。

首次运行 `review_preview_boardless_cancel_20260911` 失败于原有
`dispatch complete before all stage transfers` 断言（24205 ns）。根因是
上一任务的 dispatch_complete_q 在新任务接收/启动边沿仍可为高：旧逻辑
只在 engine_start 的寄存更新后清零，外部观察到的完成标志及数据屏障未
同步关闭。这次直接连续重启暴露了旧状态，不以放松断言处理。

## 生产修复

`c1_r1_boardless_frame_system.sv` 新增 `dispatch_open`，要求旧完成位为高
且没有 job_start_fire、engine_start、descriptor_abort 或 compute_abort。
输入/反向输出的原描述符数据屏障、对外 stage_dispatch_complete 统一
使用该有效标志；job_start_fire 也清除寄存完成位。这样任务接收、启动、
取消的同拍即关闭屏障，下一次真实 descriptor dispatch 才重新打开。

本次证据首先证明“公开完成标志陈旧”，并未观察到已损坏的实际 DDR 数据；
不能把断言失败夸大为已实测的跨帧内存污染。原同拍取消规则保留。

## 最终定向结果

`review_preview_boardless_cancel_final_20260911` complete/exit=0：

- jobs=3、done=2、aborted=1，未接受额外 restart；
- held_B=1、取消后强制阻塞 24 cycles，全部 B 退休后才能取消完成；
- 恢复帧预览 3 AW/6 W/3 B，24 个像素及处理后输出正确；
- `C1_BOARDLESS_DISPATCH_REARM_PASS old_complete_at_admission=1`，实际覆盖
  任务接收边沿旧寄存完成位仍为 1，而公开屏障必须为 0；
- start 后改坏实时预览基址/stride，写入仍使用任务快照。

修复后的中间运行 `review_preview_boardless_cancel_r2_20260911` 同样通过，
最终版本增加了专门的旧完成位覆盖计数及准确的任务数标志。
默认关闭预览的 `review_preview_barrier_default_20260911` 原九任务通过：
2 done、5 error、2 aborted，110 个 stage transfers，5 次完整 dispatch。

```powershell
& case1/scripts/run_r1_boardless_frame_system_xsim_detached.ps1 -RunId <unique-id> -Preview -PreviewCancel
```

runner 检查唯一的预览与取消标志；PreviewCancel 必须搭配 Preview。
worker 通过 WMI 脱离 Codex Windows Job，所有终态临时目录自动清理。
失败运行仍保留精简日志，不算通过。

## 回归与影响检查

本轮重新执行全量 Icarus，145 配置通过；queued-write 整机编译为
132 sources、0 errors、608 条工具诊断，不宣称零警告。
`review_preview_barrier_soc_20260911` 完成真实 trained-artifact SoC 小图：
12×10→8×8，queued write、双采集、fatal ticket、burst refill/request handoff。
Python golden 比较通过：64 输入、22 stages、836 个 C8 结果、64 DDR 像素、
120 原始显示像素和 64 处理显示像素。AW/W/B=864/912/864，全部退休。
这个最外层 SoC 仍关闭预览，用于检查公共屏障修改未破坏原完整 CNN 路径，
不是启用预览的完整 CNN 证明。未重跑检查器破坏性负例。

本轮五个 xsim 运行（含首次失败）对应临时目录均已不存在，精简日志合计
100968 bytes，约 98.6 KiB；没有保留波形或大型临时工程。

## 未完成范围

本轮取消为最后一个预览 B 在途场景，不是完整启用预览的错误矩阵。
preview BRESP 错误、非法预览布局等还需在真实 boardless 接入中验证。
最外层 portable SoC 的共享写 master、元数据、地址互斥和显示接线仍待完成；
不能把 boardless 的 loopback 测试替代整机完整 CNN/显示的预览验证。
