# 取消排空期间的 RAW 停流检测

日期：2026-09-11。

## 问题

上一版 RAW_IDLE_TIMEOUT_CYCLES 仅计数 ST_STREAM。主动取消后若仍有
ISP 帧状态，前端会进入 ST_DRAIN_RAW 并等待剩余 RAW；这期间源停止，
看门狗不再计数，无法产生 0x06 或局部 ISP flush。

新增 RASTER_CASE=7 / RASTER_ABORT=1 测试：20-token 前缀的最后一个
token 处断言 abort，随后源停止，等待超时错误后再恢复。旧 RTL 在
IDLE_TIMEOUT=16、CAMERA_HALF=3 下运行至 testbench 1 ms 超时失败；
源等待硬件错误，硬件却因状态已退出 ST_STREAM 不再计数。

## 修复

raw_idle_wait 改为 checking_raw 且输入 FIFO 为空：正常采集仍要求
input_has_headroom，已进入 ISP 的取消排空不要求 RGB FIFO 余量（其输出
本来就被丢弃）。checking_raw 只包含 ST_STREAM 和 drain_through_isp=1
的 ST_DRAIN_RAW，静默维护不会被纳入。

达到阈值后沿用 0x06/局部 flush/ST_RESYNC，不自行完成帧、不撤回已提交
AXI、不释放帧缓冲区。持续 abort 不阻止超时分支，解除 abort 也不代替
新的 SOF/EOF。参数默认 0 和其他状态的行为不变。

## 验证

两种阈值 16/33 × 两种 camera 半周期 3/7 ns，新增 4 个取消后停流配置。
保留原正常采集停流 4 配置以及精确阈值检查。新增配置验证 abort 计数一次、
0x06、局部 flush 后继续等待 64 周期、下一 SOF 保留、无 reset/无配置重载
恢复，20 个 RGB 输出逐像素和逐标记正确。

前端整组 Icarus **78 配置通过**，退出码 0。命令：
`case1/scripts/run_iverilog_review_fixes.ps1 -Python <含 NumPy 的 Python> -TestTop tb_c1_r1_capture_frontend`。
本轮不重跑全量或整机 xsim，故不能
把之前正常采集超时的整机通过结论扩展到这次“软件取消后停流”组合。
永久停止仍需源恢复或未来明确的源复位契约，不能认为超时已保证软件完全退出。
