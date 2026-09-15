# 三帧布局检查接入任务准入

日期：2026-09-11。本轮不再只验证独立检查器，而是把它串入真实 frontend
的帧表预检响应路径。

## 生产接线

`c1_r1_job_frontend` 新增默认关闭的 `CHECK_PREVIEW_LAYOUT` 和附加
`job_preview_base/stride` 输入，在 job 接受时锁存。原 pair resolver 先
读取/验证 input/output 表项；若它报错，仍直接返回原错误，不调用三帧检查。
若它成功，则保持原 response 不被消费，启动一次三帧检查：

- frame 0 为 resolved input；frame 1 为 resolved output；
- frame 2 为预览基址/stride 快照，宽高等于 resolved output；
- 仅当三帧结果有效，才向 job controller 提供最终 pair response，并同步
  消费原 resolver 和 checker 两个结果；
- pair_busy 包含检查器 busy，job abort/pair abort 与其待处理状态会取消
  本地检查；原有 AXI ARVALID 等待/排空路径不改。

错误通过现有 prerequisite failure 通道，在任何 input DMA/output DMA/
engine 启动前结束任务。新增错误码：0x31 几何/对齐，0x32 地址跨度越界，
0x33 三帧像素区域重叠；原 pair resolver 错误（包括原 input/output 重叠
0x30）保持不变。地址返回涉错帧基址，涉及预览的重叠返回预览基址快照。

`c1_r1_boardless_frame_system` 将 CHECK_PREVIEW_LAYOUT 绑定 ENABLE_PREVIEW，
传入原始 job_preview 输入供 frontend 同边沿锁存，不能传入延后一拍的
boardless 快照。默认预览关闭路径只直通原 pair response。

## 真实 boardless 七任务验证

`review_preview_layout_frontend_final_20260911`：

1. 正常预览帧；
2. preview 与 input 同基址，0x33，无运行时启动；
3. preview 与 output 同基址，0x33，无运行时启动；
4. preview stride=16，小于 8 像素行的 32 bytes，0x31；
5. preview base=0xFFFFFFF0，最终跨度越过 4 GiB，0x32；
6. 合法布局正在计算时取消，无运行时启动；
7. 不复位恢复正常帧，预览和处理后输出逐像素检查通过。

最终计数要求 7 accepted、2 done、4 error、1 aborted。除 CNN launch 和
AW/W 计数之外，直接监测 input_dma_start/output_dma_start/engine_start，
四个拒绝任务和检查中取消均不得增加启动计数；全部七任务共两次运行时
启动。原 config bank 可独立提交，布局失败不要求回滚该已验证缓存。

`review_preview_layout_bresp_20260911` 在新增预检后继续通过三任务预览 B
错误/恢复；`review_preview_layout_default_20260911` 默认九任务兼容通过。
中间布局运行 `review_preview_layout_frontend_20260911` 也通过，最终版本
进一步补齐所有运行时 start 脉冲的直接监测。

```powershell
& case1/scripts/run_r1_boardless_frame_system_xsim_detached.ps1 -RunId <unique-id> -Preview -PreviewLayout
```

PreviewLayout 要求 Preview，与 PreviewCancel/PreviewError 互斥；runner
要求唯一的布局覆盖标志，仍通过独立 WMI worker 脱离 Codex Windows Job。
测试 CNN 为 boardless 行为 loopback，不代表完整 22-stage CNN 的预览运行。

本轮全量 Icarus 146 配置通过；queued-write 整机编译 133 sources、0 errors、
608 条工具诊断，不宣称零警告。没有重跑完整 SoC golden 或综合。
四个 xsim 状态均 complete/exit=0，临时目录均不存在，精简日志合计
45601 bytes，约 44.5 KiB，无波形。

## 保护范围

现在启用预览的 boardless 任务已具备**本任务三个帧布局**的启动前互斥检查。
但没有检查其他仍被持有的采集/显示帧、tensor arena、参数或描述符区域。
静态预览 arena 边界仍由 writer 检查；它与三帧互斥是两种不同约束。
最外层 portable SoC 的预览 master/元数据/显示接线仍未完成，不能宣称全部
DDR 已隔离或板级系统已集成。预检延迟取决于行数，未给出新的物理时序/帧率结论。
