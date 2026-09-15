# 板卡无关 RTL 边界检查：显示配置与完成性

本记录接续 `RTL_FIXES_20260910.md`。本轮为实质性进展，整体架构检查仍在继续，不代表性能、异常恢复和系统集成已签核。

## 已修复

1. `c1_display_prefetch_pair.sv` 的 `primed` 原先必须同时有奇偶两行。height=1 时永远不满足，显示 bootstrap 无法开启。现在锁存高度，单行只要求两路各有一条完整已提交行；多行仍保持双行 priming。
2. 原先宽度越界只在仿真触发 fatal；综合硬件会继续读取并截断坐标。现在在启动两路 reader 前检查非零尺寸、4 像素对齐、MAX_WIDTH/MAX_HEIGHT 和 X_BITS/Y_BITS 可表示范围。不合法请求正常握手后返回一次 done+error，不发起 AXI；下一合法 START 清除错误并可重启。
3. `c1_r1_display_subsystem.sv` 将 pair 容量限制为 min(FRAME_WIDTH,640)×480，与固定 compositor 面板相符。单独使用 pair 时新增末尾参数 MAX_HEIGHT，默认 65535，不强制所有独立用途均为 480 行。

这里的尺寸合法性不替代 reader 原有的 base/stride/地址范围校验；也没有宣称单像素宽度已获支持，XRGB burst reader 当前要求宽度为 4 的倍数。

## 验证

- `run_iverilog_review_fixes.ps1`：20 个配置通过。
- 扩展 `tb_c1_display_prefetch_pair.sv`，真实 reader、FIFO、双时钟 line store 和 AXI BFM 组合分别测试 FIFO=0/1。
- 每种配置均拒绝零宽、零高、超宽、超高、非 4 对齐宽度，检查一次完成、error、恢复 ready、不新增 AR。
- 错误之后执行 4×1 图像，核对两源 RGB、primed、最终 busy/ready 和完成计数；总计核对 32 个实际源像素（含原 4×3 正常事务）。
- 保留原早期取消测试。新增单行测试等待 core primed 后留出 ready-toggle 的三拍 pixel 同步时间；这与 subsystem 同步 enable 后等待 raster 边界的使用合同一致，不能将 core primed 当作 pixel 同拍有效。
- 127 源文件主顶层编译：exit=0，errors=0，warnings=598。未运行新综合/P&R，也未将历史 xsim 结果当成本次源码版本的整系统验证。
- Icarus 编译镜像由脚本 finally 删除，无波形和大型临时工程。

## 仍需检查的关键问题

1. **两路异常与取消排空**：下节已修复 pair 层的循环等待并完成定向验证。仍须补全外层 SoC 错误广播、外层 flush 与本地恢复交叠的系统测试，以及长 burst 中途错误、不同 AXI 客户端竞争下的恢复测试。
2. **有效显示负载下的并发证明**：几何修复后的双帧记录整体失败于 overlap 覆盖断言；旧 48 次重叠不能用作性能证据。需构造合法且持续的扫描负载，不删除断言或恢复越界请求。
3. **native 算术与实时性**：需要 native 数据面 golden 对照、按层访存/MAC 周期统计、显示服务空窗测试。小图零欠载不等于 640×480、15 fps 达标。
4. **物理边界**：CDC 时序约束、RAM/DSP 推断、Ti60 资源/时序及摄像头/DDR/HDMI IP 集成仍需后续 EDA/板卡验证，不属于本轮的通过声明。

## 追加：取消与单路错误恢复

### 确认的问题与修复

原 pair 在 abort 或单路 error 后仍要求 line store 和 FIFO 被像素消费者读空才给 done。若像素请求因恢复而停止，外层 `safe_to_flush(!busy)` 无法成立，形成循环等待。另外 START 与 abort 同拍时，reader 优先取消、不接收 START，而 pair 已进入 active，无法等到 reader 的完成脉冲。

现在 `c1_display_prefetch_pair.sv` 实现两个独立退出合同：

- 正常结束仍等待 reader、FIFO、line store 全部排空，保持完整显示所有权。
- abort 或任一路 reader error 时，锁存恢复状态并取消两路 reader；已呈现的 AR 不撤回，已接受的 R 继续排空。确认两路完成且 reader 均空闲后，复用 `c1_display_flush_reset` 对 **FIFO/line store** 做双时钟协调清理，不复位 AXI reader。收到像素侧复位断言与释放确认后才给终止脉冲、恢复 ready。
- START 同拍 abort 走无 AXI 的本地取消完成路径。显式 abort 与错误保持不同的 aborted/error 语义；合法重启清除错误。恢复期间不再报告 primed。

### 新增验证证据

