# 输入身份校验：原始错误优先级与取消排空

日期：2026-09-11。

本轮检查新增 `0x34` 输入身份错误是否会掩盖其它预检故障。未修改生产 RTL，只扩展 frontend testbench 和常规回归清单。

## 新增测试

`INPUT_SNAPSHOT_CASE=7/8/9` 均将捕获身份 valid 清零，同时制造以下事件：

| 模式 | 注入 | 必须保留的行为 |
| --- | --- | --- |
| 7 | 输入表项 AXI 读返回错误 | 报 0x10 和输入表项地址，而不是 0x34 |
| 8 | 输出表项 AXI 读返回错误 | 报 0x11 和输出表项地址，而不是 0x34 |
| 9 | 首个 ARVALID 被背压时取消预检 | ARVALID 保持；背压 5 拍内不提前 aborted、不报身份错误；READY 恢复后提交并排空，最后 aborted |

所有用例要求失败/取消的任务没有运行端启动，没有成功 done；然后重新提供有效身份，在无复位条件下完成下一次合法任务。模式 9 沿用公共 AXI 稳定性检查器。

两种输入几何 × 两种 preview-layout 开关 × 三种场景，共 12 个新增配置。最终 frontend 定向回归 **38 配置通过**，含原 2 个完整流程及 36 个身份配置用例。

## 复现

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -Python <python-path> -TestTop tb_c1_r1_job_frontend
```

本轮未启动 Vivado/xsim，不生成波形，使用现有 Icarus runner 的 finally 清理。当前全量清单为 279 配置，但本轮未全量重跑；最近完整运行是上一轮 267 配置通过。

## 边界

这里验证的是 frontend 在随机 AR/R 间隔内的错误优先级、取消退休及恢复，不是 CPU 实际改写 DDR 表项的整机故障注入。其它 writer 的统一区域申请仲裁仍未完成，也不能据此宣称全系统内存隔离。
