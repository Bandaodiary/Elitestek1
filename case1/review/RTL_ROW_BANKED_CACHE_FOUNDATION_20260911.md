# 按行独立 RAM：多 tap 读取的存储基础

日期：2026-09-11。生产 RTL 已修改，仅完成存储层与现有标量缓存接入；未实现端到端多 tap 请求，不声称已有整机吞吐收益。

## 1. 原有约束

`c1_window_line_cache_c8.sv` 将所有行存入一个 `data_mem` 数组，读口每次只返回一个 C8。把上层返回总线直接加宽不能创造并行读口。要在一拍取同一列的三行，必须先有独立可读的行 bank，并处理行标签、未命中和维护边界。

## 2. 本轮实现

新增 `rtl/common/c1_row_banked_ram.sv`：

- 每行实例化一个既有 `c1_ram_sdp_read_first`，具有独立 read enable、地址和同步读输出；各 bank 可在同一拍读取不同地址。
- refill 使用共享写地址/数据、独立 bank write-enable。没有复制所有行的完整副本来增加读口。
- 同一 bank 同址读写采用 read-first，停用读口时保持输出。数据 RAM 不复位；标签和有效性属于外层控制器。
- 对被使能的越界/未知读写地址增加仿真诊断。

缓存新增末尾参数 `ROW_BANKED_STORAGE=0`，默认保留原 flat 路径。开启时使用按行 RAM，stage 2 注册 bank 选择和行内偏移，stage 3 读取所选 bank；输出按寄存的 bank 选择取值。错误响应数据为零，不暴露未初始化 RAM。

refill 写入资格保持原逻辑：取消、维护、已经污染的 refill、错误数据、错误 last 都不能提交有效 payload；仍照合同排空。原 flat 数组在 bank 模式下没有读写活动。没有新增 tag/refill 副本或放宽行有效性条件。

**当前控制器仍只驱动一个 bank 的读使能，输出仍为单个 tap。** 该参数目前只在 cache 叶级配置，未贯穿 SoC 默认配置。

## 3. 验证

存储原语 6 配置：

- `(ROWS,WORDS)=(1,1)、(3,5)、(4,16)、(3,1280)` 正常配置通过。
- 所有 bank 并行读、不同地址、连续逐拍返回、读写碰撞返回旧值、停用保持以及最终全地址回读均有独立 shadow memory 检查。
- 每个正常配置覆盖 19 次读写同址碰撞。3×1280 配置含 1335 个全 bank 同拍读取周期。
- 读、写越界两项预期诊断通过。

缓存 6 配置：正常、fault、maxrow 三个 bench 分别运行 flat/banked 两种模式。

- 正常测试均得到 1445 响应、18 次 refill、288 refill words，停顿和维护计数一致。
- fault 配置、refill 数据/last 错误、维护排空检查通过。
- maxrow 配置完整写入并验证 1280-word 行及组间地址。
- banked 正常测试额外实例化 flat 参考实例，使用完全相同输入，在 **8161 个周期**逐拍比较控制输出及有效响应数据，全部一致。这是该测试序列下的锁步仿真，不是所有状态的形式等价证明。

共 12 个定向配置通过。开发时修正了新 generate 逻辑对后声明控制信号的绑定问题及新增 PowerShell 条件运算符笔误，然后重新运行相关测试。未将编译失败算作功能通过。

复现：

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_row_banked_ram -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_window_line_cache_c8 -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_window_line_cache_c8_faults -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_window_line_cache_c8_maxrow -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
```

本轮不运行 Vivado、不生成波形，Icarus 按 runner 的 finally 策略清理临时 VVP/向量；未进行综合或新版本完整套件回归。

## 4. 下一步不能省略的控制逻辑

1. 定义列请求：一组 x/group 对应三个钳位 y，同时解析三个 row tag。边界处重复 y 应复用同一 bank 的返回，不额外要求双读口。
2. 未命中填行时保护本列已需要的 resident 行，避免替换刚填好的其他目标行而无法完成请求。至少三行容量是一般三行列请求的前提；不足容量要明确拒绝或回退。
3. 明确整列的接纳、错误、返回保持和取消排空，不得在三个行数据不属于同一配置时发布结果。
4. 向缓存封装和 tensor adapter 接入宽返回，让水平复用后的新增列真正一次取得三个 C8；仅保留宽 RAM 原语不等于完成上层多 tap 架构。

物理风险：bank 分离可能改变 EBR 利用率，输出 bank mux 可能改变时序路径；逻辑容量和等价仿真不能证明资源或频率改善。现有标量输出时序虽然相同，仍需实际工具评估物理映射。
