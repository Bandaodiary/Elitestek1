# 任务成功排空：完成发布边界审查与修复

日期：2026-09-12。范围：EDA/板卡无关的公共任务控制器及其系统集成。

## 1. 已证实的问题

`c1_r1_job_controller.sv` 收齐 input DMA、output DMA、descriptor executor、engine
四个完成事件后，在 `STATE_DRAIN` 中等待所有 client busy 降低。旧实现只保留
`drain_for_success`，不再处理此期间的取消或运行时错误，因而“已经报告计算完成”
被错误地当成“成功结果不可再否决”。

这是可复现的功能错误，不是时序推测：

- 公开接口驱动所有完成脉冲，继续保持 client busy；此后取消，旧实现没有发出取消。
- 取消与最后 busy 下降同拍，旧实现仍输出 `job_done=1`。
- output DMA error 与最后 busy 下降同拍，旧实现同样输出 `job_done=1`。

证据分别保存在 `logs/success_drain_reproduction.log`、
`logs/success_drain_cancel_edge_before.log`、`logs/success_drain_error_edge_before.log`。
第一次新增 TB 因 pair/config 错误信号命名不正确而绑定失败，记录在
`logs/success_drain_before_fix.log`；它不是 RTL 缺陷证据，修正 TB 后才取得以上反例。

## 2. 修复后的合同

成功只在实际对外发布的边沿提交；发布前仍允许当前任务的取消/错误否决。

| 当前状态 | 新事件 | 处理 |
| --- | --- | --- |
| 已启动任务的成功排空 | abort，可与错误同拍 | 改为取消排空，descriptor/engine 各发一次取消脉冲，不发布 DONE |
| 已启动任务的成功排空 | 运行时错误 | 改为错误排空，锁存错误信息并各发一次取消脉冲 |
| 成功排空 | 无取消/错误且全部 client idle | 按原路径报告一次 `job_done` |
| 已确定错误/取消的排空 | 后续错误或取消 | 不重分类终态、不改写首个错误、不重复发送取消 |

同时错误仍按原 RUN 优先级：input DMA → descriptor → engine → output DMA。
只采样当前任务运行时错误，不把已完成 preflight 的 pair/config 旧错误当成新故障。
已发布完成的任务不回滚。watchdog 原有 preflight/wait/run 计时边界不变，不用超时
强行抹除仍在进行的 AXI 事务。

没有新状态、寄存器、RAM、MAC、总线端口或配置开关；复用原错误/取消锁存与 drain
条件。正常成功路径周期不变，晚到取消/错误转入原排空路径，继续等待物理 client idle。
本修复不是默认关闭的性能实验，而是所有配置共同使用的正确性修复。

## 3. 修改文件

- `rtl/control/c1_r1_job_controller.sv`：在成功排空的完成发布前增加取消/错误优先判断。
- `sim/tb_c1_r1_job_controller.sv`：10 类事件 × 2 个边界条件；保留原26任务回归和3种复位边界。
- `sim/tb_c1_r1_boardless_frame_system.sv`：新增公开 job_abort 驱动的真实 DMA 完成边界测试。
- `scripts/run_iverilog_review_fixes.ps1`：注册上述20种新控制器配置。
- `scripts/run_r1_boardless_frame_system_xsim_detached.ps1`：新增 `-SuccessDrainCancel`，
  可与 `-Preview` 配合；保留 WMI 分离运行与临时工程清理。

没有修改算术核心、模型、descriptor/权重 ABI、缓存或 AXI 数据格式。

## 4. 验证覆盖

### Icarus

24种 controller、58种 job frontend、172种 SoC control 配置，共254种完成回归。
controller 定向用例覆盖独立运行时错误、同时错误优先级、abort+error、已有错误/取消
不被覆盖、旧 preflight 错误隔离，以及正常完整任务的无复位重启。
每个事件分别在 busy 尚未清空时与最后 busy 下降同拍发生；没有强制 DUT 内部状态。

日志：`logs/success_drain_controller_after.log`、`success_drain_frontend_regression.log`、
`success_drain_soc_control_regression.log`。

### xsim：真实 boardless 数据路径

目录前缀为 `logs/r1_boardless_frame_system_runs/`：

| Run ID | 已验证内容 |
| --- | --- |
| `boardless_success_drain_plain_20260912_a` | 正常帧→最终成功发布前取消→无复位正常帧；3个任务、2次成功、1次取消 |
| `boardless_success_drain_preview_20260912_a` | 同上，开启真实 preview DMA/runtime join；恢复图像24像素正确 |
| `boardless_success_drain_compat_20260912_a` | 原9任务集成回归：正常、配置/运行错误、AXI排空、取消等；2成功/5错误/2取消 |
| `boardless_success_drain_bresp_20260912_a` | 真实 preview BRESP=SLVERR，保持24拍后排空，code63/address6000，随后无复位恢复 |

新边界测试在观察到正常执行进入成功排空后，直接驱动公开 job_abort；不 force 内部
状态、不伪造完成、不直接复位DMA。取消时同时尝试 START，验证不能把旧任务算作成功
或重新分配；真实 AW/W/B 和 client busy 必须先退休。输出区域已有像素并不等于任务成功。

### xsim：完整 MicroStyle / DDR / 显示

目录前缀为 `logs/portable_soc_cache_ddr_bfm_runs/`：

- `soc_success_drain_64x48_20260912_a`：完整22逻辑层训练权重 golden、19个物理输出
  阶段、最终3072个DDR/显示像素通过。周期仍342,287，C8读3456/写28608；
  AXI AW/W/B仍4035/16128/4035，与上一阶段相同配置一致；452项检查器负测试通过。
- `soc_success_drain_pf_abort_20260912_a`：owner7真实4beat读保持64拍、取消排空、
  12×10输入到8×8输出无复位恢复；恢复帧24,274拍，最终596个C8结果及DDR/视频通过；
  501项检查器负测试通过。

上述结果是功能仿真证据，不是 Efinity Fmax、资源或实体板帧率。

## 5. 关联审查与剩余边界

`c1_r1_runtime_join.sv` 已在真正完成边沿检查 cancel/error 与 children_idle；本次未发现
相同的“成功排空后不再否决”实现缺口，无需覆盖该模块。SoC 控制回归继续覆盖同拍
abort/DONE 和 fatal/DONE 优先级。

本轮未更改宽数据路径，也未新增物理综合/布局布线结果；新控制组合条件的实际 LUT
和时序影响仍需目标工具确认。原生640×480、15fps吞吐尚未证明，上一阶段8,928,000拍
仅是理想工作量下界。全局复位不能作为在途事务取消的替代：外部 AXI 永不响应时必须保留
事务归属，不能以“快速结束”为理由伪造排空。

上述六次xsim均complete/exit0，worker均退出、临时工程目录均不存在；仅保留1.618MiB
文本证据。总审计为`logs/success_drain_closure_audit.log`，阶段记录见`DEVELOPMENT_LOG.md`。
