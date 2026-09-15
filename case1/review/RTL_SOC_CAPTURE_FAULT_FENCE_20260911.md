# SoC 控制器的 RAW 错误与物理缓冲区保持验证

日期：2026-09-11。

## 检查发现与本轮改动

实际 `c1_r1_soc_control.sv` 已具备以下机制，本轮未发现需要修改该逻辑的反例：

- operation_enable 时，capture_error 产生 fatal，RAW 0x05 映射为软件错误 0x45。
- manager_abort 驱动 capture_abort_frame、capture_writer_cancel 和 capture_clear_error。
- 逻辑所有权可在取消时清空，但 input_region_cancel_hold_q 保留物理地址快照。
- capture_cleanup_fence_q 等待前端 cleanup、writer busy 和表读取排空。
- 启用 FENCE_FABRIC_DRAIN 时，共享总线未静止也阻止物理区域释放。

此前定向测试主要在该占用场景下发出软件 abort；缺少 RAW fatal 自动传播与
不同尾部完成顺序的组合。本轮扩充 `tb_c1_r1_soc_control.sv`，添加
`CAPTURE_FAULT_DRAIN=1/2`，并将新配置纳入常规 Icarus 回归。生产 RTL 不变。

## 新场景

启动并实际经过控制器的表响应、区域检查、捕获 writer_start，建立 slot 0
的物理区域记录（0x00100000）。随后注入 RAW 错误 0x05，检查取消扇出、
软件错误 0x45、地址 0、错误仅报告一次。

每个场景按顺序检查三个 20-cycle 等待窗口：

1. writer、前端 cleanup 和共享写总线全部未结束。
2. 顺序一先结束 writer；顺序二先结束前端 cleanup。另一个叶端仍未结束。
3. 两个叶端均已结束，但共享写总线仍未静止。

每拍要求 BUSY 为 1、原物理区域有效且地址未变、逻辑 owned mask 为 0、
没有新的 capture_begin_frame/writer_start，错误数不增加。最后放开共享写
排空条件，检查 BUSY 和物理记录正确释放，再无复位启动并复用相同地址。

两种顺序 × REGISTER_FATAL_TICKET 关闭/开启，共 **4 个新配置通过**。
控制器整组 Icarus **172 配置通过**，进程退出码 0。命令为
`case1/scripts/run_iverilog_review_fixes.ps1 -Python <含 NumPy 的 Python> -TestTop tb_c1_r1_soc_control`。

## 证据边界

这里实例化的是真实 SoC 控制器、帧管理及地址保护逻辑；前端 cleanup、writer
busy 和 fabric quiescent 仍是测试驱动的输入，没有实例化真实 RAW/DDR 数据通路。
因此，这份证据与上一轮真实 capture subsystem/AXI writer 测试互补，但不能
替代一次完整 portable SoC 故障注入，也不能把“叶端模型忙信号”说成真实 B 响应。

本轮没有改生产 RTL、没有测量资源/时序、没有运行 Efinity/Vivado；不将已有
521 配置全量结果冒称为新增测试后的全量结果。CHECK_RAW_RASTER 默认仍关闭。

下一步仍是让真实 RAW guard 错误经实际 SoC 控制器取消实际 writer，并由
共享 DDR 模型延迟 B，核对物理区域记录、恢复分配及新帧像素，覆盖寄存错误路径。
