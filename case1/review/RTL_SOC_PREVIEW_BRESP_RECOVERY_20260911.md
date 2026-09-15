# 预览 BRESP 故障后的无复位重算

## 变更

在上一轮 `-PreviewBrespError` 基础上新增 `-PreviewBrespRecovery`：
第一帧末 B 延迟并返回一次 SLVERR，严格完成已有排空、错误码和零发布
检查后，通过 APB 确认 IRQ、恢复下一任务几何配置、发 START，再送一帧。
不复位 DUT，不修改内部 RTL 状态，不擦除 DDR，不清零总线事务/错误计数。
仅在确认排空后重置 testbench 的每帧像素计数和物理写覆盖位图；这样旧帧
写入不能冒充恢复帧的写入。注入计数保持为 1，后续合法 B 不再注入错误。

第一帧部分 CNN 结果不纳入成功帧数值轨迹；故障的计数/排空证据独立保留。
第二帧重新启用 CNN 与预览数值导出，沿用完整 22 层、处理图 DDR、预览 DDR、
原图/处理图显示的 golden 检查。错误总数保持 1，成功总数应为 1，采集共 2 次。

## 独立验证门槛

Python 新增 `--require-preview-recovery`，要求：

- 唯一故障记录：末 B 至少等待 64 cycles，0x63/0x01000000，未发布、已排空。
- 唯一恢复记录：errors=1 / done=1 / captures=2 / injected=1 / reset=0。
- 日志中故障先于恢复，且恢复帧必须通过既有独立预览与 CNN golden。

新增负向变异覆盖删除/重复恢复记录、伪报使用复位、缺少第二次采集、
缺少故障记录、未等待 B、错误发布和颠倒故障/成功顺序。日志仅在内存中变异。
预览槽绑定负向测试改为根据实际槽号取反，不再假定总是 slot 0。

## 调试与证据保留

1. `review_soc_preview_bresp_recovery_20260911`：测试代码把 packed 常量赋给
   unpacked 写覆盖数组，xvlog 拒绝；改为逐项清零。
2. `review_soc_preview_bresp_recovery_final_20260911`：RTL 仿真 complete，
   78.828 s，但压缩日志漏掉第一阶段故障记录，Python 正确拒绝不完整证据。
   没有凭成功标记绕过检查，也没有补写历史日志。
3. runner 现在逐行保留 `C1_SOC_PREVIEW_BRESP_` 标记及其顺序/重复，恢复
   模式要求唯一故障记录和预览写回记录。小日志策略不变，无需保留大临时树。

最终证据运行：`review_soc_preview_bresp_recovery_evidence_20260911`。

结果 complete / exit 0，81.869 s。独立 Python 验证通过：故障先排空，随后
无复位恢复；64 个预览 DDR 像素、64 个 CNN 输入、22 层 836 个 C8 结果、
64 个处理图 DDR 像素、120 个原图显示像素和 64 个处理图显示像素全部匹配。
整个故障+恢复运行共 943 AW / 1007 W / 943 B，峰值 outstanding=2，
W-ahead=16；成功任务仅 1 个，累计错误仍为 1。

检查器 56 项负向变异通过，其中恢复证据新增 8 项；既有无错误预览日志
检查器兼容测试也通过。原单次故障模式复跑
`review_soc_preview_bresp_single_compat_20260911` 通过，13.301 s。
本轮未重跑全量 Icarus 155 配置，不新增资源或物理时序结论。

```powershell
& <python.exe> case1/golden/check_portable_soc_numerical_trace.py `
  case1/logs/portable_soc_cache_ddr_bfm_runs/review_soc_preview_bresp_recovery_evidence_20260911 `
  --require-preview-recovery --require-video --require-queued-write
```

## 范围

生产 RTL 本轮没有修改；这是八客户端系统错误恢复证据的补齐。两槽连续
成功、末 B 阻塞下的软件取消，以及预览显示元数据/源切换仍需继续完成。