同一真实 AXI BFM/reader/FIFO/CDC store 组合，在 FIFO=0 和 FIFO=1 各执行七类故障，并在每次恢复后读取一幅新图、核对 RGB：

1. 两行银行占满后取消；FIFO 配置还确认已有未消费像素排队。
2. 仅 styled 基地址不对齐，original 配置合法。
3. 仅 styled 第二行返回 SLVERR。
4. START 和 abort 同拍。
5. ARVALID 已呈现但 ARREADY 延迟，取消后继续等待原 AR 握手。
6. AR 已握手但 R 返回延迟，取消后不得提前清理或完成。
7. 满缓存后停止 pixel clock，再取消；确认没有像素域应答时 busy 保持，恢复时钟后完成并可重启。

每种配置检查 88 个实际源像素，终止次数与 aborted/error 分类符合预期。断言检查本地缓存复位不得早于 AXI reader 退休，测试同时检查不遗留 BFM 待返回响应。`C1_DISPLAY_RECOVERY_PASS scenarios=7 fifo=0/1` 与全部 20 配置回归通过；最新顶层编译 errors=0、warnings=599（不是无警告签核）。未运行新 EDA 综合或整系统 xsim，不能据此宣称整个 SoC 异常恢复已签核。

环境假设仍为 AXI 对端最终握手/返回响应、两个时钟最终运行；不对永久失联 DDR 或永久停钟承诺自行完成。本轮只使用小型 Icarus 临时镜像，脚本结束清理，无波形。

## 追加：外层 flush 合同与组合验证

进一步检查发现 `c1_r1_display_subsystem` 的 flush 会停止 raster 消费，但原先只把独立 abort 输入传给 pair。若调用者只发 flush，外层等 `!busy`，pair 正常路径却等待停掉的 raster 排空缓存。虽然当前 `c1_r1_soc_control` 通常同时发 abort/flush，这仍是子系统独立使用时的接口缺陷。

先新增 `tb_c1_display_outer_flush.sv`，在真实 subsystem（包括两级 flush、reader、line store、可选 FIFO）上复现：`mode=0 busy=1 flush=1 done=0 aborted=0`。随后修改：

- pair 取消条件为 `abort || flush_request || flush_busy`，确保先退役 AXI/清理本地缓存，外层再执行协调复位；
- `start_ready` 和传入 pair 的 start_valid 均在 flush_request 同拍关闭，防止 flush_busy 尚未寄存时意外接受新事务。

新测试故意保持 hold_requests、不消费像素，在 FIFO=0/1 各验证五类场景：满缓存单独 flush、abort+flush、R 延迟期间 flush、单路 RRESP 错误后 flush、空闲时 START/flush 同拍。检查完成及 aborted 次数、flush 后错误清除和 ready 恢复、AR/R 数量闭合，并断言外层复位不得早于待返回 AXI 和 pair 退休。结果每种配置 `scenarios=5 ar=16 r=16`。

当前回归 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=22`，127 文件编译 errors=0、warnings=599。本次测试覆盖完整显示子系统，但没有把 SoC 的 APB/错误广播/多客户端仲裁器纳入故障注入环路；不能把组合测试改称完整 SoC 异常恢复签核。默认整系统正常单帧复测入口为 `display_recovery_base_20260910`，运行状态另行记录。

该正常单帧 xsim 现已通过：59.821 s，AW/W/B=852/868/852、AR/R=1119/2199，终止为 exit=0。见 [运行状态](D:/contest/2026FPGA/yilingsi/case1/logs/portable_soc_cache_ddr_bfm_runs/display_recovery_base_20260910/status.json)。此结果覆盖包含近期尺寸、pair 恢复和外层 flush 修改的当前默认正常路径；不是故障注入、native 算术或 15 fps 签核。运行使用 detached/breakaway worker，完整临时工程目录确认已删除。

## 追加：长 burst 恢复与 4 KB 边界验证

本轮未改生产 RTL，扩展 `tb_c1_display_outer_flush.sv` 的 AXI BFM：按 ARLEN 保存尚欠拍数、生成正确 RLAST，回压时保持响应，加入两路不同周期的返回间隔。完成检查从“AR 次数等于 R 拍数”（只适用于单拍）改为“所有已握手 AR 的 ARLEN+1 总和等于已接收 R 拍数”。对每个 AR 检查不跨 4 KB、最多 16 拍。

新增 WIDTH=128、BASE_SKEW=16，初始地址在 4 KB 边界前 16 字节，实际运行同时包含边界分段和长 burst。FIFO=0/1 各六类场景覆盖此前的 flush 合同，以及第 8 拍单路 SLVERR、已接收七拍后的中途取消。中途取消期间暂停后续响应生成 20 个 core 周期，检查不能提前 done/复位，恢复响应后才允许退役。没有撤回已呈现的 RVALID。

两种长 burst 配置各得到 `scenarios=6 ar=34 r=390 long=20 errors=1`。恢复后会继续启动后续场景，读事务计数必须闭合。BFM 数据为固定颜色，本测试证明协议排空与恢复顺序，不是长帧逐像素运算对照；现有 pair 短图恢复后 RGB 测试仍保留。

另外把已有 `tb_c1_r1_soc_control` 的 `C1_REGISTER_FATAL_TICKET` 配置纳入固定回归，覆盖直接/寄存两种错误广播控制策略。最新 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=25`。临时 VVP 自动删除，无波形；生产 RTL 未变化，未重复运行综合或正常路径 xsim。

