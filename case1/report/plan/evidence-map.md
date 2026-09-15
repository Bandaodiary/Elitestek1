# 架构报告证据映射

## 2026-09-15 当前证据（优先于下方历史E02—E19）

| ID | 来源 | 支持内容 | 边界 |
|---|---|---|---|
| E20 | case1/review/C39_THREE_OBJECTIVES_FINAL_ACCEPTANCE_20260915.md及其直接日志链接 | 三个优化目标、六帧/五间隔、资源与时序、待板级验证 | 历史汇总不得覆盖直接原始记录 |
| E21 | case1/golden/c39_onehot_sources.py；case1/rtl/c39/README.md；选中的49个源 | 当前算子/窗口/六lane/96乘积、量化、总线与图执行 | 不是整个rtl目录通配；不支持任意CNN图自动编译 |
| E22 | case1/golden/c39_onehot_trained_contract.py；r2_execution_plan.py；r2_row_fused_plan.py及实际训练metadata | 当前18阶段网络、训练/量化及融合计划 | 需核实所用稳定模型；不套用旧22阶段数据或冒充标准CycleGAN |
| E23 | case1/review/C39_ONEHOT_JOINT_RESOURCE_CDC_REVIEW_20260915.json；实际S2合同/BSP | 真实CPU/DDR联合100MHz、资源和host指定CDC | CPU受保护实现未执行、完整工具CDC分类失败、无板测 |
| E24 | case1/logs/c39_model_queue_runs/c39_onehot_model_queue_20260915b/status.json；native独立终态输出 | 三模型、640×480六帧、23.314907fps@标称150MHz | 不是100MHz联合吞吐、不是GUI/板卡实测 |
| E25 | case1/rtl/top及efinity当前联合顶层；case1/review中企业Demo适配审计 | 已实现链路与计划集成边界 | 官方IP源不再分发；pin/PLL/PHY及真实输入另验 |

正文引用以内部工程来源为主，不开展新文学综述或增加未核实外部文献。用户提供的赛题要求与既有核验保留为背景来源；写作只引用已经明确读取的范围。

全部路径相对 `D:/contest/2026FPGA/yilingsi`，除明确列出的外部原始文献。摘录与摘要不扩张为未读全文结论。

