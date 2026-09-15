# R2-C24：Resize接入真实Capture/CNN主机

日期：2026-09-13。范围：板卡无关RTL连接、数值与错误恢复验证、Ti60联合核心资源/时序；不是板级验收或新的15 fps证明。原R1、C18、C21、C22生产源码保留。

## 1. 本阶段完成了什么

C23的紧凑Resize已真正接到采集写入器、帧池、CNN与主机系统。新增入口是 [c1_r2_resize_host_system.sv](../rtl/r2/c1_r2_resize_host_system.sv)，使用 [c1_ti60_r2_resize_host96.xml](../efinity/c1_ti60_r2_resize_host96.xml) 的41个生产源加资源探针，不应把整个RTL目录同时加入工程。

```text
待接：SC431/CSI → Debayer/居中ROI → 有限缓冲/CDC
                                  │ 同步RGB，必须遵守ready
                                  ▼
CPU AXI/APB接口 → resize_host_system → video_resize_system
                                      ├─ frame leases：接纳时锁存源配置
                                      ├─ resize_capture_rgbx32
                                      │   ├─ C23 Resize：四点取样、双线性
                                      │   └─ 原Capture：RGBX32打包、AXI写、B排空
                                      ├─ C22 CNN：共享特征存储、96 MAC、生成式DAG
                                      ├─ 配对显示：缩放原图＋风格图
                                      └─ 原四主机AXI fabric → DDR接口
待接：实际Sapphire/DDR控制器、显示CDC与物理HDMI
```

新增三个生产模块各有一个职责：

| 文件 | 职责 | 保留的底层实现 |
| --- | --- | --- |
| [c1_r2_resize_capture_rgbx32.sv](../rtl/r2/c1_r2_resize_capture_rgbx32.sv) | 一份任务共同拥有Resize与Capture，错误/取消联动，完成结果保持稳定 | C23 Resize、原RGBX32 Capture/AXI写入器 |
| [c1_r2_video_resize_system.sv](../rtl/r2/c1_r2_video_resize_system.sv) | 在帧池预约时锁存源尺寸/Q16参数，暂存pending期间取消，失败帧不交给CNN | C22帧池、CNN、显示、CSR、fabric |
| [c1_r2_resize_host_system.sv](../rtl/r2/c1_r2_resize_host_system.sv) | 转发新源配置/流接口，保持CPU AXI适配、APB16与IRQ接口 | C22主机桥与CPU适配器 |

CNN模型、执行计划、算术、共享缓存和DDR格式没有重写。新Resize影响采集完成时间及总线竞争相位，故小系统周期不要求与C22逐拍一致，也不以本轮结果声称CNN计算加速。

## 2. 接口与错误合同

- 源尺寸为16位，宽度1..2048、高度非零；Y步进不允许负数。X/Y步进与起始相位为有符号Q16。输出尺寸由系统WIDTH/HEIGHT确定，资源探针为640×480。
- `capture_request && capture_request_ready` 是源配置的锁存点，早于内部Capture描述符握手。调用方不得在此之后仍以修改端口影响当前帧。测试在接纳后立即改成零尺寸/负Y步进，后续结果仍正确。
- `s_valid/s_ready` 共同接纳源像素；坐标、SOF/EOL/EOF与RGB在背压下必须保持。当前没有相机域CDC，也不支持把不可回压CSI直接连到此口。
- 非法配置不接纳、不预约帧池；`source_config_error` 是随非法请求成立的电平，不是已接纳任务的错误完成，也未新增对应APB寄存器/IRQ。
- 源错、Capture溢出、AXI写错误或取消停止Resize/后续输入，已提交的Capture写事务仍由原写入器排空。只有Resize已退出且Capture完成后，才释放任务所有权；失败帧不进入CNN/FRONT。
- 取消在描述符等待期间会记住；取消在内部命令接纳时已成立也不会吃掉源像素。已发布、被下游保持的完成结果不可被随后取消改写。
- `source_error/source_error_code` 保存本次源故障，下一次内部任务接纳时清除；主动取消以dropped返回，不冒充坐标错误。现有失败采集通路更新错误IRQ。

