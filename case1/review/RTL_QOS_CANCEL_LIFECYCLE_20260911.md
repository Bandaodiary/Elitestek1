# QoS 取消计时与失败终止过滤

日期：2026-09-11。范围：观察用 QoS 的任务生命周期，不改变 AXI 取消/排空与帧槽所有权。

## 检查结论与复现

显示请求在 flush 时由显示子系统拉低 ready；配对读端处理已接收任务的取消。未发现必须在控制器任意撤回已保持 valid 的证据，本轮不修改该握手契约。

发现并复现两处计量缺陷：

1. QoS 只有 start/done，没有取消入口。任务取消后 `frame_active` 继续为 1，下一次合法 start 会命中重入诊断。新增测试在尚未实现取消语义时失败：`canceled frame timer remains active or altered completed statistics`。
2. `display_prefetch_new_done_event` 只检查 done 与 new 标签，没有排除错误/取消。读端的 done 也用于失败终止，可能被当成成功完成；寄存故障广播时尤其不能等待下一拍取消来纠正已经增加的统计。新增 done/error 同拍测试失败：`failed committed-frame terminal counted as successful completion`。

## 实现

- `c1_axi_shared_qos_monitor` 尾部新增同步输入 `frame_abort`，优先于 start/done，仅清活动帧计时及本帧回绕记录。
- 不增加 completed frame 或 deadline miss，不清历史计数、最后成功帧时长及全局诊断；AXI 握手/等待/排空统计继续更新。
- 取消同拍的 start/done 不产生重入或孤立终止诊断。总线自身的协议诊断不被取消屏蔽。
- `c1_r1_portable_soc` 将该输入连接到控制器共享生命周期广播 `boardless_abort`，包含计算后的显示故障，不使用全局统计清零替代取消。
- `c1_r1_soc_control` 的新帧完成事件增加 aborted、error、manager_abort、raw fatal 四项否决，原始故障不等待寄存广播。
- 已更新仓库内已知实例；不需要取消功能的实例显式接 0。外部自行实例化监测器的工程必须连接新增输入，不能悬空。

计时取消不是内存事务取消：它不控制 VALID/READY，不释放 AXI owner，不替代软件 BUSY 的实际排空判据。未新增取消帧数 CSR。

## 验证

监测器定向覆盖：取消活动帧、保持取消 4 拍、3 拍 start/done 碰撞、无复位重新启动、历史统计保持；取消边沿接受一笔 AW 并确认计数增加。原有 7 项计时回绕边界也通过。

控制器测试接入真实 QoS 实例（不是行为计数器），连接方式与 portable SoC 一致。提交前/后、原图/预览、直接/寄存广播、软件取消/显示错误共 16 个双任务场景检查：第一帧成功后第二帧取消，完成帧数仍为 1、active=0、protocol_error=0。总计 26 组控制器配置通过。错误场景还注入 done/error 同拍并检查新帧成功事件不产生。

133 源文件 queued-write 顶层编译通过，0 errors / 608 工具诊断。全量 186 配置通过，最终标记 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=186`，退出码 0；控制器后来增加真实 QoS 实例的最终版本另行完成上述 26 组定向复验。全量回归的唯一 VVP 和向量目录已清理并检查不存在。

独立 xsim：`review_cancel_qos_lifecycle_20260911`，预览显示、寄存故障广播、提交后 done/error 碰撞，complete / exit 0，8.232 s。实际日志同时包含 `C1_SOC_CANCEL_QOS_PASS ... completed=1 active=0 protocol_errors=0` 与对应故障场景标记。WMI 独立启动，Vivado 不绑定 Codex Windows Job；仿真目录完成后检查不存在。

## 仍未完成

本轮控制联动中的读写客户端为行为模型，总线统计另由监测器测试验证。尚未将不同内容双成功帧、真实 CNN/DDR/最终显示的逐像素 golden 全部闭合。目标尺寸吞吐、物理资源与时序也未因本轮计量修复而得到证明。
