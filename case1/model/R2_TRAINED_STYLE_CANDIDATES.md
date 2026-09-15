# 已训练 R2 风格模型：产物与接入边界

更新：2026-09-15 08:13。本轮训练、软件测试和实际RTL验证已完成；本文不是板级发布说明。

## 最终交付结论

稳定Mosaic在新的约30.43fps源/每帧采集条件下完成640×480原生六帧，独立检查得到CNN五个完成间隔中最慢**23.319344fps@名义150MHz**，九次采集的八个间隔中最慢**30.426568fps**。9次采集/6帧CNN/14次显示、8,601,600个显示像素正确，零下溢、零显示缺帧。[完整原生证据](../logs/r2_c36_camera30_native_gate_20260915a.log)、[矩阵终态检查](../logs/r2_c36_camera30_matrix_terminal_20260915a.log)、[小图终态检查](../logs/r2_c36_camera30_small_terminal_20260915a.log)均通过。

三个冻结参数包与当前计算RTL兼容，使用相同B拓扑和计划ROM。Starry B保留更多照片结构，原Mosaic纹理较强，稳定Mosaic更平滑；保留三者，不自动覆盖原模型。稳定候选的合成位移/微噪声敏感性有所降低，但教师相似度下降，不能称为所有画质指标都更好。Mosaic分支可准确命名为“基于Fast Neural Style思路与知识蒸馏的轻量化INT8风格迁移CNN”；Starry B使用感知/风格损失直接训练，没有使用Mosaic教师。三者都不是CycleGAN或原版FNS的逐项复现。

本轮不需要继续训练或重跑EDA。原进程均已退出、私有仿真目录已清理，最后运行保留34个文件/311,868字节。官方DDR/CPU IP、真实摄像头视频、物理CDC、联合资源/时序和运行时风格切换仍属于后续平台集成；上述帧率不是板测值，也不是无限时长或所有DDR延迟条件的保证。以下带时间的进度段落是历史快照。

06:36：最后的新采集压力运行已真实进入原生xsim；私有TB实际编译、分频1实际展开、kernel34040的Job外/掩码3/BelowNormal均已检查。自身矩阵和小图也已通过，但新压力原生结果仍在等待，不能预先沿用23.452fps。[执行边界与证据](../review/C36_CAMERA_CADENCE_REVIEW_20260915.md)。

06:30：稳定候选短回归也已完成并清理，[4配置矩阵](../logs/r2_c36_mosaic_stable_matrix_gate_20260915a.log)及[原生时钟小图](../logs/r2_c36_mosaic_stable_small_gate_20260915a.log)均通过独立终态检查。新采集压力运行已通过真实前序small门禁并开始自身矩阵；还没有新配置原生帧率。

06:27：**Mosaic已完成实际640×480六帧整机仿真，并通过独立终态检查，最慢23.452fps@名义150MHz。** 原进程真实退出、私有目录清理；稳定候选短回归正常接续。Mosaic与Starry B的五个完成间隔完全相同，不是直接套用Starry的帧率。[Mosaic实际门禁](../logs/r2_c36_mosaic_native_gate_20260915a.log)。两者仍属于旧约29.26fps采集配置；新约30.43fps/每帧采集运行在队列后续，尚未通过。

05:55 采集速率更正：原配置实际约58.52 fps源、分频2后29.26 fps采集，并非严格30 fps。下述Starry B的23.452 fps CNN结果仍适用于原配置。已独立排队稳定Mosaic的约30.43 fps源/每帧采集六帧测试，等待现有长测与短回归真实退出后串行执行；新配置尚无RTL通过或帧率结论。见[采集速率复核与测试条件](../review/C36_CAMERA_CADENCE_REVIEW_20260915.md)。

Starry B已通过[实际原生六帧整机门禁](../logs/r2_c36_b_native_gate_20260915b.log)：五个完成间隔的最慢值按名义150MHz折算为**23.452fps**，该仿真配置达到15fps；不是官方DDR/CPU IP或板测结果。原进程实际退出，私有仿真目录已清理。Mosaic实际RTL已接续启动。

新增可选[视频稳定候选](../outputs/c36_qat_b_mosaic_stable_20260915a)：从原Mosaic量化模型继续600步一致性微调，保持相同ROM/参数布局。全尺寸合成位移误差约减少21.9%、微噪声变化约减少17.5%，但会减少部分细节/艺术纹理，因此不覆盖下面两个模型。[微调前后实图](../outputs/c36_eval_mosaic_stable_20260915a/astronaut_mosaic_comparison.png)、[数值与边界](../review/C36_CNN_TRAINING_LOG_20260915.md)保留；短RTL及新采集压力原生六帧均已通过，实摄视频尚未验收。

