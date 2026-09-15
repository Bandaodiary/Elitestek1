# 当前 RTL 的完整小图网络与 golden 来源复核

日期：2026-09-10。本轮不修改生产 RTL，复核已有完整数值测试，并新增可复现的 golden 来源检查入口。不是 native 640×480 或 15 fps 签核。

## 测试究竟覆盖什么

`tb_c1_r1_microstyle_artifact_tensor_engine_8x8.sv` 的 FullStage21 模式实际贯穿 22 个阶段，包含真实参数 bank、tensor adapter 和 MicroStyle engine。每个 adapter operand 对比窗口/残差/坐标/group/stage；每个 engine result 比较整数 golden 及输出位置和帧标记；最终流逐项比较 64 个像素。各层写回检查实际 `mem_req_wdata`，再将实际数据写入本地模型供后续层读取，并非把 golden 层结果直接写回替代计算。

它使用本地有延迟的逻辑内存模型，不经过正式共享 AXI fabric、显示和 CPU；不能用它替代最近写通道修复的协议回归。原子参数 bank 与 packed-affine 两种实现选项均可运行同一端到端数值检查。

## 当前工作树的重新运行结果

| 配置 | 结果 |
|---|---|
| [普通参数布局](../logs/stage1_handoff_runs/review_full22_20260910/status.json) | complete / exit 0，22 stages、896 operands、836 results、64 final pixels、22 stage_done、abort=0 |
| [Packed affine](../logs/stage1_handoff_runs/review_full22_packed_20260910/status.json) | complete / exit 0，同样全部计数与数值检查通过 |

两个 worker 经既有 breakaway 机制脱离 Codex Windows Job，未请求波形。结束后直接检查两处 `run_directory` 均不存在。日志耗时约 10.2 秒为工具墙钟时间，不是硬件每帧处理时间。

## Golden 来源检查

新增 `scripts/check_microstyle_engine_vectors.ps1`：调用现有 Python 整数推理生成器，以现存 `model/microstyle24_starry_functional` 参数和 8×8 图案重新生成向量，然后逐条比较五份 `.mem` 的实际记录。只忽略行首尾空白，不使用摘要，也不改写保存的参考向量。

本次直接比较通过：22 个 descriptor、1056 个参数记录、896 个输入记录、836 个输出记录、22 个 stage metadata，共 2832 条。图案为 `(17*x + 31*y + 53*c + 11) mod 256`。这证明当前保存向量与当前生成器/参数一致；生成器和 RTL 仍可能共享规格误解，因此不是独立数学形式证明，也不证明模型视觉质量。

复现命令（显式选择已安装 NumPy/PyTorch 的解释器）：

```powershell
& case1/scripts/check_microstyle_engine_vectors.ps1 -Python D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe
& case1/scripts/run_r1_stage1_handoff_xsim_detached.ps1 -FullStage21
& case1/scripts/run_r1_stage1_handoff_xsim_detached.ps1 -FullStage21 -PackedAffine
```

当前默认 Miniconda base 缺少 NumPy，首次生成尝试失败；复用已有环境后通过，未安装或下载包，也未修改该环境。生成结果位于唯一临时目录，脚本只删除自己产生的六个已知文件及空目录，不保留另一套向量副本。

## 后续仍需推进

本轮将“现有逐层测试是否仍完整、golden 是否过期”落实为新证据，但仅有一种 8×8 输入图案。原生尺寸的全部算术输出、较大尺寸边界、实际共享内存下的持续显示和 15 fps 服务预算仍需分别验证，不能以 PASS 数量替代这些覆盖。
