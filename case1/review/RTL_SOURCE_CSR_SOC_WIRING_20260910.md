# 源尺寸 CSR 与完整 SoC 接线

## 改动与兼容规则

`c1_r1_portable_soc` 将 0x060 `INPUT_FRAME_SIZE` 接入生命周期控制器，并启用控制器、boardless 的独立输入几何模式。控制器接受 START 时锁存源尺寸，随后采集帧表校验、输入 DMA 和 Resize 输入使用该快照，目标尺寸仍由原 FRAME_SIZE 控制。

规则是 **整个 32 位源尺寸寄存器为零时，继承目标 FRAME_SIZE**，保持旧软件不写新寄存器的行为；非零时分别取低 16 位宽、高 16 位高。不得对其中为零的半字分别补默认值，避免将非法配置偷偷变成有效任务。

采集结构并非运行时可任意改大小：当前 R1 ISP 的 3×3 valid Debayer 对固定 SENSOR_WIDTH/HEIGHT 每轴减少两个边缘像素。因此控制器的 REQUIRED_INPUT_WIDTH/HEIGHT 绑定 `SENSOR_WIDTH-2` / `SENSOR_HEIGHT-2`，软件给出的源尺寸必须匹配该构建的实际采集输出。CSR 写入不会重配置传感器硬件参数。

boardless Resize 的 MAX_WIDTH 改为目标宽度与采集输出宽度的较大值，避免源图更宽时仍按目标宽度配置行缓存。显示 subsystem 的容量参数同样考虑两者，但其既有每侧 640×480 限制继续保留；大图预览不是仅扩缓存即可完成。

`c1_accel.h` 已更新零值继承规则、固定采集尺寸要求，以及其他旧 wrapper 可能仅暴露 CSR 存储的区别。接口存在不代表那些 wrapper 已实现同样接线。

## 验证设计

整机数值 testbench 覆盖两条软件路径：

- 无 ResizeFixture：不写源尺寸，使用复位零值继承目标尺寸，单位映射；
- ResizeFixture：START 前显式写入 8×8 源尺寸，使用此前反向/分数 Resize 压力配置。

两者都在 START 后通过 APB 写入非零但宽为零的 `0x00080000`，读回确认影子写生效，再检查 boardless 的源尺寸仍为活动任务快照。恢复影子零值后才发送摄像头帧。新日志标记为 `C1_NUM_SOURCE_CSR_SNAPSHOT_PASS busy_writes=1`；任务结果继续用真实 CNN、物理 DDR 和两路显示 golden 检查。

这些运行仍是 8×8 采集输出/8×8 目标，因此是新接线的默认兼容、显式配置和忙时隔离证据，**不是真正不同源/目标尺寸的整机验证**。后者需要扩展摄像头 BFM、输入帧表、DDR 分配与原图显示 trace，再独立核对结果。此前异尺寸控制器/boardless/显示边界测试不能替代这一整机证据。

## 剩余工作

实测结果：全量 Icarus **123 配置符合预期**，完整 SoC 编译/展开通过（128 源文件、0 errors、603 条工具诊断）。安全脱离 Windows Job 的 xsim 运行 `review_source_csr_explicit_20260910`、`review_source_csr_legacy_20260910` 均 complete（74.057 秒、80.157 秒）。两者均包含源尺寸影子改写隔离 PASS，且 64 CNN 输入、22 stage/836 C8 输出、64 DDR 像素及原图/处理图各 64 显示像素均通过 Python `--require-video` 核对。两处临时 xsim 工程已确认删除，未保留波形。

真正异尺寸整机数值用例与错误源尺寸在 SoC/APB 边界的启动拒绝验证仍需补齐。超出 640×480 的原图显示仍需缩放预览或完整消费方案；本次不解除限制，不作 15 fps、资源、时序或板测结论。
