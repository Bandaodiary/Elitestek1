# 显示双 DMA 独立几何

## RTL 改进

`c1_display_prefetch_pair.sv` 追加默认关闭的 `SEPARATE_ORIGINAL_GEOMETRY` 参数，以及 `original_width_pixels/original_height_lines` 输入。启用时原有 `width_pixels/height_lines` 仅描述处理图，默认模式仍共用原有尺寸并忽略新输入。

此次不是仅增加接口：

- 两路几何分别检查非零、4 像素对齐、缓存容量与坐标位宽；任一路非法均不启动读 DMA，返回终止错误。
- 原图读 DMA 使用独立输入尺寸，处理图读 DMA 保持原接口；base/stride 原本已独立。
- 原图宽高在 START 握手时锁存。原图宽度通过独立两级寄存器进入像素域，其 `request_last` 根据自身宽度产生，不再用处理图宽度提前释放缓存行。
- `primed` 对两路分别选择单行非空条件或双行就绪条件，再合并；支持一侧单行、另一侧多行。
- 既有完成规则保留：两路 reader 完成、响应 FIFO 与双时钟行缓存均排空后才报告 done。

宽度同步沿用既有 bundled-data 约束：仅接受 START 时改变，运行期间保持，行缓存的行就绪传递发生在 DMA 填充之后。两路同步寄存器标注 `ASYNC_REG`。这不是一次板级 CDC 或时序签核。

现有 display subsystem、旧单元测试和 native 测试显式将新输入接零，参数默认关闭。完整 SoC 的显示消费者仍是同尺寸布局，尚未启用新功能。

## 新增验证

`tb_c1_display_prefetch_separate.sv` 使用真实两个 AXI frame reader、真实双时钟行缓存及可选响应 FIFO，不强制内部状态。core 时钟周期 10 ns，pixel 时钟周期 14 ns。

每个 FIFO 配置执行：

1. 原图 8×3、处理图 4×1；然后反向 4×1 与 8×3。每个任务逐像素检查两幅完整图，共 56 像素/配置。
2. AXI BFM 对每路检查精确行地址、burst 长度、size/type、总行数。原图 stride=64，处理图 stride=48；8 像素行使用 2 beats，4 像素行使用 1 beat。RGB 包含独立通道、行列标识。
3. START 后立即改写所有实时宽高，确认 DMA 和行释放使用已锁存配置。消费完全部像素后要求 done，验证两路缓存排空；每行之间留有固定 refill 时间，不据此宣称吞吐性能。
4. 原图宽=0、原图高超限、处理图宽不对齐、处理图高=0，均须报错且不得增加 AXI 请求。

FIFO=0/1 均输出 `C1_DISPLAY_PREFETCH_SEPARATE_PASS jobs=2 pixels=56 invalid=4`。默认全量回归登记两个新配置。新测试未注入取消或 AXI 故障，原有同尺寸故障/排空回归仍保留；不能把该边界测试解释为整机异尺寸数值证明。

全量 Icarus 回归最终 **121 配置符合预期**（包括预期失败检查）。最终注释、同步属性与未用测试变量清理后再次运行新增两配置，均通过。

完整 portable SoC 的 128 源文件 Icarus 编译/展开通过，0 errors，602 条工具诊断；未新增综合、P&R、xsim 或板测结果。

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_display_prefetch_separate -Python D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe
& case1/scripts/run_iverilog_rtl_compile.ps1 -WarningSampleCount 1
```

## 尚需贯通

下一层 `c1_r1_display_subsystem` 的几何快照、请求坐标与 padding 仍共用尺寸。需要把上阶段控制器的原图宽高快照连接到它，并明确大图到 640×480 显示区域的映射/消费规则，再启用本参数。随后仍需 SoC/CSR 输入输出几何、采集与 Resize 相位配置、真实 CNN 端到端验证。不能直接打开参数代替这些工作。
