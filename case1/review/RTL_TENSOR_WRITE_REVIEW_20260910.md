# Tensor 写路径握手补修与剩余审查项

日期：2026-09-10。本轮接续帧 DMA 修复，检查 tensor 单 burst、多 outstanding 和 skid 写路径，不依赖特定厂商 IP。

## 已修复：单 burst tensor 写客户端

`rtl/dma/c1_tensor_mem_axi128_write_burst_client.sv` 原先同样以 AW 握手作为发送 W 的前提。该模块是 `c1_tensor_mem_axi128_write_parallel_fabric` 各并行 lane 的真实叶级客户端，因此外层仲裁器的独立 AW/W 修复不足以解决此处依赖。

修改为完整 burst 构建后同时驱动 AW/W，分别保存 `aw_done_q`、`w_done_q`，两者完成后进入 B 阶段。W 索引在 burst 发布前初始化，而不是在 AW 接收时重置，避免 W-first 场景重发数据。`perf_outstanding` 仍按 AW 已接收、B 未接收计数，不把仅发送数据的阶段错误计入该指标。

保持 pack2、相同 lane 去重规则、4 KiB 分拆、请求/响应 FIFO、BRESP 错误传播和原始响应顺序。`req_flush` 是关闭构建批次的请求，不是取消已呈现的总线事务。

## 本轮通过的验证

统一入口：`scripts/run_iverilog_review_fixes.ps1`，结果 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=54`。

| 用例 | 实际证据 |
|---|---|
| 原 tensor burst 测试，普通/依赖型 AWREADY | 每种 21 个请求、10 个 burst、13 个数据拍、7 次 packing、2 个预期错误响应；保留响应 FIFO 回压检查 |
| 新 `tb_c1_tensor_write_early_w` | 2 个场景，每次 4 个数据拍全部先于 AW；共 16 个逻辑响应，其中 8 个 SLVERR 响应；检查数据、WSTRB、WLAST、AW 地址长度、停顿稳定性与计数 |
| 请求 FIFO 同拍 pop/refill，关闭/开启 | 各 12 个请求、12 个 burst、12 个数据拍；开启时确认 full 边界的同拍替换 |
| 两路并行写 fabric | 16 请求、4 burst、8 beats、8 次 packing，max outstanding=2，4 个预期错误响应 |
| 四路并行写 fabric | 32 请求、8 burst、16 beats、16 次 packing，max outstanding=4，4 个预期错误响应 |

旧单 burst BFM 原本随机宣告 WREADY，却没有早到 W 的存储，并把早到 W 视为错误。本轮将其明确限定为地址已知才接收 W 的合法模型，并增加 AWREADY 等待 WVALID 的配置。数据先到的正确性由独立新 TB 验证，不删减已有数据和错误检查。

测试没有生成波形；VVP 与临时 golden 向量由统一脚本在结束时清理。本轮未启动 Vivado、未重新综合/P&R。54 项通过不构成 native 全网络吞吐或板级集成签核。

## 尚未修复的同类风险（静态发现）

1. `c1_axi128_write_mlp.sv`：当时发现 WVALID 以 `issued_count_q != 0` 和 `desc_aw_issued_mem[head_q]` 为条件；后续已补修并通过定向测试，见下节。不能直接用并行 fabric 的通过替代该核心验证；两者是不同方案。
2. `c1_axi_write_skid_bridge.sv`：仅在 `aw_committed` 后接收 W，而且 WLAST 后就清除此标记，可能在前一事务 B 尚未完成时重新开放 AW；需要补事务占有期与独立通道测试。本轮搜索在 `case1/rtl` 内未找到其他模块实例化它，属于旧候选，不应未经验证直接插入正式集成路径。

既有单拍 bridge 与 packer 的发送条件在静态检查中已分别使用独立 AW/W 完成标记；此次不据此宣称它们所有参数/异常情形都已验证。

此外，持续显示服务、native 640×480 数值与吞吐、缓存节流/服务空窗、多主机 CPU 集成和物理 CDC 仍有独立验收工作，未因本轮协议修复而闭合。

## 追加：MLP 核心修复与 65 配置回归

生产修改只去除 `c1_axi128_write_mlp` 的 WVALID 对 AW 已接收计数/标记的依赖。仍要求 head descriptor 存在、payload 完成、W 未完成且不是应本地拒绝的错误描述符。W 完成不推进 head；原有 AW-issued、B 和响应空间条件继续控制退休，因而不会因数据先发而释放其存储槽。没有改变接口、存储深度或 early-AW 的零 strobe 填充合同。

新增 `tb_c1_mlp_early_w.sv`，分别运行 `EARLY_AW=0/1`：每种 3 个描述符、9 个 W 数据拍全部先于对应 AW；W 完成后地址继续停顿，随后 B 延迟、逻辑响应回压。首个事务在 WLAST 后、AW 前注入一次孤立 B，检查描述符仍占用、无响应、outstanding 仍为零；最终只收到三个合法退休响应，最后一项传播 SLVERR。逐项检查数据、WSTRB、WLAST、地址、长度、tag、响应顺序、停顿保持及错误计数。

原核心测试增加首个 AWREADY 等待 WVALID 的配置，仍要求原来的三个地址在途覆盖，未将其降级成单 outstanding 测试。

本轮统一脚本通过 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=65`，其中新增的 MLP 验证包括：

