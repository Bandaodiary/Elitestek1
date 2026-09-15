# 列缓存回填集成、连续请求交接与突发利用率

日期：2026-09-12。范围：板卡无关 RTL 的现有能力集成与验证；不修改算法、模型、
描述符、CPU/APB/AXI ABI，不替换企业外设例程。没有本轮 Efinity 综合/P&R 或板测。

## 1. 结论与实际改动

当前64×48训练模型性能组合，任务从329,619降到310,689拍，减少18,930拍，约5.74%。
22层结果、DDR及显示图像一致。收益来自更连续地提交已有行回填请求、扩大有界C8
请求窗口后形成更完整的AXI读突发，**不是减少计算量或少读输入数据**。

`c1_cache_refill_scheduler.ALLOW_REQ_HANDOFF`和`MAX_OUTSTANDING`在此前已实现，
`c1_r1_portable_soc`也已把两者传入真实列读后端。但系统仿真运行器仅允许旧的
`TensorBurstRefill`标量路径使用`RefillRequestHandoff`与`WideRefillWindow`；该路径
与`TensorColumnReads`互斥，导致新主组合无法选择它们。原容量探针也只观测标量层次。

本轮修复运行器的路径/trace前提，增加实际列读后端的配置、容量、握手和突发统计，
并建立独立golden合同检查。生产SV仅纠正两处过时注释，**没有新增数据通路逻辑，
没有修改任何默认开关**。不把已有RTL能力冒称为本轮新设计，也没有实现下一行预取。

## 2. 归因与数据流

实际层次为：

```text
c1_r1_portable_soc.g_tensor_column_reads
  u_column : c1_column_cache_owned_exact_burst_shell
    u_backend.g_column.u_cache : c1_column_line_cache_c8
      行缺失 → 声明一行的base/word数/epoch
    u_backend.u_exact : c1_cache_refill_scheduler_read_client_exact
      u_completion → 已声明行的精确数量补齐/错误与取消排空
      u_core.u_scheduler → 已接收请求metadata + 待发送请求预留
      u_core.u_read_client → C8请求打包、AXI128 AR/R、按序C8响应
```

`TENSOR_BURST_SCHED_REQ_HANDOFF=1`使旧pending请求实际握手时能够同拍装入下一笔。
信用判断使用沿前metadata数量，同时为旧请求和下一笔pending预留容量；不把响应端
READY接回请求发射判断。原保持请求、实际响应退休、epoch和取消协议不变。

`TENSOR_BURST_SCHED_MAX_OUTSTANDING=32`是**32个C8逻辑请求的有界容量**，
不是32个AXI burst，也不是MAC并行数。此配置中请求FIFO仍32、响应FIFO仍128个C8，
AXI reader仍最多4笔物理事务，每笔最大16个128-bit beat。行回填一次只管理一行，
所以8×8实际峰值只有16；64×48才观察到32。不能用配置值替代实测峰值。

新增逐层列缓存FSM直方图后，stage19原来42,669拍中的17,916拍处于行回填DATA状态，
约42%。DATA占用包含6,144次真实word接收，不能全部称为纯等待；扣除有效接收后
无word握手的DATA周期为11,772。其余包含计算、列采样、配置和空闲。
此前adapter READ_RSP占64%不意味着
这些时间都能靠消除cache-hit握手节省。每层FSM周期总和、实际column capture和
descriptor导出的回填行数/C8数分别交叉核对，仿真数组不进入生产综合。

## 3. 同条件结果

所有64×48行均使用相同训练artifact、彩色RGGB输入、完整22逻辑层、既有最终输出
融合与DW整层流水，默认BFM延迟相同；没有改MAC工作量或目标时钟。

| 指标 | 16项，交接关闭 | 16项，交接开启 | 32项，交接关闭 | 32项，交接开启 |
| --- | ---: | ---: | ---: | ---: |
| 完整任务周期 | 329,619 | 315,443 | 327,654 | 310,689 |
| stage0周期 | 33,928 | 32,068 | 33,940 | 31,704 |
| stage15周期 | 10,784 | 10,449 | 10,749 | 10,422 |
| stage18周期 | 26,854 | 25,990 | 26,855 | 25,707 |
| stage19周期 | 42,669 | 39,491 | 41,694 | 38,040 |
| stage20周期 | 46,393 | 44,657 | 46,395 | 44,095 |
| 回填逻辑请求/响应 | 26,880 / 26,880 | 26,880 / 26,880 | 26,880 / 26,880 | 26,880 / 26,880 |
| 实际AR事务 | 1,680 | 1,680 | 864 | 864 |
| 实际128-bit R beat | 13,440 | 13,440 | 13,440 | 13,440 |
| 连续请求实际交接 | 0 | 15,792 | 0 | 18,480 |
| 实际含pending预留峰值 | 16 | 16 | 32 | 32 |

