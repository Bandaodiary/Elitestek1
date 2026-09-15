# RAW 错帧后的真实 capture subsystem / AXI writer 排空

日期：2026-09-11。验证层级：实际 capture subsystem；不是整机所有权签核。

## 修复：坐标位宽未逐层透传

`c1_r1_capture_subsystem` 暴露 `X_BITS/Y_BITS`，但内部 frontend 使用按图像
尺寸推导的默认位宽。`c1_r1_portable_soc` 到 subsystem 也遗漏了
`CAMERA_X_BITS/CAMERA_Y_BITS` 的传递。本轮补齐这两级参数连接。

这不是仅有编译警告的问题。例如 6 像素宽输入本应在 x=0 时收到错误 x=8，
若外层接口是 4 位、内层默认 3 位，截断后就成为合法 x=0，硬件校验会漏报。
类似地，预期 y=5 时收到 y=13，截断后也可能被误判为正确。

修复前证据：新联合测试的 6 组 3 位坐标配置通过；随后第一组 4 位坐标配置
因等不到 RAW 错误而超时（`COORD_BITS=4, STALL=0, CAMERA_HALF=3`）。
补齐 subsystem 参数后，初始 12 组配置全部通过。随后补齐 portable SoC
连接，并扩充 X/Y 两种错误轴，纳入全量回归。

默认推导位宽的配置不改变；显式扩大坐标位宽时不再静默丢弃高位。

## 新测试的真实连接

`tb_c1_capture_raster_writer_drain.sv` 实例化实际 `c1_r1_capture_subsystem`，
包含摄像头异步 FIFO、RAW guard、完整 ISP、RGB FIFO 和真实 XRGB AXI writer。
表读取端口禁用，writer 地址直接配置；外部控制过程模拟错误后 cancel、等待
writer 排空，再允许下一帧开始的契约。

测试顺序：

1. 输入 6×7 RAW 仿射灰度图，暂停在 30 个已接受 token 后。
2. 等待真实 ISP 已产生首行、writer 已接受 RGB 并发出首笔单 beat AXI 写。
3. 分别保持 AW 不接受、W 不接受、B 不返回；前两种允许另一通道先接受。
4. 恢复 RAW 源，在第 31 个 token 注入 X 或 Y 高位错误，并预排下一完整帧。
5. 接到 0x05 后发出 writer cancel；继续阻塞总线 24 个 core 周期，要求
   writer busy 不下降、done 不出现、坏帧 ingress_done 不出现。
6. 释放总线，要求旧帧恰好完成一笔 AW/W/B 后退出取消，没有追加旧帧写事务。
7. 不复位 ISP、不重写 Gamma/标量配置，在不同目的地址启动下一帧。
8. 检查干净帧 5 笔写回的全部 20 个 XRGB 像素，灰度由输入解析公式独立计算。

AW/W 使用逐周期 ready/valid 稳定性检查器；其 cancel 固定为 0，不允许用
内部取消请求豁免 AXI VALID 或 payload 保持义务。检查地址顺序、AWLEN、
AWSIZE、AWBURST、WSTRB、WLAST、事务数量及恢复帧逐像素内存结果。

矩阵：2 种坐标位宽 × X/Y 两种错误轴 × AW/W/B 三类阻塞 × 两种摄像头
时钟（半周期 3/7 ns），共 **24 配置通过**。最终全量 Icarus **521 配置通过**，
进程退出码 0，上一轮全量基线为 497 配置。运行脚本
`case1/scripts/run_iverilog_review_fixes.ps1`；定向运行加
`-TestTop tb_c1_capture_raster_writer_drain`。未生成波形，临时镜像/向量自动清理。

## 证据边界与下一步

- 已覆盖真实 writer 接收部分 RGB 后的在途写取消，而非只在前端阻塞全部输出。
- 控制器是 testbench 中的契约模型，不是 portable SoC 的真实生命周期控制器；
  尚不能证明自动故障传播、帧缓冲占用记录、共享仲裁器和显示并发整体正确。
- 当前 writer 每行只有一个 AXI beat；长行、多 beat burst、共享 DDR 背压组合
  仍需在真实 SoC 层验证。其他 writer 单元测试不替代这项联合验证。
- 本轮仅模拟正确 B 响应；错误 B 响应叠加 RAW 错误未在此矩阵覆盖。
- `CHECK_RAW_RASTER` 继续默认关闭。下一步应将相同故障注入真实 SoC 控制路径，
  明确检查旧缓冲区在 B 返回前保持占用、恢复分配不覆盖仍在使用的帧。
- 本轮未运行 Vivado/Efinity 综合、时序分析或板测；没有新增资源或吞吐性能结论。
