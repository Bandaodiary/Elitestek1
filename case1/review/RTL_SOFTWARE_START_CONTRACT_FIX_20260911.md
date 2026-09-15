# 软件 START 与 RTL 使能契约修复

## 发现与复现

`c1_r1_soc_control` 在 system_enable 为低时不会接纳 START，且取消已有
运行使能。原 `c1_accel_start` 却只检查 NULL/BUSY；对初始 steady_control=0
的句柄，清除 DONE/ERROR IRQ 并写入不含 ENABLE 的 START，最后返回 true。

先增加主机测试，旧代码实际失败：
`FAIL: disabled start was reported successful`，退出码 1。

## 修复及范围

在读取状态、清 IRQ 和写 CONTROL 之前检查 steady_control 的 ENABLE。
缺失时返回 false，不修改寄存器。新增测试覆盖连续/丢帧两位的四种组合，
均不包含 ENABLE；检查 CONTROL 与 IRQ 哨兵值保持不变，并检查 NULL。
保留已配置启动、BUSY 拒绝及原有配置测试。

这里未改变 RTL 行为，也没有给软件句柄增加“已配置”状态。ENABLE 检查
不能证明 DDR 已初始化、描述符有效或硬件已接纳；reset 后恢复、并发控制
仍须由平台管理。直接 MMIO 接口不能报告 APB 错误，返回 true 只表示发出
命令，不是完成/硬件接纳确认。调用者须串行化控制并提供有序设备访问。

## 同步澄清 legacy CSR

头文件注明：当前 portable SoC 的 stride CSR 不替代 framebuffer table
entry 的 stride；style ID 是元数据，不会自行选择模型。切换风格需要
匹配的 descriptor/weight 工件及既有参数加载流程。

不为这些 CSR 擅自新增 live 数据通路，避免旁路既有任务快照和所有权规则。

## 验证

修复后原驱动 C host 测试通过；独立恢复接口 C host 测试通过。
这是主机数组模拟 MMIO 测试，不是 RISC-V/RTL 联合仿真。
本轮未修改可执行 RTL，未重跑 RTL 全量、整机 golden、综合或板测。
