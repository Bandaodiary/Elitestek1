# 跨任务区域占用：现有边界与接入契约

日期：2026-09-11。性质：依据当前生产源码形成的实现约束，**不是已实现的全局隔离器**。

实施进展：图像申请互斥与记录见 `RTL_IMAGE_WRITE_ADMISSION_20260911.md`，tensor/图像隔离见 `RTL_TENSOR_ARENA_ADMISSION_20260911.md`，当前权重/描述符/帧表保护见 `RTL_STATIC_ARTIFACT_ADMISSION_20260911.md`。任意软件区域、外部主机写入和完整下游退休边界仍待审计，因此本文的全局契约尚未全部实现。

## 为什么不能只延长一个 busy

当前 `c1_r1_soc_control` 在 manager_abort 时清空 capture_writer 的配置输出；`c1_axi_xrgb_frame_writer` 则在 start 时自行锁存 base/stride/geometry，并保持已提交 AXI 直到 B 响应退休。这符合现有 DMA 契约，但前者不能直接用作取消期间的物理区域占用记录。

反过来，DMA busy 清零也不能表示帧区域可重用：已捕获且 READY_NN 的图像仍属于输入槽；完成但 READY_DISPLAY 的图像仍属于输出槽。帧数据所有权比单次总线事务更长。

## 已有生产入口

| 资源 | 当前启动/地址来源 | 必须保留至何时 |
| --- | --- | --- |
| 输入三槽 | SoC capture table response，经启动前 guard 后发 writer-start | 捕获写退休后转为帧占用；经过 READY_NN、NN 输入读取及原图显示，直到槽所有者真正释放 |
| 处理图两槽 | job frontend 的 pair resolver；input/output DMA 与 engine 原子启动 | 输出 B 退休后转为待显示占用；旧显示读退休且完成换帧释放 |
| 预览两槽 | portable SoC 固定地址，与 processed output index 绑定；preview runtime/join | 不能早于预览 B 与计算参与者退休；随对应输出帧的显示所有权释放 |
| tensor arena | MicroStyle adapter 的 tensor_base 快照与三个 bank | 整个计算任务及 tensor AXI 排空结束；不能以 CNN 最后一个输出 token 代替外部响应退休 |

源码入口：`c1_r1_soc_control.sv`、`c1_frame_manager.sv`、`c1_r1_job_frontend.sv`、`c1_r1_boardless_frame_system.sv`、`c1_r1_preview_runtime.sv`、`c1_r1_microstyle_tensor_adapter.sv`。portable SoC 当前固定每个 tensor bank 为 8 MiB，adapter 使用三个 bank；这是当前构建事实，不等于所有参数化实例都固定 24 MiB。

## 正确的接入次序

1. 建立独立于 live CSR 和 abort 清零控制状态的区域记录。记录候选的 base、stride、width、height、资源类型、槽/任务身份以及 valid/排空状态。只在明确申请接受边沿生成记录。
2. capture 在实际 writer-start 之前申请；计算在 frame pair 已解析、运行参与者原子启动之前申请输入保留及 output/preview/tensor 需求。此时两条路径都尚未发出属于新任务的写事务。
3. 两个入口共享区域申请仲裁或等价的原子检查提交机制。不能让双方各自在同一份旧区域表上独立检查成功，然后同时写入重叠区域。
4. 已持有的输入帧从 capture owner 移交到同一帧的 NN/display owner，不应被误判为新的跨任务冲突。读读共享可允许；新写者对其它帧已保留的数据必须检查。
5. 普通完成将写事务状态转换为帧保留状态，而不是无条件清 valid。槽释放与 AXI 退休都满足后才能真正释放物理占用。
6. abort 只取消未提交申请。已接受事务和仍显示的帧不能因 manager 清理非显示槽而提前清掉物理记录；取消任务须等待对应 writer/reader 与外层 fabric 排空。

申请可以顺序比较并短暂互斥；已经通过申请的 capture、NN 和 display 应继续并行运行。不能以禁用 continuous/concurrent 模式代替隔离，也不应只向 SoC 添加一个未连接的比较模块。

## 范围与一致性要求

- XRGB 保留精确有效行检查与合法 padding 共享。tensor 等连续 arena 使用其实际分配范围。不同资源类型不能简单用图像尺寸推断。
- exclusive end 必须能表示 2^32，乘加不得先在 32 位回绕。
- table 内容在软件中可变时，后续消费者不能悄悄把同一已占用槽解析成另一个区域。需在申请/转移处核对物理元数据一致性，或复用已登记快照。
- 发布 pending、VSYNC 更新 current 与旧读事务退休是不同事件。不能仅凭 current 指针改变就释放尚有事务的旧区域。
- 参数、描述符和 CPU 可写数据的静态 arena 边界也应纳入最终工程内存布局契约；当前图像三帧 guard 不覆盖所有内存用途。

## 验收用例

- 已存在的捕获别名、NN 完成发布、VSYNC 重试及合法不重叠对照继续通过。
- capture 与计算同拍申请部分重叠区域，只能有一个被接受；输家报错或按明确协议等待，不能双方启动。
- 已捕获 READY_NN 图像、待显示图像以及当前显示图像均不能被其它 writer 覆盖。
- 在最后 B/R 到来前取消，区域仍不可申请；B/R 退休后按帧所有权规则释放。
- START 之后篡改表项不得改变已持有槽的区域；拒绝后的下一合法任务能无复位恢复。
- 合法并行任务不被串行化；记录实际预检周期和并行时段，区分检查开销与计算吞吐。

上述契约尚未全部实现。当前已有图像原子申请、输出槽记录、单 NN 配置下的 tensor/图像检查及四类静态数据保护，不能替代任意软件区域、外部写入和完整退休边界的后续工作。
