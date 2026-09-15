# APB 整机恢复与缓存重复取消死锁修复

## 实际发现

将永久停流场景改为仅通过 APB 0x130 发起恢复后，出现新的整机死锁。
故障自动取消之后，软件恢复再次触发取消。读写 fabric、计算、参数、显示、
bridge 和 adapter 均已空闲，但 tensor cache busy 始终为 1。

`c1_tensor_window_cache_burst_axi_client.sv` 的取消汇合逻辑在第二次请求时
无条件清除 `abort_burst_seen_q`。第一次取消的子缓存确认可能已经到达，而
上层仍在等本地/bridge 响应排空。子缓存看到的请求由 pending 保持为高，
不会发第二次确认；因此清掉已有确认会让父层永久等待。flush 有相同代码
结构。

修复：仅在开启一个新的 pending 过程时清除子确认；pending 期间的重复
abort/flush 合并到当前排空过程，保留已收到的确认。不缩减总线排空条件，
不以超时伪造完成，也不强制清 busy。

## 验证与失败记录

- `apb_recovery_soc_20260911`：停在确认后的等待，人工停止已核实归属的
  kernel；worker 正常记录失败并清理。其他会话仿真未操作。
- 增加 1024 周期局部握手超时与阻塞信号打印，
  `apb_recovery_diag_20260911` 明确报告 cache=1、其余相关客户端已排空。
- 修复后 `apb_recovery_fixed_20260911` detached xsim 通过，122.222 秒，
  退出码 0。Python `--require-apb-recovery --require-late-source-ack` 通过。
  APB 能读故障码 0x46、接纳命令、拒绝重复命令、读完成并清除；硬件请求
  保持低。两个在途 B 阻塞 64 周期、DDR 排空后等源确认 32 周期期间保持
  占用，恢复后无全局 reset 完成新任务。
- 22 阶段、836 C8 结果、64 DDR 像素及 120+64 显示像素正确；AW=B=874，
  W=924，在途峰值 2。
- 专用 testbench 增加响应保持 40 周期后重复取消刺激；
  `repeated_abort_fixed_20260911` detached xsim 通过（10.244 秒）。该测试
  尝试 Icarus 时超过 30 秒，不计为通过；未纳入默认 Icarus 全量列表。
- 新增 6 个 APB 证据负测试，与原有合计 37 个通过。

上述四个运行临时目录均已确认不存在；只保留精简日志。没有手工删除其他
历史产物。未重跑全量 Icarus（最近 596 是 APB 修改前结果）或 Efinity。

## 范围与下一项

软件整机验证为寄存 fatal ticket、小帧灰阶斜坡和排队写配置；不能推广为
所有参数组合。重复 abort 已有专用及整机证据，重复 flush 的对称修复尚需
独立定向刺激。还应审查其他层级的取消/flush 汇合状态是否存在同类重复
请求清除确认问题，补全量回归，之后完善软件轮询封装和板级源控制契约。
