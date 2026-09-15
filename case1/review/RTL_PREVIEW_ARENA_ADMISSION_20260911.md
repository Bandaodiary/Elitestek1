# 预览 DDR 分区准入检查

## 问题与修复

此前三帧检查只保证地址不溢出及有效像素行不重叠，静态预览分区仅由
`c1_axi_xrgb_frame_writer` 在运行时检查。因此不重叠但超出指定分区的布局
仍可通过 frontend，让 DMA/CNN 启动后再取消；这是可提前拒绝的配置错误。

`c1_frame_triple_layout_check` 新增 `PREVIEW_REGION_BEGIN/END` 参数，默认
覆盖完整 32-bit 地址空间。在预览帧的 EXTENT 阶段复用现有 49-bit 串行
计算，验证 `[base, base+(height-1)*stride+width*4)` 完整跨度位于分区内。
允许 exclusive end 恰好等于分区终点；空区间、反向区间及 END 超过 4 GiB
均拒绝。不新增乘法器或检查状态，但没有进行物理资源和时序测量。

boardless → frontend → checker 与 boardless → preview runtime → writer
使用同一组参数。writer 的二次检查保留。frontend 上报 0x32 和预览基址；
几何检查优先，跨度/分区检查其次，三帧重叠检查最后。故同时违反分区及
重叠约束的布局现在上报 0x32，而不是 0x33。

## 验证

- Icarus 检查器原有 213 次核对通过，包括 200 次随机行重叠参考核对。
- 新增四种分区配置共 12 次核对：合法终点、起点不足、末行越界、padding
  增大跨度、单行、无复位恢复，以及空/反向/超地址空间分区。均通过。
- xsim `review_preview_arena_final_20260911`：九任务通过，2 done / 6 error /
  1 aborted。输入/输出地址别名、非法 stride、地址溢出、分区下溢/上溢
  六种拒绝路径均检查实际 input/output DMA 和 engine start 未发生。
  检查中取消后可无复位成功执行下一任务。CNN 为行为模型，非完整模型数值验证。
- 133 个 RTL 源文件的 queued-write SoC 编译通过：0 errors，608 工具诊断。
- 全量 Icarus 回归通过：`C1_REVIEW_FIXES_REGRESSION_PASS configurations=150`。
- xsim 由现有 WMI 脱离 Windows Job 启动，无波形；最终运行临时目录已删除，
  仅保留小日志。没有调用 Efinity 或进行板卡验证。

## 边界

静态分区不是动态内存所有权系统。该检查不能证明分区与所有 tensor、权重、
描述符或其他活动帧隔离；系统集成仍需给出一致的内存分配与租约约束。
最外层 portable SoC 的预览 AXI master、双缓冲元数据和显示选择仍待接入。
