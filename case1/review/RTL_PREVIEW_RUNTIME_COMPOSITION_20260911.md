# 预览运行时统一封装

日期：2026-09-11。新增生产 RTL `rtl/top/c1_r1_preview_runtime.sv`，组合
已验证的 runtime join 与 preview DMA，为实际顶层接线提供单一生命周期接口。

## 为什么封装在这里

当前 `c1_r1_boardless_frame_system` 的 frontend 将 engine_busy/done/error
直接连接 compute shell；portable SoC 的 Resize/CNN seam 从该模块导出。
只在 seam 上插入 fork/AXI writer，不调整这组完成信号，会遗漏预览退休条件。

新模块接受外部 compute_ready/busy/done/error，并输出 compute_start；
输入端接 Resize C8 token，输出 CNN 分支和一套独立预览 AXI 写通道。
对父控制器提供 start_ready/busy/done/error/code/address，预览状态额外导出
供诊断。只有 compute 与 preview 均 ready 时才原子启动；成功等待双方
done、busy 清零，包含预览最终 B 退休。错误第一到达者优先，同时错误时
compute 优先，沿用 runtime join 规则。

预览错误码默认 0x63，可参数化；预览错误地址在实际 compute_start（双方
启动握手）时锁存基址，不使用任务结束时可能已改变的实时配置。
DEST_REGION_BEGIN/END 传给真实 preview DMA/writer，默认完整地址空间。

父模块仍必须把 cancel 送给外部 compute；本模块只能取消内部 preview。
错误不等于自动取消，也不等于成功完成；必须保留父控制器的错误/取消
排空状态机。模块为同一时钟域，不是 CDC 桥或 DDR 适配器。

## 验证

原 `tb_c1_r1_preview_job_join` 保留分立实例，新增 `USE_RUNTIME=1` 使用
真实新封装。两配置分别完成十个任务，均通过：

- 3 成功、5 错误、2 取消，CNN/实际 XRGB 共比较 80 pixels；
- watchdog、晚 B、预览先完成/计算先完成、无复位恢复；
- DONE+预览错误、双方错误、取消+DONE 三种实际碰撞各 1 次；
- 启动同拍之后把实时基址改为 0xBAD00000，当前 AW 及预览错误地址
  仍为 0x1000，验证两处快照一致。

新封装模式在测试中把外部两项启动许可合并到 compute_ready，以模拟父层
准入限制；内部 preview_ready 来自真实 DMA，不对它强制赋值。分立模式
继续保留分别限制两个 ready 的原测试。

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_r1_preview_job_join -Python <python.exe>
```

两配置 exit=0；新封装要求 `C1_PREVIEW_RUNTIME_PASS` 和碰撞覆盖标志。
整机 queued-write 编译通过：132 sources、0 errors、608 条工具诊断。
本轮未重跑全量回归或物理实现，未生成波形；Icarus 临时文件由 runner 清理。

## 尚未接入部分

新增模块尚未在 `c1_r1_boardless_frame_system` / `c1_r1_portable_soc` 实例化，
不能据此声称第三路已集成。后续须同时完成：

1. boardless runtime completion 改用联合接口，dispatcher 等已有任务条件
   不能遗漏；父层取消同时到 compute 和预览。
2. 预览配置随输出槽/任务快照；独立地址区与其他帧/tensor/参数区不重叠。
3. Resize 输出接本模块，CNN 从分叉输出取数据；预览 AXI 接共享写 fabric，
   busy/error/QoS 纳入整机排空屏障。
4. pending/display pair 增加预览元数据，复用 output-slot 所有权；显示切换
   仍需旧读事务排空。完整 SoC golden 与跨帧恢复不能以本测试的行为 compute 替代。
