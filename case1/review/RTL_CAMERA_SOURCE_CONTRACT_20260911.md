# 相机输入源契约显式化

日期：2026-09-11。

## 问题

捕获前端既提供 `camera_valid/camera_ready`，原注释又要求源遵守 ready，但溢出条件为任何 `valid && !ready`。这适用于每拍不可重试的摄像头采样脉冲，却会将标准 ready/valid 源合法保持一拍的行为当成溢出。两者不能混用，也不能直接关闭真实摄像头的溢出保护。

## 实现

在 `c1_r1_capture_frontend`、`c1_r1_capture_subsystem` 和 `c1_r1_portable_soc` 尾部增加 `CAMERA_READY_VALID_SOURCE` 参数，并逐层传递：

- 默认 `0`：保持原有不可暂停采样模式。FIFO 满时的 valid 表示丢失的采样，报告溢出。物理摄像头/不支持背压的 CSI 输出应保留此模式。
- 显式 `1`：支持保持 valid 的可暂停源。`valid && !ready` 本身不是错误；保存被阻塞的完整 RAW10、坐标和帧标志，下一采样沿若提前撤销 valid 或改变任一位，报告源协议违例。
- ready 恢复时仍须保持原数据通过接受沿，不能借 ready 变高提前换成下一拍。
- 两种错误沿用 `camera_overflow` sticky 状态与核心域 `capture_error_code=0x01`，不修改软件地址或错误码 ABI。可暂停模式下该错误码涵盖源协议违例，不仅是容量溢出。

默认分支不引入 payload 保持寄存器。可暂停分支增加一份被阻塞 token 的寄存器、pending 位和比较逻辑；未经综合，不报告具体 LUT/FF 数字。协议违例检测不能修复已经损坏或丢失的帧，系统仍需沿现有错误/清理路径处理。

## 验证

新增源类型参数后、旧溢出逻辑尚未改变时，测试复现 `legal camera ready/valid stall reported overflow`。修改逻辑后，4 个事件/接口层用例通过：

1. 填满 FIFO 后保持 valid/payload，不溢出；释放空间并接受该拍后，撤销 valid 也不误报。
2. 可暂停模式下修改被阻塞数据，报告错误。
3. 可暂停模式下撤销被阻塞 valid，报告错误。
4. 默认不可暂停模式下满 FIFO 仍有 valid，保持原溢出行为。

同时核验错误通过 CDC 到达核心诊断，错误码为 `0x01`。上述填 FIFO token 是隔离入口契约的合成激励，不作为合法 ISP 光栅帧送去数值验证。

接入已有 `tb_c1_r1_capture_frontend` 时发现测试未遵循当前软件初始化 Gamma LUT 的契约，触发明确的未初始化读 FATAL。测试改为在捕获前通过正式接口写入 1024 项线性 LUT，每次检查 ready；没有移除或屏蔽生产 RTL 断言。原完整捕获测试随后通过：5 帧激励、2 次 ingress done、1 次 drop、1 次 abort、24 个输出像素及 4 次 cleanup。

最终捕获定向 **5 配置通过**；portable SoC smoke **15 配置通过**，包括 opt-in 参数值沿 SoC→subsystem→frontend 的接线核验。SoC smoke 仍是数据面空闲的结构/APB 测试，不是可暂停源的整帧 DDR 联调。

## 边界

没有改变板级 wrapper 的默认源类型。使用者必须根据真实源是否能保持 token 选择参数，不能对自由运行传感器盲目开启可暂停模式。独立时钟域热复位、违例后的整帧数值恢复、原生 640×480 吞吐和板级 CSI 时序不在本轮证明范围。

本轮未重跑全量；最近一次全量仍是此前 RTL 的 428 配置，不能作为新增模式的全量验证证据。没有启动 xsim、综合或板测，不生成波形；测试脚本清理临时编译文件和向量。
