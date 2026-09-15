# 捕获前端的显式双域恢复接口

日期：2026-09-11。

新增默认关闭的 ENABLE_EXPLICIT_RECOVERY，以及尾部端口 recovery_request、
recovery_source_quiescent、recovery_fabric_drained、recovery_ready/busy/done。
只接入 c1_r1_capture_frontend，**尚未向 subsystem、portable SoC 或 APB
提供端到端软件操作**。默认关闭时新输入不影响行为，输出固定为 0。

## 实际连接

- 请求接纳后，recovery_busy 纳入 cleanup_busy 并关闭 frame_waiting。
- FIFO 读出和 ISP 输入暂停；RAW guard 输入同时暂停，避免 FIFO 未弹出
  却让 guard 私自前进。停流计数在显式恢复期间停止。
- 等待安全确认期间不复位 FIFO，也不提前清除旧帧；已进入 ISP 的结果
  可继续向旧输出路径排出。调用方必须取消下游 writer、停止源并保持接纳
  关闭，不能用这个接口代替 AXI 取消协议。
- 两个安全确认均满足后，双域握手复位摄像头异步 FIFO；core 域同时
  清理 ISP 像素流水和 RGB FIFO，前端回到 IDLE，guard 取消旧计数状态。
- core reset 保持到 camera 释放确认返回；camera clock 停止时不宣布完成。
- capture_error 保留，恢复完成后仍需显式 clear_error；ISP active 配置
  和 Gamma RAM 保留。配置写操作应与恢复操作串行，不能在等待安全条件时
  任意改写配置并同时要求“配置未变”。
- request 持续为高不会重复清理已经恢复的新帧。

新增依赖加入捕获 xsim 源清单和 Efinity portable SoC 源清单；本轮只解析
清单/脚本，不将更新源清单等同为综合或目标工程集成已通过。

## 验证

真实前端（含 FIFO、guard、ISP）新增 6 配置：camera 半周期 3/7 ns，
正常时钟、camera clock 停在复位前、停在复位期间三种情况。

先接纳 20-token 前缀并触发 0x06 超时，再接纳显式恢复请求。在源尚未
确认静止期间输入 30 个旧尾部 token，确认它们冻结于 FIFO 而非被当成 EOF
消费；随后 source_quiescent 到达，fabric_drained 未到时仍不能开始复位。
camera clock 暂停期间检查 31 个 core 周期 busy/cleanup 保持。

done 后旧 FIFO 和 RGB 状态为空，错误保持；清错但不 reset、不重写
ISP/Gamma，输入新的完整仿射 RAW 图像，逐像素/逐标记检查 20 个 RGB。
request 继续保持为高，验证不会重触发清理。

前端整组 Icarus **86 配置通过**，退出码 0；其中新增 6。命令为
`run_iverilog_review_fixes.ps1 -Python <含 NumPy 的 Python> -TestTop tb_c1_r1_capture_frontend`。
本轮未跑全量（最近 547）、xsim 或 Efinity。

## 下一项门槛

将接口接入 subsystem 时必须用实际 writer/表读取的取消排空作为安全条件，
再在真实 SoC 保持物理地址记录直至 recovery_done。source_quiescent 必须
来自源停止确认，不能使用 !camera_valid。没有 camera clock 时仍不保证
恢复完成；需要平台恢复该时钟，或另外设计有验证依据的复位架构。