基线真实突发为1,680笔×8 beat；32项组合为816笔×16 beat＋48笔×8 beat。
AR减少48.57%，R数据量不变。扩大窗口之前，仅消除请求间空拍已减少14,176拍；
扩大窗口再减少4,754拍。仅扩大窗口而不开交接，虽然AR同样降至864，任务却只减少
1,965拍（0.60%），stage0/18/20还略有回退；不能把AR次数减半当作吞吐接近翻倍。
stage19的DATA占用从17,916降至13,287拍，均包含6,144次有效接收；其无word握手
周期从11,772降至7,143，整层减少4,629拍。
标量C8读/写仍3,456/28,608，写AXI AW/W/B仍3,939/14,592/3,939。
上述写计数于同日双条目缓存收尾时依据四组原始`C1_PERF_TENSOR_AXI_WRITE`更正；
初版误抄了4,035/16,128/4,035，原始日志、四组周期及读突发结论均未变。

schema1探索运行记录了握手总数但没有突发长度直方图；schema2最终证据再独立核对
ARLEN直方图的笔数与加权beat总数。不要把早期日志称作事后重新跑过的新schema。

## 4. 验证覆盖与证据入口

系统日志根目录：`logs/portable_soc_cache_ddr_bfm_runs/`。

| 运行 | 范围/结果 |
| --- | --- |
| `soc_column_stage_profile_64x48_20260912_a` | 首次逐层归因，329,619拍 |
| `soc_refill_handoff_64x48_20260912_a` | schema1，16项交接，315,443拍 |
| `soc_refill_wide_64x48_20260912_a` | schema1，32项交接，310,689拍 |
| `soc_column_refill_off_64x48_20260912_b` | schema2最终关闭基线，完整golden；485项负测试 |
| `soc_column_refill_wide_64x48_20260912_b` | schema2最终32项，完整golden；487项负测试 |
| `soc_column_refill_handoff_64x48_20260912_c` | 新配置入口实际派发，schema2的16项中间对照；315,443拍，完整golden |
| `soc_column_refill_windowonly_64x48_20260912_a` | 新配置入口实际派发，仅32项窗口；327,654拍，完整golden及310项列合同变异检查 |
| `soc_column_refill_read_abort_20260912_a` | 真实client7读债务4 beat保持64拍，禁止重启；无复位12×10→8×8恢复，23,986拍；540项负测试 |
| `soc_column_refill_write_abort_20260912_a` | stage18真实B债务2笔保持64拍，AW/B排空81/81；无复位恢复23,993拍，最终191/191；530项负测试 |
| `soc_column_refill_twoframe_20260912_a` | 两种输入连续两帧，22,944/22,925拍，1,192 C8/128 DDR与两路视频正确，2次切帧、0丢帧；597项负测试 |

两个取消恢复场景均验证完整22层596个C8、64个DDR像素，以及120个raw/64个styled
显示像素；只对成功job2输出完整工作量统计，被取消job1不会混入成功预算。

底层真实列cache/exact/scheduler/AXI链路另有四组xsim，位于
`logs/xsim_runs/window_line_cache_c8_exact/column_handoff_{off,word,beat,epoch}_20260912_a/`：

- word模式最小2个C8响应FIFO、beat模式16个beat响应FIFO，实际交接开启/关闭；
  三组常规测试各完成34次column请求、68次refill、2,244个声明word。
- W=11、G=3，一行33个C8，起点0x1ff8：真实高半beat、奇数行、4 KiB拆分、
  多突发在途、AR背压、R间隙、响应保持和三行并行读取。
- 四个取消相位×abort/flush/同时到达，共12场景；SLVERR和DECERR行精确错误补齐，
  完全排空后改变配置/数据代次恢复。该测试不新增畸形RLAST注入，不能混称覆盖。
- 2-bit epoch耗尽后3行共99 word明确错误完成、不产生新AXI，重配置不能清除防别名
  状态；只有整个域排空后复位才能恢复，恢复后再次真实访存且列数据正确。
- 全过程检查metadata＋pending≤32。word/beat实际峰值分别24/21、真实AXI峰值3；
  这是异常压力场景，不是64×48吞吐对照，不能据其AR差异计算正常帧加速。

4种SoC结构配置（16/32×交接开/关）通过实际叶子参数检查；Python共61项单元测试，
真实22层列统计通过310项独立变异检查。压缩器验证37条关键、重复及损坏记录在
80行保留尾部之外也不会丢失，保障负测试不会被日志去重掩盖。

schema1的负测试只破坏能够独立证明的合同；没有ARLEN直方图时，微调一笔AR或R
可能仍是合法的事务形状，不能谎称已证明其错误。本轮为该边界增加专门单元测试。
14次WMI运行（10系统＋4底层）全部complete/exit0，逐项确认worker与私有临时目录
均不存在。必要运行文本共约10.817MiB，不含几个独立小型单元日志；没有波形或大型
仿真工程归档。终结核对见`logs/column_refill_closure_audit.log`，未删除其他会话文件。

