# 生命周期控制器独立输入尺寸与非法任务准入修复

## 本次改动

`c1_r1_soc_control.sv` 增加默认关闭的 `SEPARATE_INPUT_GEOMETRY`，以及默认继承目标尺寸的 `REQUIRED_INPUT_WIDTH/HEIGHT`。追加 `input_frame_width/height` 和 `boardless_input_width/height` 端口。

启用时，旧 `frame_width/height` 为目标尺寸，新输入为源尺寸。控制器接受 START 时对源和目标尺寸原子快照：任务尺寸检查分别匹配配置的源/目标要求；采集帧表的即时错误检测和采集状态机两处检查都改为源几何；boardless 命令分别输出源/目标尺寸。默认模式忽略新增输入，源尺寸由旧 frame 参数快照，保持兼容。

完整 portable SoC 暂时保留默认模式，新增控制器源输入接零、源命令输出显式悬空。CSR 和实际源配置尚未接通，因此不能宣称完整 SoC 已接受独立采集尺寸。

## 测试发现并修复的实际缺陷

新增非法源尺寸测试在直接故障广播模式通过，但在 `REGISTER_FATAL_TICKET=1` 时复现 `invalid source geometry launched work`。原因是 `parameter_start_valid` 只检查参数地址，没有检查完整 job 配置；错误通知寄存一级后，非法任务可在 abort 到达前先发起参数加载。

修复将 `job_config_legal` 同时加入参数加载及采集准入条件。该校验由已锁存配置产生，不依赖延迟到来的故障广播；未改变合法任务的故障通知延迟规则。此修复也覆盖尺寸以外的无效任务配置（现有 descriptor/tensor/table/format 合法性逻辑），但本次新增定向反例专门测试源尺寸。

## 定向验证

原有 `tb_c1_r1_soc_control` 的异尺寸模式由仅注入 resolved 元数据，升级为真正通过控制器的源尺寸快照与采集帧表校验：源 960×720、stride=4096，目标 640×480、stride=2560。

- START 接受后将实时源尺寸清零，检查采集 writer 使用源宽高/stride，boardless 命令保持源/目标各自的正确尺寸；
- 继续覆盖任务完成、原图/处理图显示快照、请求背压、取消后重复显示、前台/后台错误与 system-disable 取消；
- 新增源宽=0、宽不匹配、高=0、高不匹配四种拒绝场景；同时有待采集帧，要求不发出参数启动、采集帧表请求、采集写入或 boardless 启动，且恰好一次错误报告；
- 两种广播模式均通过；默认同尺寸两种模式也通过，四配置均保留在回归中；新增模式要求 `C1_SOC_INPUT_GEOMETRY_PASS` 标记。

此测试的采集/boardless/显示端点为行为握手模型，960×720 不代表现有 640×480 显示窗口可直接容纳大图，也不是实际 CNN 的异尺寸端到端证明。

完整 portable SoC Icarus 编译/展开通过：128 源文件、0 errors、602 条工具诊断。

全量 Icarus **122 配置符合预期**，包含预期失败检查；配置数量不变，本轮扩展的是既有控制器异尺寸配置的实际覆盖范围。

完整 SoC 兼容性复测：安全脱离 Windows Job 的 `review_soc_input_control_20260910` xsim 运行 complete，72.019 秒。彩色 RGGB / 8×8 真实网络的 64 输入、22 stage/836 C8 结果、64 DDR 像素及原图/处理图各 64 显示响应通过 Python `--require-video` 核对。临时工程目录确认已删除；此测试为旧同尺寸路径，不是整机独立源尺寸验证。

## 后续

下一步需要定义并实现软件 CSR 的源宽高及 Resize 步长/初相位，接入控制器快照、boardless 启动及采集配置。大尺寸原图的显示预览仍需明确方案；现有每侧 640×480 上限不可直接解除。性能、资源、15 fps 和板级集成仍未签核。
