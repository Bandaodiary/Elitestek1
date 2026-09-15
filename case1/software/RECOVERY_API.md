# 可移植恢复调用接口

`include/c1_recovery.h` 与 `src/c1_recovery.c` 提供独立于 CPU/EDA 的恢复
调用流程。现有 `c1_accel_t` 和直接 MMIO 驱动保持不变。

调用方提供 `read32/write32` 回调：地址为控制块内字节偏移，访问必须有序
且已完成；返回 true 才表示总线成功。平台适配层必须处理总线错误/异常
及必要的 MMIO 屏障，不能用“已发出 posted write”冒充已接纳。现有简单
volatile MMIO 函数本身不满足可报告 APB 拒绝的要求。

1. 独占恢复控制及源控制，避免其他软件、硬件恢复请求或复位穿插其中。
2. 调用 `c1_recovery_request`：先查能力，读取就绪状态和诊断，最后只写
   一次恢复命令。源停止确认仍来自硬件；调用方安排停止源，保持到恢复完成。
3. 只有返回 OK/command_accepted 为 true 才可调用 `c1_recovery_wait`。
   wait 只读寄存器，要求恢复 done、恢复不 busy、系统 BUSY 清除。
4. TIMEOUT 后可以继续调用 wait，不能因此重复调用 request、伪造停止确认
   或强制复位。polls 是最多采样轮数，不是毫秒，也无法打断阻塞的总线访问。
5. 成功后由调用方恢复源并配置/启动新任务。接口不自动 START、不写源确认、
   不清诊断、不自动清 sticky done，避免隐藏事件；下一次成功请求由 RTL
   清掉旧 done。

写回调失败时 command_attempted=true、command_accepted=false，表示无法
确认接纳，不证明硬件没有执行。需要平台明确处理异常结果；禁止自动重发。
若发生外部复位或其他恢复控制者介入，应放弃本次报告并重新协调，不能用
历史 done 推断操作归属。硬件目前没有事务序号，故独占控制是接口契约。

若 CAPABILITY bit17 有效，接口使用 0x028 故障序号前后夹读 code/address，
最多尝试四次；序号相同才设置 diagnostic_valid/diagnostic_coherent，
否则返回 NOT_READY 且不发命令。旧硬件无此能力时仍读取 code/address，
但 diagnostic_coherent=false，调用方不可把它当作原子诊断。
序号每次 error_event 加一，32 位回绕；要求一次读取期间不发生全局复位，
且不经过整整 2^32 个错误事件。该保护保证一对记录一致，不保证它是随后
命令接纳瞬间的最新错误。源控制驱动、异常处理
和超时计时仍留在板级适配层，本接口没有假定某型号 Sapphire 的异常机制。

验证：`scripts/run_recovery_host_test.ps1` 使用 C11 和
`-Wall -Wextra -Werror` 编译回调模拟测试；覆盖能力缺失、not-ready、诊断
读取失败、命令失败、旧 done、完成但系统仍忙、超时续查、读取错误及首轮
即完成。临时测试程序在 finally 清理。主机 mock 不是 CPU/RTL 联合仿真。
