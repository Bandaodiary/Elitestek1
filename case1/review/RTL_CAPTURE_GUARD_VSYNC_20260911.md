# 捕获预检期间 VSYNC 换帧验证

日期：2026-09-11。

## 本轮新增证据

`tb_c1_r1_soc_control.sv` 的 `CAPTURE_GUARD_PUBLISH=5/6` 先完成首帧显示及第二次 NN，接受第二帧的预取请求，再分配第三次捕获。捕获比较器进入 busy 后，通过真实 `display_frame_start_event` 提交待显示槽；不强制任何内部寄存器。

测试确认 `manager_display_swap` 真正出现、current 风格图基址更新为 `0x00600000`、显示 output slot 变为 1、软件换帧计数变为 2。软件事件比槽提交晚两拍，测试按实际寄存流水采样；最初过早采样导致的失败已修正，仅修改 testbench。

| 模式 | 第三次捕获地址 | 换帧后要求 |
| --- | --- | --- |
| 5 | 0x00600010，与新当前风格图部分重叠 | 重新检查；拒绝 writer-start / begin-frame；一次 0x31 错误；保留已经提交的新当前画面 |
| 6 | 0x03000000，不重叠 | 重新检查后正常启动，保持正确基址且不误报 |

两种显示模式 × 两种故障广播 × 两种场景，共 8 个新增配置。控制器定向回归 **66 配置通过**。两种场景均观察到两次范围检查：旧 current 快照检查作废，重新检查新 current；pending 已被换帧消费，不应再作为第三次检查。

## xsim

本轮全量 Icarus 最终输出 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=229`，退出码 0；所有新增配置均包含在这次全量运行中。

使用预览显示和寄存故障广播：

- `capture_guard_vsync_reject_20260911`：模式 5，complete / exit 0，9.210 秒；`checks=2 swaps=2 nn_jobs=2 captures=3 no_writer_start=1 committed_display_retained=1`。
- `capture_guard_vsync_legal_20260911`：模式 6，complete / exit 0，9.233 秒；`checks=2 swaps=2 legal_retry_started=1`。

WMI detached 启动，不绑定 Codex Windows Job，无波形。两个 `case1/sim/soc_control_run_<id>` 临时目录均确认不存在，仅保留两组共 8026 字节文本日志。

## 修改及复现

仅修改测试及 runner，生产 RTL 本轮未改。xsim 的 CaptureGuardPublish 现在支持模式 1..6。

```powershell
& case1/scripts/run_soc_control_xsim_detached.ps1 -RunId <new-id> `
  -PreviewDisplay -RegisterFatalTicket -CaptureGuardPublish 5
# 合法对照使用 CaptureGuardPublish 6。
& case1/scripts/run_iverilog_review_fixes.ps1 -Python <python-path> -TestTop tb_c1_r1_soc_control
```

## 结论边界

已补齐真实控制器 VSYNC/current 元数据更新触发重新检查的证据；前一轮验证的是 NN 完成发布 pending，两者不是同一事件。

显示预取的 busy/primed 仍由行为模型提供，本轮不能证明物理 DDR 所有旧读事务的退休，也未检查实际显示像素。捕获启动后的持续区域占用、后续新 writer 与活动捕获的冲突，以及 processed/preview/tensor 等其它写入口的全局隔离仍未完成。这个通过结果不意味着可以放松整体内存布局约束。
