# Boardless 真实预览路径接入

日期：2026-09-11。本轮将预览从独立基础模块接入真实
`c1_r1_boardless_frame_system`，尚未扩展最外层 portable SoC 的共享写 fabric。

## 实现

新增默认关闭的 `ENABLE_PREVIEW`，以及 `PREVIEW_REGION_BEGIN/END`。
接口追加 `job_preview_base/stride` 和独立 AXI128 预览写口。预览配置在
job_start_valid/ready 握手时锁存，尺寸使用预检解析出的目标帧尺寸。

启用路径实例化 `c1_r1_preview_runtime`：

- compute shell 的 Resize C8 输出，在描述符 dispatch_complete 屏障之后
  进入 preview runtime，CNN 从 fork 分支取得数据；ready 也经过原屏障；
- compute_start_ready 与 dispatcher_start_ready 共同作为启动许可，并与
  真实 preview_ready 联合准入。compute_launch 与 dispatcher 的 engine_start
  属于同一启动边沿，不允许只启动其中一方；
- frontend 的 engine_busy/done/error/code/address 改为联合接口，不能仅
  根据 compute shell 完成而结束任务；
- compute_abort 同时取消 compute shell 与 preview runtime，父级已有
  input/output DMA 和 descriptor 的取消控制保留；
- 默认关闭时直接恢复原数据/控制连接，额外预览输出固定为零，不依赖
  未连接的预览响应输入。原直接实例接口应继续采用命名端口。

预览范围 preflight 在 preview writer 中，**不是**完整三类缓冲互斥检查。
启用者必须提供互不重叠的安全地址；不要把默认全地址区间理解为已隔离。

## 真实 boardless 验证

扩展现有 `tb_c1_r1_boardless_frame_system` 与 detached runner。启用预览时
运行正常第一任务：真实 descriptor/table preflight、输入 DMA、Resize/
compute shell、输出 DMA 和新 preview runtime。外部 CNN 仍为原 testbench
行为模型，不是 22-stage MicroStyle 数值计算。

8×3 输入/输出，24 像素：预览区域 `[0x6000,0x6060)`，3 笔 AW、6 个
128-bit W beat、3 个 B。独立按像素公式检查完整 XRGB 值、AW 地址和属性、
WSTRB/WLAST；原处理后输出的 verify_output_frame 同时通过。
最后一个预览 B 延迟 **64 cycles**，期间必须保持 job busy、不得 job_done。
job 接受后立即将实时基址/stride 改坏，实际预览仍按任务快照写入。

启用的最终运行：`review_preview_boardless_final_20260911`。
此前同样成功的 `review_preview_boardless_r3_20260911`：

`C1_BOARDLESS_PREVIEW_PASS pixels=24 aw=3 w=6 b=3 final_B_hold=64 snapshot=1`

默认关闭运行 `review_preview_boardless_default_r3_20260911` 完成原九任务：
2 success、5 error、2 aborted，7 launches，110 stages，5 dispatches，
包括原 DMA 错误/取消/恢复测试。启用路径目前只完成正常帧测试，不能把
默认路径的错误矩阵宣称为启用预览后的整机覆盖。

本轮重新执行全量 Icarus：**145 配置全部通过**；queued-write 整机编译
132 sources、0 errors、608 条工具诊断，非零警告。完整 portable SoC
未启用预览，也未进行新 Efinity 资源/时序或 15 fps 验证。

## 复现与清理

```powershell
& case1/scripts/run_r1_boardless_frame_system_xsim_detached.ps1 -RunId <unique-id> -Preview
# 去掉 -Preview 重跑默认九任务。
```

worker 经 WMI 创建，脱离 Codex Windows Job。启用 runner 除通用 PASS 外
还要求唯一的预览专属覆盖标志。两轮各两次早期运行因新增 testbench 行为块
位于信号声明前而编译失败；移到声明后解决，四次失败不计入成功。

检查发现旧 runner 没有 finally 清理，本轮已补上 RunId 检查、精确目标路径
校验和终态自动清理。本轮前六个终态临时目录已逐一验证并删除，合计
3183111 bytes；精简日志保留，临时工程可通过 runner 重新生成。无用户数据删除。
最后一次预览运行也已 complete/exit=0，确认新增 finally 自动删除其临时目录。

## 未完成的实际接入

- 在启用预览的 boardless 路径上验证取消、错误、晚 B 后恢复及配置越界。
- 补足 preview 与 input/output/tensor/parameter 的地址互斥预检。
- portable SoC 追加预览 master，参数/元数据来自绑定 output-slot 的配置；
  共享 fabric/QoS、busy/error 及再启动排空屏障都要覆盖该 master。
- pending/display pair 增加预览元数据与选择，并在旧显示读流量排空后换帧。
- 完整 SoC 比较 raw/preview/styled golden，跨输出槽与帧验证。