CPU AXI/APB的原有ABI保持。**新源配置目前是公开RTL端口，没有增加CPU可编程寄存器、BSP初始化或真实Sapphire软件执行。** 探针的host地址18..23只是低引脚资源观察/配置壳，不是比赛软件寄存器图。

## 3. 仿真验证

### 实际Resize → CNN → 显示

[独立golden](../golden/r2_resize_plan_vectors.py) 先生成两种不同尺寸的非平凡RGB图，执行独立Python双线性Resize，再调用原DAG整数CNN oracle；预期张量仅供检查器使用，不能灌入DUT替代计算。

输入0为输出尺寸的2倍；后续帧使用另一幅图，源宽为1.5倍加1、源高为1.5倍加3，实际包含分数插值。连续帧使用两种确定性图案，不是每帧独立自然图像，也不是摄像头实拍。

| 测试 | 配置/结果 | 日志 |
| --- | --- | --- |
| 原22项DAG | 8×8、32×32，各背压0/1；24次CNN、36,736正确显示像素；实际Resize源77,419像素→29,824像素 | [主矩阵](../logs/r2_resize_host_matrix_20260913_a.log) |
| 删除res1的18项结构变体 | 同样4配置；24次CNN、32,000正确显示像素；源66,253→25,344像素 | [变体矩阵](../logs/r2_resize_host_variant_20260913_a.log) |
| 实际RAM破坏负控 | 8项，分别破坏CNN输入/配对显示存储，均被数值或实际生产关系检查拒绝 | [负控](../logs/r2_resize_host_negative_20260913_a.log) |
| Vivado xsim | 12×12、背压1、AW等待W模式2、MEMORY_DIV=2/延迟20、6次CNN、4,320正确显示像素 | [xsim结果](../logs/r2_resize_host_xsim_runs/c24_resize_host_xsim_12x12_20260913_a/result.log) |

上述矩阵还覆盖每配置3次非法源配置拒绝、接纳后配置扰动、真实CPU流量、APB/IRQ与多ID恢复、采集/计算/显示并发。结构变体未重训，不说明风格质量合格。

xsim任务 `c24_resize_host_xsim_12x12_20260913_a` 用时31.420 s，6次内部CNN周期为24402/24892/24644/24613/24667/24015；worker的Windows Job检查为false。只限小尺寸功能回归；运行器和TB拒绝将此回压源模型作为原生摄像头性能测试。

### 取消、错误和帧所有权

[Resize/Capture独立回归](../logs/r2_resize_capture_20260913_a.log) 包含背压0/1与AW等待W的0/2交叉：48次Capture、28次scan、4,608显示像素；5种错误/取消各4次，含源EOL错误、SLVERR、FIFO溢出、持有真实B响应时取消、命令接纳时取消。每次失败后不复位恢复；48次完成结果保持期间再取消，结果仍稳定。预期注入的4次溢出/下溢不应被写成正常路径故障。

完整主机另外验证三种场景，各背压0/1：

1. [预约后、子描述符启动前取消](../logs/r2_resize_host_fault1_20260913_d.log)：失败tag1无源像素、无AXI写。
2. [存在真实Capture写债务时源坐标错误](../logs/r2_resize_host_fault2_20260913_b.log)：保持B 64拍，期间禁止失败完成；释放B后才能回收帧池。
3. [存在真实写债务时外部取消](../logs/r2_resize_host_fault3_20260913_b.log)：同样等待真实B排空，不以局部Resize复位代替总线完成。

六配置共6次预期失败采集、18次正确CNN完成，均观察到错误IRQ并在无复位条件下继续。`post_fault_nn=3` 表示故障之后发生的3次完成，其中可能包含故障前已启动的任务，不声称3个任务全部在故障后启动；检查器另核对确有tag>1的新任务在故障后启动。失败tag1禁止进入CNN及真正的显示FRONT握手，后者有独立事件日志；Capture的`ARM`不是显示事件。