| ID | 引用/来源 | 类型 | 可用事实 | 支持论点/位置 | 风险与边界 |
|---|---|---|---|---|---|
| E01 | resource/2026 FPGA竞赛赛题指南 -8.22(更正版).pdf，第10—13页 | 官方赛题 | SC431HAI、640×480@30采集、720p60或1080p30显示、稳定15fps以上、FPS OSD、多风格与500KB进阶 | §1/§7指标 | 已提取并渲染四页；指标不是已完成成果 |
| E02 | case1/rtl/top/c1_r1_portable_soc.sv | 主顶层源码 | RAW10并行输入、三时钟域、七client AXI128、可选性能开关默认0 | §2/§4/§5现有架构 | 不含真实vendor IP |
| E03 | case1/rtl/top/c1_r1_capture_subsystem.sv；case1/rtl/cnn/c1_r1_compute_ingress.sv | 源码 | capture先ISP后DDR；Resize在compute ingress；sensor默认642×482 | §3/§4真实几何链 | 高分辨率sensor完整适配尚未证明 |
| E04 | case1/FIXED_POINT_SPEC.md；case1/golden/r1_isp.py | 定点契约与Golden | 四Bayer、valid crop、Q2.14/Q3.13、1024 LUT、Q16.16/Q0.12、round-away/sat | §3算术 | R0 gamma/nearest不能混入R1 |
| E05 | case1/model/microstyle_model.py；microstyle_layout.py；microstyle24_starry_functional/manifest.json | 模型/导出源码 | 22阶段、12,212卷积权重、16,896 B参数arena、428,236,800 MAC | §3网络与§6预算 | descriptor tensor offsets为0；非任意图通用执行器 |
| E06 | case1/rtl/cnn/c1_r1_microstyle_engine.sv；c1_r1_c8_parameter_scheduler.sv | 源码 | 共享算术、逐层OIHW重排、Conv/DW lane bank | §4计算与参数 | 不能沿用旧的每层专用MAC总预算 |
| E07 | case1/rtl/cnn/c1_r1_microstyle_tensor_adapter.sv | 源码 | 三个8MiB bank、C8地址、默认单64bit请求在途、固定残差bank | §4/§5存储与可移植边界 | 共享模型存在吞吐上限 |
| E08 | case1/ARCHITECTURE.md；RTL_FILE_GUIDE.md | 架构索引 | client映射、三输入双输出、APB快照、abort/drain | §4/§5 | 部分旧状态被8月29记录取代，按源码核对 |
| E09 | case1/outputs/r1_validation/metrics.json | 原始小型结果JSON | 6图×4Bayer；最低29.3863758794 dB，平均31.7269957112 dB | §6.1 ISP质量 | 合成RAW后重建/Resize，不是风格网络PSNR |
| E10 | case1/model/train_microstyle_qat.py；outputs/microstyle_qat/training_metrics.json | 训练实现/记录 | 六图、一风格、64patch、240 float+80 QAT steps、固定特征Gram/色彩/边缘/TV | §3.4/§6.1 | 未建立独立泛化评估，不能写VGG教师已部署 |
| E11 | case1/outputs/microstyle_qat/validation/validation_metrics.json | 原始结果JSON | 六张64×64 QAT对整数max error=0 | §6.1量化一致性 | 不是RTL整帧或最终艺术质量证明 |
| E12 | case1/STAGE8_21_HANDOFF_PREFLIGHT.md；相应tb | 回归记录/源码 | stage21 operands896/results836/final64、stage_done22、abort0 | §6.2有界真实参数交接 | 8×8 scaled、有界handoff；不能写native全网PASS |
| E13 | case1/sim/tb_c1_r1_native_boardless_job.sv；IMPLEMENTATION_STATUS.md | TB/状态 | native307200像素、每向4800burst；CNN为echo | §6.2 DMA回归 | 明确非真实CNN算术 |
| E14 | case1/TEST_RESULTS.md，§6历史proxy；logs/microstyle_cnn_proxy_synth_runs/6cb8dfd59ed5473383eed87f52b2a013/status.json | 紧凑结果/状态 | 2026-08-24 CNN代理28,298LUT/11,168FF/2BRAM36/35DSP；WNS -4.965ns | §6.3历史Vivado结构 | 历史Artix-7综合代理，不是当前I3 PNR |
| E15 | case1/efinity/RESOURCE_MAP_RESULTS_20260829.md | Efinity结果 | dot80DSP/189.717MHz；DW窄壳28DSP/271.592MHz；scheduler1DSP/236.855MHz | §6.3叶级结果 | C4、不同wrapper；不可简单相加或当整网Fmax |
| E16 | case1/IMPLEMENTATION_STATUS.md | 最新汇总 | 127源编译、小帧SoC、默认unpacked map崩溃、packed窄壳PASS、fullSoC map超时 | §6/§7未闭合 | 历史状态，不代表本次重新运行 |
| E17 | case1/model/tensor_perf_model.py；efinity/TI60F225_BOARD_PROFILE.md | 结构模型/板卡资料 | 单帧342,220,800 bus B、理想因子模型47,547,744 B；DDR峰值1.6GB/s | §5/§6.4/§7 | 本次轻量重算；不是DDR实测。理想read_reuse9应用范围粗粒度 |
| E18 | case1/rtl/top/c1_r1_display_subsystem.sv；display/c1_video_timing_720p.sv | 源码 | RGB/DE/HS/VS、720p、split/OSD、pending pair | §4.5/§7 | OSD现为状态/告警，未实现实际FPS叠加 |
| E19 | OFFICIAL_DEMO_ADAPTATION_GUIDE.md；OFFICIAL_RESOURCE_UPDATE_ANALYSIS.md | 已审计官方工程分析 | Demo适合作vendor集成参考；旧IMX219 RAW8；4PLL | §7 | 不是当前RTL替换依据或最终资源预算 |
| R01 | Johnson, Alahi, Fei-Fei. Perceptual Losses for Real-Time Style Transfer and Super-Resolution. 2016. https://arxiv.org/abs/1603.08155 | 原始论文摘要/元数据 | 感知损失训练前馈图像变换网络 | §1.1背景 | 仅概述路线，不宣称本项目复现其完整训练 |
| R02 | Howard et al. MobileNets: Efficient Convolutional Neural Networks for Mobile Vision Applications. 2017. https://arxiv.org/abs/1704.04861 | 原始论文摘要/元数据 | 深度可分离卷积用于轻量嵌入式视觉网络 | §3.3网络选择 | 不称MicroStyle为标准MobileNet |
| R03 | Jacob et al. Quantization and Training of Neural Networks for Efficient Integer-Arithmetic-Only Inference. 2017预印本. https://arxiv.org/abs/1712.05877 | 原始论文摘要/元数据 | 整数推理与训练协同 | §3.4量化背景 | 项目数值合同自定，不宣称复现该文全部量化方案 |
