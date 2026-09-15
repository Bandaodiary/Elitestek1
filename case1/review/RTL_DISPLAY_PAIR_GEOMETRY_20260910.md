# 显示帧对几何快照补齐

## 问题与修复边界

`c1_r1_soc_control.sv` 已分别保存原图/处理图的 base 和 stride，但原有 pending、current、prefetch 三层快照只保存处理图宽高，`boardless_resolved_input_width/height` 没有进入显示命令。旧同尺寸配置不受影响；独立输入尺寸接入完整 SoC 时，该接口会丢失原图几何，不能仅连接两个新尺寸端口就认为整机支持缩放。

本次为上述三层增加原图宽高寄存器，并在端口末尾追加 `display_original_width/height`。旧 `display_width/height` 明确保留处理图含义：

- boardless 完成时，原图几何与原图地址、stride 同时进入 pending 快照；
- 新帧预取时复制 pending，后台重复显示时复制 current；
- 帧管理器确认换帧时，将原图几何一起提交到 current；
- 取消保留当前显示帧的地址和几何，复用原有帧所有权恢复规则；复位清零新寄存器。

增加 6 个 16 位寄存器（RTL 声明层面 96 位）；实际资源取决于综合裁剪，未进行资源或时序测量。完整 portable SoC 暂时显式悬空这两个输出，保持同尺寸显示路径不变。没有提前放宽源尺寸校验。

## 定向验证

`tb_c1_r1_soc_control` 增加 `DIFFERENT_RESOLVED_GEOMETRY` 参数。默认仍为 640×480/2560；新增模式模拟已完成 boardless 的原图 960×720/4096、处理图 640×480/2560。

这是控制器边界的元数据注入，不代表摄像头、CNN 或显示 DMA 已运行该异尺寸任务。

测试在 boardless 完成后立即将所有实时 resolved 地址、stride、宽高改为明显不同的值。显示请求保持背压 5 拍，每拍检查 valid 和完整帧对快照；换帧后执行取消、排空和后台重复显示，再检查同一组地址、stride 和宽高。原有前台/后台故障报告及 system-disable 立即取消测试保留。

同尺寸/异尺寸与直接/寄存故障广播的四种组合均通过，输出 `C1_DISPLAY_PAIR_GEOMETRY_PASS` 和 `C1_R1_SOC_CONTROL_PASS`。新增两种异尺寸组合已登记默认回归。

随后全量 Icarus 回归完成，`C1_REVIEW_FIXES_REGRESSION_PASS configurations=119`，包含预期失败检查。执行结束后未发现本轮 `c1_review_*` 临时镜像/向量目录残留。

完整 `c1_r1_portable_soc` 的 Icarus 编译/展开通过：128 个 RTL 源文件，0 errors；601 条工具诊断仍存在，不能解释为无警告通过。没有运行 Vivado、Efinity、综合或板测。

复现：

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_r1_soc_control -Python D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe
& case1/scripts/run_iverilog_rtl_compile.ps1 -WarningSampleCount 1
```

初次使用默认 Python 时缺少 numpy，golden 生成失败；改用已有含 numpy 的环境后通过。runner 的 finally 覆盖生成阶段与仿真阶段，负责清理本次镜像和临时向量，不保留波形。

## 下一步实际阻碍

1. `c1_display_prefetch_pair` 两个读 DMA 仍共用 width/height，像素域两个 request_last 也共用宽度快照；必须同时拆分 DMA 配置、几何校验和 CDC，避免仅改端口。
2. `c1_r1_display_subsystem` 与 compositor 的源坐标/行释放策略必须匹配各自几何。原图尺寸大于显示窗口时，要明确缩放或裁剪策略，不能默认为完整源行已被消费。
3. 然后贯通 SoC 控制配置、软件 CSR、采集尺寸、Resize 相位/步长和真实 CNN 的描述符几何；当前控制器仍检查固定同尺寸配置。

因此本次是完整异尺寸架构所需的元数据保真修复，不是整机异尺寸功能完成声明。
