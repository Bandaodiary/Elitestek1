# SoC 队列写参数与协议故障接入

日期：2026-09-11。

## 已完成的实际接线

`c1_r1_portable_soc` 新增三个参数并传入实际 `u_memory_fabric`：

- `FABRIC_WRITE_FIFO_DEPTH=0`：默认原串行写；2..255 启用队列写。
- `FABRIC_WRITE_W_AHEAD_OF_B=0`：W/B 解耦开关。
- `FABRIC_WRITE_EMPTY_AW_BYPASS=0`：空队列 AW 旁路开关。

非零队列深度同时启用 `c1_r1_soc_control.ENABLE_FABRIC_FAULT`，连接
实际仲裁器的 `write_protocol_error` 与 `write_busy`。默认值均不改变生产行为。
这次不是仅添加孤立模块或顶层形参，参数、故障和忙状态均已实际连接。

## 故障契约

`c1_r1_soc_control` 对写协议错误实施复位才能解除的准入锁：

1. 原始错误或已锁存错误均立即关闭正常任务操作、参数加载、boardless 启动、
   采集表请求和后台 display prefetch 新启动。
2. 错误进入现有故障报告链，同时持续广播取消给相关子模块；不复位 writer，
   不撤回其已呈现的 AXI 请求，也不伪造 B 响应。
3. 已接受但未退休的 fabric 写描述符参与 status_busy。具体子模块的
   cleanup/flush 也继续参与 busy；协议硬故障期间 busy 不保证能够自行清零。
4. APB ERROR_CODE=0x14，ERROR_ADDRESS=0。零地址表示无可信故障地址，
   不是断言地址 0 发生了写入。
5. 软件 ABORT、IRQ W1C、system disable/re-enable、重复 START 均不能解除锁。
   只能由控制器与 fabric 的共同复位解除；真实板级复位还需满足 DDR/AXI
   的事务复位契约，不能把单侧复位当成正常排空。

这是非法协议流的处理，不是普通非 OKAY BRESP。合法归属的错误响应仍由
原 writer/job 错误路径处理；不能因此把每个可恢复任务错误升级为硬锁。
原 direct/registered fatal report 行为保留；显式 ABORT/disable 后既有报告
抑制状态会重新建立，可能再次报告仍然存在的硬故障，不表示锁已解除。

软件头文件新增 `C1_ERROR_FABRIC_WRITE_PROTOCOL` 并说明上述恢复限制。

## 验证

### 控制器四配置

同尺寸/独立源尺寸各自组合 direct/registered fatal ticket：注入一拍协议错误，
并模拟仍有待退休 fabric 写事务。检查忙状态、持续取消、禁止所有新启动、
第一轮错误恰好一次及 code/address、ABORT/disable/START 不解除锁、共同复位
后能重新武装任务。四配置均通过。

```text
C1_SOC_FABRIC_FAULT_PASS ticket=0 code=14 pulse_latched=1 pending_busy=1 reset_only_unlock=1
C1_SOC_FABRIC_FAULT_PASS ticket=1 code=14 pulse_latched=1 pending_busy=1 reset_only_unlock=1
```

此处模拟的是 fabric busy 信号，不等于本测试实际提交了一个 DDR burst。
真实双 writer 已提交事务的取消排空由前几轮共享 fabric 测试覆盖。

### 完整 SoC 的实际外部故障注入

扩展原 `tb_c1_r1_portable_soc_smoke`，队列深度 4、W ahead、AW bypass、
QoS 实际启用；从 SoC 外部 B 通道注入 orphan B，不强制内部故障信号。
经真实仲裁器 → 控制器 → CSR，读取 ERROR_CODE/ADDRESS；验证 W1C、ABORT、
disable/re-enable 无法重新发出 AXI 请求，最后共同复位清除两侧故障状态。
原默认 smoke 及队列模式的两种 fatal ticket 配置均通过。

```text
C1_SOC_QUEUED_WRITE_FAULT_PASS ticket=0 physical_orphan_B=1 apb_code=14 no_axi_restart=1 reset_unlock=1
C1_SOC_QUEUED_WRITE_FAULT_PASS ticket=1 physical_orphan_B=1 apb_code=14 no_axi_restart=1 reset_unlock=1
```

首次测试将故障后的 START 当成正常 APB 写，实际因持续 cleanup fence
导致 busy 而返回 PSLVERR。已修改测试，明确要求该次 START 的 PSLVERR=1；
其他 APB 写仍要求 PSLVERR=0，没有放松总线检查。

这个整机测试的数据面保持空闲，只注入非法 B，因此不等于队列模式下完整
CNN 数值、真实多 writer 满载或大图性能已经通过。

### 编译

`run_iverilog_rtl_compile.ps1` 新增 `-QueuedWriteFabric`，明确展开上述
深度 4/W ahead/AW bypass/QoS 组合，默认和新分支均为 131 源文件、0 errors。
工具诊断分别为 603/608 条，不能称作无警告。

本轮未调用 Vivado/xsim、Efinity 综合、PNR 或板测，不增加 Fmax/资源/fps 结论。
最终完整 Icarus 回归 **141 配置符合预期**，已包含新增三个 SoC smoke 配置。
此前一轮 138 配置也通过。最终回归期间生产 RTL 和测试未修改；只更新说明文档。
runner 不生成波形，临时镜像和生成向量已清理。

## 下一阶段

用真实 CNN/DDR BFM 对新参数配置跑逐像素整机回归，检查正常任务中的多笔写、
错误响应、取消及有未退休事务时的协议故障。之后才能考虑默认启用；预览第三
帧槽的预检/所有权与实际预览流接线仍是独立未完成工作。
