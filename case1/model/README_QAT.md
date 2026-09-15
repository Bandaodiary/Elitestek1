# MicroStyle-24 功能性训练与 INT8 导出

本目录现有两类产物，不能混用：

- `microstyle24_untrained/` 仍是原有的拓扑/布局占位产物，`trained=false`；
- `microstyle24_starry_functional/` 是经过浮点优化与定点 QAT 的非随机功能性 checkpoint，`trained=true`，但明确不代表最终比赛画质收敛。

## 固定训练输入

- 内容：`assets/images/` 中六张许可明确的公开图像；
- 风格：Wikimedia Commons 公共领域《The Starry Night》缩略图 `assets/styles/starry_night_public_domain.jpg`；
- 固定随机种子：`20260824`；
- 默认过程：240 个浮点训练步骤，再进行 80 个执行 RTL 算术网格的 QAT 步骤；
- 损失：由风格图提取的亮度有序调色板监督目标、低频内容、固定 RGB/Sobel/Laplacian Gram、颜色统计、边缘与 TV。

流程不依赖 `torchvision` 或在线预训练模型。当前 checkpoint 只使用六张内容图和一个风格目标进行短程工程训练，其作用是打通“训练—BN 折叠—QAT—descriptor/arena—整数 Golden—RTL 参数装载”闭环。它保留了主体结构并形成风格图的蓝灰色调映射，但仍需更大内容集、多风格/感知网络和更长训练来达到答辩画质。

## 复现命令

从 `case1/` 执行：

```powershell
D:\miniconda\miniconda\envs\SWPC_ENV\python.exe .\model\train_microstyle_qat.py --float-steps 240 --qat-steps 80 --patch 64 --batch-size 2 --artifact-dir .\model\microstyle24_starry_functional --output-dir .\outputs\microstyle_qat --device cuda
D:\miniconda\miniconda\envs\SWPC_ENV\python.exe .\model\test_microstyle_qat.py
D:\miniconda\miniconda\envs\SWPC_ENV\python.exe .\model\validate_microstyle_qat.py --device cpu --size 64
```

CPU 也能运行，把 `--device cuda` 改为 `--device cpu` 即可。相同 seed、输入文件、PyTorch/CUDA 版本和设备类型是逐值复现的前提；跨设备浮点训练结果不承诺逐位相同，但导出后的整数 artifact 自身是确定的。

## 导出 ABI

`microstyle24_starry_functional/` 包含：

| 文件 | 作用 |
|---|---|
| `descriptors.bin` | 22 × 64 B 的 R1 stage descriptor，共 1,408 B |
| `parameter_arena.bin` | 固定 16,896 B 参数 arena：12,212 个 INT8 权重，以及逐输出通道 bias/multiplier/shift |
| `weights_int8.npz` | 便于 Python 审查的逐层 INT8/INT32 数组副本，不替代 arena ABI |
| `checkpoint_qat.pt` | BN 已折叠的 PyTorch QAT checkpoint、激活尺度和权重尺度 |
| `integer_regression.npz` | 许可明确内容图派生的 32×32 输入/期望输出，用于无需重训的自动回归 |
| `manifest.json` | 训练边界、量化规则、逐层尺度、arena offset 和训练指标 |

定点规则为 signed INT8 激活/权重、signed INT32 累加与 bias、逐输出通道 signed-18 multiplier、0..47 shift、绝对值中点远离零舍入、signed INT8 饱和与 ReLU。三个 residual block 的输入/project/add 共享尺度，因此 RTL 可直接执行饱和加法。

独立 NumPy 整数模型位于 `microstyle_quant.py::integer_infer_rgb`。训练脚本在写出 artifact 后会比较 PyTorch QAT 与该模型的全部 22 个 stage，任一层不完全相同就拒绝产出 PASS。

`validate_microstyle_qat.py` 还会在六张公开内容图上分别执行重载后的 QAT checkpoint 与参数 arena 整数推理，并写出 `outputs/microstyle_qat/validation/*_pair.png` 和逐图退化指标。该验证只证明输出非恒定、不过度饱和和整数一致性，不把这些工程指标解释为感知画质评分。
