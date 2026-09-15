# 输入区域正常释放与 drop-oldest 回收验证

日期：2026-09-11。

## 本轮结果

针对上一轮新增的输入区域快照，补齐其正常释放和回收语义，未修改生产 RTL。

`INPUT_REGION_CASE=5/6/7` 阻止 NN 启动，先让真实控制器/帧管理器将三个输入槽全部填为 READY_NN，物理区域分别位于 0x00100000、0x01000000、0x02000000，再发起第四次捕获，触发真实 drop-oldest 分配：

- 模式 5：回收 slot 0 并改用 0x03000000，合法启动并更新该槽快照；slot 1/2 快照保持不变。
- 模式 6：回收 slot 0 却指向 slot 1 的 0x01000010，必须在 writer-start / begin-frame 前拒绝，报告一次 0x31 及正确地址。排除“自己”不能变成绕过其它槽检查。
- 模式 7：回收 slot 0 并重用原地址 0x00100000，合法启动，无需 reset。

每个模式均要求 captures=4、drops=1、nn_jobs=0，直接和寄存故障广播各运行一次，共 6 个新增配置。

此外，已有 VSYNC 竞争模式 5/6 新增断言：真实第二次换帧提交后，旧 input slot 0 的 region valid 必须清零，当前 slot 1 仍有效，物理快照为 0x01000000。没有通过强制内部状态制造释放。

## 验证范围

控制器定向回归 **80 配置通过**，包括上述新增测试和加强后的 VSYNC 断言。当前全量清单共有 243 配置，但本轮未重新运行全部；最近全量结果仍是上一轮 237 配置通过，不能混写为 243 全量通过。

两组 xsim 使用寄存故障广播交叉验证：

| 运行 ID | 模式 | 结果 |
| --- | --- | --- |
| input_region_recycle_20260911 | 5 | complete / exit 0，8.200 秒 |
| input_region_recycle_alias_20260911 | 6 | complete / exit 0，9.222 秒 |

使用已有 WMI detached 启动，不绑定 Codex Windows Job，没有波形。对应两个 `case1/sim/soc_control_run_<id>` 目录均确认不存在，保留文本日志合计 7009 字节。

## 修改和复现

- `tb_c1_r1_soc_control.sv`：新增 READY 捕获辅助 task、三种回收场景及 VSYNC 快照释放断言。
- `run_iverilog_review_fixes.ps1`：纳入三种新场景的两类故障广播配置。
- `run_soc_control_xsim_detached.ps1`：InputRegionCase 扩展为 1..7。

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -Python <python-path> -TestTop tb_c1_r1_soc_control
& case1/scripts/run_soc_control_xsim_detached.ps1 -RunId <new-id> `
  -RegisterFatalTicket -InputRegionCase 5
```

## 尚未完成

本轮是控制器与真实槽管理逻辑验证，DMA 数据仍由行为模型提供，不是实际 DDR 图像回收测试。其它 writer 对活动输入/输出区域的统一申请检查、计算消费者重新解析表项与捕获快照的一致性、以及完整并行区域申请仲裁仍需实现。已有输入保护不能替代这些工作。
