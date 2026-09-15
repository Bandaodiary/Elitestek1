# 将已有计算优化参数接入 SoC 层

## 集成缺口与修复

`c1_r1_microstyle_engine` 和 `c1_r1_microstyle_cnn_top` 已支持
`CACHE_DW_WEIGHT_TILES`、`MAC_PREFETCH_OVERLAP`，但上层 system bridge 与
portable SoC 没有传递这两个参数。因此不能从 SoC 实例启用它们，也不能
把已有叶模块实验视为整机已启用的优化。

本轮在两个上层模块的参数列表末尾追加这两个参数，逐层连接至真实
u_microstyle.u_cnn.u_engine。默认均为 0，保留既有默认配置；追加位置
也避免移动已有位置参数。没有更改 engine 算法、寄存器 ABI 或取消契约。

## 已验证

SoC smoke 扩展参数并直接检查最终 engine 的 elaboration 参数值，避免
“顶层接受参数但中间丢失”不被发现。新增 (0,1)、(1,0)、(1,1)，既有配置
覆盖 (0,0)。全部 SoC smoke 22 配置退出码 0。

这些是结构、复位和控制可达性测试，数据生产者保持空闲，**不证明启用
优化后的整机算术、恢复或吞吐正确**。不能只据此启用板级默认参数。

## 下一验证门槛

将对应选项接入整机 bench 与 detached runner，跑相同输入/权重/总线
扰动的 A/B 数值回归；记录实际分阶段周期而非仅仿真墙钟耗时。同时检查
abort/restart、参数代数切换对 DW 缓存失效及 MAC 预取状态的影响。

最近全量 608 配置和整机 golden 通过均发生于本次参数入口修改前。本轮
只完成 22 配置 smoke，没有重跑完整回归、综合或板测，也没有宣称 15 fps。
