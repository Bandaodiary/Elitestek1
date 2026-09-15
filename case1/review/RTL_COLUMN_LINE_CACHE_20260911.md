# 三行并行列缓存：控制器实现与集成边界

日期：2026-09-11。本阶段实现独立列缓存及定向测试，没有修改默认 SoC 数据路径。

后续进展：列缓存现已接入可选 exact-count AXI 链路，见
[列缓存 AXI 集成](RTL_COLUMN_EXACT_AXI_INTEGRATION_20260911.md)。本文保留叶模块
阶段的验证记录；adapter/SoC 列事务接入仍未完成。

## 1. 本次解决的问题

已有 `c1_row_banked_ram` 提供独立行读口，但标量缓存每次只返回一个 C8。
新增 `rtl/cnn/c1_column_line_cache_c8.sv`，使控制器能够原子返回一列三个 C8。
这不是将同一个标量数据复制三份，也不是先后执行三次标量读取。

工作关系如下：

```text
column(x, center_y, C8 group)
  → 接纳并锁定坐标/行内地址
  → 三行标签查询、保护所有已命中的目标行
  → 逐行补齐缺失行（复用 exact-count refill 合同）
  → 同一拍读出所有不同目标行的 bank
  → 按 top / center / bottom 重排并寄存 192-bit 响应
```

RAM 仍使用既有 `c1_row_banked_ram → c1_ram_sdp_read_first`。数据不复位，
只有完整无错 refill 提交后的行才可读取。默认 3×1280×64 位，即 30 KiB
逻辑 payload 容量；这不是 EBR 数量或映射利用率估计。

## 2. 对外合同

| 接口 | 合同 |
| --- | --- |
| 配置 | 空闲且无维护时接纳；同时锁存 width/height/groups 并失效旧标签 |
| 列请求 | **未命中也会接纳**，随后不再依赖输入坐标保持；一次接纳恰好一次响应 |
| 返回排列 | lane 0/1/2 分别为 `(x,y-1)/(x,y)/(x,y+1)`；每 lane 64 位 |
| 边界 | x 与三个 y 分别钳位；y 先扩展为有符号 18 位再做 ±1，避免端点溢出 |
| 重复行 | 顶部、底部、height=1 等重复行共享一个 bank 读结果，不重复 refill |
| 行内地址 | `clamped_x * groups + group`；每个缓存行包含全部 C8 group |
| 替换 | 优先无效 bank，否则从轮转指针选择不属于任何目标行的 bank |
| refill | 严格消费声明的 word_count；提前/缺失 last 或 data error 均不能提前结束 |
| 错误 | 错误行不提交；列返回零/error；refill 错误 sticky，配置或维护清除 |
| 无效 group | 接纳并返回零/error，不启动 refill，不置 sticky cache_error |
| abort/flush | 保持已提出的 refill request，排空后退还已接纳列的响应，等待响应消费再完成 |
| 已呈现响应 | 即使维护随后到达，也保持原数据/error，不把成功响应中途改成取消 |
| 重复维护 | 同类 pending 请求合并，长按不重触发；不同种类分别记录并完成 |
| 配置保留 | flush 保留几何；abort 使 config_valid 清零；高电平维护期间禁止新接纳 |

要求 `LINE_ROWS>=3`。当三行中仍有未命中行时，至多有两个不同的目标行
已经驻留，因此至少有一个可替换 bank。替换判断保护的是**全部目标行**，
而不只是当前选择的缺失行，以免反复驱逐刚补齐或随后还要使用的行。

## 3. 定向验证

`sim/tb_c1_column_line_cache_c8.sv` 用独立行/字/通道/epoch 数据函数生成源
及期望列；不以 DUT 内存内容作为数值参考。接纳后立即改变输入坐标，
检验请求快照。DUT 内部读使能只用于确认真正的多 bank 同拍读取。

已运行 `(LINE_ROWS,MAX_ROW_WORDS)=(3,13)、(4,13)、(3,1280)`：

- 三行列结果、跨 group、边界、80 项确定性伪随机访问、受保护行替换。
- 0 尺寸、group 超限、行容量超限、65535×8 宽乘积拒绝。
- signed17 的最小/最大坐标，height=1、height=65535，group=7。
- 13/1280 字满行及最后合法地址，关闭或反压时的输出持有。
- 提前 last、末尾缺 last、数据错误：均完整消费声明的 10 字后返回错误。
- 6 个取消时间点 × abort/flush/先 abort 后 flush 共 18 个场景：
  接纳后尚未 refill、refill 请求受阻、部分数据已接受、同步 RAM 读阶段、
  响应捕获阶段、成功响应已呈现。
