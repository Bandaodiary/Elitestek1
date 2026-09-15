# 捕获启动前的活动显示范围检查

日期：2026-09-11。

## 已实现的修复

`c1_r1_soc_control.sv` 在合法捕获表项响应与 writer 启动之间加入 PREP、WAIT、COMMIT 三个状态。表项中的基址、stride 和尺寸先锁存，再使用 `c1_frame_triple_layout_check` 的写读配对模式检查当前显示图像对及待显示图像对。两轮均通过后，重新确认 ingress ready、writer idle 和无 fatal，才同时发出 `capture_writer_start` / `capture_begin_frame`。

地址重叠或保护范围本身不合法时，使用已有 `ERR_CAPTURE_CONFIG=0x31` 报告捕获基址，进入原取消/排空处理，不启动写入。比较使用完整有效行，保留 4 GiB 半开末端、合法 padding 共享和读读别名语义。

保护元数据在各次检查请求时由比较器快照。检查期间出现 `manager_display_swap` 或 `boardless_done` 时，sticky dirty 标志使本轮结果失效，从当前图像对重新检查；COMMIT 也检查当拍变化。没有用可能回绕的有限版本计数器。取消同时清除控制状态和未完成比较，不伪造任何外部 AXI 完成。

## 测试修正与结果

新增检查发现旧正常恢复测试的 `0x00400000` 捕获区域与首帧预览 `0x00300000`、stride=4096、height=480 的有效行存在真实重叠。正常测试改为独立的 `0x01000000`，相关第二帧原图快照和错误地址期望同步更新。保留专门的重叠安全测试，未放宽生产保护。

| 验证 | 结果 |
| --- | --- |
| 当前原图/预览起址别名、风格图起址别名、风格图+16 部分重叠 | 两种显示模式 × 两种故障广播 × 三种别名，共 12 组通过 |
| 安全拒绝 | 无 writer-start / begin-frame，恰好一次错误，code=0x31、错误地址正确，保留当前显示 |
| 检查中取消 | 两种显示模式 × 两种故障广播，共 4 组通过；80 拍无迟到启动/响应 |
| 旧控制器回归 | 26 组通过 |
| 全量 Icarus | 201 配置通过；该运行启动时尚未加入取消的 4 配置 |
| 最终控制器定向 | 含新增取消配置共 42 组通过 |
| xsim：预览模式、寄存故障、部分重叠 | complete / exit 0，9.213 秒 |
| xsim：预览模式、寄存故障、检查中取消 | complete / exit 0，9.226 秒 |

最新回归清单共有 205 配置，但本轮不把“201 全量 + 42 控制器定向”表述为重新完成了单次 205 全量运行。

## 修改与复现入口

- 生产：`case1/rtl/top/c1_r1_soc_control.sv`。
- 测试：`case1/sim/tb_c1_r1_soc_control.sv`，`CAPTURE_DISPLAY_ALIAS=1/2/3` 或 `CAPTURE_GUARD_CANCEL=1`。
- Icarus：`case1/scripts/run_iverilog_review_fixes.ps1`，新增安全用例进入正常通过清单。
- xsim：`case1/scripts/run_soc_control_xsim_detached.ps1`，加入比较器源文件和独立安全验证选项，禁止混用冲突场景。

```powershell
& case1/scripts/run_soc_control_xsim_detached.ps1 -RunId <new-id> `
  -PreviewDisplay -RegisterFatalTicket -CaptureDisplayAlias 3
# 取消测试改用 -CaptureGuardCancel，不能与 CaptureDisplayAlias 同用。
```

实际日志：`case1/logs/soc_control_runs/capture_display_guard_alias_20260911` 和 `capture_display_guard_cancel_20260911`。均采用 WMI 脱离 Codex Windows Job 启动，没有波形；确认两个 `case1/sim/soc_control_run_<id>` 临时目录均已删除，仅保留共 7960 字节文本记录。

## 尚未完成与严格边界

这是对已复现缺陷的**真实捕获入口启动前保护**，不是完整内存隔离：

- 本轮定向测试证明当前显示区域重叠拒绝与取消行为。待显示分支及检查期间 metadata 变化重试已实现，但还需专门构造竞争场景验证，不能把代码检查当成完成验证。
- 捕获启动后若其它任务后来发布一个与该写区域别名的图像，仍需统一的活动区域占用/退休机制阻止冲突。启动前检查不能替代持续占用。
- 处理图、预览、tensor 等其它写入口的跨任务隔离未在本轮补齐。软件仍须遵守合法且互不冲突的整体内存布局。
- 未新增证明已经退休与尚未退休的旧显示读事务在所有场景下的范围保留；不得宣称整个 AXI 系统都已隔离。
- 本轮没有重跑真实 CNN 双帧像素仿真、物理综合、时序或板测；已有这些结果属于此前版本证据。新增检查延迟与资源影响仍需实测。

因此 `RTL_CAPTURE_DISPLAY_ALIAS_20260911.md` 中六种启动漏洞已转为回归通过，但整体活动区域管理目标仍未完成。
