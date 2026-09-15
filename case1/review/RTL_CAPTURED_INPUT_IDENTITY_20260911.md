# 捕获输入快照与计算端表项一致性

日期：2026-09-11。

## 修复的问题

输入区域记录来自捕获时实际接受的表项，但计算 frontend 会再次解析 DDR 表项。若两次解析之间表项发生变化，NN 可能从另一个区域读取，导致其真正的读地址与保留记录脱节。

本轮将校验接入真实 portable SoC：control 从已登记输入槽导出身份，boardless frame system 传递给 frontend，在 job admission 时锁存，frame pair resolver 成功后比较实际输入布局。缺失 valid 或任一字段不匹配时，使用 `0x34` 和实际解析的 input base 上报，禁止 input DMA、output DMA、engine 运行端启动。原 resolver 故障优先，继续保留其原始 code/address。

## 接口

新增 97 位输入身份包：

| 位域 | 含义 |
| --- | --- |
| 96 | 捕获快照 valid |
| 95:64 | XRGB base |
| 63:32 | stride bytes |
| 31:16 | width pixels |
| 15:0 | height lines |

`c1_r1_soc_control.boardless_expected_input` → `c1_r1_boardless_frame_system.job_expected_input` → `c1_r1_job_frontend.job_expected_input`。

portable SoC 固定启用 `CHECK_INPUT_SNAPSHOT=1`。独立 boardless/frontend 模块的参数默认 0，保持旧使用方式；启用时调用方必须提供已接受捕获快照，不能将本次 resolver 输出反馈成期望值。使用 `.*` 的 testbench 需声明新增端口信号，仓库内相关实例已更新。

## 验证

`tb_c1_r1_job_frontend` 新增六类用例：匹配、base 不匹配、stride 不匹配、width 不匹配、height 不匹配、valid 缺失。跨两种输入几何、两种 preview-layout 开关，共 24 配置；连同原两组 frontend 测试，定向 26 配置通过。

所有不匹配用例均要求无运行端启动、精确 `0x34`/解析地址，随后合法任务无复位恢复。提交后清零身份输入引脚，验证使用的是已接受快照。校验不一致的用例模拟捕获记录与表项内容不一致，不是 CPU 总线写事务模型。

controller testbench 同时要求每次 boardless 启动握手携带有效捕获身份。**本轮全量 Icarus 267 配置通过，退出码 0。**

## 修改文件

### 真实 SoC 数值复验

运行 `input_identity_soc_color_20260911`，启用真实训练参数、彩色双帧、12×10→8×8 Resize、tensor burst refill、寄存故障广播、queued write fabric 及预览显示。xsim complete / exit 0，297.776 秒。

独立 golden 核对通过：128 个 CNN 输入、1672 个 C8 层结果、各 128 个处理图/预览 DDR 像素、各 128 个预览/风格显示像素，53 项日志反例全部拒绝。该整机运行验证正常身份的传递和真实数据路径；身份不一致的拒绝由前述 frontend 定向用例证明，不混淆二者范围。

WMI 脱离 Codex Windows Job 启动，无波形；已确认 `case1/sim/portable_soc_cache_ddr_bfm_run_input_identity_soc_color_20260911` 不存在，保留 7 个文本文件共 114618 字节。墙钟仿真时间不是 FPGA 帧率。

### 文件清单

- `rtl/control/c1_r1_job_frontend.sv`：身份锁存、比较及错误合并。
- `rtl/top/c1_r1_boardless_frame_system.sv`：参数和身份端口传递。
- `rtl/top/c1_r1_soc_control.sv`：从输入区域记录导出身份。
- `rtl/top/c1_r1_portable_soc.sv`：默认启用并连通实际路径。
- 对应 frontend、boardless、control testbench 和 Icarus 回归清单。

## 边界

该校验不依赖表本身的存放地址，因此允许表重定位但图像布局不变。它不保护图像内容免遭 CPU 写入，也不替代其它 writer 的地址冲突检查。输出/预览/tensor 对活动帧的统一申请仲裁仍未完成。

配置 loader 可能在输入身份失败前完成其可复用配置银行的提交；本轮没有改变既有“配置提交不因另一个预检失败而回滚”的契约。身份失败保证的是不能启动运行端写入。新增比较的实际资源与物理时序尚未评估。
