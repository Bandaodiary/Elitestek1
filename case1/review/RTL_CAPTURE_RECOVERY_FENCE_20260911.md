# 捕获恢复双域清理控制模块

日期：2026-09-11。

新增 `rtl/top/c1_capture_recovery_fence.sv`，复用现有
`c1_display_flush_reset` 的双域复位确认机制，将 pixel 接口映射为 camera。
这是独立可综合组件，**尚未实例化到 frontend/subsystem/portable SoC**，
也未新增软件寄存器或板端传感器复位操作。

## 接口契约

- request 只在 request_ready 时接纳；持续高电平仅执行一次，必须撤回后
  才可再次接纳。busy 期间未接纳的请求不排队；调用方需按握手保持请求。
- 接纳后 busy 保持，直到 source_quiescent 与 fabric_drained 都为真才
  开始清理。两者必须来自外部真实安全条件，不能用 !camera_valid 代替源
  已停止的确认，也不能忽略尚未获准的 AXI VALID。
- 复用的握手先保持 core reset，再跨域断言 camera reset，等待实际 camera
  边沿采样后的确认，撤回 camera reset 后等待释放确认，最后释放 core reset。
- 摄像头时钟停止时没有虚构 ACK 或固定时间完成；必须恢复该时钟才能完成。
- 调用方从请求接纳至 done 都必须保持新任务关闭、源停止和物理占用记录。
  所有 AXI 接口仍走既有取消排空路径；本模块不复位 AXI，不撤回在途事务。
- 全局 core_rst/camera_rst 要协调断言。独立运行域复位不在本模块契约内。

与原 display flush 不同的是请求接纳层：原模块在持续 request 下完成后可
再次启动，本模块通过 armed 状态避免旧请求反复清掉新数据；原显示模块不变。

## 验证

`tb_c1_capture_recovery_fence.sv` 连接真实深度 16 的 c1_async_stream_fifo。
camera 半周期 3/7/17 ns、core 半周期 5 ns，共 **3 配置通过**。
每种配置执行正常时钟、复位前停止 camera clock、复位期间停止 camera clock
三轮。覆盖 source 确认先到与 fabric 排空先到，两者缺一都不能开始复位。

每轮预填 7 个旧 token，等待安全条件期间要求旧头数据仍可见；复位完成后
要求 FIFO 空。request 持续为高跨过完成并继续写入/读出 7 个新 token，
逐个检查顺序和数值，确认没有重复 flush。每配置共清除 21 旧 token、
核对 21 新 token、完成恰好 3 次。暂停时钟期间 busy/reset 保持 31 core
周期；未在没有 camera 边沿的情况下误报完成。

定向命令：`run_iverilog_review_fixes.ps1 -Python <含 NumPy 的 Python> -TestTop tb_c1_capture_recovery_fence`。
本轮未重跑全量（最近 547）、xsim 或 Efinity，没有资源/时序结论。

## 下一步

把模块接入捕获路径时，需要分别处理 FIFO 双域 reset、ISP 局部 frame_flush、
frontend 状态机退出以及 SoC 所有权保持。首先应做实际前端的显式恢复端口，
再验证恢复请求期间 camera clock 停止、AXI 延迟及软件请求重复，不直接
将这里的 3 个单模块通过等同为永久停流整机恢复已经完成。
