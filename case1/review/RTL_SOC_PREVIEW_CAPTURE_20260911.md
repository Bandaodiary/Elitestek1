# Portable SoC 第八客户端：Resize 预览写回

## 实现范围

`c1_r1_portable_soc.ENABLE_PREVIEW_CAPTURE` 默认 0，保持原七客户端构建。
打开后 AXI_CLIENTS=8，client 7 为 boardless preview runtime 的写通道；
读通道固定空闲。沿用同一共享 AXI 仲裁器、queued-write 协议锁定与 QoS
监视器，预览 B 错误经 boardless/frontend 进入现有任务错误路径。

现有 boardless 联合退休已经等待计算和预览写回完成。因此控制器在发布
processed 帧之前也等待预览末 B；不新增一个可能提前发布的预览完成脉冲。
最外层显示仍读取原图/处理图，本轮不改变显示源选择或 APB ABI。

## 静态双槽配置

- `PREVIEW_BUFFER0_BASE/1_BASE`：独立地址，槽索引绑定 processed 输出索引。
- 固定预览 stride 为 `FRAME_WIDTH*4`，每槽预留 `FRAME_WIDTH*FRAME_HEIGHT*4`
  字节，实际输出宽高不得超过这个容量。固定 stride 不随 APB 目标宽度变化。
- `PREVIEW_REGION_BEGIN/END`：两个槽都必须完整位于此分区。
- 两槽重叠、基址非 16-byte 对齐、分区非法、超地址空间、输出索引越界等
  会给 frontend 提供非法 stride=0，在启动任何运行时 DMA 前拒绝。
  常量槽容量与区间运算不增加运行时乘法器；物理映射尚未测量。
- 两个基址默认同为 0；若只打开开关而未配置独立槽，会拒绝任务而非覆盖内存。

集成方仍须保证整个预览分区与 tensor、权重、描述符、其他活动输入/输出槽
分离。本任务三帧相交检查不能代替完整的系统内存分配规划。

## 验证方法与过程

Icarus smoke 新增五种八客户端配置：合法、双槽重叠、低于分区、超出地址
空间、基址不对齐；检查常量保护结果与非法 stride。各配置同时运行已有的
orphan-B 协议错误测试，验证锁定、新准入禁止与复位恢复。此项为结构/故障
验证，不等同于每个非法配置都运行完整的 CNN 任务。

真实 SoC BFM 使用训练好的 22-stage MicroStyle，彩色 RAW10 12×10 输入，
Resize 到 8×8；同时启用 queued writes、并发 capture、tensor burst refill
和 refill request handoff。专门检查第八通道 AW/W/B、CNN 输入像素，以及
物理 DDR 预览像素、所有字节写 strobe 和任务完成前 B 已退休。

两个早期测试失败已修正测试代码：

1. `review_soc_preview_capture_20260911`：终态检查误放在组合块，零时刻
   对空计数器断言失败。移至主测试末尾，未放松计数约束。
2. `review_soc_preview_capture_final_20260911`：以最近接收任务基址检查
   已完成帧，遇到下一槽任务准入后查错地址。改为在 boardless_done 保存
   完成任务的基址，同时强化槽索引一致性和物理字节写入检查。

最终复验运行：`review_soc_preview_capture_retired_20260911`。

结果：complete / exit 0，82.054 s。日志证明依次准入 slot 0 和 slot 1，
实际完成并核对的是 slot 0（0x01000000）；slot 1 仅准入，不算第二帧完成。
64 个预览像素逐一匹配 CNN 入口恢复的 RGB，所有 256 字节都有物理写 strobe；
预览 AW=8 / W=16 / B=8，boardless_done 前已全部退休。

Python golden 核对通过：64 个输入、22 层 836 个 C8 结果、64 个处理图 DDR
像素、120 个原图显示像素与 64 个处理图显示像素；已有 golden 检查器的
负向测试也通过。预览由 SV DDR 记分板核对，不宣称 Python 已新增预览解析。
共享总线 AW=872 / W=928 / B=872，峰值 outstanding=3，W-ahead beats=44；
两次 capture、计算期间 capture AW=10。这里只是小图功能/并发证据，非 15 fps。

全量 Icarus 155 配置通过；默认 queued-write SoC 133 源文件编译通过，
0 errors / 608 工具诊断。新增开关打开的配置由五组 smoke 和真实 xsim 覆盖。

## 后续必做

1. 完整 SoC 两槽连续完成、末 B 阻塞取消、真实预览 BRESP 故障与恢复。
   现有 boardless 层测试不是八客户端环境下这些场景的替代证据。
2. 将预览基址/stride 加入 pending/display 元数据，并实现显示源切换，
   沿用原有换帧读排空屏障。
3. 原生尺寸吞吐、分区布局审计和实际 Efinity 全系统资源/时序评估。
