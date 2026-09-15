# 取消与显示所有权：组合验证及地址隔离边界

日期：2026-09-11。

## 本轮结果

扩展 `case1/sim/tb_c1_preview_pair_ownership.sv`，使用真实 `c1_frame_manager` 和 `c1_r1_runtime_join`，验证成功画面存在时取消另一个任务。计算/预览子模块的 busy、done 以及显示排空仍由测试模型驱动，不是整机物理 DDR 像素验证。

新增覆盖：

1. 第三个完成的图像对尚未显示时，abort 与 VSYNC 同拍；不发布被取消图像，保留第二帧的 input/output 槽与 frame ID。
2. 后续任务在计算完成、预览仍 busy 时收到单拍取消。取消后继续保持预览 busy 10 拍，join 不接受新任务、不产生成功 done，当前显示槽和 ID 保持不变。
3. 预览 busy 真正退休后，无复位启动下一帧，只复用非显示槽，成功完成后再换帧。
4. 新增持续断言：capture 分配不能使用仍属于 display 的输入槽。原有输出/预览槽排他断言保留。

结果：`C1_PREVIEW_PAIR_CANCEL_PASS pending_vsync=1 active_cancel=1 drain_hold=10 jobs=5 swaps=3 no_reset=1`。

已有 `tb_c1_frame_manager_ready_fifo` 此前有独立 xsim 脚本，但未进入 review-fixes 常规回归。本轮加入该测试，覆盖 READY 队列同时出入队、drop-oldest、取消保留显示。定向测试通过；全量 `run_iverilog_review_fixes.ps1` 重跑 **187 配置通过**。

## 生产 RTL 检查结论

未新增修改生产功能逻辑，仅在 `case1/rtl/control/c1_frame_manager.sv` 头部补充准确的集成约束：

- 帧管理器跟踪槽号和所有权，不知道物理地址。`IN_DISPLAY` / `OUT_DISPLAY` 不被分配，不代表不同槽号映射的物理内存一定不重叠。
- abort 当拍释放非显示槽的内部状态，不表示 AXI 请求已撤销。父级必须在 DMA 排空前阻止新捕获和计算任务。测试中的 join 只证明计算/预览任务入口的等待契约；捕获端还依赖 SoC 的 cleanup fence。

源码依据：`c1_r1_soc_control.sv` 的 START 配置快照、`capture_cleanup_fence_q` 和 current 显示元数据；`c1_frame_triple_layout_check.sv` 的输入/处理/预览三帧范围检查；portable SoC 中固定预览双槽分配检查。

## 仍需完善：跨任务的物理地址隔离

当前单任务三帧检查仅比较该任务的输入、处理和预览帧，不是全系统内存保护器。若软件把不同槽表项配置成同一物理区域，或在已有成功画面时让新任务的写地址映射到该画面，槽号所有权本身不能提供完整保护。current 显示元数据快照只能固定读地址，不能阻止另一个写客户端覆盖该地址。

因此目前集成要求仍是：所有活动槽与参数/描述符/tensor 等内存用途由软件/工程布局保持合法且不重叠；不能在显示仍持有区域时通过表项重映射绕过该约束。本轮没有宣称已实现硬件级跨任务隔离。

后续应在写入启动之前验证新 capture/processed/preview 范围与仍持有的显示范围，并确定 tensor arena 等其它 writer 的隔离契约；保护必须覆盖真实写入口，而不是仅给孤立比较模块增加测试。已有成功画面时的整机故障注入及实际像素保留仍需进一步验证。

## 复现与产物

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -Python <python-path> -TestTop tb_c1_preview_pair_ownership
& case1/scripts/run_iverilog_review_fixes.ps1 -Python <python-path> -TestTop tb_c1_frame_manager_ready_fifo
& case1/scripts/run_iverilog_review_fixes.ps1 -Python <python-path>
```

本轮未启动 Vivado，未生成波形。沿用 Icarus runner 的 finally 清理编译镜像和本次生成的向量文件。测试规模和模型边界不支持原生分辨率吞吐、真实 DDR 物理隔离或板级时序结论。
