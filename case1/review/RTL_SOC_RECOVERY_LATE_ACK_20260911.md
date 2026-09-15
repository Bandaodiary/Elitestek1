# DDR 先排空、源停止确认后到的恢复验证

本轮检查的是上轮覆盖不足的整机时序组合，不修改生产 RTL。

## 新增检查

在已有永久停流场景上增加 `-RecoveryLateSourceAck`，要求同时启用
`-ExplicitCaptureRecovery`。恢复请求先接纳，源停止确认暂时保持低；
真实两个在途写 B 阻塞 64 周期后放行，等待 DDR 写、捕获 writer 和计算
退出，再额外保持源确认低 32 周期。

这 32 周期必须保持恢复 BUSY、软件 BUSY、输入物理区域 valid/base 快照
以及取消占用；两个 FIFO 域不得提前复位，START 仍返回错误。随后提供源
确认，并逐周期检查整个双域复位握手期间的区域占用，直到 done。

## 结果

- detached xsim 运行 `recovery_late_ack_direct_20260911`，101.985 秒，
  状态 complete、退出码 0。本次采用直连 fatal ticket，上一轮采用寄存配置。
- Python `--require-late-source-ack` 验证通过，要求等待标记先于恢复排空
  标记，并进一步执行停流、显式恢复、写排空及完整数值检查。
- 22 阶段、836 C8 结果、64 DDR 像素及 120+64 显示像素符合整数 golden；
  AW=B=874，W=924，在途峰值 2。恢复只完成一次，无全局 reset。
- 新增 6 个源确认日志负测试，与原 25 个合计 31 个通过；无夹具文件写入。
- 已确认本次临时仿真工程目录不存在，不生成波形。

修改文件：整机 DDR BFM testbench、detached runner、数值 trace checker
及其负测试。生产 RTL 未改，未重跑全量 Icarus（最近 596 配置）或 Efinity。

## 下一步

目前已有源确认先到（寄存 ticket）和总线排空先到（直连 ticket）的真实
整机证据，但不是全部交叉组合。软件 APB 恢复命令、诊断保存策略与板级
源停止确认/CDC 的集成仍未完成。该测试中的确认延迟是模拟控制路径延迟，
源自身此前已经停流；不代表已验证某型号摄像头停止寄存器或 D-PHY 行为。