## 5. 可复现配置与后续GUI映射

新增配置入口`scripts/run_r1_column_refill_profile.ps1`，只组合已验证参数，
最终仍调用既有WMI外层。它没有Worker入口，也不会改变RTL默认值。

```powershell
# 不启动仿真，只查看完整参数对象
./case1/scripts/run_r1_column_refill_profile.ps1 -DryRun

# 四种同条件对照，各用新的RunId；不要直接运行底层脚本的-Worker
./case1/scripts/run_r1_column_refill_profile.ps1 -RefillMode Baseline -RunId my_baseline
./case1/scripts/run_r1_column_refill_profile.ps1 -RefillMode Handoff -RunId my_handoff
./case1/scripts/run_r1_column_refill_profile.ps1 -RefillMode WindowOnly -RunId my_window
./case1/scripts/run_r1_column_refill_profile.ps1 -RefillMode Wide -RunId my_wide

# 自动使用8×8；含SourceGeometry的恢复源是12×10
./case1/scripts/run_r1_column_refill_profile.ps1 -Scenario ReadAbort -RunId my_read_abort
./case1/scripts/run_r1_column_refill_profile.ps1 -Scenario WriteAbort -RunId my_write_abort
./case1/scripts/run_r1_column_refill_profile.ps1 -Scenario TwoFrame -RunId my_twoframe
```

16种scenario/mode参数对象已做无派发检查；默认完整参数对象与实际验证的32项命令
逐项相同。指定非单帧场景的64×48会明确拒绝。实际派发验证为上表handoff c及windowonly。
可重复执行`scripts/test_r1_column_refill_profile.ps1`进行无EDA配置检查。

| 运行器配置 | `c1_r1_portable_soc`参数 | 本轮最终性能组合 |
| --- | --- | --- |
| `TensorColumnReads` | `ENABLE_TENSOR_COLUMN_READS` | 1 |
| `RefillRequestHandoff` | `TENSOR_BURST_SCHED_REQ_HANDOFF` | 1 |
| `WideRefillWindow` | `TENSOR_BURST_SCHED_MAX_OUTSTANDING` | 32 |
| 请求FIFO，未改变 | `TENSOR_BURST_REQ_FIFO_DEPTH` | 32 |
| 响应FIFO，未改变 | `TENSOR_BURST_RSP_FIFO_DEPTH` / `TENSOR_BURST_RSP_FIFO_BEAT_MODE` | 128 / 0 |

这只是本轮增量映射，完整性能组合仍含DW/dot流水、行映射复用、输出融合、虚拟
upsample等前期选项，应以DryRun对象及此前阶段文档为准。企业例程拼接时使用该
portable模块的总线边界，不能覆盖列cache或绕过其实际排空协议。

最终单帧检查器需显式使用`--expect-column-refill 32 1 --require-dw-frame
--require-final-fusion --require-stage-perf --require-video --expect-frame 64x48`。
取消场景另加相应`--require-read-abort --require-pixel-prefetch-abort
--require-virtual-upsample-abort`或`--require-write-abort --require-dw-pixel-abort`，
并把frame设8x8。双帧使用专用检查器的`--require-video --require-color
--require-dw-frame --require-final-fusion --expect-column-refill 32 1 --self-test`。

## 6. 资源、时序与剩余瓶颈

32项相对16项增加16组metadata，每组epoch8＋row16＋index16＋last1=41 bit，
合计656 bit；两个指针和占用计数器各增1 bit，共约659个逻辑存储位。
这不是目标FF/LUT/Memory Block数量，综合可能重新映射/剪除；未新增行RAM或MAC。
handshake交接逻辑此前已存在，开启后的请求发射组合路径仍需目标时序确认。

5.74%是相同仿真时钟下的周期节省：若物理可达Fmax比旧配置下降超过约5.74%，
真实吞吐优势会被抵消。16项交接相对旧配置已节省4.30%，而32项相对16项交接的
增益只有约1.51%；若扩大窗口损失超过这一比例的可达频率，保留16项交接反而更好。
应先对这些组合做目标资源/关键路径对照，再考虑提高频率。
当前stage20仍需44,095拍、stage19需38,040拍、stage0需31,704拍；残差层的串行
输入/skip读写亦未优化。下一步应按这些实际等待再决定缓存预取或残差批次处理，
不能仅继续加逻辑窗口或MAC数。

原生640×480的理想工作下界仍8,928,000拍，15fps至少133.92MHz且未计任何开销。
没有原生RTL帧率、Efinity新资源/Fmax或板级摄像头/DDR/HDMI证据；不得由小图结果
直接宣布15fps完成。整体RTL优化和系统集成目标仍未完成。
