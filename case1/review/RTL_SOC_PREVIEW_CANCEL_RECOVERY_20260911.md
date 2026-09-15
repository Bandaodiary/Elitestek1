# 预览软件取消后的无复位完整恢复

## 修改范围

runner 新增 `-PreviewCancelRecovery`，必须同时启用 `-PreviewCancel`。
沿用真实八客户端 SoC、训练好的 22-stage CNN、彩色 RAW10 12×10 → 8×8
Resize、预览 writer 和 tensor burst refill，不修改生产 RTL。

首任务的最后预览 B 被阻塞，APB ABORT 后连续 64 cycles 检查忙状态、
阻止槽授权/新 START，以及不得提前报告取消。释放 B 后确认恰好一次
取消、全部事务排空、控制器 disarmed，再发一个新的 START。
被拒绝的旧 START 不会替代这次显式新启动。

重新启动前只清除 testbench 的每帧像素计数和字节写覆盖图，恢复下一
任务的几何 CSR；不复位 DUT、不擦除 DDR、不清除总线累计计数或取消
计数。首任务不完整的 CNN 数值不混入成功帧轨迹，取消协议证据单独保留。

恢复帧沿用原有完整 CNN、预览/处理图物理 DDR、原图/处理图显示 golden。
最终必须 aborted=1 / errors=0 / done=1 / captures=2。

## 独立证据要求

Python 新增 `--require-preview-cancel-recovery`：严格要求唯一且有序的
取消阶段和恢复阶段标记，并强制启用预览像素 golden。新增八种内存中
日志变异：删除/重复恢复标记、使用复位、有额外错误、缺少排空记录、
允许提前 START、缺少 64-cycle 阻塞、颠倒阶段顺序。

日志压缩逐行保留 `C1_SOC_PREVIEW_CANCEL_`，保留顺序和重复以供检查，
不会因只保留末尾日志而丢掉取消阶段证据。

## 运行配置

- `review_soc_preview_cancel_recovery_20260911`：queued W-ahead，registered
  fault ticket；真实 APB 软件取消保持立即生效。
- `review_soc_preview_cancel_recovery_serial_20260911`：串行 W，direct ticket。

W-ahead 运行 complete / exit 0，104.247 s。恢复阶段 64 个 CNN 输入、22 层
836 个 C8 结果、64 个预览 DDR 像素、64 个处理图 DDR 像素、120/64 个
原图/处理图显示像素均通过独立 Python golden。共享总线累计 943 AW /
1007 W / 943 B，峰值 outstanding=2、W-ahead=16。检查器 56 项负向验证
通过。既有 BRESP 恢复日志的 56 项检查也通过，未破坏其兼容性。

上述时间是仿真进程墙钟时间，不是硬件帧周期；两进程存在并发运行，
不能据此比较两种配置的吞吐。

串行配置同样 complete / exit 0，103.209 s，全部上述 golden 项目通过。
其 AW/W/B 累计同为 943/1007/943，峰值 outstanding=2，W-ahead=0。
首次负向检查发现删除串行模式标记仍可能被接受；检查器现要求取消恢复
日志明确给出模式，并在所有带 queued 证据的串行模式中要求 W-ahead=0。
修复后 W-ahead/串行两组分别通过 56/58 项负向变异；新增反例包括串行
模式伪报非零 W-ahead。没有放松检查或改写原仿真日志。

本轮未修改生产 RTL、未重跑全量 158 配置。两项 xsim 仍通过 WMI 脱离
Windows Job 运行，无波形；临时目录均已自动清理，仅保留小日志。

检查命令：

```powershell
& <python.exe> case1/golden/check_portable_soc_numerical_trace.py <run-log-directory> `
  --require-preview-cancel-recovery --require-video --require-queued-write
```

## 尚未完成

此场景是一帧取消后另一帧成功，不能称为两个输出槽连续成功。后者以及
预览显示元数据/显示源切换仍需继续。小图成功也不证明原生分辨率 15 fps。
