# 列缓存接入 exact-count AXI 链路

日期：2026-09-11。继独立三行列缓存之后，本阶段接通真实的 AXI128 补行
数据面；尚未将 tensor adapter 的逐 tap 请求改成列事务。

后续进展：adapter 已增加可选列事务，并与真实列缓存完成 22-stage 窗口
验证，见 [adapter 列读取路径](RTL_ADAPTER_COLUMN_READS_20260911.md)。本文件
保留 AXI 集成阶段记录；完整 adapter→AXI→SoC 的接纳/维护所有者仍待接入。

## 1. 实现结构

```text
逻辑列请求 x / center_y / group
  → c1_window_line_cache_c8_exact_burst_shell（COLUMN_MODE=1）
    → c1_column_line_cache_c8：保护目标行、补缺行、并行读三个 bank
    ↔ 既有 row/base/stride/epoch 命令桥 + refill skid
    ↔ c1_cache_refill_scheduler_read_client_exact
      → scheduler：逻辑请求及 epoch/credit
      → AXI128 read burst client：C8 packing、burst、多在途、响应 FIFO
      → completion adapter：数据/旧响应排空/未发后缀合成
    → 原子 192-bit 列响应
```

没有另写一份 AXI master 或复制整套维护逻辑。新增参数 `COLUMN_MODE=0`
保持默认标量路径；开启后既有 tap 命名端口明确变为列合同：

| 项目 | 默认标量模式 | 列模式 |
| --- | --- | --- |
| 请求坐标 | 一个 tap 的 x/y | x 与逻辑 center_y |
| miss 接纳 | 补行后才接纳 tap | 先接纳并锁定列请求，再补行 |
| 返回宽度 | 64 位 | 192 位，top/center/bottom |
| PRECLAMPED_TAP_COORDS | 可按原合同配置 | 必须为 0，避免从已钳位 top tap 错推中心 |
| 活动缓存 | g_scalar.u_cache | g_column.u_cache |

两个模式是 elaboration-time 选择，不是同时存在的两份活动缓存。
原测试中的层级诊断路径已更新为 `g_scalar.u_cache`；相关 xsim/代理综合
脚本补齐了新缓存、行 RAM 和通用同步 RAM 的源码依赖。本轮未执行综合。

## 2. 维护与接纳边界

列缓存先接纳 miss，所以外层还需要维持其事务所有权：

- 保留“维护同拍仍承接已经提出的 refill”路径，捕获旧 epoch 的命令。
- 后续由 exact reader 正常排空已发数据，并补足没有发出的声明后缀。
- 缓存子模块可能先完成，外层必须等 scheduler/reader 的完成汇合。
  新列接纳同时在 valid 和 ready 两侧受外层 pending 控制，防止提前重开。
- 已呈现的成功列响应在取消后仍保持成功数据，不能中途改成错误。
- 配置与 stage base 在共同握手时锁定；后续改变上游配置引脚不影响旧事务。

## 3. 联调发现并修复的 epoch 耗尽问题

最初使用 4-bit epoch 的长维护序列在 epoch=15 后停住。诊断显示
`exact_quiescent=1`、`exact_cmd_ready=0`、没有 AXI 在途，而列缓存仍在等待
refill 请求被接纳。这是调度器已有防回绕保护触发后，与 exact-count
消费者的事务终止合同不匹配，并非有效的成功完成状态。

修复方式：

1. 为 `c1_cache_refill_scheduler` 和普通 read-client 包装增加末尾参数
   `REJECT_ON_EPOCH_EXHAUSTION=0`，普通独立用户默认仍采用原来的停接纳策略。
2. exact-count 包装显式开启该参数。耗尽后命令仍可排队并以
   `cmd_done_error` 终止，但不会变为 leaf 请求，不会重用或回绕 epoch。
3. completion adapter 利用错误终止令牌合成所声明的零/error 后缀。
   列缓存退还错误响应，避免已经接纳的事务无限等待。
4. 常规集成仿真改用 8-bit；另外用 **2-bit 专项测试**保留对耗尽的验证，
   不是仅扩大计数器来绕过问题。

专项在 epoch=3 时，恰好于 refill 提出那一拍再次 flush。此时命令 tag 也
是 3，仅检测 tag 不一致不足以阻止它；必须检查 exhausted 状态。验证随后
三个声明均错误终止，共消费 99 个合成字，新增 AXI/leaf 请求均为零。
重新配置不能清除防回绕保护，也不能偷偷恢复有效计算。

**恢复限制仍存在**：耗尽后的正确运行需要上层在系统已排空后执行受控的
相关子系统复位。本次保证明确错误终止，没有实现自动重建 epoch 空间，
也未增加独立的 CSR 耗尽原因字段。cache_error/code=1 是当前外显错误。

## 4. 验证方法

`tb_c1_column_cache_exact_axi.sv` 实例化全部生产 refill RTL，仅用 BFM
替代 AXI 存储器。BFM 按地址和内存 epoch 产生独立参考数据，不读取 DUT RAM。

- 11×7、3 个 C8 group，每行 33 个字，stage base=0x1ff8：同时覆盖高半
  beat 起始、奇数行长度、组间地址以及 4-KiB burst 边界。
- 真实 packing、多 beat burst、至少 2 个 AXI burst outstanding。
- 请求反压、R 数据空隙、列响应反压；最小 2-word 响应 FIFO 专门产生
  真实 RREADY 反压。beat FIFO 使用符合其容量合同的 16-record 配置。
