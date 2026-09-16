# 四行 Resize 生产合入与 100 MHz 重新验证记录

日期：2026-09-16。目标：将私有四行 Resize 正式合入生产 RTL，重新做回归，并使用同一份完整 host RTL 执行 Efinity 综合、布局布线和 100 MHz STA。

最终状态：两项目标均已完成。2026-09-16 17 时，独立验收器输出 `C40_PRODUCTION_STAGE_ACCEPTED`；15 项专项、三模型 18 项 100 MHz 矩阵及生产版原生六帧全部通过。100 MHz 最差帧间隔 6,609,780 周期，约 15.1291 fps；Efinity 当前完整 host 通过 100 MHz STA。公开指标摘录见 [current-c40-metrics.json](../report/tables/current-c40-metrics.json)；原开发树中的最终机器可读证据见 [acceptance.json](../logs/c40_production_queue/c40_production_20260916b/acceptance.json)，独立发布仓库不包含 `logs/`。

## 生产修改

- `rtl/r2/c1_r2_resize_line_sampler.sv`：由两行扩展为四行，行标签和有效位相应扩展，读写 bank 选择由 1 位扩为 2 位。
- 复用两个 `c1_r2_resize_pair_ram`，每行仍按横向奇偶地址分 bank；没有复制整幅图像或像素 RAM。
- 保留原有接口、请求顺序限制、行回收规则、同步 RAM 读延迟、响应反压和错误恢复。仅释放空闲或已经早于保留行下界的 bank。
- 原私有调试打印改由 `C40_RESIZE_TRACE` 显式开启。重复行标签等原有仿真检查仍保留。
- `golden/c40_four_row_candidate.py` 保留兼容入口，但现在读取生产源码，不再从两行 RTL 自动生成另一份候选。
- 新的正式 xsim 源表直接引用生产 sampler，不再替换为临时候选。

## 回归范围

`golden/run_c40_production_regression.py` 使用本机 Vivado xsim，按顺序执行 15 个配置：

1. 串行及重叠 Resize pipeline，各覆盖直接/寄存器化取消复位，共 4 个配置。每个配置包含 11 组 Golden 图像参数，以及非法配置、异常输入尾部、反压、取消和重启检查。
2. RGB 双像素源到 ROI/CDC/Resize/AXI 采集：偶数与奇数 ROI，分别无停顿/有停顿，共 4 个配置。
3. 原生 1920×1080 摄像头源、1440×1080 ROI、640×480 输出、核心 100 MHz，完成 2 帧逐写入 Golden 检查。
4. 训练模型的完整 18 层 host 系统：8×8/32×32，各无停顿/有停顿，合计 4 个正例、8 个 CNN 帧；另有 CNN RAM 和显示 RAM 实际注错两个反例。

以上专项通过后，还须保留原完整回归的三模型范围：Starry equalized、Mosaic equalized、Mosaic stable 各自 8×8/32×32 无/有回压四个正例，以及两种 RAM 实际注错负例，共 18 项、24 个正确 CNN 帧。该矩阵显式使用 C40 100 MHz fixture、原生相机时钟及实际时钟监视器，不能用前述单模型的旧小图时钟配置替代。入口为 `run_c40_production_regression.py --matrix100-only`，由六帧 worker 在长测前自动执行。

最后用 `prepare_c40_100mhz_xsim.py` 与 `run_c40_100mhz_xsim_detached.ps1` 重新执行生产源码的原生 640×480 六帧吞吐验证。验收需包含实际时钟检查、完整逐层 Golden、CPU 接口背景流量、摄像头采集、显示像素、无下溢和连续五个 CNN 帧间隔。CPU 流量仍由行为源产生，不代表 Sapphire CPU 已实际执行程序。

## Efinity 工程

工程入口：`efinity/c1_ti60_c40_host_100.xml`。

- Ti60F225，I3，Efinity 2026.1.132.3.9。
- 显式引用当前 C39 one-hot 主线的 49 个 host 源文件，以及一个保留总线输入/输出可观测性的资源评估顶层。
- `FRAME_DIVISOR=1`，与已验证的 100 MHz 六帧配置一致。旧 C39 资源顶层使用默认值 2，不能直接当作本次资源结果。
- 工程明确引用同名 C40 SDC；核心时钟周期 10.000 ns，摄像头 14.286 ns。沿用已建立的 Gray 总线约束、跨时钟第一同步级约束和握手数据约束。
- 顺序执行 map、pnr、独立 `sta_tclsh`。单独保留核心域、摄像头域、跨域和总线偏斜的有界报告，不能用多时钟几何平均 Fmax 代替核心频率。
- 这是完整 host RTL 的资源与时序评估边界；尚不包含真实 CPU IP、DDR PHY、MIPI/HDMI 物理 IO、板级管脚/PLL/外部 IO 时序验收。

## 执行与证据

队列：`scripts/run_c40_production_stage_detached.ps1`。

当前 run-id：`c40_production_20260916b`。启动时间：2026-09-16 14:32（本机时间）。首轮 `a` 在四项 Resize 测试通过后，因 Windows batch 将未加引号的 `SW=20` 参数拆开而在采集测试展开阶段停止；已修正为逐参数引用，保留失败记录。

