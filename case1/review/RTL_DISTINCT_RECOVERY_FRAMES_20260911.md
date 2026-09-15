# 不同图像内容的无复位恢复验证

## 补齐的缺口

此前恢复前后使用同一颜色图案。即使已经要求恢复帧有新的物理写 strobe，
相同内容仍不足以直接暴露旧像素被重新使用的问题。

新增 runner 开关 `-DistinctRecoveryFrame`，只允许与彩色预览取消恢复或
BRESP 恢复组合。首任务保持原 RAW10 图案；恢复任务调用真实摄像头源时
增加 tone_offset=32。该偏移实际进入 camera_raw10，而不只是更改标签。
在当前无裁剪的线性 CFA fixture 下，对应 ISP/Resize RGB 每色道增加 8；
CNN 输出仍须重新运行完整整数模型，不能简单假设输出也只增加 8。

不复位 DUT、不擦除 DDR。已有恢复阶段写覆盖图清零、新写入要求、取消/
故障计数以及有序阶段证据继续保留。生产 RTL 本轮未修改。

## 参考模型与反例

日志新增唯一 `C1_NUM_SOURCE_TONE 32`，明确成功恢复帧的输入图案。
Python 从独立 RAW10/ISP/Resize 公式重建新参考图，再计算完整 CNN。
`--require-distinct-recovery` 禁止省略该证据；tone 标记非法/重复或没有
成功恢复记录时拒绝，旧无标记运行仍表示 tone=0。

新增六种负向变异：删除、重复、篡改 tone；将 CNN 输入、预览 DDR、
实际显示像素分别替换成前一帧对应值。变异只在内存中完成。
既有“预览显示误用原图”反例也使用新 tone 重算，避免混淆两个错误原因。

## 运行

- `review_preview_distinct_cancel_20260911`：首任务软件取消，第二幅不同
  图像成功计算、预览写回及预览/风格图显示。
- `review_preview_distinct_fault_20260911`：首任务末 B 返回 SLVERR，第二幅
  不同图像完成同样的数据路径。

两组都使用八客户端 queued W-ahead、registered fatal ticket、真实训练
参数、12×10 → 8×8 Resize 和 tensor burst refill。

两组均 complete / exit 0，并在强制要求 distinct recovery、对应恢复协议、
preview display、完整视频及 queued retirement 时通过独立 golden。
每组核对 64 个输入、22 层 836 个 C8 结果、64 个预览 DDR 像素、64 个
风格图 DDR 像素，以及实际显示的 64+64 个像素。每组 66 项负向检查
通过，包含上述六项不同图像/旧像素替换反例；旧 tone=0 日志的 60 项
兼容检查也通过。

两组均累计 943 AW / 1007 W / 943 B，峰值 outstanding=2、W-ahead=16。
墙钟时间为 108.301/109.258 s（并发仿真，不是硬件帧周期）。xsim 继续
由 WMI 在 Windows Job 外启动，无波形，两项临时仿真目录均已自动清理。
本轮未修改生产 RTL，也未重跑全量 162 配置。

## 边界

此测试仍是一帧未发布、下一帧成功，尚不是两个成功帧的连续双槽换帧。
对先前已成功显示的旧帧保留、换帧期间读排空与跨槽错配，仍需后续整机
验证。本轮不重新测量 Efinity 资源/时序，也不推断原生帧率。