- 4 个取消时间点 × 3 种维护组合：refill 同拍、部分逻辑请求已发但 AR
  受阻、AXI 数据部分返回、成功列响应已经呈现。
- abort、flush、先 abort 后 flush，以及 pending 期间重复边沿和长按。
- SLVERR/DECERR 均排空整行并返回错误，重新配置后验证成功读取。
- 2-bit epoch 耗尽专项：声明同拍耗尽及之后请求的错误终止、不发新 AXI。

Icarus 对完整新 AXI 组合的首次尝试达到 30 秒墙钟上限，未计通过；
没有据此认定 RTL 功能失败或通过。新组合改由 WMI 脱离 Windows job 的
xsim runner 验证，Icarus 完整套件仍维持它原有可运行的覆盖范围。

最终列模式四种配置均 exit 0，各通过 34 个列事务、68 次补行、2244 个
声明字。结果由最终 `_20260911_final` 运行日志读取：

| FIFO / skid | AXI burst / beat | 最大 AXI 在途 | packed 请求 | R 反压拍数 | 合成字 / 旧响应排空字 |
| --- | --- | ---: | ---: | ---: | --- |
| word / 1 | 307 / 1038 | 2 | 968 | 2039 | 238 / 53 |
| word / 2 | 307 / 1037 | 2 | 968 | 1230 | 239 / 52 |
| beat / 2 | 307 / 1036 | 2 | 968 | 0 | 240 / 51 |
| beat / 3 | 307 / 1036 | 2 | 968 | 0 | 240 / 51 |

每种配置均有 20 次三 bank 同拍读取。以上包含人为故障/停顿，不是正常
视频帧的性能对照；不同配置取消时已发请求数会稍有不同，因此真实 beat
与合成字不必相同，但每个声明的消费计数必须相同。beat 模式未产生
RREADY 反压；真实 R 反压证据来自两种 word 模式，不能扩张该覆盖结论。

最终 word/skid1 与 beat/skid3 两种 2-bit 耗尽专项也均 exit 0：三行明确
错误终止、99 个合成字、无新 AXI，配置不能清除饱和保护。

最终生产 RTL 的完整 Icarus 套件另行重跑，返回 669 配置通过、exit 0。
该数量不包含上述 xsim 列模式测试。各次运行只保留小型 status 与摘要日志。

原路径兼容性另有三个最终 xsim 回归通过：

- `column_integration_scalar_20260911_final`：默认标量 exact shell，4 响应、
  3 refill、24 字；重复维护、done 同拍与 child-ACK 汇合重叠通过。
- `column_integration_scalar_mixed_20260911_final`：先 abort 后 flush 的混合
  维护及重叠边界通过，同样得到 4 响应、3 refill、24 字。
- `column_integration_tensor_client_20260911_final`：既有 tensor 标量客户端
  开启 beat FIFO 与 packed writes；重复维护、双 fence、packed pair 正常/
  故障/取消所有权及响应持有期间配置隔离均通过。

因此本阶段最终结果为 **669 个 Icarus 配置 + 9 个 xsim 集成/专项运行**。
开发中两次用于定位 epoch 耗尽的失败运行不计为通过，较早的预备成功运行
也不重复计入上述九项。最终运行前后没有修改生产 RTL。

已按准确运行目录核查 15 个本阶段 exact-shell 临时目录及 1 个 tensor-client
临时目录，全部不存在；包括定位失败的运行，均已由 finally 清理。更早遗留
的两个 C 盘 Icarus 临时项未由本次删除。不保留波形或大型 xsim 工程。

## 5. 复现入口

```powershell
# 正常 word FIFO + 最小 refill skid
& case1/scripts/run_window_line_cache_c8_exact_burst_shell_xsim_detached.ps1 -ColumnCache -RefillSkidDepth 1 -RunId <唯一名称>
# beat FIFO + 非二次幂 skid
& case1/scripts/run_window_line_cache_c8_exact_burst_shell_xsim_detached.ps1 -ColumnCache -BeatFifo -RefillSkidDepth 3 -RunId <唯一名称>
# 小位宽耗尽专项
& case1/scripts/run_window_line_cache_c8_exact_burst_shell_xsim_detached.ps1 -ColumnCache -EpochExhaust -RunId <唯一名称>
```

由 launcher 经 WMI 创建隐藏 worker；不要直接运行 `-Worker`，否则失去
脱离当前 Windows job 的保证。返回 worker_pid 后检查该运行的 status，
只在确认 terminal 后判断成功/失败及临时目录清理结果。

## 6. 仍未完成

当前默认 tensor client / adapter / SoC 仍用标量模式。列模式未接受真实
22-stage adapter 的列请求，因而没有新的整机数值、帧率或资源结论。

后续需要将 3×3 窗口读改为显式列事务，保留非窗口标量访问；按行/列
正确落入 window_q 并与水平窗口复用配合，同时继续优化当前 5 拍/命中列
的服务间隔。完成后再进行真实网络、彩色双帧和故障恢复的新旧对照。

注意：历史 `perf_cache_rsp_count` 统计的是缓存接收的 refill 字，不是
列响应数。本报告的 columns 来自 testbench 的真实响应握手计数，不能将
上述历史 counter 直接解释为列吞吐率。
