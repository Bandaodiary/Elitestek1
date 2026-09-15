# RAW 停流超时的真实 SoC 集成验证

日期：2026-09-11。

新增 detached DDR BFM 参数 `-RawIdleTimeout`，要求 `-RawRasterFault`，与
`-RawMissingEof` 互斥。仅该测试配置给 portable SoC 设置
`RAW_IDLE_TIMEOUT_CYCLES=4096`；生产默认仍为 0。

第一帧进入 CNN 后，第二帧 RAW 在中途暂停。测试先确保两个真实 writer
有已提交写事务并冻结 B，再继续保持 camera_valid=0，直至硬件看门狗
自行产生错误。源数据坐标和 EOF 均不修改，没有强制内部 error，也没有
软件主动 abort。正常接纳期不会任意暂停超过阈值。

测试检查实际控制器报告 0x46/address=0，并沿用真实 AXI 排空检查：64 周期
不返回 B 时，系统 busy 保持，输入区域有效位和基地址完整快照不变，
禁止新的任务/缓冲区接纳。源随后恢复旧帧尾部，前端只用于重同步而不
继续输出该坏帧；所有写事务退休后，无 reset 启动下一完整帧。

新增 Python `--require-idle-timeout-recovery` 要求一次精确的阈值、0x46、
三次接纳/一次错误/一次成功且无 reset 的记录，并强制沿用 RAW 写排空、
视频、DDR 和 22 阶段 integer golden 校验。新增 4 个负测试拒绝缺失、
重复、错误代码和使用 reset 的记录；原 8+5 个负测试保持通过。

运行入口：在原 RAW 故障 detached 命令中附加 `-RawIdleTimeout`，本次
使用 `-RegisterFatalTicket`。首轮 `raw_idle_soc_20260911` 因测试变量
error_seen 在任务引用后声明而编译失败；仅移动声明顺序，重跑
`raw_idle_soc_v2_20260911`。该问题不是生产 RTL 故障，也未禁用错误检查。
最终 complete、退出码 0，耗时约 91.2 秒。Python golden 通过：64 CNN 输入、
22 阶段/836 C8 结果、64 DDR 像素及 120 原图+64 风格显示像素。最终
AW=B=874、W beats=924、峰值 outstanding=2；captures=3/errors=1/done=1。
验证命令为 `check_portable_soc_numerical_trace.py <运行日志目录> --require-idle-timeout-recovery`。
首轮编译失败与第二轮成功运行的临时工作目录均已确认清理。

## 仍然没有证明的内容

本轮是实际传感器最终恢复的帧中途停流，不是永久停止后的强制复位机制。
未验证直接 fatal ticket 路径的超时场景、已显示旧帧时的超时、取消排空
期间停流、错误 B 叠加或真实传感器最大消隐长度。4096 只是该 fixture 的
测试阈值，不能据此决定板上参数。未新增生产 RTL，未测资源/时序/15 fps，
未重跑全量 Icarus。Vivado 通过 WMI 脱离 Job 启动，runner 清理临时工作目录。