最终[本阶段检查器](../golden/check_r2_resize_host_evidence.py) 检查保留源、41源闭包、数值/事务时间线、源计数/配置、错误恢复、实际PNR层次和xsim清理，还拒绝10项证据变异；这10项不是额外10次RTL错误注入。最终结果见 [r2_c24_gate_20260913_b.log](../logs/r2_c24_gate_20260913_b.log)。

## 4. Ti60联合实现与平台容量

真实联合工程 `c24_resize_host96_i3_20260913_a` 已完成map+PNR，Titanium Ti60F225、I3、150 MHz。不是把C22与单Resize报告相加后冒充联合实现。[实现摘要](../logs/efinity_resource_runs/c24_resize_host96_i3_20260913_a/summary.json)包含实际Resize/Capture/主机/CNN层次；96个DSP24与34个DSP48均保留。

| 联合核心 | XLR | RAM | DSP | 150 MHz最终setup/hold |
| --- | ---: | ---: | ---: | --- |
| 保留C22，未含Resize | 41,252 | 134 | 112 | +0.349 / +0.026 ns |
| C24，含实际Resize与取消连接 | 43,665 | 146 | 130 | +0.387 / +0.026 ns |
| 差值 | +2,413 | +12 | +18 | 不以独立工具最优Fmax替代约束验证 |

最终最小周期6.279 ns。Resize层次12 RAM/18 DSP，原Capture仍5 RAM；本轮没有消除后者的流缓冲。上述是低引脚联合核心探针，不含实际Sapphire、CSI/Debayer、DDR PHY、时钟树/跨域、物理HDMI和全部板级IO。

按[平台资源审计](R2_WEIGHT_MEMORY_BUDGET_20260913.md)选取一套官方CPU/DDR/CSI/Debayer的粗和17,361 XLR/105 RAM/4 DSP，再加本轮实际联合核心，得到 **61,026/60,800 XLR、251/256 RAM、134/160 DSP**。逻辑约超226、RAM仅余5块，而且ROI/CDC/FIFO尚未计入。

因此容量仍未闭合。跨工程简单相加不能精确预测最终packing/裁剪，但也不能忽视余量不足。下一步需以真正平台源闭包验证，并审计Sapphire缓存/可选外设、观察壳、重复FIFO和时钟资源；不可未经验证直接把FIFO调小。官方视频PLL/Clock Mux用满的约束仍需联合规划。

## 5. 失败记录、临时文件与下一步

早期smoke遇到Python列表闭合错误、Icarus不支持plusarg直接写数组元素，以及TB信号在声明之前引用；均在新分支修正，没有改动C21/C22生产源。初版检查器误把Capture `ARM`当显示事件，最终改为真实`display_frame_armed`驱动的FRONT记录并重跑三种故障；首次失败门禁a保留，最终使用b。

所有已完成的C24向量、vvp/xsim快照、EDA私有工程由运行器自动删除，无波形归档；必要文本与清理快照保留：[清理记录](../logs/r2_c24_cleanup_20260913.json)。C21/C22原生六帧任务未重启，其活跃私有目录保留。它们的最终结果必须由各自检查器确认，不能继承C18的15.3145 fps，更不能转称C24摄像头整链路帧率。

下一阶段优先做 **不可回压输入下的有限缓冲、ROI/CDC与整帧取消恢复**：1920×1080 RGB居中取1440×1080，再送640×480 Resize；结合实际像素时钟/行消隐验证最坏水位，溢出整帧作废并从下一SOF恢复。C23完整1440×1080→640×480虽为2,477,887拍、数值正确，但最长源暂停1,921拍，不能直接连接CSI。裁剪若移到RAW域，必须重新核对Bayer相位。

之后再完成CPU可编程源配置与官方DDR/视频平台联合工程、时钟/资源闭合以及板测。当前训练模型的比赛风格效果与泛化质量仍另行评估；整体重构目标未完成。
