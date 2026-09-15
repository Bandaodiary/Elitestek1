# 完整 SoC 数值验证补漏与修复

## 结论

本轮修复的是先前系统验证的真实漏洞，不是新一轮 MAC/缓存性能优化。旧训练参数 SoC 的完成标记不足以证明数值正确：新加入的观测发现 CNN 输入含 `X`。定位后确认，系统 testbench 没有初始化 Gamma RAM，而独立 ISP 测试已包含初始化流程。

修复后，8×8 训练参数 SoC 的 64 个输入像素符合线性 RAW10 测试图案预期，真实 engine 的 22 阶段、836 个 C8 结果全部与整数 Python golden 一致。最终 Icarus 回归 105 配置符合预期，其中包括一个必须触发指定 fatal 的负向配置。

## 原因与修改

1. `sim/tb_c1_r1_portable_soc_cache_ddr_bfm.sv` 之前误将“标量 ISP 配置复位为单位变换”当作“Gamma 也已初始化”。现在在拍摄前通过真实 APB 地址 `0x260/0x264/0x268` 写入 1024 项，测试恒等映射为 `address >> 2`。没有直接改写层次化 RAM 来绕过配置链路。
2. 同一 testbench 的 APB master 原在完成上升沿之后的下降沿采样响应。Gamma 命令接受后 pending 置位，组合 PSLVERR 会反映新状态，导致这个过晚采样误报忙。读写任务现在均在实际完成上升沿、顺序逻辑更新前采样，下一下降沿撤销请求。
3. `rtl/video/r1_rgb10_color_pipeline.sv` 明确 Gamma 启动约定，新增 `ifndef SYNTHESIS` 诊断：有效像素的 CCM 结果未知，或者 Gamma 地址尚未写入有效值时立即 fatal。没有给三组 RAM 增加复位网络，也没有改变硬件数值算法、接口或流水级数。控制复位不清除已写 LUT；重新配置 FPGA 后仍须初始化。
4. `software/include/c1_isp_config_regs.h` 补充软件初始化要求。标量 COMMIT 不能代替 Gamma 表编程；一般驱动仍应遵守原有 busy/ready 协议。
5. `-NumericalTrace` 仅允许单帧、8×8、训练参数模式。限制输出为 64 个输入及 836 个结果，检查捕获数据及 CNN 数据的未知值。压缩日志不再从末尾重复收集数值行。
6. `golden/check_portable_soc_numerical_trace.py` 检查运行状态、训练模式 PASS、完整顺序、坐标、尾通道补零与数值；随后使用现有 `integer_infer_rgb` 和训练参数 arena 对全部阶段逐项比较。`test_portable_soc_numerical_trace.py` 在内存中修改日志，证明 X、错误数值、缺项及重复项均被拒绝，不生成修改后的日志文件。

## 验证证据

| 运行/检查 | 结果 |
|---|---|
| `review_numeric_x_origin_20260910` | 新检测在 capture writer 发现 `xxxxxx`，旧问题复现 |
| `review_numeric_x_isp_20260910` | BLC、Debayer 有效输出无未知值，捕获 RGB 仍未知 |
| `review_numeric_gamma_fixed_20260910` | 加入 Gamma 编程后暴露 testbench APB 过晚采样问题 |
| `review_numeric_gamma_apb_fixed_20260910` | 修正 APB 后 SoC 完成，64 输入 / 22 阶段 / 836 结果 golden 通过 |
| `review_numeric_guard_final_20260910` | 加入 RTL 诊断后 SoC 再次完成，golden 再次通过 |
| `tb_c1_gamma_initialization` | 已编程 LUT 输出 `ff8000`，控制复位后仍一致 |
| 同上，`PROGRAM_LUT=0` | 非零退出且报指定“读取未初始化 Gamma”诊断，符合负向预期 |
| `run_iverilog_review_fixes.ps1` | 105 配置符合预期 |
| Python 检查器破坏性输入测试 | unknown / wrong_value / missing / duplicate 四项均拒绝 |

最终 SoC 配置启用 DisplayResponseFifo、FabricReadResponseSkid、TensorBurstRefill、PipelinedResultWrites、TensorPackedWrites、TensorWriteEnd；这些仍然是候选开关，没有修改生产默认值。最终 xsim 的 AXI AW/W/B 为 708/774/708，任务完成一次，描述符 22 个。不能把这些计数当作性能提升结论。

## 重现

在项目根目录运行；`python` 应替换为已有 NumPy/PyTorch 的 Python 解释器，不要求额外下载：

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 `
  -RunId numerical_recheck -Frame 8x8 -TrainedArtifact `
  -DisplayResponseFifo -FabricReadResponseSkid -TensorBurstRefill `
  -PipelinedResultWrites -TensorPackedWrites -TensorWriteEnd -NumericalTrace
# 等 status.json 为 complete 后，再做独立数值判定；xsim PASS 本身不替代下式。
python case1/golden/check_portable_soc_numerical_trace.py `
  case1/logs/portable_soc_cache_ddr_bfm_runs/numerical_recheck
