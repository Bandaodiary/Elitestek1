# 源尺寸与 Resize 影子寄存器

后续更新：本文件记录影子存储阶段。四个 Resize 寄存器现已在 R1 portable SoC 接入启动快照，详见 `RTL_RESIZE_CSR_LAUNCH_SNAPSHOT_20260910.md`；源尺寸仍未接通。下文“仅存储”是当时阶段边界。

## ABI

在 `c1_apb_csr.sv` 未使用的地址区间增加五个 32 位可读写影子寄存器，`software/include/c1_accel.h` 同步定义偏移：

| 地址 | 名称 | 含义 | 复位值 |
|---|---|---|---|
| 0x060 | INPUT_FRAME_SIZE | 高 16 位源高度，低 16 位源宽度 | 0，未配置 |
| 0x064 | RESIZE_X_STEP | 横向有符号 Q16.16 步长 | 0x00010000 |
| 0x068 | RESIZE_Y_STEP | 纵向有符号 Q16.16 步长 | 0x00010000 |
| 0x06c | RESIZE_X_PHASE | 横向有符号 Q16.16 初相位 | 0 |
| 0x070 | RESIZE_Y_PHASE | 纵向有符号 Q16.16 初相位 | 0 |

采用现有 `merge_wstrb`，允许软件在 busy 时更新下一任务的影子配置；零写掩码不改变值，非对齐访问沿用原有 PSLVERR 拒绝规则。CSR 本身只保存 32 位数据，不在写入时限制源尺寸或符号值，语义合法性需由启动配置校验负责。

没有修改旧 FRAME_SIZE 等地址、版本或 capability。**本阶段只实现寄存器存储，不表示整机已经支持该配置。** portable SoC 对这些新输出显式悬空，原有源尺寸与单位映射行为保持不变。头文件也明确写出这一边界，不能由寄存器可读写推断功能已启用。

## 验证

扩展原有 `tb_c1_control.sv` 并登记到默认回归：

- 五个寄存器各遍历 16 种 byte-enable，共 80 次写入，验证独立参考合并值、APB 读回及 RTL 输出一致；
- 这些写入在 busy=1 时执行，检查不会发出 start/abort 脉冲；
- 每个寄存器做一次非对齐写，要求报错且原值不变；
- 编程后复位，重新读回五个默认值；
- 保留旧 CSR 的控制、busy START 拒绝、IRQ/W1C 与帧管理器测试；普通 APB 读写任务增加 pready/pslverr 检查。

定向结果：`C1_CSR_GEOMETRY_SHADOW_PASS registers=5 masks=80 busy_write=1 unaligned=5 reset=1`、`C1_CONTROL_PASS`。五项 RTL 地址与 C 头文件枚举通过直接解析比较，未计算文件校验值。

全量 Icarus 回归完成，**123 配置符合预期**，包含预期失败检查。新增计数来自此前未登记在该回归中的 `tb_c1_control`。镜像及临时向量由 runner 清理，无波形保留。

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_control -Python D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe
```

完整 SoC Icarus 编译/展开通过：128 源文件、0 errors、602 条工具诊断。未运行新的 xsim、综合或板测；本轮不作性能结论。

## 后续必须完成

将影子值在生命周期控制器接受 START 时一起快照，再连接 boardless 的源尺寸、步长和初相位；任务运行中不能直接使用 CSR 输出。还须处理旧软件未配置源尺寸时的兼容策略、源尺寸与固定采集结构的匹配、负纵向步长拒绝、完整异尺寸 CNN/显示验证及大图预览。当前影子存储测试不覆盖这些尚未接通的行为。
