# 行 bank 控制信号检查补强

本次为有限范围修复，不代表整个 RTL 已重新完成审计。

## 问题与修改

`c1_row_banked_ram.sv` 原有检查只在读写使能为真时检查地址。
SystemVerilog 的 `if` 会跳过 X 使能，因此未初始化的控制信号可能被仿真
静默忽略，掩盖上游控制缺陷。新增逐 bank 的读/写使能未知值检查，
置于 `ifndef SYNTHESIS` 内，不改变综合电路、接口或 RAM 读延迟。
这不是 CDC 修复，也不应视为实际器件能检测 X 状态。

测试新增启用端口的未知读地址、未知写地址、未知读使能、未知写使能
四项负测试；每项必须非零退出并包含对应 DUT 诊断。正测试同时要求
关闭端口时允许未知地址，且读输出保持不变，避免检查过严造成误报。

## 本次实际运行

通过 `scripts/run_iverilog_review_fixes.ps1 -TestTop <名称>` 执行：

| TestTop | 配置数 | 结果 |
| --- | ---: | --- |
| tb_c1_row_banked_ram | 10 | 全通过，含 6 项预期失败 |
| tb_c1_window_line_cache_c8 | 2 | flat/banked 均通过，8161 周期锁步一致 |
| tb_c1_window_line_cache_c8_faults | 2 | 故障及维护场景通过 |
| tb_c1_window_line_cache_c8_maxrow | 2 | 1280 字行补充及响应反压通过 |

共 16 个定向配置。没有重跑全部回归，没有启动 Vivado/Efinity，
没有生成波形；使用现有 runner 的临时文件清理流程。

## 未完成边界

行 bank 原语有独立并行读端口，但现有缓存仍只输出单个 C8。
三行列请求、目标行保护替换策略、原子多 C8 返回和 adapter 接入
仍需设计及验证。本次没有提高吞吐率，也没有证明 640×480 达到 15 fps。
