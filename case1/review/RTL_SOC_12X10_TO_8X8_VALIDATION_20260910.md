# 真正异尺寸整机用例：12×10 → 8×8

## 端到端配置

安全 xsim runner 新增 `-SourceGeometry`，要求单帧 8×8 trained numerical trace，与反向 ResizeFixture 互斥。测试使用真实 portable SoC，不强制内部尺寸或以回环模型替代 CNN。

- 摄像头：14×12 RAW10，彩色 RGGB 线性测试图；
- ISP valid crop 输出：12×10 RGB，输入帧表 width/height=12/10，stride=64；
- CSR：源尺寸=12×10、目标=8×8，x_step=1.5/x_phase=0.25、y_step=1.25/y_phase=0.125，中心对齐双线性缩放；
- CNN：真实训练参数、22 层，目标仍为 8×8；
- 输出帧表：8×8、stride=32；
- 原图显示：独立核对 120 像素；处理图显示：64 像素。

输入槽容量与目标槽容量分离：源每槽 768 字节（64×10 后按 256 字节对齐），目标每槽 256 字节。原有物理输出写掩码仍跟踪目标分配，没有扩大它来掩盖越界。涉及输入缓冲范围的 BFM 故障分类同样改用输入槽大小。

## 参考与覆盖边界

checker 通过唯一 `C1_NUM_SOURCE 12x10` 标记选择独立原图几何，先构造完整 12×10 ISP 参考，再用标量整数相位参考生成 8×8 CNN 输入。检查全部 CNN 输入和 22 stage 输出、实际 AXI 提交的目标 DDR 像素，以及完整两路显示。原图末尾 56 个超出旧 64 像素上限的像素也必须存在，不能只查前 64 个。

新增标记缺失、未知、重复和原图最后一个像素缺失四个反例。旧 8×8 单位映射及反向分数映射日志仍由新版 checker 正确核对。

该场景的目标验证范围仅为小帧链路，不代表原生大分辨率、15 fps、板级接口或时序达标。未修改生产 RTL；超出 640×480 的大图预览方案、SoC/APB 非法源尺寸拒绝场景仍需后续工作。

## 初次失败与 BFM 修复

首次 `review_source_12x10_20260910` 的流程运行 complete（83.268 秒），但 Python 数值检查拒绝：CNN 输入、全部网络层和 DDR 输出符合参考，原图显示第 48 个像素（x=0,y=4）开始错误。因此不能将模拟器流程 PASS 当成完整数值 PASS。

原因是旧小帧 BFM 的固定大小直接映射存储发生槽冲突：输入行地址 0x00100100 和输出行地址 0x00200080 均映射到槽 24。输出写入覆盖了该槽原先的输入记录；随后原图显示读取因地址标签不匹配而得到模型占位值，首像素为 0x00100120，而不是原始采集值。这不是 RTL 对源 DDR 的真实写覆盖。

异尺寸用例改用原已用于 native 大帧的按完整地址关联存储，不再受直接映射槽冲突影响。最终输出检查同步支持关联存储，但仍要求每个目标像素的四个字节都有真实 AXI WSTRB 提交记录，缺失地址立即失败；未通过放松像素检查来取得 PASS。

## 最终结果

`review_source_12x10_assoc_20260910` complete（83.238 秒）后独立检查通过：64 CNN 输入、22 stage/836 C8 输出、64 物理 DDR 输出像素、120 原图显示像素和 64 处理图显示像素全部符合参考。19 个错误日志反例全部拒绝。该结果支持本小帧配置的完整异尺寸链路，而不是仅接口编译或回环验证。

旧单位映射和反向分数映射日志均通过新版 checker。未重跑全量 Icarus或综合；既有 123 配置结果仍为上一阶段历史证据。两次 xsim 均安全脱离 Windows Job，临时工程已清理，保留失败与成功的精简日志供追溯，无波形。

复现：

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -RunId review_source_12x10_assoc_20260910 -TrainedArtifact -Frame8x8 -NumericalTrace -ColorFixture -SourceGeometry
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe case1/golden/test_portable_soc_numerical_trace.py case1/logs/portable_soc_cache_ddr_bfm_runs/review_source_12x10_assoc_20260910
```
