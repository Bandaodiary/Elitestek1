# 相邻窗口复用：减少实际逻辑读请求

日期：2026-09-11。新增默认关闭的 `REUSE_HORIZONTAL_WINDOW`，已接入 portable SoC。未运行综合或板测。

## 1. 架构改动

每个输入 C8 group 保留最近一次已经被 engine 接纳的 3×3 窗口的最后两列，以及输出 x/y 标签。相同阶段、相同行、相同 group、紧邻下一输出像素才允许复用；输入/输出 bank 必须不同。

| 水平 stride | 复制到新窗口的列 | 每行仍需读取 |
|---|---|---|
| 1 | 旧列 1→新列 0，旧列 2→新列 1 | 新列 2 |
| 2 | 旧列 2→新列 0 | 新列 1、2 |

列索引从 0 开始。新行首像素不复用；未命中标签或不支持的条件走完整窗口读取。SAME_REPLICATE 的坐标钳位仍使用原函数，水平移动后的重叠列与钳位语义一致。

`next_operand_tap_fn` 按实际缺少的 tap 前进，并同步用于请求地址、cache sideband 和下一地址准备，避免复用后仍按 +1/+2 准备错误 tap。窗口历史只在 engine 真正握手时提交；stage load 和 abort 清除有效位，存储数据本体不复位。每阶段输入保持不可变仍是合同，与外部 line cache 的要求一致。

八个 group 的历史列、坐标和有效位逻辑容量为 `8×(384+16+16+1)=3336 bit`，另有少量控制。这个数字不是综合资源估计：宽而浅的存储可能被实现为寄存器、分布式存储或低利用率 RAM；是否需要调整 bank/端口组织，应由实际综合证据决定。

该功能保持单 read outstanding，不新增已接受但等待排空的请求，也没有 posted write acknowledgement。

## 2. 独立预算与单元验证

adapter 定向回归 **25 配置通过，退出码 0**。新增六个窗口复用配置，覆盖无地址流水线、两级/三级地址流水线、地址准备开关及结果写流水化组合；其他既有配置保留。

8×4、22 阶段完整正常任务：

- 不复用：1810 次逻辑读。
- 复用：1066 次逻辑读，减少 744 次；engine 操作数仍为 448 个，全部窗口/残差/上采样数据检查通过。
- stride=1 复用 120 次，stride=2 复用 8 次。

测试按独立的 stage 几何和算子表计算稠密读预算；每个窗口算子减去 `(输出宽度−1)×输出高度×输入组数×可复用tap数`，并同时核对实际读请求数及观测 savings。不是仅检查 DUT 自报命中率。

额外在历史已经有效且将要复用的边界取消任务：要求历史有效位清零、无遗留响应，随后不做硬件 reset，重新配置并跑完完整任务，最终帧正确。已有请求未接纳/已接纳时 abort、读错误和写排空测试继续通过。

## 3. 同版 RTL 整机对照

两组配置与上一轮故障恢复场景一致：真实参数、12×10→8×8 输入、burst line cache、queued writes、packing/end、三级地址流水线和提前地址准备；仅切换水平窗口复用。

| 成功任务指标 | 关闭复用 | 开启复用 |
|---|---:|---:|
| 周期 | 69789 | 63838 |
| 逻辑读 | 3620 | 2132 |
| 逻辑写 | 836 | 836 |
| engine feed | 896 | 896 |
| 地址准备命中 | 2688 | 1200 |
| 复用节省读数 | 0 | 1488 |

逻辑读减少 **41.10%**，周期减少 **5951 / 8.53%**。地址准备命中次数下降是因为很多 tap 已直接复用，不再发请求，并非优化失效。

这些是 adapter→cache/memory 的逻辑读，不能称为片外 DDR 带宽降低 41.10%；此前 line cache 已经消除了相当一部分重复片外读取。整个测试的 AXI AW/B 都为 628/628，W 从 770 变为 768，属于实际 coalescing 时序下的观察，不能与成功任务逻辑计数混为一谈。

运行：

- `horizontal_reuse_off_system_20260911`：complete，退出码 0。
- `horizontal_reuse_system_20260911`：complete，退出码 0。

两者独立 Python golden 均通过：22 阶段、836 C8、64 DDR 像素；原图显示 120 像素和风格显示 64 像素匹配。RAW idle timeout、最终写响应延迟 64 周期、DDR 排空后源确认延迟 32 周期、APB 软件恢复和无 reset 重启检查均通过。

通过 WMI/breakaway 独立运行 xsim；两次专属临时工程目录均已清理，只保留小型状态/trace。没有修改企业原始例程。

## 4. 复现与后续

单元：

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_r1_microstyle_tensor_adapter -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
```

整机使用 `run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1`，沿用 [提前地址准备整机参数](RTL_EARLY_TAP_PREFETCH_20260911.md)，开启组增加 `-ReuseHorizontalWindow`。runner 检查真实 adapter 参数标记，性能监视器新增每任务 stride1/stride2/saved 计数。

完成后用 `check_portable_soc_numerical_trace.py RUN目录 --require-apb-recovery --require-late-source-ack` 检查。

上一轮 639 配置完整回归针对修改前版本；本轮只完成 25 配置及两项整机回归，不能沿用旧全量结论。仍需补新版本完整套件、正常彩色连续帧和更大几何验证，测量历史窗口存储映射及实际时序。没有证明原生 640×480/15 fps，默认仍关闭。
