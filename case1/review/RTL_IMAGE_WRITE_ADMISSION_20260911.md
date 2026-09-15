# 图像写入口的原子区域申请

日期：2026-09-11。范围：不依赖具体 EDA/IP 的图像区域所有权保护；不是完整 DDR 内存隔离器。

## 已接入的生产路径

1. `c1_r1_job_frontend.sv` 先完成表项解析、输入身份核对和可选的 input/output/preview 三帧布局校验。只有本地成功才提出 `region_request`。在区域响应前，成功的 pair response 不会交给 job controller，因此 input DMA、output DMA 和 engine 仍保持原子启动，不通过单独屏蔽某一路 start 来等待。
2. `c1_frame_write_region_guard.sv` 锁存两名图像写者（处理图、可选预览）和七条已占用记录（三个输入槽、两个处理图槽、两个预览槽）。复用精确有效行检查器，对每名写者逐组比较；缺失的读区域不会被替换成地址零的假帧。允许读读别名、有效行不重叠的 padding 共享及 exclusive end 等于 4 GiB。
3. `c1_r1_soc_control.sv` 在申请成功后立即登记处理图与预览的 base/stride/geometry，不等到计算结束。`c1_frame_manager.sv` 新增 `output_owned_mask`，让这些记录随 PROCESSING、READY_DISPLAY、DISPLAY 状态保留，FREE 后才能释放。取消时复用已有 drain hold，不能仅因为 manager 清除了逻辑所有权便清掉物理记录。
4. 捕获 guard 增加两个输出槽的检查阶段，覆盖运行中尚未发布为 pending/current 的计算写区域。捕获与计算只在区域申请时互斥；已经开始的 AXI/计算/显示工作不会因此整体串行化。
5. `c1_r1_portable_soc.sv` 固定启用该图像区域保护，并按 `PREVIEW_CAPTURE_ACTIVE` 决定是否保留预览。独立 frontend、boardless frame system 和 SoC controller 的新增参数默认关闭，保留其无外部分配器的使用方式。

## 同拍与取消协议

- 捕获已处于 PREP/WAIT/COMMIT 时，计算申请等待；捕获启动脉冲也被纳入互斥，避免计算在输入记录写入的同一边沿读取旧目录。
- 若计算开始检查与捕获表项响应同拍，捕获可以锁存表项，但停在 PREP；计算提交记录后，捕获才检查这些记录。不能让双方基于旧目录各自成功。
- `region_request` 是电平协议，不是 AXI valid：从本地校验成功保持至响应被消费或取消。响应保持至 request 撤销；取消可以丢弃这类尚未发起任何 AXI 的本地检查。
- 原始解析/布局错误优先，不会送去区域检查。新增 `0x35` 表示图像写者与占用区域重叠，`0x36` 表示区域检查遇到无效几何/范围，诊断地址是被拒绝写者的基地址。
- 等待申请仍受 job watchdog 管理。取消/超时不产生迟到 DMA 启动，下一合法任务无需系统复位即可恢复。
- 已有 CPU 表项读错误、输入身份错误和本地布局错误码保持不变。区域获准后如果 config preflight 再失败，记录会由任务取消/排空和槽释放规则回收；获准不等于已经执行计算。

## 验证范围

定向 Icarus 已通过：

- 区域检查器 21 个检查：两名写者 × 七个占用位置的部分重叠；有效行 padding；4 GiB 边界；禁用预览；采样后改变输入引脚；响应保持；运行中取消与恢复。
- SoC controller 共 100 配置，其中本轮新增 20 配置（10 场景 × 原始/注册故障票据）：计算写者覆盖输入、捕获覆盖计算输出/预览、捕获先申请、计算与捕获表项响应同拍、合法并行、取消排空、下一任务覆盖当前显示输出、DMA 已空闲但 READY_DISPLAY 内容仍须保留。
- Frontend 共 58 配置，其中新增 20 配置（五场景 × 两种输入几何 × 有无预览）：批准前等待、拒绝、批准与取消同拍、等待超时、本地 AXI 错误，以及失败/取消后的成功恢复。
- Portable SoC 14 个 smoke 配置通过，证明启用保护后的顶层可编译且原有配置/故障 smoke 未退化；smoke 不替代完整 CNN 数据验证。

随后全量 Icarus 回归以退出码 0 结束：`C1_REVIEW_FIXES_REGRESSION_PASS configurations=324`。

真实 SoC 彩色双帧 xsim 运行 `image_region_admission_20260911` 完成，退出码 0，用时 260.482 秒。启用训练参数、tensor burst refill、注册故障票据、源图几何/Resize、queued write fabric、预览写入及预览显示。独立 Python golden 检查通过：128 个 CNN 输入、1672 个 C8 结果、128 个处理图 DDR 像素、128 个预览 DDR 像素、各 128 个两路显示像素；每个预览槽的 8 AW/16 W/8 B 均退休，53 项日志反例检查通过。

这证明实际小尺寸双帧数据通路在启用申请机制后仍正确完成；恶意别名和同拍申请由上述 controller/frontend 定向测试覆盖，不应把它们说成已经由 CPU 在完整 SoC 双帧中注入验证。

运行日志位于 `logs/portable_soc_cache_ddr_bfm_runs/image_region_admission_20260911/`。检查时临时 xsim 工程目录已不存在，保留七个文本文件共 114,612 字节。未生成波形、未运行综合。Icarus 编译镜像和生成向量由回归脚本自动清理。

## 接口兼容与代价

- 新增参数/端口均追加，命名端口调用在保护关闭时可以不接区域接口；使用 `.*` 的调用者需声明相应信号，现有回归 testbench 已更新。
- 独立 SoC controller 的 xsim 脚本增加新模块源文件；整机脚本按 RTL 目录收集源码。
- GUI 中若使用手工维护的源文件清单，需要加入 `rtl/control/c1_frame_write_region_guard.sv`；不要只更新已有顶层而漏掉该依赖。
- 新增串行比较延迟和区域快照寄存器。沿用已有串行范围计算，不增加图像宽高的组合乘法器；尚无本轮综合资源/Fmax 数据，不把结构估算当成硬件结果。

## 仍须继续

1. 本文记录的图像阶段尚未包含 tensor；后续已接入 tensor/图像检查，见 `RTL_TENSOR_ARENA_ADMISSION_20260911.md`。权重、描述符及软件可写区仍待完善，不能称为全局 DDR 隔离完成。
2. 独立复位域和强制 reset 不能替代 AXI 排空。
3. 实际 DDR/显示桥必须兑现“busy/完成覆盖下游事务退休”的集成契约；后续仍需对共享 fabric 及旧显示读事务的释放边界进行整机审计。
4. 本轮功能验证不证明 640×480 的 15 fps、Efinity 时序收敛或板级正确性。
