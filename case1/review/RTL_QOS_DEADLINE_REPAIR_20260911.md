# QoS 帧期限监测修复

日期：2026-09-11。范围：生产 RTL 的 QoS 计量逻辑与对应验证，不改变 CNN、AXI 事务顺序、帧槽所有权或软件寄存器地址。

## 发现与修复

1. **空闲误报溢出**：原实现无条件检查 `&current_frame_cycles`。帧恰在计数器最大值结束后，空闲阶段仍会置位 `monitor_overflow`，尽管没有发生回绕。修复为仅在活动帧实际递增且没有新 start 时检测。
2. **回绕漏报超时**：原实现只比较截断后的 `next_frame_cycles`。16 位计数器执行 65536 cycles、期限 65535 时，记录周期为 0，超时次数不增加。新增单比特 `frame_wrapped_q`，本帧发生过回绕或终止当拍发生回绕，都算超出任意非零可表示期限。新帧、复位或 clear-stats 清除该位；不会把上一帧或其他诊断计数器的溢出当成本帧超时。
3. **顶层期限截断**：32 位参数直接取低 `SHARED_QOS_COUNTER_W` 位，可能把正期限转换成 0，关闭监测。现在采用常量钳位：超范围正值映射为计数器最大值，合法值及显式 0 保持不变，避免越界位选。

第 3 项属于保守告警：请求的期限大于计数范围时，可能提前判定超时。要准确使用更大的期限，必须增大 `SHARED_QOS_COUNTER_W`，不能依赖钳位。常量适配不需要运行时比较器。

保留原有周期递增结构与周期快照 ABI；`last_frame_cycles` 仍是计数位宽内的回绕值，`monitor_overflow` 仍为全局粘滞标志。新增位用于防止超时漏计，不是完整的 64 位计时扩展。期限仍按终止时输入比较，未新增动态期限锁存语义。QoS 是观察逻辑，不替代任务 watchdog，也不主动终止任务。

## 验证

先添加测试，再修生产代码，观察到两次预期失败：

```text
idle frame timer fabricated overflow cycles=65535
frame boundary cycles=65536 deadline=65535 last=0 miss_delta=0 overflow=1
```

修复后定向测试通过：真实时钟推进，不 force 内部计数器。覆盖最大值等于期限、终止当拍回绕、回绕后延迟终止、短帧不继承前帧回绕、期限 0 禁用、clear-stats，以及期限相等/超出一拍，共 7 项边界。

顶层 smoke 14 配置通过：新增 24 位期限 0x01000000、0x00ffffff、12345，以及 32 位期限 0xffffffff；原配置继续覆盖显式 0。各启用配置还运行原 orphan-B 协议锁定和复位恢复测试。

133 个源文件的 queued-write 顶层 Icarus 编译通过，0 errors / 608 工具诊断。本轮未运行 Vivado 或 Efinity，不能据此声称物理资源、时序或 15 fps 已达标。

全量 Icarus 回归 **166 配置通过**（原 162 + 新增 4），最终标记
`C1_REVIEW_FIXES_REGRESSION_PASS configurations=166`，进程退出码 0。
回归生成的唯一 VVP 和随机命名向量目录已由脚本清理，完成后检查均不存在；
未生成波形或大型仿真工程。

## 文件

- `rtl/dma/c1_axi_shared_qos_monitor.sv`：实际递增的溢出限定、本帧回绕记录、终止超时比较。
- `rtl/top/c1_r1_portable_soc.sv`：静态期限钳位及参数契约说明。
- `sim/tb_c1_axi_shared_qos_monitor.sv`：长帧与空闲边界测试。
- `sim/tb_c1_r1_portable_soc_smoke.sv`：顶层参数到监测器输入核对。
- `scripts/run_iverilog_review_fixes.ps1`：新增四组配置和必需 PASS 标记。

仍未解决的独立事项包括两个成功帧的连续双槽整机显示验证、已有成功画面时的失败保留验证、原生尺寸吞吐及目标板资源/时序签核。本轮不宣称整个 RTL 项目完成。
