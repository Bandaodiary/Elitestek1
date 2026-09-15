# 独立输入/输出帧尺寸：解析器基础扩展

## 发现的架构限制

`c1_r1_boardless_frame_system` 明确只提供一组 `job_width_pixels/job_height_lines`。`c1_r1_job_frontend` 将这组尺寸传给 `c1_frame_pair_resolver`，后者要求输入和输出帧表项均匹配。因此当前上层不支持不同输入/输出尺寸的完整帧任务，虽然独立 Resize/ingress 已支持变尺寸和不同横纵步长。

这不是把某个测试尺寸改成另一个值就能解决的问题。完整支持需要依次打通解析器、任务前端、boardless 组合、SoC 控制/帧生命周期及软件配置，且输入 DMA、CNN 目标尺寸、输出 DMA 和显示元数据必须各自使用正确尺寸。

## 本阶段修改

在 `rtl/control/c1_frame_pair_resolver.sv` 新增默认关闭的参数 `SEPARATE_INPUT_GEOMETRY=0` 与两个追加输入端口 `expected_input_width_pixels/expected_input_height_lines`。

- 默认 0：仍由旧 `expected_width_pixels/expected_height_lines` 描述两帧，追加端口被忽略。
- 参数 1：追加端口描述输入帧，旧端口描述输出帧。四个尺寸在 start 握手时一起快照，运行中软件改值不影响本次解析。
- 任一侧期望宽高为 0 返回既有错误码 03；输入表项尺寸错误返回 24，输出表项尺寸错误返回 25。没有修改表项布局或错误码 ABI。
- 两个帧的基址、对齐、stride、32-bit 地址边界检查沿用已有逻辑。
- 重叠检查改为分别使用 `resolved_input_width/height` 与 `resolved_output_width/height`。每行有效区间宽度不同、行数不同仍进行双行区间列表归并，不用矩形外包范围代替有效像素检查。保持 O(input_height+output_height) 的检查方式，无新乘法器。

`c1_r1_job_frontend` 暂时仍使用参数默认值，新增端口显式接 0，保持已有业务接口和行为；旧 resolver TB 的 wildcard 连接补齐对应信号。没有声称完整 SoC 已获得异尺寸任务能力。

## 定向证据

新增 `tb_c1_frame_pair_geometry.sv` 使用参数 1，通过真实表项 AXI 读取解析。参考模型枚举两帧所有有效行区间的两两交集，与 RTL 的区间归并算法不同。

22 个用例全部通过，覆盖：12×6→8×8、8×8→12×6、输入较宽导致行尾重叠、输出较宽导致行尾重叠、较后输入/输出行才出现重叠、12 种基址偏移下的填充区与有效区交错、两侧尺寸不符、两侧零宽拒绝。每个用例都在 start 后将四个期望尺寸改为 0，验证快照独立性。

默认模式 `tb_c1_frame_pair_resolver` 也通过：47 次接受、43 次响应、23 次成功、20 次错误、4 次 abort、3 次重启、74 次 AXI 地址/数据响应，并覆盖背压与响应停顿。未删除或弱化原有测试。