- 补行错误与双类维护交叉 3 项；未完成排空前保留诊断，完成后正确清除。
- pending 期间同类请求再次产生边沿、长按防重触发、无全局复位重启。
- 响应反压期间禁止新配置抢占；维护也必须等响应实际消费。

每个配置通过 154 个列事务，观测到 84 次三 bank 同拍读取、16 次双 bank
读取和 35 次单 bank 读取。其余事务属于无效 group、错误或读取前取消等
情况，不能简单将列事务数等同于 RAM 读取次数。

| 行数/容量 | refill 请求 | 实际消费字数 | 请求停顿 | 响应停顿 | 源空隙 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 3/13 | 240 | 2394 | 106 | 559 | 1014 |
| 4/13 | 215 | 2144 | 92 | 559 | 908 |
| 3/1280 | 240 | 6195 | 104 | 559 | 2279 |

最后 12 个连续命中请求同时保持请求 valid 与响应 ready：没有 refill，
实测每 5 拍接纳一列；runner 要求对应 HIT_RATE_PASS 标记。

完整 Icarus 回归已返回 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=669`，
进程正常结束（exit 0）。完整运行期间仅为新 bench 补加了上述命中速率
测量，生产 RTL 没有再改动；补加后的三个列缓存配置也单独重跑通过。
因此旧路径的完整回归与新模块最终定向测试均有实际结果，不将本次结果
扩展解释为 xsim 整机或 Efinity 综合验证。

开发时纠正了测试对 4-bank 配置的 refill 次数假设：第四个 bank 可以保留
旧行，不能套用 3-bank 的必须缺失次数。该次失败未计为通过。

复现：

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_column_line_cache_c8 -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
```

## 4. 不能直接接线替换的地方

现有 `c1_window_line_cache_c8` 的 miss **不接纳** tap，新列缓存的 miss
**接纳** column。这是刻意定义的新接口，不是原标量 cache 的兼容替换件。

后续接入应保留已有已验证的数据面和维护合同：

1. 为列缓存接入现有 exact-count reader 的 base/row/stride/epoch 桥、refill
   skid 和维护汇合；不能丢掉 `c1_window_line_cache_c8_exact_burst_shell`
   中“维护同拍仍承接已经提出的 refill”的处理，否则会等待成环。
2. 在 tensor adapter 中引入显式列事务和宽返回，仅对 3×3 窗口使用。
   普通/残差/上采样读保持现有标量路径；不要把所有 mem_rsp 直接扩大三倍。
3. 将一列的三行写入 `window_q[(row*3+column)*64 +:64]`，配合水平复用：
   无复用取三列，stride1 复用后取一列，stride2 复用后取两列。
4. 行中心必须由未钳位的逻辑窗口中心得到。不能从已钳位的 top tap
   反推中心，否则 top/bottom 边界会发生偏移。
5. 更新 adapter 的取消/错误排空，使**被接纳的列请求**也最终接收响应，
   再切换 stage/epoch。否则叶模块正确地等响应，系统却会死锁。
6. 用现有 22-stage 整数 golden、彩色双帧和故障恢复做新旧配置对照；
   以实际周期与请求统计衡量收益，而不是将 192 位口宽直接折算成 3 倍帧率。

## 5. 性能与物理边界

当前控制器为单在途列请求，命中也经过 lookup/read/capture/response。
连续命中 initiation interval 实测为 **5 拍/列**，不是 1 拍/列。三 bank
的同拍读取不等于每拍可接纳一列。后续仍需审查命中流水和请求/响应弹性。

从当前 `tensor_perf_model.layer_specs(640,480)` 的固定网络和已实现水平复用
推导，若未来将所有适用 3×3 读换成列请求：

- 每个窗口层列数为 `outH * ceil(Cin/8) * [3 + (outW-1)*stride]`。
- 合计 1,737,120 列，即 5,211,360 个窗口 C8；另有 2,860,800 个非窗口
  标量 C8，合计仍为既有模型的 8,072,160 个 C8。
- 按本叶模块 5 拍/命中列、原标量接口至少请求/响应 2 拍粗算读服务占用，
  为 14,407,200 周期。此数是**尚未接通路径的结构预算**，不是整机周期
  或 DDR 传输计数，也没计补行、计算、写回和 stage 切换。

因此，列缓存只是必要的并行数据供给基础，不能据此宣称原生 15 fps 已达标。
流水化列命中、非窗口读调度及计算/写回重叠仍是后续工作。

本轮没有 AXI 带宽、整机时延、EBR 映射或时序收敛的新实测。默认 SoC、
旧标量缓存与 adapter 不因新增模块而改变行为；它们仍使用原路径。
没有调用 Vivado/Efinity，没有波形或大型仿真工程。
