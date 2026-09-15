# RTL 集成接口与缓存切层回归补强

日期：2026-09-11。范围：Sapphire 中断适配器、缓存响应与新配置的交界、对应回归脚本。未进行综合、P&R 或板测。

## 1. 生产 RTL 改进

`rtl/vendor/c1_sapphire_irq_adapter.sv` 原先固定输出八位，注释也将 Sapphire 中断接口概括为八位。企业 08 工程的 `userInterruptA` 实际是标量，因此不应靠连线时的隐式截断适配。

新增 `USER_INTERRUPT_COUNT` 参数，默认 8；原 `USER_INTERRUPT_INDEX` 保留为第一个参数，保持既有实例兼容。支持 1～8 位输出，索引必须在实际输出宽度内。非法配置在仿真中报 fatal，不引入额外时序逻辑。

企业标量接口的显式接法：

```systemverilog
wire sapphire_irq_a;
c1_sapphire_irq_adapter #(
    .USER_INTERRUPT_INDEX(0),
    .USER_INTERRUPT_COUNT(1)
) u_irq (
    .c1_irq(c1_irq),
    .sapphire_user_interrupt(sapphire_irq_a)
);
// 将 sapphire_irq_a 连接企业 soc 实例的 userInterruptA。
```

该模块仍只做电平路由，不负责 CDC，不定义 PLIC 编号，也不替代 BSP 中断初始化。若 CPU 与 CSR 的时钟关系改变，必须单独审核电平跨域。没有修改企业原始工程。

新增 `sim/tb_c1_sapphire_irq_adapter.sv`：验证标量及八位各索引，IRQ 连续保持 20 个时间单位、解除及重复触发。9 个正常配置与 4 个非法参数配置全部通过。非法测试包括标量索引 1、八位索引 8/−1、输出宽度 9。

复现：

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_sapphire_irq_adapter -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
```

## 2. 缓存切层边界

`tb_c1_tensor_window_cache_burst_axi_client.sv` 的 `config_while_response_held` 用真实 cacheable 读取得旧响应，将响应背压 12 个周期，同时持续提供下一次配置请求：

- 旧响应 valid、数据和错误位不得被新配置破坏；新配置不得提前握手或完成。
- 放行旧响应后，新配置必须在有界时间内接纳并完成。
- 再次读取缓存，检查期望数据及响应背压。

已有 packed-write 配置运行 `cache_config_response_fence_20260911` 通过。本轮使用更新后的 runner 运行 `cache_config_fence_beat_20260911`，开启 BeatFifo、不开启 PackedWrites，也通过，退出码 0，耗时 9.244 秒。

runner 现在在原始 xsim 输出上强制检查唯一的 `C1_CACHE_CONFIG_RESPONSE_FENCE_PASS` 标记，然后才压缩日志和清理。这样不会因日志去重而误判重复标记。两个运行的专属仿真目录均已清理，保留小型状态与摘要。

这是相同配置重新提交、单个旧响应的边界验证，不是改变几何的切层测试，也不是多上层 tap outstanding 证明。本轮未修改缓存生产 RTL：现有逻辑在该场景下正确。

## 3. 尚未解决的主要工程项

早期 AXI AW/W 互等、RLAST 掩盖等问题已在既有代码中修复，不能将旧审查的原始发现视为当前未修复状态。当前仍应优先推进上层串行 tap 访存的流水化，并验证新架构的顺序、取消和返回容量；最终需要原生尺寸吞吐、Ti60 全系统资源/时序、CDC 物理约束及板级链路验证。

本轮不是全量回归，也不增加 15 fps 或完整 Sapphire 系统兼容性的证明。
