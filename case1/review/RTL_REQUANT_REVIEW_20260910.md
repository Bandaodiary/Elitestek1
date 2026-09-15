# INT8 量化边界检查

本轮检查 `c1_requant_bank8.sv` 的 8 通道弹性量化流水，并参考 `c1_requant_s8.sv` 与 `c1_fixed_pkg.sv` 的运算合同。未发现本轮测试覆盖范围内的 bank8 算术缺陷，未修改生产 RTL。

## 新增验证

`sim/tb_c1_requant_bank8_boundaries.sv` 使用独立 signed64 除法/余数参考：计算乘积绝对值的整数商和余数，余数达到除数一半时进位，再恢复符号、饱和到 [-128,127]、按通道应用 ReLU。它不调用生产函数，也不复制 bank 的“幅值—偏置—移位”实现。

定向部分包含 16 个 accumulator 值 × 8 个 multiplier 值 × 48 个移位起点；八通道分配不同 shift/activation，再加入 1024 个固定种子的伪随机向量。覆盖：

- signed32 最小/最大值、signed18 最小/最大乘数及零乘数；
- 正负号组合，所有合法 shift=0..47；
- ±1 以及 ±255/256/257 等值形成的半整数舍入与饱和临界点；
- ACT_NONE/ReLU，按通道打包次序；
- 周期性下游回压，输入受阻时保持不变，输出数据及 SOF/EOL/EOF/X/Y 在回压期间稳定；
- 每个已接受向量对应且仅对应一个有序输出，数据和标记均与队列参考逐项比较。

结果：`C1_REQUANT_BOUNDARIES_PASS vectors=7168 lanes=57344 shifts=48 stalls=6447`。固定回归现为 34 配置且全部通过。测试结束自动清理 VVP，不生成波形；本轮生产 RTL 未变化，未重复运行正常路径 xsim/综合。

## 证据边界

通过证明的是合法输入下 bank8 的量化与弹性传输，不包括非法 shift/activation、运行中复位取消、MAC 累加本身、卷积取窗、残差对齐或完整模型逐像素正确性。标记验证不是 native 帧吞吐验证，不能支持“640×480 算术已签核”或“15 fps 达标”。scalar requant 和 fixed_pkg 本轮仅阅读，未将 bank8 结果泛化为它们的独立验证。

后续应沿数据依赖扩展到 MAC 累加、残差/逐层输出，再与 Python golden 的真实模型输入作比较；同时推进合法持续显示负载下的并发和访存统计。

## 追加：MAC 三种实现及标量残差全输入验证

阅读 `tb_c1_dot8x8_requant_core.sv` 后，将其三种编译配置纳入固定回归：默认、C1_PIPELINED_DOT_TREE、C1_PIPELINED_DOT_TREE_FULL。该测试逐通道/逐 lane 用整数乘加形成参考，使用 longint 检测 signed32 范围溢出，再通过赋值截断实现规格规定的 modulo-2^32 累加；不是将溢出当成饱和处理。

三种实现各通过 160 场景、781 个输入 group、141 个尾 mask 场景、19 个全 mask 场景、2 个溢出场景，均验证最终量化数据、溢出标记和输出元数据。对应输出回压检查次数为 638/635/596，输入 source gap 均为 926。此项复用了现有测试，不声称其覆盖所有可能 K、所有 mask 或全部累加输入；ALLOW_OUTPUT_RESTART 的非默认路径也不在这三种配置的结论内。

新增 `tb_c1_residual_s8_exhaustive.sv`，使用 signed integer 加法、比较夹紧作为独立参考，枚举全部 256×256 输入位模式及 ReLU 开/关，共 131,072 组，检查 `c1_residual_add_s8` 的数据、两级流水有效延迟与 SOF/EOL/EOF/X/Y 对齐，并插入无效周期。所有组合通过。这是标量残差的全输入算术验证，不涵盖 `c1_residual_add_c8` 的独立 main/skip 队列、配对错误和 abort 合同。

最新固定回归为 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=38`。本轮无生产 RTL 变更、未重复运行 EDA 综合/整系统 xsim，临时 VVP 自动清理，无波形。整体架构审查尚未完成，需继续推进 C8 配对、卷积窗口和真实模型逐层/逐像素对照，以及 native 访存与吞吐验证。

## 追加：C8 双流配对及受阻输出后的错误顺序

本轮检查 `c1_residual_add_c8`，将已有 Python golden 生成器和 C8 testbench 接入固定回归。每次运行在唯一临时目录生成 4 个 .mem 和 1 个 JSON，VVP 的工作目录指向该目录；结束后仅删除这五个已知文件与空目录，不留下向量副本或波形。runner 新增可选 `-Python` 路径，默认使用 PATH 上的 python；生成器仅依赖 Python 标准库。本次使用现有 D:/miniconda/miniconda/python.exe，未安装依赖。

已有测试覆盖六帧（1×1、5×3、4×4、7×5、3×6、8×8），共 149 个 C8 像素与 Python 饱和加法/ReLU 对照，含 main/skip 不同空隙、任一侧领先、输出阻塞和正常 EOF 完成；另覆盖坐标错误、标记错误、两者同时错误，以及只有 main 孤立输入时 abort。正常帧在错误测试之后执行，证明该路径可重新开始并产生正确像素。

新增 `check_stalled_mismatch` 定向场景：先产生每 lane=7 的正确结果并阻塞下游，再把坐标不匹配的下一对输入放入两侧缓存。连续检查旧输出、元数据、busy 保持且不提前报错；释放下游后，确认旧结果先完成握手，随后错误 pair 被丢弃、error_code=坐标错误、无 done、可再次 START。结果 `C1_RESIDUAL_STALLED_MISMATCH_PASS prior_output_preserved=1`。

C8 回归结果：frames=6、pixels=149，main/skip holes=233/241、main/skip hold=262/251、output hold/stall=465、main/skip leads=58/57、full-rate overlap=69。完整固定回归现为 39 配置并全部通过。未发现本轮覆盖范围内需要修改生产 RTL 的问题。

该结果覆盖单个 C8 残差模块的配对合同，不证明 residual 来源地址正确、不同量化尺度可直接相加，也不证明卷积窗口或完整模型正确；这些仍属于后续逐层数据面验证。
