# tensor 连续工作区与图像区域隔离

日期：2026-09-11。范围：补齐 tensor 写入与图像所有权之间的保护，不等于对 CPU/所有 DDR 地址实现硬件防火墙。

## 实现依据

当前 `c1_r1_portable_soc.sv` 将 adapter 的 `TENSOR_BANK_BYTES` 固定为 8 MiB；`c1_r1_microstyle_tensor_adapter.sv` 使用 bank 0/1/2。因此本轮保护整个 `[cfg_tensor_base, cfg_tensor_base + 24 MiB)`，不是按当前小尺寸测试实际访问的几 KB 缩小保护范围。

SoC controller 已要求 tensor 基址 8-MiB 对齐且不超过 `0xfe800000`。新的端点计算显式使用 33 位，允许最后 exclusive end 恰好等于 4 GiB。`cfg_tensor_base_q` 仅在 `start_pulse && !status_busy` 时更新，任务期间使用该配置快照，而不是跟随 live CSR。

## RTL 变化

- 新增 `rtl/control/c1_frames_arena_check.sv`：可参数化帧数，锁存帧布局与一个连续 arena。用 49 位串行乘加先验证完整 extent，再检查有效像素行；若整体 envelope 已经分离，直接结束该帧检查。只有 envelope 相交时才逐行判断，因此不会因 arena 仅落在合法行间 padding 内而误拒绝。
- `c1_frame_write_region_guard.sv` 在图像写者互相占用检查之前，检查两个候选图像与七个保留图像区域是否与 tensor arena 相交。所有这些图像都需要保护，因为 tensor 是写者，即使图像此刻只用于显示读取也不能放行。
- `c1_r1_soc_control.sv` 捕获 guard 增加 tensor 检查阶段，尚未启动捕获 writer 时即拒绝冲突。没有新建一个未接入的数据检查器，也没有等到 tensor 真正发 AXI 写入后才报错。
- `CHECK_TENSOR_ARENA` 默认跟随 SoC controller 的 `CHECK_WRITE_REGIONS`；portable SoC 已启用后者，因此整机默认启用 tensor/图像隔离。独立图像区域 guard 的该参数默认关闭，保留原有接口用法。
- SoC controller 的独立 xsim 源文件清单已加入新依赖。GUI 若手工维护文件列表，也需加入 `c1_frames_arena_check.sv`。

## 错误与生命周期

计算申请新增 `0x37`：tensor 与有效图像行重叠；`0x38`：tensor 检查遇到非法 arena/图像布局或 extent。诊断地址为检查失败处对应的图像基地址。捕获入口继续沿用 `0x31` 和捕获基地址，维持现有软件错误分类。

保持上一阶段的原子申请锁、输出槽记录和取消排空规则。tensor 检查也在申请锁内完成，取消会清除本地检查，不允许迟到成功触发运行端。获准之前仍没有该任务的运行 DMA/engine 启动。

这里并未新增多任务 tensor 分配器：当前一次只有一个 NN 任务，tensor arena 随 run 配置保留。取消后的新 run 可以选择不同基址，但计算申请必须重新对仍存活的旧显示帧做检查。若以后引入多 NN 同时执行或动态 bank 分配，必须重新设计 tensor 所有权记录，而不能仅复用此单任务假设。

## 定向验证

- 通用连续区域 checker：192 项检查，其中 180 组随机有效行布局以独立 64 位乘法和逐行枚举 oracle 对照。包括半开端点相等、4 GiB 末端、真正地址溢出、非法 arena、禁用帧、采样后改变全部输入、响应背压、运行中取消及恢复。
- 集成图像区域 guard：新增 12 项 tensor 检查，覆盖两名候选写者和七个保留位置、非法 arena、取消/恢复。原有 21 项图像区域检查仍通过。
- SoC controller：108 配置通过。其中新增四场景 × 两种故障票据模式，覆盖处理图与 tensor 重叠、预览与 tensor 重叠、捕获与 tensor 重叠，以及旧显示保留后新 run 改变 tensor 基址的冲突。
- 最后一个场景使用真实 controller/frame-manager 状态转换与 START 配置快照，不通过直接改 DUT 内部区域记录伪造旧显示。其子模块完成/预取仍由 testbench 模拟，不是完整 SoC 的 CPU 恶意地址测试。

全量 Icarus 回归正常结束，退出码 0：`C1_REVIEW_FIXES_REGRESSION_PASS configurations=334`。

真实 SoC 彩色双帧运行 `tensor_region_admission_20260911` 完成，退出码 0，耗时 277.206 秒。启用训练参数、tensor burst refill、注册故障票据、源图几何/Resize、queued write fabric、预览写入和预览显示。独立 golden 核对通过：128 个 CNN 输入、1672 个 C8 结果、128 个处理 DDR 像素、128 个预览 DDR 像素，以及两路各 128 个显示像素；每个预览槽 8 AW/16 W/8 B 退休，53 项日志反例检查通过。

运行位于 `logs/portable_soc_cache_ddr_bfm_runs/tensor_region_admission_20260911/`，保留七个文本文件共 114,615 字节。临时 xsim 工程目录经检查已不存在，未生成波形、未运行综合。该结果证明合法小尺寸双帧数据通路仍正确，不替代定向测试中的恶意地址/跨 run 冲突覆盖。

## 仍未覆盖

本文对应阶段尚未包含静态数据；后续权重包、描述符和帧表的准入保护见 `RTL_STATIC_ARTIFACT_ADMISSION_20260911.md`。任意软件内存及 CPU/外部主机写入仍不受这里的内部 DMA 准入控制。共享 fabric 和旧显示读事务的实际退休仍须满足集成契约并继续审计。未提供本轮综合资源、Fmax、640×480 15 fps 或板级验证结果。
