# 卷积取窗与行缓存检查

## 扩展验证

已阅读 `c1_s8_window3x3_same_c8` 的 replicate-SAME 合同和 Python 参考。参考按中心坐标、逐 tap 的 clamp(x/y) 打包 9 个 C8 像素；与 RTL 的双行 RAM、右边界 flush 和最后一行 replay 实现不同。

在原 9 帧测试之外加入 `(W,H,stride)`：1×1×2、1×5×2、5×1×2、2×2×2、640×3×1。新增覆盖 stride=2 的退化维度、640 宽 stride=1 的右边界和第三行银行轮换。现在共有 14 帧、3325 输入像素、2330 个完整 576-bit 窗口，逐窗口数据/中心坐标/标记检查通过；输入 hold=7086、输出 hold=8695、输出 stall=8696。既有无效尺寸、无效步长、配置快照和 abort 检查保留。

将以下已有自校验行缓存测试纳入固定回归：

- `tb_c1_window_line_cache_c8`：1445 个 tap 响应、18 次 refill/288 words，含响应回压、flush、受阻响应期间 abort 后排空。
- `tb_c1_window_line_cache_c8_faults`：9 次配置检查、3 类 refill 故障、2 类维护过程，最终 quiescent、无残留错误。
- `tb_c1_window_line_cache_c8_maxrow`：1280 words 行容量、16 次 tap、一次完整 refill，包含请求/源/响应停顿。

最新固定回归 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=43` 全部通过。窗口 Python 向量由现有生成器每次写入唯一临时目录，runner 清理四个窗口输出文件；与残差向量共用该临时目录。无生产 RTL 修改、无波形，未重复执行 EDA 综合或整系统 xsim。

## 与主架构的对应关系

`c1_s8_window3x3_same_c8` 在生产 RTL 中没有被其他模块实例化，是独立流式取窗候选，不能把本次通过写成“当前 SoC 卷积输入路径已验证”。其双行 RAM 大小为 2×640×8=10240 字节，当前保守调度的内部 stride=1 输入启动间隔并非每拍一个像素；此数字也不是主 SoC 的吞吐瓶颈实测。

当前 `c1_r1_portable_soc` 经 tensor adapter 和 `c1_tensor_window_cache_axi_client`，或可选 burst client 连接共享内存；普通 client 的启用 cache 分支使用 `c1_tensor_window_cache_seam` 与行缓存。顶层 ENABLE_TENSOR_WINDOW_CACHE 默认 0，而已有 SoC DDR BFM 显式设为 1。此次行缓存底层测试直接有参考价值，但未贯穿 adapter 的坐标/通道转换、seam 的请求属性和真实 AXI 响应。

因此，下一阶段应优先检查/运行现有 `tb_c1_r1_microstyle_tensor_adapter` 及 `tb_c1_r1_adapter_window_cache_axi_dynamic`，核对主路径逻辑请求、边界 tap、通道组和读写地址，而不是继续以独立流式候选测试代替主通路证据。后者测试采用分层重定向且 AXI 写入只 ACK、底层内存由 base scoreboard 更新，引用结果时必须保留这一证据边界。

全模型逐层算术、native 数据面对照和合法持续显示负载下的吞吐仍未签核。

## 追加：实际 adapter/cache/AXI 组合与独立内存

已将 `tb_c1_r1_microstyle_tensor_adapter` 和 `tb_c1_r1_adapter_window_cache_axi_dynamic` 纳入固定回归。runner 支持组合测试的额外 TB 源文件，并要求动态组合同时输出 adapter、AXI 内存提交和完整组合三个通过标记，防止仅 base 测试通过就误判整个组合通过。

先运行原组合取得基线，然后补强 AXI BFM：保留 `base.memory` 作为按逻辑请求更新的参考，新增独立 `axi_memory`。该数组除了初始测试复位清零外，仅由真正握手的 AWADDR/WDATA/WSTRB 更新；AW 与 W 各自独立锁存，收齐后逐字节写入，覆盖 AW-first、W-first 和同拍。

AR 响应现在来自独立 AXI 内存，而非 `base.memory`；每次读之前比较对应 128-bit 存储值，最终比较全部 384 个 64-bit 字，并检查提交次数与 W/B 次数一致。两份内存不共享写进程，也不从参考内存复制数据。因此前文“AXI 写端只 ACK”的局限已对本次修改后的组合测试消除，不能再用于描述该测试当前版本。

结果：

- adapter 单独测试：2230 请求、1810 读、420 写、448 次引擎操作数检查、32 个最终输出；含边界 tap、upsample、residual 和 abort 排空。
- 组合：22 个 stage 配置，其中 8 cache、14 bypass；2230 逻辑请求/响应，1512 cacheable 读、298 bypass 读。
- cache：1493 hits、19 misses、19 行 refill、204 words；不是 FPS 或板上带宽结果。
- bridge/AXI：922 下行请求/响应，502 AR/R，420 AW/W/B；318 AW-first、81 W-first、21 同拍，lower/upper halves=462/460。
- 独立内存：`C1_ADAPTER_AXI_MEMORY_COMMIT_PASS writes=420 compared_words=384`。保留一次注入的内存错误和 abort drain 检查。
- 全固定回归 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=45`，无生产 RTL 变更，无波形，临时向量与 VVP 自动清理。

证据仍有边界：组合通过层次重定向把 base 逻辑请求接入 seam/bridge；引擎仍是 base 的测试模型，检查操作数并提供模拟结果，不是实际 CNN MAC 逐层运行。小存储范围与单 outstanding AXI BFM 也不代替 native 容量、多 outstanding 或 15 fps。下一步应推进真实 engine 与真实参数的逐层数值对照，而不是继续仅累计 testbench 数量。
