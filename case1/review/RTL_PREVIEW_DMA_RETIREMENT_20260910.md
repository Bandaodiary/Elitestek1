# 预览 DMA 生命周期修复与验证

日期：2026-09-10。

## 实现范围

新增 `rtl/video/c1_r1_preview_dma.sv`，组合已经验证的
`c1_r1_preview_fork` 与 `c1_axi_xrgb_frame_writer`。
Resize 的 centered-C8 数据一路保持完整 64 位送 CNN，另一路恢复
RGB888，由现有 writer 打包为 128 位 AXI 写数据。

这是独立单元，不是已经接入 portable SoC 的功能；本轮未修改整机地址布局、
CPU 接口、DDR 仲裁或显示模式。预览语义是“Resize 后、CNN 前”，不等同于
现有显示路径的原始 ISP 图像。

## 生命周期约束

- START 只在空闲时接受；writer 在 START 保存地址、尺寸和 stride。
- writer 完成配置预检之前，不允许源数据进入任一消费者。
- 接受 EOF 后立即锁住源入口，防止等待 B 响应时误接收下一帧。
- `done` 必须同时满足 writer 终止、writer 空闲和两路分流数据消费完毕。
  因而最后像素已入队不等于 DDR 写入已退休；DDR 完成也不等于 CNN 已接收 EOF。
- cancel 清空本地分流状态并锁住入口，但不会复位 AXI writer。
  已经呈现的写事务由 writer 排空至 B 响应，再允许新任务。
- error 保留到下一 START。错误发生时，已经呈现且被背压的 CNN token
  不能直接撤回；父控制器必须取消整个任务以终止消费者和局部流。
  该单元不承诺在消费者永久停顿或 AXI 永久不响应时自行完成。
- 全局 rst 仍是破坏性复位；运行中取消使用 cancel，不能用 rst 替代事务退休。

## 验证结果

`sim/tb_c1_r1_preview_dma.sv` 连续执行五个无复位任务：正常完成、
已发出写事务后的取消、非 OKAY 写响应、非法宽度预检、CNN 末像素长背压。
逐项检查 C8/坐标/边界标志、32 个实际写出像素、AW 地址和 burst 属性、
WSTRB/WLAST、忙状态、错误/取消终态以及 START 后修改配置的隔离。
AW/W 使用不同周期背压；B 响应延迟期间继续提供后续输入，确认 EOF 后拒收。

实际输出：

```text
C1_PREVIEW_DMA_PASS jobs=5 successful=2 aborted=1 errors=2 pixels_compared=32 late_B=4 late_CNN=1 no_reset_restart=1
C1_REVIEW_FIXES_REGRESSION_PASS configurations=126
```

全量回归启动后进一步补充了 EOF 入口封锁与对应断言；最终版本的该定向测试
再次通过。完整 SoC 编译为 130 个源文件、0 errors，存在 603 条工具诊断，
不应表述为无警告。由于新 DMA 尚未实例化进 SoC，整机编译不代表整机预览验证。

本轮没有运行 Vivado/xsim、Efinity 综合或板测，不产生新的资源/时序结论。
Icarus runner 不生成波形，临时镜像和生成向量由 finally 清理。

## 下一集成门

1. 明确预览开关、单独 DDR 缓冲区及与采集/输出槽的所有权，拒绝地址重叠。
2. 将预览 AXI 写端加入仲裁/QoS，并把 busy/error/cancel 接入任务控制器。
3. 显示帧对按模式选择原图或预览及其对应几何，不能只替换地址。
4. 加入整机随机背压、取消/恢复和逐像素 golden；之后才评估大分辨率吞吐。

不宣称大图预览、15 fps 或 Ti60 资源/时序签核已完成。
