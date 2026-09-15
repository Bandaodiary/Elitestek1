# 捕获启动预检与 NN 完成发布竞争

日期：2026-09-11。

## 本轮覆盖

扩展真实控制器测试，不修改生产 RTL，也不强制内部寄存器：首先完成首帧显示，第二次任务以 continuous 模式启动 NN，使用剩余输入槽启动第三次捕获。第二次 NN 的真实接口完成事件负责发布待显示元数据，构造预检期间保护范围变化。

新增参数 `CAPTURE_GUARD_PUBLISH`：

| 模式 | 发布时机 / 布局 | 期望与观察 |
| --- | --- | --- |
| 1 | 第三次捕获的当前显示比较进行中，第二次 NN 完成 | 旧检查作废；共 3 次比较请求；拒绝重叠写入 |
| 2 | 第三次捕获已到 CAP_GUARD_COMMIT，第二次 NN 同拍完成 | 不发启动脉冲；共 3 次比较请求；拒绝重叠写入 |
| 3 | 第二次 NN 完成在第三次捕获之前，待显示图像已存在 | 比较当前与待显示两对；共 2 次比较请求；拒绝重叠写入 |
| 4 | 同模式 2，但第三次捕获位于不重叠区域 | 共 3 次比较请求；正常、成对发出 writer-start / begin-frame |

拒绝测试的捕获基址是 `0x00600010`，与新风格图 `0x00600000` 部分重叠；合法对照位于 `0x03000000`。完成之后立即污染 live resolved-output 引脚，检查必须依赖已接受的元数据快照。

拒绝测试要求无写启动、恰好一次 `0x31` 错误、错误地址正确、旧显示保留；捕获请求数必须为 3，NN 启动数必须为 2。合法测试要求重新检查而非误报，待显示状态仍保留。两种显示模式、两种故障广播配置下均运行以上四种场景。

这是控制器及真实槽分配逻辑的验证，计算、捕获和显示数据客户端仍是行为模型；不等于真实 DDR 像素或整机 CNN 竞争测试。

本轮完整运行最终回归清单，`C1_REVIEW_FIXES_REGRESSION_PASS configurations=221`，退出码 0。新增 16 配置全部包含在该次全量结果中。

## xsim 交叉验证

- `capture_guard_publish_commit_20260911`：预览显示、寄存故障广播、模式 2，complete / exit 0，9.211 秒。观察 `checks=3`、`nn_jobs=2`、`captures=3`、`no_writer_start=1`。
- `capture_guard_publish_legal_20260911`：同样配置、模式 4，complete / exit 0，9.233 秒。观察 `checks=3`、`legal_retry_started=1`。

使用已有 WMI detached runner，不绑定 Codex Windows Job，无波形。两个 `case1/sim/soc_control_run_<id>` 目录均确认不存在，仅保留两组日志共 8013 字节。

## 修改及复现

修改 testbench、Icarus 配置清单及 xsim runner，生产逻辑本轮未改。

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -Python <python-path> -TestTop tb_c1_r1_soc_control
& case1/scripts/run_soc_control_xsim_detached.ps1 -RunId <new-id> `
  -PreviewDisplay -RegisterFatalTicket -CaptureGuardPublish 2
```

xsim 的 CaptureGuardPublish=1..4 必须独立于地址别名、取消和 swap-collision 测试选项运行。

## 仍未覆盖的边界

本轮补齐的是 `boardless_done` 发布待显示图像所触发的重试，并非全部换帧竞争：实际 VSYNC 提交导致 current 元数据改变的定向重试还需验证。捕获已经启动之后的持续区域占用、其它 writer 的跨任务保护、未退休旧读事务的完整范围管理仍未完成。不能把启动前拒绝和本轮重试结果扩大为全系统内存隔离结论。
