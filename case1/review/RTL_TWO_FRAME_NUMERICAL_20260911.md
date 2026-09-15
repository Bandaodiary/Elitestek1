# 真实 CNN 两个成功帧的数值验证

日期：2026-09-11。本轮扩展仿真和独立 golden，不修改生产 RTL。

## 原基线

运行 `review_trained_two_frame_baseline_20260911`：真实 portable SoC、训练参数、tensor burst refill、寄存故障广播，两个 8×8 任务不复位连续运行。

结果 complete / exit 0，162.456 s：done=2、swaps=2、drops=0、descriptors=44，AXI AW/W/B=1704/1736/1704。该模式只提供任务与换帧证据，不能仅凭这些计数认定两帧像素正确。

## 新增独立双帧模式

`run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -TwoFrame -TwoFrameTrace -TrainedArtifact -TensorBurstRefill -RegisterFatalTicket`

仅支持当前 8×8 训练图，不能与单帧 NumericalTrace 混用。输入为两幅灰度线性 RAW10，tone 分别为 0 与 32；identity ISP/Gamma 和单位 Resize 后，第二帧各通道比第一帧高 8。无饱和或回绕。

- 保留两个独立 BEGIN/END 边界，分别要求输入/输出槽索引 0、1。
- 每帧记录 64 个 CNN 输入、22 层共 836 个 C8 输出。
- 真正的 boardless_done 时，检查解析后的源/目的基址与本任务槽一致，再导出 64 个物理 DDR 像素。
- 检查每个 DDR 像素四字节都曾被实际 WSTRB 写入，不仅检查读回数值。
- 双帧跟踪固定使用地址键控的内存模型，避免小型直接映射模型冲突。
- 最后严格要求 2 次任务完成、2 次换帧、0 个错误，而不是仅统计第二槽准入。

文本保留使用既有 `C1_NUM_` 有界日志机制，不保存波形。原单帧跟踪与校验器未放宽。

## Python golden

`golden/check_portable_soc_two_frame_trace.py` 从独立 RAW10 公式生成两幅输入，调用整数模型计算每一层及最终 RGB；逐项检查行序、通道、层/组编号、数值和 DDR 图像。校验器不使用观测到的 CNN 输入反推参考结果。

严格拒绝未知值、帧间串扰、记录重复/缺失、提前 END/PASS、错误槽位。`--self-test` 在已通过的真实日志上做内存变异，不生成大批临时文件。

## 调试记录

第一次数值运行 `review_two_frame_numeric_20260911` RTL 流程 complete / exit 0，164.836 s，但 golden 拒绝第二帧第一个输入。原因是最初补丁改变了另一个恢复分支，真正 TwoFrame 分支仍发送旧 tone=341。第一输入 `0xf0f0f0` 对应该旧夹具；不是所约定的 tone=32，也不能据此指控生产 RTL。

已恢复无关恢复分支，修正实际 TwoFrame 分支，并以 `review_two_frame_numeric_final_20260911` 重新运行。结果 complete / exit 0，157.705 s。独立 golden 通过：128 个输入、1672 个逐层 C8 结果、128 个 DDR 像素；19 项负向变异检查通过，包括缺失/重复边界、像素或 PASS、错误数值、未知值及第二帧混入第一帧输入。未修改 golden 的预期以迁就错误夹具，也未把首次数值运行记为通过。

三次运行均由独立 WMI worker 启动，未绑定 Codex Windows Job。完成后已检查三个仿真目录均不存在；只保留紧凑文本日志和状态。未运行物理综合，也未为纯验证改动重复宣称新的全量 RTL 回归。

## 范围边界

该双帧模式覆盖真实摄像头输入、ISP、CNN、DDR 写回及两个槽的成功换帧。但本轮新 golden 尚未记录和核对两帧最终显示像素，也未启用 Resize 预览第八客户端；这两点不能由上述 DDR 证据替代。原生尺寸 15 fps、实际 Efinity 资源/时序与板卡联调仍未完成。
