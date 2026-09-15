# 计算与预览的联合任务生命周期

日期：2026-09-10。

## 新增 RTL

`rtl/control/c1_r1_runtime_join.sv` 是同一时钟域的双参与者控制组合模块。
它为未来 boardless 中的 compute shell 与 preview DMA 提供原子启动和
联合终态，不包含 CNN 算术、存储配置、AXI 仲裁或跨时钟同步。

- 仅在两个参与者 ready 且均空闲时接受 START，并输出共同 child_start。
- 分别记忆两路 done，不要求两个单拍脉冲同时到达。
- 两路 done 均到达且两路 busy 均清除后，才向父控制器输出联合 done。
  done 在最终满足条件的周期组合输出，使控制器能够按既有规则处理
  完成与 watchdog 同拍的优先级；本轮测试未专项验证截止周期精确同拍。
- 第一条观察到的错误被保存；同拍首次错误左路优先。错误上报父控制器，
  由父控制器取消两个子单元，join 不自行复位或假造 DMA 完成。
- cancel 记忆到退休；取消后不再报告成功，即使之后收到了两路 done。
  等待两个 busy 清除后退出活动状态，允许无需复位重启。
- 空闲与启动采样边沿的旧 done/error 不作为新任务事件。子单元必须在
  child_start 清除旧终态，且在实际外部事务退休前持续保持 busy。

若只是把 preview_busy 并入 engine_busy，而 engine_done 仍直接使用
compute_done，父控制器可能在预览仍未结束时进入成功 STATE_DRAIN，
不再检查 watchdog。本模块延迟联合 done，令这种正常等待留在 STATE_RUN。
超时触发取消后，仍不能强行清除 AXI 所有权，必须继续等待已提交事务排空。

## 组合验证

新增 `sim/tb_c1_r1_preview_job_join.sv`，实际实例化：

```text
c1_r1_job_controller
    engine ready/start/busy/done/error/cancel
                 |
c1_r1_runtime_join
    |                         |
计算生命周期 BFM        c1_r1_preview_dma
                              |
                        AXI 写响应 BFM
```

预检、其余运行客户端以及计算完成/故障由行为模型提供；预览 fork/writer、
联合完成模块、任务控制器均为真实 RTL。这不是完整 CNN 或 SoC 验证。

连续七个无复位任务覆盖：计算先完成、预览先完成、预览迟迟不收到 B 时
watchdog 超时、显式取消、错误 B 响应、计算错误、正常恢复。每次任务
实际写出八个 XRGB 像素，共核对 56 个；CNN 输入也逐 token 核对。
每个 job terminal 必须满足两子单元不忙且对应 B 已经接受，并且只出现一次。
错误 code/address 分别核对 F0/64、63/0x1000、91/0xabc0。
其中 63 是测试连接选择的预览故障码，尚未扩展生产 SoC 的错误 ABI。

首个任务另加入 16 拍启动阻塞：先两路都不 ready，再只有计算 ready，
期间要求无启动、无像素接收、无 AXI 写；两路 ready 后共同启动恰好一次。

最终定向输出：

```text
C1_PREVIEW_JOB_JOIN_PASS jobs=7 success=3 error=3 abort=1 watchdog=1 late_B=5 no_reset=1 pixels=56 ready_barrier=16
C1_REVIEW_FIXES_REGRESSION_PASS configurations=1
```

完整 Icarus 回归输出 `C1_REVIEW_FIXES_REGRESSION_PASS configurations=128`。
全量启动后补充了启动 ready 屏障检查，最终版定向重测通过；生产 RTL
在这两次测试之间没有变化。runner 无波形，临时镜像/生成向量已清理。

完整 SoC 编译/展开检查为 131 个源文件，0 errors、603 条工具诊断。
新 join 尚未实例化进 SoC，故该编译结果只支持现有 SoC 的编译兼容性。
本轮没有运行 xsim、Efinity 综合、PNR 或板测。

## 未完成的实际接线

`c1_r1_boardless_frame_system` 当前仍直接连接 compute_busy/compute_done。
本模块仅在上述组合测试中连接，尚未替换生产路径。之后需一起处理：

1. 第三个帧槽的独立配置、完整范围/重叠预检、任务启动快照及所有权。
2. 保持 descriptor 屏障，将 Resize C8 接入 fork，再连接 CNN。
3. 在生产 frontend 的 engine 端接入联合 ready/busy/done/error，错误码与
   当前 SoC fault ABI 一致；共同 cancel 传给两个实际子单元。
4. 为输出 writer 与预览 writer 实现共享 AXI 写仲裁，锁定响应归属直到 B。
5. 显示端原子选择预览地址/stride/几何，并在整机 golden 回归中核对。

不能将本轮结果表述为整机预览完成、15 fps 达成或板级可实现性签核。
