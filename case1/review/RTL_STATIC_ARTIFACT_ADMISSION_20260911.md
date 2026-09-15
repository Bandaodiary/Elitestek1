# 权重、描述符与帧表的写保护准入

日期：2026-09-11。性质：当前 run 的内部 DMA 写入约束，不是 CPU/外部主机的 AXI 防火墙。

## 范围依据

| 数据 | 当前保留长度 | RTL 依据 |
| --- | ---: | --- |
| 权重/参数镜像 | 16,896 B | portable SoC 的 parameter subsystem `ARENA_BYTES=16896`；loader 完整读取该镜像 |
| 描述符数组 | `descriptor_count × 64 B`，当前合法任务为 22 条，即 1,408 B | config loader 每条描述符读取四个 128-bit beat；controller 要求规定 stage 数 |
| 输入帧表 | 48 B | 三输入槽，每条表项 16 B |
| 输出帧表 | 32 B | 两输出槽，每条表项 16 B |

不是仅保护当前使用的那一个帧表条目，也不是按仿真实际访问字节缩小范围。所有 exclusive end 使用 33 位，允许 end 等于 4 GiB，但拒绝跨越该边界。未来若修改参数镜像大小或表项格式，必须同步更新 controller 的范围契约；这里未声称这些常数自动适配任意 CNN。

## 生产 RTL 变化

`c1_r1_soc_control.sv` 在 START 接受沿锁存四个静态范围的合法性和首个错误地址，与 `cfg_*` 的采样时刻一致。结果约束 parameter、capture 和 NN 的新工作发起：静态范围为空/越界，或与整个 24-MiB tensor 写区域相交时，拒绝启动。比较逻辑从运行中的宽组合错误传播路径前移到配置采样边界；未新增正常任务的配置等待状态。

`c1_frame_write_region_guard.sv` 复用已有 arena checker，按 tensor、四类静态数据的顺序检查。tensor 阶段仍检查候选图像和所有保留图像；静态数据阶段只检查新的处理图/预览写者。范围和图像元数据在申请时锁存，后续串行阶段不读取 live CSR。

捕获 guard 扩展为 current、pending、输入目录、两个输出槽、tensor 和四类静态数据检查；通过所有阶段后才发出 capture writer-start。与计算申请之间的原子互斥保持不变，已启动数据通路不因此整体串行化。

`CHECK_STATIC_ARENAS` 在 SoC controller 中默认跟随 `CHECK_WRITE_REGIONS`，所以 portable SoC 默认启用。独立区域 guard 默认关闭该新增功能，启用时需提供四对 begin/end。

## 错误与边界

- `0x15`：SoC START 配置的静态范围越界/为空或与 tensor 冲突，地址为首个非法静态区域的基地址。原有基址高位、对齐、描述符数量和 tensor 基址错误优先级保持。
- `0x39`：计算候选图像写者覆盖静态数据，地址为被拒绝图像的基地址。
- `0x3a`：独立区域 guard 的静态检查遇到非法 arena/图像范围。正常 SoC 配置应更早被配置检查或本地图像检查拒绝。
- 捕获继续沿用 `0x31` 和捕获基地址。

精确有效行比较允许静态数据完全落在未写入的 padding 中。静态读取与已保留图像读取的地址别名不是本检查器的写冲突；但 CPU 把新数据上传到仍在显示的图像地址，依然会破坏显示，必须由软件分配器避免。

## 定向测试

区域 guard 四配置通过：原有 21 项图像、12 项 tensor 检查，以及有/无 tensor 阶段时各 13 项静态检查。新增场景覆盖两名写者 × 四个区域的部分覆盖、合法 read/read 与 padding、最后一个静态阶段的非法范围、输入改变后的快照、末阶段取消与恢复。

SoC controller 160 配置通过。本轮在之前 108 配置基础上新增 52 配置（26 场景 × 原始/注册故障票据），包括：

- 处理图、预览、捕获分别覆盖四类静态数据；
- 四类静态数据分别与 tensor 重叠，未发起 parameter/capture/NN 工作即拒绝；
- 四类范围分别跨越 4 GiB，以及 end 恰好等于 4 GiB 的合法对照；
- START 后把 live CSR 改成非法地址不污染已接受任务；把非法配置的 live CSR 改回合法也不能消除已锁存的错误。

这些是 controller/guard 级定向刺激，不是完整 SoC 中由 CPU 执行恶意 DDR 上传的测试。

随后全量 Icarus 回归退出码 0，摘要为 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=388`。

真实 SoC 彩色双帧运行 `static_region_admission_20260911` 完成，退出码 0，耗时 311.771 秒。启用训练参数、tensor burst refill、注册故障票据、源图几何/Resize、queued write fabric、预览写入和预览显示。独立 golden 核对通过：128 个 CNN 输入、1672 个 C8 结果、128 个处理 DDR 像素、128 个预览 DDR 像素，以及两路各 128 个显示像素；每个预览槽 8 AW/16 W/8 B 退休，53 项日志反例检查通过。

日志在 `logs/portable_soc_cache_ddr_bfm_runs/static_region_admission_20260911/`，七个文本文件共 114,615 字节。临时 xsim 工程目录经检查已不存在，Icarus 临时镜像/向量由脚本清理。未生成波形、未运行综合。

## 尚未完成

当前四类范围并不涵盖 CPU 程序、栈、堆、未来模型包等任意软件内存；不得凭空猜测其地址范围。外部 CPU/主机写入没有经过这些 DMA 准入点，因此这不是完整系统内存防火墙。共享 fabric 与旧显示读事务的最终退休仍需继续审计。本轮未做综合资源/Fmax 或 15 fps 验证。