重现定向用例：

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_frame_pair_geometry -Python <已有Python解释器>
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_frame_pair_resolver -Python <已有Python解释器>
```

## 下一步及边界

1. 将独立输入几何配置贯通 job_frontend 与 boardless，并保持默认同尺寸兼容。
2. 用不同尺寸的真实输入/输出帧表、DMA 和 Resize/C8 数据流做联合数值验证，检查未读完源帧的生命周期。
3. 明确 SoC/CSR 的源尺寸与目标尺寸配置、描述符目标尺寸约束、原图/风格图显示策略；不能只放开解析器检查就宣称集成完成。

本阶段不更改软件 CSR 或上层任务 ABI，不替代不同尺寸下的整套系统验证，也不代表资源/时序/帧率签核。

## 最终兼容性复测

全量 Icarus 回归 **115 配置符合预期**，包括新模式的 22 用例、旧模式 resolver 回归，以及之前的 Resize 相位/尾部异常恢复、ingress、显示与总线测试。

`review_geometry_legacy_soc_20260910` complete / exit 0，69.943 秒。保持旧同尺寸模式的彩色 SoC 经 `--require-video` 核验，64 输入、22 阶段 836 个 C8 结果、64 最终 DDR 像素、原图/风格图各 64 显示像素全部一致。这证明已测旧配置兼容，不作为独立几何模式的整套 SoC 证据。

未重跑综合。xsim 使用既有 Windows Job 脱离启动器，临时目录已清理，仅保留 53,913 bytes 精简日志，无波形；Icarus 临时镜像与向量也由 runner 清理。

## 追加：任务前端与 boardless 链路贯通

`c1_r1_job_frontend` 与 `c1_r1_boardless_frame_system` 均增加默认 0 的 `SEPARATE_INPUT_GEOMETRY`，追加 `job_input_width_pixels/job_input_height_lines`。前端在 job start 时对输入尺寸做原子快照并传递给 resolver；启用时旧 job_width/job_height 为目标尺寸。boardless 中现有 resolved_input_* 已分别接输入 DMA 与 Resize 输入，resolved_output_* 接 Resize 输出及输出 DMA，故不需改 DMA 端口或帧表格式。

完整 portable SoC 暂时仍使用默认模式，新增 boardless 输入显式接 0；已有 native boardless testbench 同样保持默认。软件 CSR、SoC 生命周期与不同尺寸的显示布局尚未扩展，不能把本阶段能力等同于整机已支持异尺寸摄像头到 CNN。

### 实测

- job_frontend：旧模式和 12×6→8×4 新模式分别通过，每种 11 个任务开始、5 次引擎启动、3 次完成、6 次错误、2 次取消。保持描述符缓存/故障/重启测试；任务开始后将新增输入尺寸改为 0，证明配置快照有效。
- boardless：旧 8×3→8×3 与新 8×6→8×3 各通过 9 个任务场景，7 次启动、2 次成功、5 次错误、2 次取消、5 次排空检查。新模式 x_step=1.0、y_step=2.0、y_phase0=0.5，是真实不同横纵比例的缩放，而不是不同尺寸元数据却仍做单位映射。
- 两次成功任务分别逐像素核对最终输出 DDR 的 24 个 XRGB 字。异尺寸参考对源图相邻两行逐通道做 `(a+b+1)>>1`，对应规范的半相位插值；输入图案各通道不同并包含 u8 回绕。输入 DMA、两行缓存、Resize、RGB/C8 编解码和输出 DMA 均为真实 RTL；CNN 是原有回环模型，不是完整训练网络。
- `review_boardless_geom_new3_20260910` 与 `review_boardless_geom_old3_20260910` 为最终通过的 xsim 运行。`review_frontend_geometry_soc_compile_20260910` 证明更新接口后完整 portable SoC 编译/展开通过，未把此次 compile-only 解释为新的 SoC 数值验证。

### 仿真工具处理与复现

Icarus 在 boardless 组合上超过 30 秒，runner 已终止该镜像并清理临时文件；不能仅凭超时归因于 RTL。该组合改用已有安全启动/自动清理的 xsim runner，新加互斥入口：

```powershell
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -RunId geometry_new -BoardlessGeometry separate
& case1/scripts/run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 -RunId geometry_old -BoardlessGeometry legacy
```

首次 xelab 参数传递因 Windows 批处理拆分 `NAME=VALUE` 失败，改用 testbench 编译宏选择模式；不是 RTL 编译错误。随后两种模式均完成数值测试，但原有随机 AW 背压计数为零而未通过覆盖判定，因此 BFM 改为明确插入至少两拍 AW 等待，保留覆盖要求再跑，最终通过。没有删除失败检查以取得 PASS。

boardless 组合没有放进默认 Icarus 回归，以避免已知超时；job_frontend 两模式已登记。旧专用 boardless xsim 脚本未作为本次运行入口，此处使用支持 Windows Job 脱离和失败路径自动清理的公共 runner。

最终全量 Icarus **117 配置符合预期**，另有上述两种 boardless xsim 和完整 SoC compile-only 证据。本轮七个 xsim 尝试（包括失败及 compile-only）的临时工程目录均已清理，没有波形保留。未进行综合或布局布线。

## 追加：双轴异尺寸、独立 stride 与输出保护区

上一阶段异尺寸用例只改变输入高度，宽度与 stride 仍相同。新版 `-BoardlessGeometry separate` 改为 **12×6→8×3**，输入 stride=64、输出 stride=32；默认 legacy 仍为 8×3→8×3。输入每行仅 48 字节有效，16 字节填充区使用明显不同的 `0x00dead55`，避免错误 stride 恰好读到相同图案。

中心对齐的采样位置为 `x=1.5*i+0.25`、`y=2*j+0.5`。testbench 用整数四分之一权重先分别插值上下两行、每次半向上舍入，再以二分之一权重纵向插值。该显式参考在全部 24 个 RGB 像素（72 个通道值）上与 Python `resize_bilinear_q16_u8` 独立交叉核对一致。

每次成功任务结束后同时检查：

- 解析的输入宽高/stride 为源几何，输出为目标几何；
- 实际 AXI 写提交的 24 个 XRGB 字逐个符合参考；
- 96 字节有效输出之后的 160 字节保护区全部保留初值 `0xcc`。

最终 `review_boardless_biaxis_guard_new_20260910` 和 `review_boardless_biaxis_guard_old_20260910` 均通过：各 9 个任务、7 次启动、2 次成功、5 次错误、2 次取消、5 次排空检查。两次成功任务均执行完整帧及保护区核对；日志压缩可能将相同结果行合并，不能用保留行数代替 testbench 调用次数。

这次只修改 testbench 和参考，没有修改生产 RTL。没有重跑全量 117 配置或综合；新旧两模式各先运行一次，再加保护区检查复跑，共四个 xsim 运行全部完成，临时目录均已清理，仅保留 48,097 bytes 精简日志，无波形。

该用例依旧使用 CNN 回环模型。它证明已测 boardless 的源 DMA、Resize/C8、目标 DMA 与几何传递正确，不是不同尺寸下完整训练网络或完整 SoC/CSR 支持的证据。上层配置、帧生命周期和显示策略仍需继续贯通。