python case1/golden/test_portable_soc_numerical_trace.py `
  case1/logs/portable_soc_cache_ddr_bfm_runs/numerical_recheck
```

## 证据边界与后续工作

- 输入检查覆盖本测试的线性 RAW10 梯度、单位 AWB/CCM、恒等 Gamma、相同输入输出尺寸。不是全部 Bayer 图案、任意 ISP 参数和缩放比例的联合数值签核。
- 836 个 C8 比较点是 engine 到 adapter 的结果握手，覆盖实际 engine、adapter 取数、缓存和共享 AXI 路径；不是最终显示图像逐像素核对，也不替代最终输出 DDR 读回与 HDMI 检查。
- 旧系统测试缺初始化期间的 PASS 应仅作为流程/协议证据，不能引用为训练网络数值正确证据。旧周期对照也不要与增加 APB 初始化后的运行直接混用。
- 未重跑 Efinity 综合、布局布线，没有新的面积、时序或板上 fps 结论。原生 640×480 全网络、DDR 竞争、CPU 主机及板上 15 fps 仍需要后续验证。
- 本轮五个新 xsim 运行均使用既有 Windows Job 脱离启动器；运行已结束，五个临时工程目录均不存在。仅保留约 137 KB 精简日志，无波形或大型仿真产物。Icarus 镜像和临时向量由 runner 清理。

## 追加：最终帧的实际 DDR 提交验证

上一节的 836 个 C8 结果检查已进一步延伸到最终帧缓冲。新版本 `-NumericalTrace` 在显示换帧与任务完成后，使用 `display_styled_base/stride` 定位最终图像，而不是假设输出总在第零槽。

- 按 AXI 从机 `store_beat` 实际接收的 WSTRB，独立记录三帧槽的逐字节写入覆盖；逻辑写请求或 engine 结果不算作写入证据。
- 验证显示帧基址在输出槽范围且槽对齐、stride 正确，检查稀疏内存地址标签，逐像素要求四字节均曾写入，并拒绝未知值。不使用未写内存的合成返回值作为证据。
- 打印 64 条 `C1_NUM_DDR`，Python 将其与完整整数模型的最终 RGB 比较，要求内存字格式为 `0x00RRGGBB`。这同时检查 s8 转 RGB、通道顺序、输出写入及帧槽选择。
- 新版检查器强制要求 DDR 记录；旧版只有 engine trace 的日志现在会被拒绝，不再悄悄降级为较弱验证。错误注入测试先确认原始日志通过，再测试原有四项和 DDR 错值、缺项、重复、未知值共八项，避免“原始输入本来无效”造成负向测试假通过。

`review_numeric_ddr_commit_20260910`（打包写＋结束标记候选）已完成，64 输入、22 阶段、836 C8 结果以及 64 DDR 像素全部与 golden 一致；八项检查器负向测试符合预期。本次增加的是验证覆盖，没有改生产数据通路或性能默认值。

`review_numeric_ddr_default_20260910` 也已完成并通过同一数值检查：不启用 TensorBurstRefill、PipelinedResultWrites、TensorPackedWrites、TensorWriteEnd，仍保留 DisplayResponseFifo 和 FabricReadResponseSkid。因此它验证默认 tensor 读写路径，不是所有顶层参数均默认的配置。两个新运行临时目录均已清理，合计保留 99,683 bytes（约 97 KB）精简日志，无波形。

该检查是在 AXI BFM 已提交的存储中观察最终数据，不是新增 AXI 读主机，也不是对 HDMI 输出像素的检查。显示预取虽然仍运行，其数据到视频输出的对应关系尚未纳入本数值 scoreboard。当前输入图案仍为灰度梯度，彩色摄像头输入通道映射及任意 ISP/Resize 配置需要后续扩展。

## 追加：彩色 Bayer 到最终帧的通道检查

灰度输入的三个分量相同，不能独立发现 ingress 红蓝交换。新增 `-ColorFixture`（必须同时启用 `-NumericalTrace`），保留原有灰度回归。彩色模式仍为 10×10 RAW10 输入，经有效 3×3 Debayer 裁剪得到 8×8，使用 RGGB，三色平面分别为：

```text
L(x,y) = 64 + 17*x + 29*y
R = L + 96，G = L + 40，B = L
```

该尺寸内没有 RAW10 裁剪/环绕；双线性 CFA 插值精确恢复三组线性平面。单位 AWB/CCM 与 `Gamma[i]=i>>2` 下，CNN 输入像素 `(x,y)` 对应 RGB 为 `[(L(x+1,y+1)+96)>>2, (L(x+1,y+1)+40)>>2, L(x+1,y+1)>>2]`。第一像素为 `(51,37,27)`，不再是灰度。Python 独立核对该 RGB，再运行原有 22 阶段与最终 XRGB DDR 比较。

日志新增唯一 `C1_NUM_FIXTURE color_rggb` 或 `gray` 标记。检查器拒绝非法/重复标记；旧日志无标记只按历史灰度处理。检查器负向测试增加源输入红蓝交换、错用灰度标记、非法标记、重复标记四项，并在任何变异之前先证明原始日志有效。