剩余重点仍是完整 SoC 的故障注入、多客户端共享链路中的异常归属和重启，以及合法持续显示负载下的并发/性能验证。此处长 burst 通过不涵盖任意畸形 RLAST 或无限额外响应的恢复承诺。

## 追加：完整 SoC 显示错误注入及控制器修复

新增 runner 开关 `-DisplayFaultRecovery`。在原 portable SoC DDR BFM 内，首次 CNN DONE 后按被接受的 input-frame DDR 地址选中一个 burst，仅第一拍返回 SLVERR；RRESP 与 RDATA/RLAST 同步寄存，不在回压期间改变。使用真实共享 AXI、display reader、pair、控制器、APB、摄像头输入与 CNN engine，不强制内部 error 信号。该模式有独立错误/重启 scoreboard，不与 TwoFrame、SharedQosMonitor、TrainedArtifact、ClientTrafficGate 混用。

### 新发现与修复

1. 显示后台服务在单次 CNN DONE、run_armed 清零后仍运行，但 `c1_r1_soc_control` 原先用 `operation_enable = system_enable && run_armed_q` 资格化 display error，导致后台错误未报告。现改为 `system_enable && display_prefetch_error`，保留系统禁用时的边界。
2. 直接 fatal 路径对持续错误逐周期报告。新增报告去重寄存器：持续错误只报告一次、清除后可再报告；立即电平取消保持不变。寄存 fatal-ticket 配置保留已有的单次报告行为。

`tb_c1_r1_soc_control` 新增无前台 armed 的后台显示错误测试，持续错误保持 8 个周期，检查一次报告及 abort/flush 广播。修复中曾实测直接路径错误计数从 1 累积到 7；去重后直接/寄存两种配置均通过。全回归仍为 25 配置，最新编译 127 源文件 errors=0、warnings=599。

### SoC 运行证据与边界

- 首轮 `soc_display_fault_20260910` 因 TB 声明顺序未编译通过，修复后重跑，不计作功能证据。
- `soc_display_fault_v2_20260910` 未取得预期控制错误报告而失败。日志出现 display terminal，但没有 control error；后续单独控制器测试明确覆盖并确认了后台门控缺陷。保留该失败摘要。
- 修复后的 `soc_display_fault_v3_20260910`（DisplayResponseFifo + FabricReadResponseSkid + RegisterFatalTicket）通过，65.889 s，`injected=1 errors=1 done=2 descriptors=44`。日志显示错误 code=0x70/address=0x00100000，APB 验证错误码，再 W1C 确认错误 IRQ；错误详情寄存器按原合同保留，不假设 START 清零。所有活动 DDR/显示/flush 退役后，通过 APB 重新 START 并发送新摄像头帧，完成第二个 CNN 与正常显示。该配置不包含之后新增的 direct 分支去重逻辑，direct 配置另行验证。

完整 SoC 测试仍是 8×8 生命周期证据，不是模型逐像素 golden、native 15 fps、多错误优先级或任意畸形 AXI 恢复签核。后续还需验证其他客户端故障归属、持续合法显示并发及 native 数据面性能。

默认 direct 配置 `soc_display_fault_direct_20260910` 也通过（68.828 s），相同 `injected=1 errors=1 done=2 descriptors=44`，包含报告去重修复且未开启显示 FIFO/读 skid/fatal ticket。两种通过结果分别见 [direct 状态](D:/contest/2026FPGA/yilingsi/case1/logs/portable_soc_cache_ddr_bfm_runs/soc_display_fault_direct_20260910/status.json) 和 [ticket/FIFO/skid 状态](D:/contest/2026FPGA/yilingsi/case1/logs/portable_soc_cache_ddr_bfm_runs/soc_display_fault_v3_20260910/status.json)。本轮四个 xsim 运行的完整临时目录均确认已清理，仅保留小型状态与日志；启动均为 detached/breakaway。
