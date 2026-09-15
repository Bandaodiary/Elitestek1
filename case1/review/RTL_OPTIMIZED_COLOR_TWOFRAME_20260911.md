# 优化组合的正常彩色双帧基线

Run `optimized_color_twoframe_20260911`，独立 worker 22012；开启训练
工件、彩色双帧 trace、tensor burst refill、queued writes、注册 fatal
ticket、DW cache、MAC overlap、结果写流水化、packing 与 end-marker。
最终 complete/done、exit_code=0，实际 engine 两项计算优化均为 1。

## 数值及复用验证

两帧输入亮度不同，R/G/B 平面有不同偏置。独立 checker 要求 color 和
video，并运行 self-test：

- 两帧 128 输入、1672 C8 结果、128 DDR 像素匹配。
- 两帧视频原图 128/处理图 128 像素匹配。
- 39 个检查器负测试通过。
- 两任务 elapsed=49949/49924 核心周期，逻辑读/写均为 3620/836。
- 临时工程目录已确认清理。

此场景没有此前的并发采集和 RAW timeout 恢复激励，不可把 49949 与
恢复场景的 65670 直接作加速对比；不同任务的视频等待也不包含在相同
计算周期统计内。本轮未修改生产 RTL 或默认参数。

## 读通路结构检查

当前 tensor adapter 的 ST_READ_REQ 接纳后进入 ST_READ_RSP，收到一个
C8 返回值后才推进 tap；外层 burst cache client 也以单 owner 管理
逻辑 tap。refill scheduler 的 outstanding 是下层整行补充工作，不能
等同于上层并行 tap 请求。仅扩大 AXI 队列不会自动改变这一结构。

若优化为并行 tap，至少要定义每个请求的 tap/group/像素归属、响应次序、
窗口完整性、跨 stage fence 和取消排空，且修改 adapter 与缓存入口两层。
本次正常双帧数值基线可用于后续读调度变更回归，但未完成该架构改造。
原生分辨率吞吐、目标器件资源/时序和实际板卡仍未由此证明。