04:21补记：公开三图99次全尺寸推理显示Mosaic比Starry更敏感于1～3像素位移；已启动同拓扑、固定量化尺度的一致性QAT试验，尚未替换下表两个模型。原模型的[位移/噪声证据](../outputs/c36_style_stability_20260915a/stability.json)及[本轮试验记录](../review/C36_CNN_TRAINING_LOG_20260915.md)保留。

## 三个已训练并通过实际RTL验证的 B 模型

| 模型 | 训练产物目录（相对 case1） | 当前用途 |
|---|---|---|
| Starry B / 平衡 INT8 | [c36_qat_b_starry_equalized_20260915a](../outputs/c36_qat_b_starry_equalized_20260915a) | 较多保留照片结构、风格较浅；小图及640×480原生六帧RTL通过，仿真最慢23.452fps@名义150MHz |
| Mosaic 蒸馏 B / 平衡 INT8 | [c36_qat_b_mosaic_equalized_20260915a](../outputs/c36_qat_b_mosaic_equalized_20260915a) | 更明显的彩色线描/浅色块；软件/整数、小图矩阵及640×480原生六帧RTL通过，仿真最慢23.452fps@名义150MHz |
| 稳定 Mosaic B / 一致性 INT8 | [c36_qat_b_mosaic_stable_20260915a](../outputs/c36_qat_b_mosaic_stable_20260915a) | 纹理更平滑；新约30.43fps采集配置的原生六帧RTL通过，CNN最慢23.319fps@名义150MHz |

三者都是2残差块、扩展24通道、上采样前24→16投影、18项执行图/13带权卷积，640×480下295,526,400 MAC/帧。各自原始量化参数arena为8,931字节，部署参数镜像147,456字节，参数事务1,277个128位beat。相比原22项模型，静态MAC减少31.0%；不能把此百分比直接当作fps提升。23.452与23.319fps采用不同采集压力，不用于判断两套权重本身的速度差异。

[直接比对](../logs/c36_style_deployment_pair_20260915a.log)确认13个带权层的内容确实不同，但所有参数形状及两份生成ROM完全相同。这证明两种已训练风格不需要两套计算架构；**不证明运行时权重切换、100ms时限或不丢帧已经验证**。

## GUI / 工程接入时使用哪些文件

以下以Mosaic目录为例；Starry B目录结构相同。保留原C35工程作为基线，在独立工程中选择新生成ROM，不能覆盖当前正在执行仿真的源文件。

| 产物 | 用途与注意事项 |
|---|---|
| [plan_fused/execution_plan.sv](../outputs/c36_qat_b_mosaic_equalized_20260915a/plan_fused/execution_plan.sv) | 编译期18项执行ROM，模块名`c1_r2_microstyle_plan`；替换工程源列表中的`rtl/r2/c1_r2_row_fused_microstyle_plan.sv`，不要同时编译两个同名模块 |
| [plan_fused/row_fusion_plan.sv](../outputs/c36_qat_b_mosaic_equalized_20260915a/plan_fused/row_fusion_plan.sv) | DW14→PW15尾部融合ROM，模块名`c1_r2_row_fusion_plan`；替换源列表中原同名模块文件，必须与上项配对 |
| [plan_unfused/parameters.bin](../outputs/c36_qat_b_mosaic_equalized_20260915a/plan_unfused/parameters.bin) | 147,456字节、按执行器参数块偏移布局的DDR参数镜像；融合/未融合计划共用同一布局。目录虽名`plan_unfused`，融合计划manifest明确引用此文件 |
| [artifact/parameter_arena.bin](../outputs/c36_qat_b_mosaic_equalized_20260915a/artifact/parameter_arena.bin) | 8,931字节紧凑模型导出，用于绑定编译器；**不是**可直接替代上述DDR镜像的内存布局 |
| [artifact/manifest.json](../outputs/c36_qat_b_mosaic_equalized_20260915a/artifact/manifest.json) | 量化尺度、逐层数组布局及训练来源，供软件编译/审查使用 |
| [checkpoint_best.pt](../outputs/c36_qat_b_mosaic_equalized_20260915a/checkpoint_best.pt) | QAT训练参考/复核，不由RTL读取 |

不要误用`plan_unfused/execution_plan.sv`配尾部融合ROM。RTL执行器由ROM的`valid/last`等字段决定图的执行，不需要把教师网络移入RTL。测试入口中的`STAGE_COUNT=18`、`RGB_STAGE=16`、`FUSED_DW_STAGE=14`、`FUSED_PW_STAGE=15`是相应检查器的期望值，不应被误当成另一个可任意改写的CNN。