重现命令在前面的数值回归命令末尾追加 `-ColorFixture` 即可。未修改生产 RTL 或默认性能开关；测试不等价于全部 Bayer/ROI 相位与任意缩放比例验证。

验证结果：`review_color_ddr_default_20260910` 与 `review_color_ddr_packed_20260910` 两个 SoC 运行均完成，分别通过 64 个彩色输入、22 阶段 836 个 C8 结果及 64 个 DDR 像素的 golden 检查。默认 tensor 路径的日志通过全部 12 项检查器负向测试；旧灰度 `review_numeric_ddr_commit_20260910` 也通过新版检查器，未丢失原有覆盖。两个新临时工程目录均已清理，无波形保存。

## 追加：显示预取与跨时钟行缓存的数值验证

`review_video_numeric_fix_20260910` 已完成（82.186 秒）。在彩色、打包写候选基础上，新增 pixel clock 域监视器，记录原图/风格图行缓存有效响应及前一周期采样的读取坐标。两个流各取完整 8×8 图像，Python 将原图与 ISP 后 RGB 比较、风格图与最终整数网络 RGB 比较，128 个显示读响应均一致；原有 64 输入、836 个 C8 结果、64 个 DDR 像素检查也全部通过。

监视器按前一周期 compositor 请求选择期望源，有效响应缺失时为黑色，在顺序逻辑更新后检查 compositor_rgb，从而核对数据选择与一拍响应的流水对齐。它尚未独立推导屏幕窗口坐标，因此不能据此声称全屏布局正确。

当前 APB display mode 为 0（风格图居中显示），原图经后台读取路径消费。这覆盖原图/风格图 DDR 读取、行缓存跨时钟数据以及风格图可见路径；不等价于原图单屏、左右分屏的屏幕位置检查。检查点在 OSD 之前，不覆盖 OSD 字符叠加、HDMI 编码/序列化，也不证明 native 无欠载或 15 fps。

新版 golden 检查器新增 `--require-video`：显式要求原图和风格图两个显示流都完整；不加此参数时兼容旧日志，但只要有一个视频流出现，仍要求两者均完整。新证据必须使用：

```powershell
python case1/golden/check_portable_soc_numerical_trace.py `
  case1/logs/portable_soc_cache_ddr_bfm_runs/review_video_numeric_fix_20260910 --require-video
```

检查器增加视频错值、缺像素、删除全部视频记录三项负向测试，共 15 项符合预期。测试从原始日志确定视频要求，并将该要求保持到变异后的检查中，避免删除全部记录后退回旧版较弱检查。

首次监视器编译因引用不存在的 `pair_pixel_rst` 失败；已根据实际 RTL 修正为 `pair_pixel_reset` 与 `pixel_rst`，再重新编译运行。该失败仅为新增 testbench 的层次名称错误，不是生产 RTL 缺陷。两个新临时工程目录已清理，合计保留 63,424 bytes 精简日志，无波形。本轮仍只增强验证，没有修改生产 RTL。

## 追加：四种显示模式的独立完整光栅检查

原 `tb_c1_split_compositor.sv` 已有完整分屏光栅参考，而 `tb_c1_compositor_modes.sv` 只做 11 个静态点。此次复用前者，新增 `MODE=0/1/2/3` 参数，保留默认 2 与旧脚本兼容。根据屏幕布局独立定义期望源与坐标，不从 DUT request 或 source-select 推导期望位置；同时明确检查“期望有请求但 RTL 漏发”的情况。

四个配置均由 Icarus 实测通过，每种遍历一整帧 1650×750=1,237,500 周期（有效区域 1280×720=921,600 像素），四种共 4,950,000 周期。逐周期检查时序发生器坐标、DE/HSYNC/VSYNC、源请求、完整源坐标、RGB 输出、黑边及输出同步对齐；源模型为一拍同步读取的坐标图案，不是 DDR。

| MODE | 可见布局 | 原图请求数 | 风格图请求数 |
|---:|---|---:|---:|
| 0 | 风格图居中，x=320..959，y=120..599 | 0 | 307200 |
| 1 | 原图居中，相同窗口 | 307200 | 0 |
| 2 | 原图左侧、风格图右侧 | 307200 | 307200 |
| 3 | 保留模式，全部黑色 | 0 | 0 |

重现：

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_split_compositor -Python <已有Python解释器>
```

结果标记 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=4`。四配置已加入回归脚本，但本轮只执行这四个定向配置，不能将“已登记 109 个配置”写成“全量 109 配置已通过”。没有启动 Vivado/Efinity，没有修改生产 RTL，Icarus 临时镜像/向量由既有 runner 自动清理。

这补齐合成器单模块在四种静态模式下的独立屏幕坐标证据，不替代多模式完整 SoC、帧边界模式切换、DDR 仲裁、OSD/HDMI 或非等比例 Resize 的联合验证。
