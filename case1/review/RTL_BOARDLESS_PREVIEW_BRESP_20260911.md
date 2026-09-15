# Boardless 预览 BRESP 错误与恢复

日期：2026-09-11。本轮仅增强真实接入路径的测试和 runner，未改生产 RTL。

## 场景

在 ENABLE_PREVIEW 的 boardless 系统中连续运行三任务：正常、预览 SLVERR、
无复位正常恢复。第二任务接受三笔预览 AW、六个 W beat、前两个 B 后，
将最后 B 阻塞。在阻塞阶段连续 24 cycles 提出新任务，检查 busy 为高、
start_ready 为低、没有终止通知；然后撤回该请求，释放最后 B，并让它
携带 BRESP=2（SLVERR）。本模式不由 testbench 发出软件 abort，错误应经
真实 preview writer → preview runtime → frontend/job controller 上报。

要求 job_error，错误码 0x63、错误地址 0x6000，不能误报 job_done 或
job_aborted。上报时所有已提交读写与预览 B 已退休。任务接受后已将实时
预览基址/stride 改坏，因此同时验证错误地址仍取原任务快照。

第三任务不复位，检查处理后输出和 24 个预览像素、3 AW/6 W/3 B 全部正确。
最终任务计数必须为 3 accepted、2 done、1 error、0 aborted。

## 结果

`review_preview_boardless_bresp_final_20260911` complete/exit=0：

`C1_BOARDLESS_PREVIEW_ERROR_PASS jobs=3 done=2 errors=1 bresp=2 code=63 address=00006000 held_cycles=24 no_reset=1 recovery_pixels=24`

同一 testbench 重新运行软件取消模式
`review_preview_boardless_cancel_compat_final_20260911` 也通过：
3 accepted、2 done、1 aborted、0 error。两者旧描述符完成位重置的实际
覆盖计数均为 1。没有发现需要额外修改生产 RTL 的新缺陷。

```powershell
& case1/scripts/run_r1_boardless_frame_system_xsim_detached.ps1 -RunId <unique-id> -Preview -PreviewError
```

PreviewError 要求 Preview，且与 PreviewCancel 互斥；runner 要求唯一的
预览专属和错误专属 PASS。新增 BRESP 连续赋值首次位于 preview_row 声明
之前，导致两个早期运行编译失败；移到声明之后修正。失败记录不计成功。

四个运行的临时目录均已清理，独立 WMI worker 不绑定 Codex Windows Job。
无波形；精简日志保留。本轮没有重跑 Icarus 全量、整机 CNN golden 或综合，
不把上一轮 145 配置结果当作本轮新结果。

## 边界

这是最后一笔预览 B 的 SLVERR 测试，不是每笔响应/DECERR/协议畸形的穷举。
24-cycle 强制阻塞发生在错误 B 被呈现前，不等于错误通知后又阻塞 24 cycles。
boardless 的 CNN 仍为行为 loopback；最外层 SoC 预览 master、地址互斥预检、
元数据与显示选择仍未完成，也没有新帧率或资源结论。