| 用例 | 结果 |
|---|---|
| 核心默认、首 AW 依赖 WVALID、响应 pop/refill | 每种 6 个描述符、3 AW、12 W、3 B、max outstanding=3、4 个预期错误；pop/refill 开启时覆盖一次 full 同拍替换 |
| early-AW payload 异常 | 6 个描述符、5 AW、15 W、5 B、5 个预期错误，检查早/晚 LAST 与 flush |
| 新 W-first 测试，默认/early-AW | 每种 3 个描述符、9 个早到 W、1 次孤立 B、1 次 SLVERR |
| logical-write adapter 三配置 | 每种 5 个描述符、26 个逻辑请求/响应；默认及 pop/refill：4 AW/12 W；early-AW：5 AW/14 W |
| MLP+peer 双客户端 fabric 两配置 | 每种 4 AW、7 W、4 B、8 个 adapter 响应、2 个 peer B，max in-flight=4 |

一次中间回归因新增测试引用了不存在的计数器名 `aw_count` 而编译失败，已改为实际的 `aw_seen` 后完整重跑；失败不计入通过结果。未启动 Vivado、未保存波形，临时 VVP/向量由回归脚本清理。

当次剩余范围：旧 skid bridge 尚未修复（后续进展见下节）；MLP 仍按 head 顺序完成 W/B，当前改动消除握手依赖但没有证明最大带宽，也不意味着原生全网络 15 fps 闭合。

## 追加：旧 write skid bridge 修复

`c1_axi_write_skid_bridge.sv` 已将 W 接收条件与 AW 下游握手解耦，可以先缓存/发送 W。增加独立 `w_committed` 标记；AW/W 的完成标记直到上游 B 握手才清除，修复 WLAST 后、B 返回前重新开放 AW 的占有期漏洞。下游 BREADY 只在 AW 与 W 均已完成且 B 缓冲为空时开放。六个公开 READY/VALID 均在 reset 时屏蔽，避免复位丢弃事务却对外显示握手。

保持单事务、单 beat W 缓冲，无组合 READY 穿越或同拍满槽旁路。因此最大 W 速率仍为每两拍一 beat，本轮没有将其作为吞吐优化插入主系统。它要求正确的 WLAST；没有新增 malformed burst 恢复接口，复位仍需与上下游协调。

新增 `tb_c1_axi_write_skid_bridge.sv`，三种服务模式覆盖 AWREADY 等待 WVALID、全部 W 先于 AW、AW 先于 W；逐拍检查 payload/strobe/last、地址属性和停顿稳定性，检查 WLAST 后等待 B 时不开放新事务、B 回压期间保持响应、DECERR 透传和 reset 握手屏蔽。结果：`transactions=3 beats=9 early_w=4 response_hold=24 reset=1`。

统一回归已通过 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=66`。本轮使用 Icarus，未启动 Vivado、未生成波形，临时 VVP 与 golden 向量由脚本清理。该单模块结果不等价于所有参数、非法 AXI 行为、板级集成或完整系统吞吐签核。
