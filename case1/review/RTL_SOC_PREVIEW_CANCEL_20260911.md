# 八客户端预览末 B 阻塞下的软件取消

## 本轮实现

新增 runner 开关 `-PreviewCancel`，要求启用 `-PreviewCapture`，与预览
SLVERR 注入和并发第二次 capture 互斥。使用真实训练参数、CNN、Resize、
预览 writer、tensor burst refill 和共享 queued-write AXI，不强制修改
DUT 内部信号。生产 RTL 本轮未修改。

BFM 只阻塞预览槽 0 最后一行 AW=0x010000e0 对应的 B，且是在呈现 BVALID
之前暂停，不撤回已经呈现的响应。实际到达 8 AW / 16 W / 7 B 后：

1. 通过 APB 写 ABORT；待已产生的控制信号传播后发送新的 START。
2. 要求 START 通过正常 APB 拒绝路径返回，不把它暂存成排空后自动重启。
3. 连续 64 cycles 检查 system/boardless/fabric busy 保持，AW/B 计数不变，
   没有 capture/NN 新授权，没有 job_aborted、done、error 或显示 swap。
4. 释放最后 B，等待所有读写和任务忙状态退出，再观察 64 cycles。
5. 必须恰好一次 boardless aborted、零错误/成功/swap，全部 AW 对应 B，
   预览 B=8，且控制器保持 disarmed、不自动重新采集、无协议损坏锁定。

## 验证

`review_soc_preview_cancel_20260911`：complete / exit 0，13.359 s。
配置为八客户端、queued W-ahead、REGISTER_FATAL_TICKET=1。

关键证据：

```
C1_SOC_PREVIEW_CANCEL_PASS clients=8 held_cycles=64 preview_aw=8 preview_w=16 preview_b=8 aborted=1 errors=0 done=0 swaps=0 start_rejected=1 drained=1 reset=0
```

兼容对照运行：`review_soc_preview_cancel_serial_20260911`，串行写数据、
REGISTER_FATAL_TICKET 默认 0，其余保持上述实际计算/内存路径。

该对照也 complete / exit 0，13.326 s，同样通过最后 B 阻塞、START 拒绝、
唯一取消和零发布检查。runner 原先把 SerializeWriteData 限制在并发 capture
模式，首次命令因此在启动前被拒绝；现只增加 PreviewCancel 这个已验证
组合，原 inflight-abort 互斥约束保持不变。

## 范围

取消任务故意不完成 CNN，不能套用成功帧 golden；本轮验证的是取消/排空/
禁止重新分配协议，没有重跑全量 158 配置。前一轮的 SLVERR 无复位重算
不能代替“软件取消后重新启动完整任务”的独立证据。后续仍需补这项、
连续双槽成功，以及预览显示元数据/显示源切换。

xsim 继续由 WMI 脱离 Windows Job 启动，无波形，临时仿真目录自动清理，
只保留小型状态及诊断日志。