执行顺序为 15 项专项 → Efinity map/PNR/STA → 三模型 18 项 100 MHz 矩阵 → 原生六帧 xsim。所有步骤串行；worker 通过 WMI 创建并检查不属于 Windows Job。仿真及 Efinity 中间文件位于 D 盘独占临时目录，结束自动清理，保留小型日志、manifest 和报告。

- 队列状态：`logs/c40_production_queue/c40_production_20260916b/status.json`
- 15 项回归：`logs/c40_production_runs/c40_production_20260916b/`
- 三模型 100 MHz 矩阵：`logs/c40_production_runs/c40_production_20260916b_matrix100/`
- Efinity：`logs/efinity_resource_runs/c40_production_20260916b_pnr/`
- 原生六帧：`logs/c40_100mhz_xsim_runs/c40_production_20260916b_native/`

已完成源表/工程绑定检查。忽略注释和显式调试宏的改动后，生产 sampler 与此前验证候选的逻辑文本一致。15 项专项包含 100 MHz 原生两帧采集 Golden：153600 个 AXI 写入数据拍全部匹配，ROI 像素合计 3110400，FIFO 峰值 208/512；4 个 host 正例累计 8 帧 CNN 通过，两种实际 RAM 注错均被拒绝。三模型补充矩阵及原生六帧随后完成。本次验收直接引用生产 sampler；原生仿真的执行计划与 Efinity 模型计划文本一致，不以历史候选结果替代新运行。

最终验收入口：`golden/check_c40_production_stage.py --run-id c40_production_20260916b`。验收读取实际仿真记录、源表、模型执行计划、帧间隔、Efinity 最终时钟关系表和独立 STA 报告；任何一步缺失或失败均不接受。

## 最终验收结果

| 项目 | 结果 |
|---|---|
| 15 项生产回归 | 通过（xsim，生产源码，无私有 sampler 替换） |
| 三模型 18 项 100 MHz 矩阵 | 全部通过：12 正例、24 正确 CNN 帧、6 实际 RAM 注错反例，约 667 秒 |
| 原生六帧 xsim | 14:55:25～17:05:24，正常退出，约 2 小时 10 分钟 |
| 100 MHz 最差帧间隔 / fps | 6,609,780 周期 / 15.12909658 fps，达到 15 fps |
| 原生采集 / CNN / 显示 | 13 / 6 / 21，12,902,400 个显示像素校验通过，underflow=0，display_misses=0 |
| Efinity map / PNR / 独立 STA | 全部完成，约 318.7 秒，最终 STA 通过 |
| XLR / RAM / DSP | 41,394/60,800（68.08%）/ 129/256（50.39%）/ 121/160（75.62%） |
| 核心域 setup / hold slack | +2.046 ns / +0.026 ns，实际约束 10.000 ns |
| 摄像头域 setup / hold | +5.181 ns / +0.071 ns，实际约束 14.286 ns |
| 核心→摄像头 / 摄像头→核心 | setup +4.571 ns / +3.743 ns，沿用定向 CDC max-delay 约束 |
| Gray 总线偏斜 | 两组的端点与参考端点并集均覆盖 0～9 位，实际 0.051 ns / 0.028 ns，均小于 1 ns 约束 |
| 临时目录清理 | 15 项专项、18 项矩阵、Efinity 与原生六帧均已自动清理；进程已退出 |

实际 CNN 完成时刻为 `[9395687, 15937109, 22517211, 29102813, 35706367, 42316147]`，连续五个间隔为 `[6541422, 6580102, 6585602, 6603554, 6609780]`。15 fps 的周期预算为 6,666,666.67，最差项余量约 56,886 周期（0.569 ms，约 0.85%），因此仍需实板 DDR/CPU 并发验证，不能将这点余量当作板级性能保证。

独立验收期间修正了两个工具输出格式兼容问题：Efinity 保存 XML 时删除末尾换行；Windows PowerShell 5 的原生 stdout 重定向采用 BOM 标记 UTF-16/CRLF。检查器只归一化这些格式差异，继续严格比对工程内容、源表、模型计划、原始数值/时序及 PASS 证据；未改变 RTL 或降低任何仿真、吞吐、STA 门槛。

本次最终报告明确标识 `c1_ti60_c40_host_100` 及其同名 SDC。核心域单独报告的最大分析频率为 125.723 MHz；这里只验收 100 MHz，不以报告中的多时钟几何平均 117.509 MHz 替代核心域指标，也不外推板级可用频率。

Gray skew 报告的 `Endpoints` 分别为 10 和 9；第二组以 `rd_sync1[8]` 为参考，省略参考端点与自身的比较，不能将该行数直接解释为漏约束一位。检查器核对端点及参考端点的实际位号并集均为 0～9，并核对独立跨域时序报告。

与旧 C39 纯 host 历史结果相比，本次总量增加 918 XLR、12 RAM，DSP 不变。但本次同时改为 100 MHz、FRAME_DIVISOR=1，故 XLR 差异不应全部归因于四行缓存；新增两行的逻辑存储为 12 KiB（MAX_WIDTH=2048），与额外 12 个物理 RAM block 不是同一个计量单位。
