# 三帧布局预检 RTL

日期：2026-09-11。新增 `rtl/control/c1_frame_triple_layout_check.sv`，为
input/processed/preview 地址互斥提供可综合检查器，尚未接入任务准入。

## 接口和约束

单时钟域 req_valid/ready 接收三组 base/stride/width/height 并锁存；布局
在工作期间改变不影响本次检查。rsp_valid/ready 返回结果并保持至接收。
busy 表示正在计算，未消费的结果仍通过 req_ready 阻止新请求；父级不要
仅根据 busy=0 判断可重新提交。cancel 只丢弃本模块本地检查/结果，无 AXI
事务；不能借此复位或释放外部 DMA 所有权。

XRGB 限制与当前帧读写路径匹配：宽高非零、宽度为四像素整数倍、基址和
stride 按 16-byte 对齐、stride 不小于 width×4。base 输入为 32-bit；
来自 64-bit 表项的高位必须先由上游 resolver 验证，不得截断后假装合法。

错误码：1=几何/对齐非法，2=最终地址越界，3=实际像素区间重叠。
前两种的 error_index 是 frame 0/1/2；重叠时为 pair 0=(0,1)、1=(0,2)、
2=(1,2)。成功 code/index 均为零。按帧顺序检查基本条件/跨度，再按配对
顺序检查重叠；只返回优先遇到的一项，不是并行错误位图。

## 算法与可移植性

对每帧使用 16 次移位加法计算 `base+(height-1)*stride+width*4`，用 49-bit
累加保存进位；exclusive end 可以等于 2^32，但不能超过。生产 RTL 不使用
乘法运算符。尚无综合资源证据，不直接宣称实际 DSP 数为零或某个 Fmax。

验证跨度后，三个帧对分别合并两份按地址递增的行区间列表：若交叠则拒绝，
否则推进在前的一行，耗尽任一列表即该对无重叠。比较端点用 33-bit。
这是实际像素范围检查，允许共享 padding；没有将整帧包围区间相交误判为
像素重叠。每对最多约 height_a+height_b-1 次扫描，超大高度时预检不恒时；
未来父级 watchdog/取消协议应把这段时延算入预算。

初次 Icarus 编译暴露动态 packed-array 索引后再位选的工具限制，已改为
先选出标量 base/stride/width 再位选，避免这一兼容性问题。

## 验证

新增 `tb_c1_frame_triple_layout_check.sv`：

- 13 次定向结果核对：三个配对冲突、非法宽度/stride/对齐、恰好到 4 GiB、
  32-bit 越界、最大高度/stride 的宽位溢出、padding 交错共享、跨行冲突和恢复。
- 每个请求后改坏全部输入布局，验证快照；每个结果停顿 8 cycles 检查稳定。
- 计算中取消，随后 70 cycles 不得泄漏旧结果，再完成正常请求。
- 200 组固定种子的随机小布局，用独立的行对双重枚举算法作为参考，而非
  重用 RTL 的合并扫描算法；27 合法、173 重叠，所有错误码/索引一致。

最终输出：

`C1_FRAME_LAYOUT_ORACLE_PASS legal=27 overlap=173`

`C1_FRAME_TRIPLE_LAYOUT_PASS checks=213 randomized=200 pairs=3 padding_shared=1 end_4GiB=1 overflow_wide=1 snapshot=1 stall=8 cancel_restart=1`

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_frame_triple_layout_check -Python <python.exe>
```

新配置加入全量 runner，本轮只执行新增配置；未重跑全部旧配置。
queued-write 整机编译 133 sources、0 errors、608 条诊断；新检查器尚未
在 SoC 实例化，所以该整机编译不等于新模块综合/整机保护证明。
没有 Vivado/波形；Icarus 临时编译文件及生成向量由 runner 清理。

## 后续接入不能省略的工作

必须在 input/output 表项解析与布局快照完成后调用，并在成功之前禁止
DMA/compute/preview 运行时启动；失败走明确的任务 preflight 错误响应，
取消则撤销本地检查并遵守现有总线排空边界。还需对 tensor、参数、描述符
等其他活动区域及其他仍被占有的帧做隔离；三帧互斥不覆盖全部 DDR 地址空间。
当前 boardless/portable SoC 不会因新增文件而自动获得这些保护。