06:12补齐交付检查：此前仿真从紧凑arena重建参数镜像，并未在共同入口中同时核验保存的`plan_unfused/parameters.bin`；现在[统一绑定入口](../golden/r2_trained_style_vectors.py)也直接比较已保存镜像/未融合计划/manifest及两份融合ROM/manifest，总计每模型6个文件。三种候选的[实际检查](../logs/c36_saved_deployment_contract_20260915a.log)均通过，DDR镜像147,456字节、有效命令20,432字节（1,277个128位beat）。7项内存注入负控覆盖有效字节、填充字节、其他风格、截断、把未融合ROM放进融合槽、错误镜像引用及错误融合对；没有修改模型文件或创建临时副本。

这使本页建议GUI加载的文件与经过训练/整数检查的内容建立直接联系；不证明CPU真实上传、运行时风格切换或板级功能。已完成Starry原生和Mosaic小图的独立检查在加强后仍通过，旧周期证据未改变。

## Starry B 的冻结模型测试

浮点第3,250步、QAT第600步保持不变；重新用相同实际8位RGB输入完成[32图val](../outputs/c36_final_starry_val_20260915a/comparison.json)及[32图test](../outputs/c36_final_starry_test_20260915a/comparison.json)。test没有参与这个模型的梯度、校准或选模，但该集合此前已用于Mosaic评估，因此不宣称是整个项目首次盲评。

| Starry B INT8指标 | val | test |
|---|---:|---:|
| 对输入亮度SSIM(box11) | 0.8190 | 0.8245 |
| 对浮点参考MAE（/255） | 4.190 | 4.197 |
| 对浮点参考平均PSNR | 33.317dB | 32.591dB |
| 对浮点参考亮度SSIM(box11) | 0.9669 | 0.9630 |
| 输入原有端点比例（RGB通道值0或255） | 0.893% | 5.942% |
| 输出端点比例 | 0.870% | 5.762% |
| 新产生的端点比例 | 0.731% | 1.172% |

旧QAT在同一test上的输入亮度SSIM为0.5305、输出端点比例14.332%；新模型更保留照片细节，但**这不等于艺术风格更强或普遍更美观**。新模型的明显风格仍弱于Mosaic路线。

端点比例已对[val](../outputs/c36_starry_val_saturation_20260915a/audit.json)和[test](../outputs/c36_starry_test_saturation_20260915a/audit.json)逐图重算，没有剔除样本：test中的白底商品图与线稿拉高原始白色比例，不能将其全部当作模型高光损坏；仍保留1.172%的新增端点统计和0.256%的中间灰度至端点统计作为风险信息。两者也不是独立美学指标。

**数据划分以manifest的`split`字段为准，不以文件所在目录名为准。** 初始下载照片位于`train/`，逻辑划分后未移动文件；训练入口显式筛选`split=='train'`，不能手动把该目录全部照片重新当作训练集。

## Mosaic 的实际证据

- 浮点：4,500步，按32张val选第2,500步；QAT：600步，选第600步。训练集192张，val32张，test32张；学生训练/选模不读取test。
- [同一32图val评估](../outputs/c36_eval_mosaic_int8_20260915a/evaluation.json)：INT8相对浮点MAE约9.293/255、平均PSNR26.876dB、亮度SSIM(box11)0.9080。
- [固定模型32图test评估](../outputs/c36_test_mosaic_int8_20260915a/evaluation.json)：INT8相对浮点MAE约9.039/255、平均PSNR27.080dB、SSIM0.9088。该test已使用，后续不得把基于这些结果再调参的模型仍称为对同一test的首次盲评。
- 一张640×480 `astronaut` 的921,600个RGB字节与独立导出arena整数参考完全一致；这是软件数值证据，不是RTL仿真。
- 实际[旧版/Starry B/教师/Mosaic浮点/INT8对比图](../outputs/c36_eval_mosaic_int8_20260915a/astronaut_mosaic_comparison.png)中教师仅作参考，不能把左下的教师效果当作FPGA输出。
- INT8对官方教师的val/test平均PSNR约14.49/14.53dB、SSIM约0.477/0.491，仍存在明显拟合差距。当前应描述为“Mosaic蒸馏的彩色线描/浅色块”，不是标准教师的高保真复现；上述相似度也不是独立美学评分。

## 稳定 Mosaic：冻结 test 结果与取舍

06:01完成[固定32图test评估](../outputs/c36_test_mosaic_stable_20260915a/evaluation.json)，浮点参考仍为第2,500步，原Mosaic与稳定候选均使用各自已选定的QAT第600步；没有根据test修改权重或超参数。该集合此前已用于原Mosaic评估，不称为首次盲测。本轮不重复生成公开预览图片，不使用GPU或网络。

