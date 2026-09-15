# 通用 FIFO 参数与复位合同检查

## 本轮发现与修复

检查对象为 `rtl/common/c1_stream_fifo.sv` 与 `c1_async_stream_fifo.sv`。异步 FIFO 已在各自复位域屏蔽 ready/valid，同步 FIFO 原先没有。

新增定向测试先复现：depth=2、occupancy=0、rst=1 时 in_ready=1。若上游未与该局部复位同步，会认为写入已握手，但 FIFO 的 always_ff 仅执行复位，数据未写入。复位前有数据时也可能呈现 out_valid，让消费者误认为输出已接受。这是局部 flush 接口的不一致，不代表所有共享复位的既有系统都必然丢数据。

同步 FIFO 现将 `out_valid` 资格化为 `!rst && !empty`，`in_ready` 资格化为 `!rst && (!full || pop_fire)`。复位期间禁止两端握手；正常状态仍支持满 FIFO 同拍弹出与替换，不增加流水级、不清空 RAM 数组、不改变容量。full/empty/level 仍是占用寄存器的状态，时钟沿执行复位后清零。

## 验证与测试改进

- 将现有 `tb_c1_stream_fifo.sv` 深度参数化，运行 2、3、5、64；每种核对 300 个数据的顺序、占用量、回压稳定性、显式指针回绕和满队列同拍替换。
- 深度 64 的旧随机序列未自然达到输入受阻覆盖，因此补充“满队列阻塞一拍，再同拍替换”的定向阶段，保留原覆盖断言，不将未覆盖当作通过。
- 新增 `tb_c1_stream_fifo_reset.sv`，每种深度遍历 occupancy=0..DEPTH，共 78 个复位占用场景。上下游在 rst 期间保持 valid/ready 活动，检查握手被屏蔽、时钟复位后占用清零、新事务返回 0xbeef 而非复位前数据或复位期间的 0xdead。
- 固定回归从 25 扩为 33 配置，全部通过，涵盖已有显示 pair/外层 flush、后台错误、长 burst 恢复等检查。127 文件主顶层编译 errors=0、warnings=599，不等于无警告签核。
- 异步 FIFO 本轮仅检查现有合同与实现，未修改；仍要求有效深度为至少 2 的二次幂，运行中清理需协调两侧复位。其物理 CDC 约束和 RAM 映射不由功能仿真证明。

## 系统验证与剩余范围

带显示 FIFO/读 skid、默认直接错误广播的完整 SoC 故障恢复重跑入口为 `fifo_reset_soc_fault_20260910`。该运行检验共享 FIFO 修改后，摄像头/计算/显示及错误后重启的实际连接；结果按运行状态单独记录。使用 detached/breakaway xsim，Icarus 无波形，临时镜像由 runner 清理。

本轮不涉及更改 tensor cache、MAC 并行度或内存映射，不据此宣称 native 算术、15 fps 或物理资源闭合。后续仍须推进合法持续显示负载下的并发验证、其他总线客户端故障注入和 native 数据面对照。

系统复测现已通过：[fifo_reset_soc_fault_20260910](D:/contest/2026FPGA/yilingsi/case1/logs/portable_soc_cache_ddr_bfm_runs/fifo_reset_soc_fault_20260910/status.json)，72.772 s，`injected=1 errors=1 done=2 descriptors=44`。完整临时仿真目录已确认删除；只保留小型运行摘要。此为 8×8 故障恢复与生命周期证据，不是逐像素图像正确性签核。
