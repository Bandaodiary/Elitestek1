# C40 报告与独立源码发布记录

日期：2026-09-16。

本次发布把独立赛题一仓库从 C39 one-hot 快照更新到 C40 生产版 host。计算子系统继续采用 C39 one-hot 的 49 源闭包和稳定 Mosaic 18 阶段模型，采集前端则将经过候选验证的四行 Resize 正式合入 `rtl/r2/c1_r2_resize_line_sampler.sv`。比赛工程报告、公开指标摘录、Efinity 工程、回归脚本及生产验收说明均同步到同一边界。

公开报告记录的当前结果为：Ti60F225/I3、100 MHz 完整 host 使用 41,394 XLR、129 RAM 和 121 DSP，核心域 setup/hold 裕量为 +2.046/+0.026 ns；640×480 六帧 xsim 的最差完成间隔为 6,609,780 周期，对应 15.12909658 fps，underflow 与 display miss 均为零。15 项生产专项和三模型 18 项 100 MHz 矩阵已经通过。上述吞吐使用行为 CPU 流量与行为 DDR，不能表述为官方 Sapphire CPU 或真实 DDR PHY 联合验收。

发布包只包含赛题一手写 RTL、测试台、Python/PowerShell/Tcl 脚本、软件源、模型与 Golden 代码、Efinity XML/SDC、评审文档和三个已测模型的精选小型部署输入。Xilinx 生成目录、波形、日志、快照、网表、Efinity 中间数据库、官方受保护 CPU/DDR 载荷、其他赛题、训练图像和教师权重均不进入仓库。XML 中的本机源码根目录替换为 `@CASE1_ROOT@`，克隆后由 `configure_publication.ps1` 定位到当前副本。

历史 S2+C39+唯一 DDR 的 100 MHz 联合资源结果仍作为集成参考，但没有换入 C40 四行 Resize，也没有执行当前 CPU 应用。剩余工作为 C40 与官方 CPU/唯一 DDR 的重新联合、启动及中断、缓存和 DMA 所有权、MIPI/CSI/RAW/ISP、HDMI、板级 PLL/引脚/完整时序，以及画质、功耗、温升和长期运行验收。