| 同一test集指标 | 原Mosaic INT8 | 稳定候选INT8 | 解释 |
| --- | --- | --- | --- |
| 与输入的亮度SSIM | 0.470462 | 0.525516 | 31/32图提高，结构更接近输入 |
| 与Mosaic教师的亮度SSIM | 0.490695 | 0.470299 | 25/32图下降，不是教师保真度全面提升 |
| 输出端点通道比例 | 1.187621% | 0.515727% | 所有32图降低，不等于自动提高艺术质量 |
| 输出/输入边缘能量比 | 2.252909 | 1.574813 | 所有32图降低，整体约−30.1%，包括纹理被削弱的代价 |

[test逐图配对审计](../outputs/c36_test_mosaic_stable_pair_audit_20260915a/audit.json)和[val审计](../outputs/c36_val_mosaic_stable_pair_audit_20260915a/audit.json)均核验完整32图、全部均值、原浮点/原INT8参考各512个重复标量，并拒绝各9种错误报告；没有剔除不利图片。这些结果支持“更平滑、更接近内容结构”的可选视频模式，不支持自动覆盖原Mosaic。此前合成位移/噪声误差降低仍只对应三张公开图，不外推成test或实摄视频的时序验收。

注意，报告`quantized_vs_float`比较的是**当前INT8与原始浮点训练checkpoint**。稳定候选又经过一致性微调，其MAE15.147/255包含训练漂移，不能称为纯INT8舍入误差；其他QAT/原浮点比较也应保留这个边界。参数包与QAT整数路径逐字节一致是另一项检查，不能混为一谈。后续报告新增明确的参考范围字段，旧报告保留并由本说明解释。

## 不训练也能复现一张图片

新增[infer_r2_style_artifact.py](infer_r2_style_artifact.py)只读取所选`artifact/manifest.json`和`parameter_arena.bin`，不加载`.pt`、教师或训练集，不下载资源。现有Python模块仍需要本机PyTorch、NumPy、Pillow和psutil；没有声称已去除PyTorch安装依赖。

在PowerShell运行下面命令。输出目录必须不存在；更换风格只需选择另一个已导出的`artifact`目录并使用新的输出目录，不需要重新训练。

```powershell
& 'D:\miniconda\miniconda\envs\SWPC_ENV\python.exe' -X utf8 -B 'D:\contest\2026FPGA\yilingsi\case1\model\infer_r2_style_artifact.py' --artifact 'D:\contest\2026FPGA\yilingsi\case1\outputs\c36_qat_b_mosaic_stable_20260915a\artifact' --input 'D:\contest\2026FPGA\yilingsi\case1\assets\images\astronaut.png' --fit 640 480 --output-dir 'D:\contest\2026FPGA\yilingsi\case1\outputs\my_style_preview_01'
```

输出`input.png`、`stylized.png`及`inference.json`。`--fit 640 480`明确采用Pillow中心裁剪/Lanczos缩放，**不是RTL摄像头Resize的逐位golden**；省略`--fit`时只接受宽4～640、高4～480且均为4倍数的图像，不会默默缩放。脚本的CPU墙钟耗时不是FPGA帧率。

已实际生成的[完整分辨率输出](../outputs/c36_artifact_demo_20260915a/stylized.png)通过[独立checkpoint参考对照](../logs/c36_artifact_cli_native_20260915a.log)：输入及输出各921,600字节完全一致。三个冻结模型的小图[参数包独立推理测试](../logs/c36_artifact_inference_unit_20260915b.log)同时禁止`torch.load`，验证推理确实不读取checkpoint；实际CLI也拒绝覆盖已有结果。

## 本轮完成与后续平台边界

[Starry B原生RTL运行](../logs/r2_trained_host_runs/c36_b_trained_host_20260915b/status.json)、[Mosaic RTL运行](../logs/r2_trained_host_runs/c36_mosaic_host_20260915a/status.json)、稳定候选短回归及[独立新配置运行](../logs/r2_trained_host_runs/c36_mosaic_stable_camera30_20260915a/status.json)均已完成并清理。最后一轮于08:11真实退出，矩阵/小图/原生三项均通过独立终态检查。重型EDA全程串行、Job外、低优先级、最多两逻辑CPU，无波形；没有因观察超时重启仿真。

本轮“兼容当前RTL的新CNN训练与测试”已完成。官方平台联合实现/板测和运行时风格切换尚未验证，实际摄像头视频的艺术效果也仍需现场评估。模型较小不意味着固定MAC、缓存或DDR/视频外壳的FPGA资源同比减少。完整流水、失败、逐项复核与来源记录见[C36开发日志](../review/C36_CNN_TRAINING_LOG_20260915.md)。
