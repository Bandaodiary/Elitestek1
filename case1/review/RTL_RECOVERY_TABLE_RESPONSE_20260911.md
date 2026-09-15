# 显式恢复与待取表响应的组合验证

日期：2026-09-11。

上轮已验证 writer 和在途 AR/R 取消，但未开启表响应 FIFO。本轮扩充
`tb_c1_capture_raster_writer_drain.sv` 的 TABLE_FIFO=0/1 和 TABLE_INFLIGHT=2。
模式 2 表示先完成表 AR/R，再让 table_response_ready 持续为 0，制造
控制器尚未接受的表响应，不是未完成的总线事务。

恢复前连续 8 周期检查表响应有效并保持。其后实际 RAW 错误触发显式
恢复，要求自动取消清除响应、在真实 writer 排空前不复位。恢复后检查
table_response_valid 为 0，新帧在新地址写回的 20 个 RGB 像素均正确。
此处表读取数据由测试返回固定值，用于验证生命周期，不用于新帧地址分配；
新帧地址仍由现有 testbench 直接提供，不能当作 SoC 表项寻址正确性的证据。

## 矩阵与结果

显式恢复部分：AW/W/B 三类阻塞 × 两种 camera 时钟 × 直连/缓存两种
表响应配置 × 无表事务/在途 AR-R/待取响应三种表状态，共 36 配置。
加上原 24 个 RAW writer 回归，定向整组 **60 配置通过**，退出码 0。
相较上一轮 36 个定向配置，本轮新增 24 配置。生产 RTL 未修改。

执行入口：`run_iverilog_review_fixes.ps1 -Python <含 NumPy 的 Python> -TestTop tb_c1_capture_raster_writer_drain`。
无波形，临时编译镜像与向量由 runner 清理；本轮未重跑全量或整机 xsim。

这项结果补齐了实际表响应 FIFO 与取消连接的测试证据，不能替代尚未实现
的 portable SoC/APB 显式恢复接口、共享缓冲区所有权及源静止确认。
