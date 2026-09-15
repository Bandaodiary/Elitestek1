# 八客户端 SoC 预览末 B 故障路径

## 测试目的

在真实 MicroStyle、Resize、预览 DMA 与共享 queued-write AXI 上注入错误，
验证 boardless 层的故障处理在最外层 SoC 中仍成立。生产 RTL 本轮未修改。

`run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -PreviewCapture
-PreviewBrespError` 新增定向模式：彩色 RAW10 12×10 → 8×8，真实训练参数、
tensor burst refill 与请求接续，打开 REGISTER_FATAL_TICKET；不启用第二次
并发 capture，以隔离预览响应故障。此模式的任务故意失败，不运行完整
单帧成功 golden，也不把部分 CNN 输出宣称为完整推理。

## 注入与检查

BFM 仅对 slot 0 最后一行（AW=0x010000e0）对应的物理 B 返回 SLVERR。
该 B 额外延迟 64 cycles；在延迟期间必须保持 system/boardless busy，禁止
报告成功。响应在 AXI 握手前保持稳定，不强制修改 DUT 内部信号，也不发
软件 ABORT。随后要求：

- 控制错误恰好一次，APB code=0x63 / address=0x01000000。
- 所有已接收写事务 AW/W/B 排空；读状态和任务 busy 退出。
- 成功帧数和显示 swap 都为零，控制器解除 armed，且未触发协议损坏锁定。
- 预览 8 AW / 16 W / 8 B；末 B 故障时 CNN 支路仍有一个待接收像素。
  故障取消后 CNN 仅接收 63 像素，这是两个独立消费者的合法取消行为，
  不是成功帧丢像素。正常成功测试仍严格要求 64 个 CNN 输入。

原来全局禁止控制错误的断言仅对“真实注入一次且 code/address 完全匹配”
作定向例外；其他控制错误、CNN/compute 错误仍立即终止测试。

## 调试记录

1. `review_soc_preview_bresp_20260911` 已观察到 code=63，但被原全局
   禁止控制错误断言提前结束；增加上述精确例外。
2. `review_soc_preview_bresp_final_20260911` 的失败显示 CNN 最后一个像素
   尚未接收。错误测试不能套用成功路径的 64 像素约束；改为同时要求
   63 次 CNN 握手与实际故障 B 握手时存在 pending CNN token。

最终复验：`review_soc_preview_bresp_pending_20260911`。

结果 complete / exit 0，13.341 s：末 B 实际等待 68 cycles；errors=1、
done=0、swaps=0，预览 8 AW / 16 W / 8 B，CNN 63 次握手且故障时 pending=1。
共享总线共 81 AW / 109 W / 81 B，峰值 outstanding=2，W-ahead=8，均排空。
正常不注入模式 `review_soc_preview_bresp_compat_20260911` 的编译/展开通过；
该兼容检查未运行仿真。没有重跑全量 155 配置或成功帧 Python golden。

所有 xsim 运行仍通过 WMI 脱离 Windows Job；无波形，四个测试运行的临时
目录均已自动清理，仅保留小型状态和诊断日志。

## 尚未覆盖

本测试不证明故障后无复位完整重算，也不证明连续两槽均成功。仍需补上
这两项、八客户端末 B 阻塞软件取消，以及预览显示元数据/源切换。
