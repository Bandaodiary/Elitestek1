# 已接纳帧的 RAW 停流检测

日期：2026-09-11。

## 新增能力

capture frontend 增加 `RAW_IDLE_TIMEOUT_CYCLES`，经 capture subsystem 和
portable SoC 逐级透传。默认 0 禁用；非零必须启用 CHECK_RAW_RASTER。
参数单位是 core 时钟周期，不是像素时钟、毫秒或帧率。

初始版本仅在 ST_STREAM、camera FIFO 输出无有效 token、入口仍有 output FIFO
余量时累计连续等待周期。输入到达、入口无余量、退出 ST_STREAM 时计数
清零。达到阈值的采样边沿报告 capture_error/code=0x06，并使用已有局部
flush 清除 ISP 像素状态和 RGB FIFO，保留 active 配置与 Gamma RAM。

超时进入 ST_RESYNC，等待后续 EOF 或合法 SOF 边界；**不**直接宣布完成，
不清空摄像头异步 FIFO，不复位 DDR writer，不释放外部缓冲区所有权。
现有控制器前端错误映射对应软件 0x46；本轮仅静态检查其通用映射，未做
0x46 整机运行验证。原 0x05 光栅错误路径保持不变。

## 测试

- 16/33 两种阈值 × camera 半周期 3/7 ns：已接纳 20 个 RAW token 后源停止。
- 对每个有效计数周期核对 fault 是否恰在阈值出现，检查 off-by-one。
- 超时后继续无输入 64 周期，要求 cleanup 保持、begin_ready 关闭、没有
  RGB/ingress_done 泄漏，硬件错误码为 0x06。
- 源恢复为下一完整帧后，不 reset、不重写 ISP/Gamma，逐像素检查 20 个
  RGB 及帧标记，确认下一 SOF 保留。
- 另以 16-entry camera FIFO 和阈值 16，复测两种时钟下正常双帧背压场景，
  要求无误报；原默认禁用超时的长暂停/取消测试继续保留。

共新增 6 配置。最终全量 Icarus **541 配置通过**，退出码 0；上一轮基线
535。运行 `case1/scripts/run_iverilog_review_fixes.ps1 -Python <含 NumPy 的 Python>`。
本轮未生成波形，沿用脚本 finally 清理本次临时镜像和向量。

## 配置与剩余工作

阈值必须大于传感器在帧内的最大合法停顿，计入行消隐、时钟比、CDC 可见性
延迟以及主动暂停；不能直接把本测试的 16/33 周期用于真实摄像头。
目前为综合期参数，未增加 APB 配置寄存器。

本功能检测帧内停流，不是墙钟帧截止时间。后续修复已覆盖有 ISP 帧状态的
取消尾部排空，见 [取消排空停流修复](RTL_RAW_CANCEL_IDLE_TIMEOUT_20260911.md)。
启动前、静默维护、ST_RESYNC 中不累计新超时；正常采集的持续下游阻塞也不会触发它。
永久停流可被报告，但安全退出仍需要明确的源重置/重新同步契约，尚未设计
强制释放途径。后续应验证实际控制器 0x46 错误、在途 AXI 排空、停流发生于
取消阶段及软件驱动复位摄像头后的恢复。默认开关不变，未跑 EDA 综合/时序。
