# 实测 adapter 等待周期分解

## 方法与验证

在整机 bench 的原有性能窗口内，按实际 adapter state_q 建立 32-bin
直方图，并分别记录每个状态下的 input_wait、result_stall。每次任务终止
要求状态总数等于 elapsed，两个分类总数分别等于原有对应计数，遇未知
状态立即失败。仅添加 testbench 计数，不增加综合资源。

Run：`apb_engine11_profile_20260911`，DW 缓存与 MAC 预取均开启，独立
worker 15348；最终 complete/done、退出码 0。完整数值及 APB 恢复 golden
通过（22 阶段/836 C8/64 DDR/120+64 视频），临时工程目录已清理。
成功 job=2 的 elapsed=71826，与未插入直方图前相同。

## 主要结果

状态编号对应当前 adapter enum；不是通用 AXI 状态编号。

| 状态 | 周期 | 其中 input_wait | 其中 result_stall |
|---|---:|---:|---:|
| ST_WRITE_RSP (14) | 28859 | 13342 | 12113 |
| ST_ENGINE (11) | 13974 | 0 | 0 |
| ST_READ_RSP (8) | 13277 | 13038 | 0 |
| ST_READ_REQ (7) | 5510 | 4706 | 0 |
| ST_RESULT (12) | 4101 | 0 | 0 |
| ST_SOURCE_RSP (4) | 2392 | 2005 | 0 |
| ST_WRITE_REQ (13) | 772 | 351 | 120 |

写响应状态约占任务 40.2%；12113/12233 的结果背压周期发生于该状态。
这里不能直接称为纯 DDR 延迟：它包括逻辑写响应路径、桥接和仲裁等端到端
等待。input_wait 指 engine ready 而 adapter 无输入，不限于读等待。
各状态周期互斥；input_wait/result_stall 为交叉分类，不能额外相加。

## 下一优化位置

当前 ST_WRITE_REQ 在 PIPELINED_RESULT_WRITES=0 时每次提交后进入
ST_WRITE_RSP，等待该逻辑写响应后才前进。已有可选分支允许非末组继续
收集结果，最后等待 pending 写全部排空。应优先对这个开关及 tensor
packing/end-marker 做同一场景的数值、取消排空与周期 A/B，检查收益是否
真实来自减少此处等待，而不是转移到其他缓冲或提前释放完成。

本轮未更改默认配置或生产逻辑，未证明完整原生分辨率吞吐。直方图只
覆盖当前测量窗口内的成功任务，不提供被 abort 的任务全程分类，也不是
逐层或物理 DDR 分析。后续可在需要时按 stage 索引细化。
