# 当前 RTL 整机数值与 APB 恢复回归

## 运行身份与结果

- Run ID：`apb_recovery_current608_20260911`。
- 通过已有 WMI/breakaway detached runner 启动独立 worker PID 50448；
  没有把 Vivado 直接放入 Codex Windows job。
- 最终 status：complete/done、exit_code=0，130.319 秒。
- 完整 golden 检查退出码 0，并启用 require-apb-recovery、
  require-late-source-ack；本轮没有更改生产 RTL。

## 观察到的证据

| 检查 | 实测结果 |
|---|---|
| 数值链路 | gray fixture，12×10 下采样为 8×8，22 阶段、836 个 C8 结果、64 个 DDR 像素匹配 |
| 显示结果 | 原图 120 像素、处理图 64 像素匹配 |
| 排队写事务 | AW=874、W=924、B=874，峰值 2 outstanding |
| RAW 停顿 | 4096 周期门槛，错误码 0x46，延迟写响应 64 周期 |
| APB 恢复 | 不使用外部硬件 request；读取诊断、发恢复命令、检查及清除完成状态 |
| 延迟源停止确认 | 32 周期保持内存所有权，未提前释放 |
| 恢复行为 | 一次 flush，无全局 reset，恢复后继续计算与显示 |

37 个日志负测试全部通过，包括缺失 RAW/EOF/idle-timeout/explicit-recovery/
late-source-ack/APB 证据时的拒绝检查。仅靠进程退出码或某个 PASS 字符串
不足以替代本次数值及恢复链路完整检查。

## 文件与限制

精简结果在 `case1/logs/portable_soc_cache_ddr_bfm_runs/apb_recovery_current608_20260911`。
`case1/sim/portable_soc_cache_ddr_bfm_run_apb_recovery_current608_20260911`
已不存在，临时工程清理确认完成。只读状态及检查器输出，没有读取大型
仿真数据库。

此证据对应当前包含 ERROR_SEQUENCE 与 RAM 参数断言的 RTL；序号夹读的
故障交错仍由独立 APB 测试证明，整机 bench 没有执行真实 C/RISC-V 驱动。
这是缩小图像的真实算术/控制集成验证，不是原生 640×480/15 fps 性能证明，
也不包含 Efinity 资源、物理 CDC/时序、DDR PHY、MIPI 或 HDMI 板测。
