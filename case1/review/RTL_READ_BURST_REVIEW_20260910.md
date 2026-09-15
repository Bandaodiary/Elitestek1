# 多 outstanding 读仲裁器的 RLAST 错误语义修复

日期：2026-09-10。范围为 `c1_axi_n_read_burst_arbiter_128` 及现有双客户端读 fabric。不是原生全网络性能或板级签核。

## 发现与修复

该候选仲裁器在预期末拍缺少 RLAST 时，原先向上游补 RLAST=1、透传 OKAY，同时仅置旁路错误标志。若叶级没有接入错误标志，它会把损坏的事务当作正常结束。模块用于 `c1_tensor_mem_axi128_read_fabric_2c`，不同于此前已修复的串行仲裁器。

现在向客户端保留实际 RLAST；提前或缺失 RLAST 时，OKAY/EXOKAY 升为 SLVERR，已有 SLVERR/DECERR 原样保留。内部 owner 结束仍采用 `actual_last || expected_last`，只在真实 R 握手后推进。正常响应的仲裁、FIFO 和延迟结构不变。

特别限制：本轮没有解决缺失 RLAST 后任意多余物理拍的归属问题。ID-less 多事务队列无法凭数据区分多余拍与下一事务首拍；若实际控制器边界未知，应停止新任务并协调排空/复位。源码注释已去除“任何异常都不会死锁”的过强保证，不能把简单清错误当作安全恢复。

## 测试及实际结果

更新原 testbench：检查客户端 RLAST 等于实际总线值，独立根据注入的事务长度推进计分板；新增客户端 RRESP 对比，不再把修饰后的 RLAST 当作正确性依据。

八种组合：EMPTY_AR_BYPASS 开/关 × RRESP 四编码。每种通过正常 16 beats、异常 10 beats、4 个在途请求的覆盖，检查 owner/data 顺序、提前和缺失 RLAST 错误标志。bypass 开启时验证零周期首 AR 及停顿捕获路径，默认首 AR 延迟一周期保持不变。

双客户端读 fabric 的默认、beat FIFO、request pop/refill、empty AR bypass 四配置也通过：每种 16 个逻辑请求、6 个 AR、8 个 AXI 数据拍、6 次 packing、最大 5 个在途事务。此 fabric 用例使用正常 RLAST，不应把它表述为异常恢复组合验证。

统一入口 `scripts/run_iverilog_review_fixes.ps1`：

```text
C1_REVIEW_FIXES_REGRESSION_PASS configurations=78
```

本轮只运行 Icarus，不生成波形；VVP 和临时向量由脚本清理，未重新综合或进行全 SoC xsim。当前修改提高协议错误可见性，不改变缓存复用或 MAC 吞吐；原生尺寸和实时显示仍需独立验收。

## 追加：读客户端与仲裁器的异常组合验证

扩展 `tb_c1_tensor_mem_axi128_read_fabric_2c.sv`，增加 `FAULT_MODE=1/2`。使用真实两个 tensor 读客户端、pack2 和多 outstanding 仲裁器；分别在默认逻辑响应 FIFO 与 beat FIFO 下运行，共四个新配置。不修改生产 RTL。

- 模式 1：两客户端的 `0x1200 + owner*0x10000` 单拍 packed burst 均省略 RLAST。每个物理错误拍对应两个逻辑错误响应；加上原有两个未对齐请求，共 6 个错误响应。
- 模式 2：两客户端的 `0x1000 + owner*0x10000` 两拍 burst 都在第一拍提前 RLAST。实际到达的两 lane 报错，尚未到达的两 lane 由真实客户端补零数据错误响应；加上原有未对齐请求，共 10 个错误响应。

计分板独立根据请求索引建立数据/错误预期，逐项比较返回值及每客户端顺序，要求全部 16 个请求恰好返回 16 个响应，两个期望队列与 BFM 均排空；同时检查 early/missing/orphan 标志和真实注入次数。注入点实际 ARLEN 必须为预期的 0/1，否则测试直接失败，不能因 packing 未发生而空过。

四配置均通过：每种注入 2 次、6 个 AR、max in-flight=5；缺失末拍模式为 8 个 AXI R beats，提前末拍模式为 6 个 AXI R beats。两种 FIFO 下结果相同。统一入口通过 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=82`。

边界仍保留：故障从机在缺失末拍时恰好发送声明长度，在提前末拍后立即结束该事务，不注入无法归属的额外 R 拍。新组合用例的逻辑响应消费者保持 ready，尚未覆盖异常与长时间逻辑响应回压的组合，也未证明物理控制器异常后的自动恢复。无波形或大体积临时工程保留。

## 追加：异常叠加响应 FIFO 满与长回压

新增 testbench 参数 `STRESS_BACKPRESSURE`。打开时响应 FIFO 深度为 2，叶级 BURST_BEATS=2、MAX_OUTSTANDING=1（两客户端合计仍有 2 个在途事务），满足 beat FIFO 的容量约束。第 0/1 个消费者分别到第 300/450 周期才释放，之后继续施加不同周期的 ready 间隙。原有较深 FIFO、5 个在途事务的用例继续保留，不被替换。

新增断言要求两个 FIFO 均真实满至少 20 周期，逻辑响应保持检查超过 100 次；逐拍检查 `valid && !ready` 后的数据、错误位与 VALID 稳定性。最终仍必须逐项匹配全部 16 个响应、6/10 个错误、两个注入事件及队列排空。

| 故障 | FIFO 模式 | 满周期（客户端 0/1） | 逻辑保持检查 | AXI R 回压周期 |
|---|---|---|---|---|
| 缺失 RLAST | logical | 282 / 148 | 425 | 428 |
| 缺失 RLAST | beat | 282 / 428 | 708 | 424 |
| 提前 RLAST | logical | 281 / 429 | 707 | 0 |
| 提前 RLAST | beat | 280 / 428 | 707 | 0 |

提前 RLAST 模式主要验证真实客户端生成后续错误响应时的输出阻塞，不将其误写成物理 R 回压覆盖。四配置均通过，统一回归结果为 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=86`。本轮没有修改生产 RTL，也没有安装依赖、运行综合或保存波形；临时编译和向量由脚本清理。

未闭合：任意额外物理 R 拍的归属和系统级恢复、长时间持续工作负载、原生分辨率数值与实时吞吐仍需后续证据。
