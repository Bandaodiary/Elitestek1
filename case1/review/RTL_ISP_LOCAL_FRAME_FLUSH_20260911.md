# ISP 局部帧状态清理

日期：2026-09-11。为 RAW 光栅校验器接入提供恢复边界，尚不等于整机重同步完成。

## 实现

`c1_r1_isp_pipeline.sv` 尾部增加默认关闭的参数 `ENABLE_FRAME_FLUSH=0` 和输入 `frame_flush`。只有显式启用时才响应此输入；旧实例保持默认配置时不依赖新增端口的值。

启用的局部 flush 形成 `pixel_rst`，清理 BLC、Debayer/window 和颜色流水线中的当前帧状态、valid/元数据，以及顶层 pipeline_busy 与仿真光栅跟踪状态。顶层 active 标量配置寄存器仍只受全局 rst/正常 cfg_commit 控制，局部 flush 不将它们恢复成默认值；Gamma RAM 原有不复位的行为保留。

flush 期间禁止 cfg_ready、gamma_cfg_ready 和 out_valid，配置提交/Gamma 写入不能利用清理窗口改变正在保留的配置。局部 flush 持续至少一个核心时钟沿，解除后源必须从一个新的合法 SOF 开始，不得继续发送已被丢弃帧的中段。

它只清理 ISP 内部状态，不触及相机异步 FIFO、捕获输出 FIFO、DDR writer、共享 AXI 或帧所有权。不能用它撤回已经被下游消费的数据。

## 定向验证

新增 `tb_c1_isp_frame_flush.sv`，6×5 输入、4×3 输出，flush 保持 1/4 周期两组均通过。

一次性配置非默认黑电平 16、单位 AWB/CCM，以及逆变 Gamma `255-(x>>2)`。分别发送 5、17、30 个 RAW token 后 flush，覆盖不完整前缀和完整输入后的流水残留。flush 同拍还呈现 in_valid、cfg_commit（试图将黑电平改成 0）和 Gamma 写入（试图破坏索引 240），确认所有这些请求被丢弃/拒绝。

解除 flush 后连续观察 16 周期无旧输出，pipeline_busy 为零、cfg_ready 有效；然后不重装配置/LUT、不全局复位地发送完整帧。RAW 256 经原黑电平和逆变 Gamma 的解析结果为 RGB `(195,195,195)`；逐像素验证 12 个输出以及坐标/SOF/EOL/EOF。每组完成三个恢复帧，证明该配置/LUT 在所测场景中保留且流水状态已清除。

## 尚未完成的接入工作

目前只有专用测试显式启用该功能，capture frontend 尚未实例化 RAW guard 或驱动此 flush。

接入时必须先锁存光栅错误并禁止坏帧发布，再清理捕获输出队列/通知 writer 取消；ISP 局部 flush 和 RAW FIFO 的丢弃/新 SOF 保留需要协调。即使 ISP 已 cfg_ready，也不能据此释放仍有 DDR 写事务的帧。源永久停流的硬件重同步政策仍未实现。

最终全量 Icarus **473 配置通过**，进程退出码 0，包括两组新 flush 测试和既有默认捕获/SoC 路径。旧 compute-ingress 偶发失败未重现，根因仍未知。本轮未执行 xsim、综合、板测或性能评估，不生成波形；回归脚本清理临时编译文件和向量。
