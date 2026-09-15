# 防止错误码/地址跨事件拼接

本轮发现软件读取 ERROR_CODE、ERROR_ADDRESS 的两次总线访问之间可能有
新错误，得到跨事件组合。对比两次错误码不足以检测，因为两次错误可同码
不同地址。

## 改动

- CSR 新增只读 `ERROR_SEQUENCE=0x028`，CAPABILITY bit17 宣告支持。
  每次 error_event 与错误码/地址同时更新序号；reset 清零；IRQ W1C、
  统计清零不会改变序号。写此寄存器返回 PSLVERR，无写副作用。
- 保留 0x020/0x024 原含义，不增加读取副作用，不冻结最新故障记录。
- `c1_recovery_request` 使用序号→code→address→序号，序号不一致重试，
  最多四次。读不到稳定记录返回 NOT_READY，diagnostic_valid=false，
  不写恢复命令。成功报告包含 error_sequence 和 diagnostic_coherent。
- 旧硬件不支持序号时保留旧读取方式，明确 coherent=false。

此方案要求有序访问、读取期间无外部 reset、没有 2^32 次事件回绕。它
保证记录配对，不保证读取后没有发生更晚故障。故障序号不是不回绕的事务
编号，也不是错误 FIFO；软件仍须遵守既有独占恢复控制契约。

## 结果

IRQ CSR 定向 Icarus 1 配置通过（含 1024 事件/W1C 组合和新序号检查）：
同码不同地址仍加序号、清 IRQ/统计不重置、只读写拒绝、reset 清零。
恢复 C host 测试通过：中途序号变化后重读、连续变化拒绝命令、旧硬件
回退；原 C 驱动 host 测试也通过。SoC smoke 19 配置通过，退出码 0。

生产 RTL 和软件均已修改；未重跑全量（最近 597）、整机 golden 或
Efinity。主机 mock 与 RTL 定向测试不是 CPU/RTL 联合执行证明。新字段
改变了 recovery report 的 C 布局，使用该新接口的应用需要重新编译。
