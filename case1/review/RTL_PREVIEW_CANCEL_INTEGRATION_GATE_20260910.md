# 预览支路取消验证与整机集成约束

日期：2026-09-10。

## 本轮结论

新增 `sim/tb_c1_r1_preview_dma_cancel.sv`，使用真实预览分流与 AXI writer，
验证共享 DDR 接入前必须满足的取消/背压约束。本轮没有修改生产 RTL，
没有将预览端口接入 SoC，也没有重新综合。

八个任务连续执行，中途不复位：

| 用例 | 核对结果 |
| --- | --- |
| 预检中取消 | 不接收源像素，不发出 AXI 写入 |
| 部分帧且 CNN 背压时取消 | 清除未提交数据，不产生 AW/W |
| AW/W 都被背压时取消 | VALID/载荷保持；取消后先接受 W、再接受 AW，最终等待 B |
| AW 已接受、W 被背压时取消 | W 保持有效，接受后等待 B |
| W 已接受、AW 被背压时取消 | AW 不撤回，接受后等待 B |
| 错误 B 响应且 CNN EOF 背压 | error 不能撤回 CNN token；父级 cancel 后终止 |
| 错误 SOF 且 CNN 背压 | 保持已呈现 token，停止源入口，cancel 后清除部分帧 |
| 最后正常任务 | 先前错误/取消不污染新任务，全部八个像素正确 |

AW、W 和 CNN 的背压稳定性检查跨拍执行；AXI 检查在 cancel 时不豁免，
CNN 的稳定性仅在明确 cancel 时允许清空。额外检查完整 XRGB 写载荷、
AW 地址/burst、WSTRB/WLAST、终态只出现一拍、取消后无流握手。

定向测试实际输出：

```text
C1_PREVIEW_DMA_CANCEL_PASS jobs=8 cancel=7 errors=2 restart=1 aw_stalls=55 w_stalls=27 cnn_stalls=47
C1_REVIEW_FIXES_REGRESSION_PASS configurations=1
```

随后完整 Icarus 回归输出 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=127`，
包含新增取消测试及原有模块/参数配置回归。没有重跑 xsim 或综合。
runner 不生成波形，测试镜像及生成向量由 finally 清理。

首次运行在错误 B 后取消的用例失败，原因是测试任务在 cancel 已经产生
done 的下降沿再次等待下一下降沿，漏采了一拍 aborted。检查器改为先检查
当前 done，再等待未来 done；未修改 DUT，也未放松终态值检查。

## 从当前源码确认的集成约束

`rtl/top/c1_r1_boardless_frame_system.sv` 当前直接将 Resize/compute shell
输出在 `dispatch_complete_q` 门控后送往 CNN；frontend 的 `engine_busy`
和 `engine_done` 分别直接连接 `compute_busy` / `compute_done`。
当前写端只有输出帧 writer，不能把新增 writer 的输出直接并接。

后续集成必须同时实现以下约束：

1. 保留 descriptor 完成屏障。CNN 支路无论经过何种分流，均不得在最后一个
   stage config 被接受前传输像素。
2. 原子启动。预览在已完成任务预检的启动边沿接受独立配置，不读取执行期间
   可变的 CSR。preview ready 参与启动准入，不允许 start 丢失后永久等待。
3. 联合完成。记录 compute 和 preview 各自终止事件，不能简单 AND 两个
   单拍 done。只有两个事件均已记录且两个单元均空闲，才向 frontend 报告
   联合 engine_done；新任务必须清除旧事件。
4. 联合 busy/error/cancel。预览 busy 必须纳入 engine busy；预览错误必须触发
   控制器的任务级取消，取消传给两个消费者及 writer，并等待 AXI 退休。
   空闲残留 sticky error 需按任务生命周期隔离，避免阻止下一次启动。
5. 不可只增加 busy。`c1_r1_job_controller` 在 STATE_RUN 观察 watchdog，
   成功终止事件齐全后进入 STATE_DRAIN，不再计时。若保留原 compute_done
   而只 OR preview_busy，可能提前进入成功排空阶段并丢失等待预览的超时监护。
   联合完成应延后到预览退休，让控制器保持 RUN；超时后仍须安全等待 AXI 排空。
6. 地址与所有权。为预览提供独立槽并完成范围/重叠校验；重新设计写端仲裁，
   锁定事务归属直至 B；显示选择必须一起切换地址、stride、几何和释放对象。

上述是明确的待实现事项，不是已完成的接线或整机验证。本轮测试不证明
多行/跨 4 KiB 预览、多主 DDR 公平性、真实 CNN 加预览整机或 15 fps。
