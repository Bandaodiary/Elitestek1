# 控制器层的预览显示元数据路径

## 实现

`c1_r1_soc_control` 新增默认关闭的 `DISPLAY_RESIZED_PREVIEW`，以及
`boardless_resolved_preview_base/stride` 两个输入。当开关打开，成功任务
的“原图显示支路”元数据改为预览地址/stride，宽高取该任务处理后尺寸；
风格化支路不变。这里“original”是既有显示接口名称，并非仍读取摄像头原图。

选择发生在已有 boardless_done 成功发布边沿，沿用同一条状态路径：

```
完成任务的预览/处理图配置
  → pending pair 快照
  → prefetch request 快照（支持背压）
  → 成功换帧后 current pair 快照
  → 取消后仍可重复显示已提交的旧帧
```

不增加独立的预览发布状态机，不改变原有 frame manager 的所有权或读排空
门槛。boardless_done 的取消/错误否决保持原有优先级。输入拍摄尺寸、
frame-table 查询和 Resize 参数均不因此改成显示尺寸。

调用者契约：两个新增输入必须来自该完成任务的配置快照，预览与处理图
必须属于同一输出槽生命周期，且 boardless_done 必须等待预览末 B 退休。
不能接到可任意修改的下一任务 CSR，也不能从 display index 反推运行任务。

## 测试

`tb_c1_r1_soc_control.PREVIEW_DISPLAY=1` 使用故意不同的配置：

| 项目 | 输入原图 | 预览显示支路 | 处理图显示支路 |
| --- | --- | --- | --- |
| 基址 | 0x00100000 | 0x00300000 | 0x00200000 |
| stride | 4096 | 4096 | 2560 |
| 尺寸 | 960×720 | 640×480 | 640×480 |

完成后把原图、预览、处理图输入地址/stride/尺寸改成错误值，要求 pending、
五周期 stalled request、当前帧及取消后的重复预取都继续使用完成时快照。
原输入几何与 Resize 的既有快照/非法配置测试继续通过。

direct/registered fatal ticket 两种新增配置均通过；连同原图默认模式共
六个控制器测试配置通过，包含已有 ABORT/DONE、fatal/DONE 优先级、
显示错误恢复和 fabric 协议锁定检查。

## 边界

本轮已接入控制器内部的显示元数据选择，并由 boardless 新增输出
`resolved_preview_base/stride` 导出任务准入时的快照（预览关闭时输出零）。
最外层 `c1_r1_portable_soc` 已将这两个输出传给控制器，但尚未公开启用
预览显示选择，当前整机仍显示原图/处理图。
因此不能宣称已完成“预览/风格图”视频输出，也没有新增相关视频 golden。
下一步须公开并约束 top 的显示选择，更新显示参考模型并
运行真实 SoC 视频验证。连续两槽成功仍需独立验证。

最终接线后的 SoC 八组 smoke/故障锁定配置通过；133 源文件 queued-write
编译通过，0 errors / 608 工具诊断。boardless xsim 首次运行
`review_preview_metadata_export_20260911` 在 xelab 因测试台 `.*` 缺少新信号
声明而失败；补齐声明后 `review_preview_metadata_export_final_20260911`
九任务通过，公开快照严格保持 0x6000/32，即使实时输入已被故意篡改。
两次临时目录均自动清理，xsim 继续运行于 Windows Job 外。

全量 Icarus 160 配置通过；随后新增的快照输出接线另以最终 SoC 八组
smoke、133 源编译和上述 boardless xsim 核对。本轮没有运行预览作为
显示源的真实 SoC 视频 golden，不能用控制器行为测试替代它。
