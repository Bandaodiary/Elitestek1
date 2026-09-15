# capture subsystem 显式恢复接入

日期：2026-09-11。

在 capture subsystem 新增默认关闭 ENABLE_EXPLICIT_RECOVERY 和尾部恢复
接口，将前端恢复 ready/busy/done 透出。尚未接入 portable SoC 或 APB。

## 真实排空条件

恢复接纳后，recovery_busy 自动驱动 writer cancel 和表读取 abort fence，
禁止新的 writer_start、table request 接纳。表读取已提出的 AR 仍由原
abort fence 保持到握手；请求握手后原 reader 排空 R，并丢弃取消响应。
启用 table response FIFO 的分支同时收到取消，避免旧响应滞留。

传给前端的安全条件不再只是外部 recovery_fabric_drained，还必须满足：
writer 不 busy、无 AW/W VALID、表 reader 内部 ready、无 AR VALID 和
无 pending abort。必须使用内部 table_leaf_ready，不能用恢复期间主动
拉低的外部 table_request_ready，否则会形成永远不能完成的等待。
source_quiescent 仍必须由外部源停止确认提供，模块不会自行推测。

因此，即使调用者提前给出外部 fabric-drained，模块也不会在自身已提交
的 B/R 响应未退休时开始清理。这个检查只涵盖本 subsystem 的叶端；
外部共享 fabric 的其他排队事务仍由集成方负责确认。

## 测试

扩充真实 `tb_c1_capture_raster_writer_drain`：3 种 AW/W/B 阻塞 × 两种
camera 半周期 3/7 ns × 是否有在途表读取，共 12 个显式恢复配置。

- 实际 ISP 已输出首行，writer 已提交事务；坏 RAW 触发 0x05 后发 recovery
  request，不发外部 writer_cancel。
- 外部 fabric-drained 始终为 1，验证内部门槛仍阻止过早 FIFO reset。
- 冻结写通道 24 周期，busy 保持且不能接纳新 capture/table。
- 在途表读取配置先保持 ARREADY=0。写端排空后额外 12 周期验证 ARVALID
  不撤回、不开始复位；接受 AR 后再延迟 R 12 周期，仍不能完成恢复。
- R 退休后没有取消响应泄漏；清理完成后不 reset、不重写 ISP/Gamma，
  在新地址写回干净帧，检查 20 个 XRGB 像素以及 AW/W/B 数量。
- request 持续为高，不重触发复位；原 24 个非显式恢复配置继续保留。

定向整组 Icarus **36 配置通过**，退出码 0，包含上述新增 12 配置及原有
24 配置。命令：`run_iverilog_review_fixes.ps1 -Python <含 NumPy 的 Python> -TestTop tb_c1_capture_raster_writer_drain`。
未重跑全量、xsim 或 Efinity。

## 待完成

当前恢复端口仅到 subsystem。SoC 层需关闭接纳、保持物理地址记录，
等待共享 fabric 全部退休和 recovery_done，软件需有明确命令和源静止
确认。不能把子系统测试当作整机软件强制恢复已完成。
表响应 FIFO 取消连接在本文件对应轮次尚未测试；后续已补齐直连/缓存与
待取响应组合，见 [表响应恢复验证](RTL_RECOVERY_TABLE_RESPONSE_20260911.md)。
当前表模型正常单 beat R 响应，未覆盖错误 R/B 或不可恢复的时钟停止。
