# 任务控制器复位边界加固

日期：2026-09-11。

## 修改与适用边界

`rtl/control/c1_r1_job_controller.sv` 原先仅在 `start_ready` 中屏蔽 `rst`，但预检请求 valid、预检响应 ready 和三个运行端 start 仍由旧状态组合产生。在复位已经拉高、同步状态尚未清零的窗口内，接口仍可能呈现握手。

本轮在上述五处组合条件中增加 `!rst`，使控制器在复位期间不再发起新预检、接收新预检结果或启动 DMA/engine。正常任务的状态转换、三路原子启动、错误优先级、watchdog 以及 abort 排空规则不变；未增加端口、状态或流水级。

这是加强接口复位契约：若所有收发模块在同一时钟沿使用同一个同步复位并且都优先处理复位，旧实现未必造成实际事务。本轮反例证明的是旧实现不满足“复位期间握手立即静默”的更强约束，不应据此声称已经发现板级数据损坏。

本修改不提供独立复位域之间的完整协议恢复，不是 CDC 修复，也不使运行中强制 reset 成为安全取消方式。已有 AXI 事务必须继续使用 abort/drain，系统复位仍须协调 fabric 和外设。

## 验证

在既有 `sim/tb_c1_r1_job_controller.sv` 增加独立参数场景 `RESET_BOUNDARY=1..3`：

1. 预检请求尚未接受时复位，同时令下游 ready 和响应 valid 有效。
2. 预检请求已接受、尚未返回结果时复位。
3. 预检成功、运行端尚未启动时复位，同时令三个运行端 ready 有效。

每个场景均在复位后的第一个时钟沿之前直接检查握手输出，避免 testbench 的同步复位分支把问题隐藏；随后验证没有迟到启动/终止，并重新运行一个完整成功任务。

先加测试、后改生产 RTL：旧实现首先在场景 1 失败，实际诊断为 `reset leaked handshake stage=1 req=11 rsp=11 launch=000`。本轮没有逐一运行旧实现的场景 2/3，不能将它们列为已复现的旧版本失败。

修复后定向四配置全部通过：原有测试覆盖 26 个任务（17 成功、7 错误、2 取消），另有上述三个复位/恢复场景。原有控制器测试此前未列入 `run_iverilog_review_fixes.ps1`，本轮一并纳入，避免只执行新增场景而遗漏原有生命周期验证。

随后全量 Icarus 回归正常结束，退出码 0，摘要为 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=283`。该数字是测试配置数，不是任务数或板级测试数。包含原有 279 配置以及本轮补入的控制器基线和三个复位配置。

复验命令：

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -TestTop tb_c1_r1_job_controller
& case1/scripts/run_iverilog_review_fixes.ps1 -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
```

## 尚未完成

本轮没有实现 output、preview、tensor 与 capture 之间的统一区域申请仲裁，也没有改变现有输入区域快照和身份校验。该工作仍应按 `RTL_REGION_LIFETIME_CONTRACT_20260911.md` 推进，不能通过独立门控某一路 start 破坏计算任务的原子启动。

未运行 Vivado/Efinity，未生成波形；不涉及工具链进程绑定或新的时序/资源结果。
