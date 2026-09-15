# C39已验收开发组合（保留C37回退版）

完整实施状态与测试证据见[三个目标记录](../../review/C39_THREE_OBJECTIVES_IMPLEMENTATION_20260915.md)。不得把本目录和所有旧RTL一起通配加入工程，否则同名模块冲突。

## 当前已验收组合：one-hot

本目录并非全部“最新版”源码的集合。最初combined版本整机面积回退后，获胜组合采用以下选择；保留旧源作为独立对照，不覆盖C37。

| 当前实际使用文件 | 关系 |
| --- | --- |
| [c39_requant_bank8_narrow.sv](c39_requant_bank8_narrow.sv) | 五级弹性窄舍入，被下行compute实例化 |
| [c37_compute6_indexed.sv](c37_compute6_indexed.sv) | 96乘积MAC和参数所有权，接新量化模块 |
| [c1_r2_partitioned_window_store.sv](c1_r2_partitioned_window_store.sv) | 共享选择译码、双请求槽，接空间feeder |
| [c39_direct中的row shadow engine](../c39_direct/c1_r2_cnn_row_shadow_engine.sv) | 直接消费产生端压缩格式，不额外放通用pack器 |
| [c39_native中的spatial feeder](../c39_native/c1_r2_spatial_partitioned_feeder.sv) | 在RGB/DW构造端形成432位操作数 |
| [c39_onehot中的operand codec](../c39_onehot/c39_operand_codec.sv) | 共享模式译码、掩码并行OR解包，连接compute输入 |

其余源由[one-hot显式49源闭包](../../golden/c39_onehot_sources.py)选择，工程是[纯host XML](../../efinity/c1_ti60_c39_host_onehot.xml)。默认资源探针为24通道/512行字容量；48/1024仍有数值/容量兼容测试，但不意味着扩大配置仍占同样资源或已证明能装入板卡。

官方S2/DDR联合入口为[one-hot CDC XML](../../efinity/c1_ti60_c39_joint_s2_onehot_cdc.xml)，其核心/CPU/DDR用户时钟为100MHz，与纯host150MHz验证分开。生成的`*_CONTRACT.json`描述源码预期，实际MAP/PNR与映射后检查结果应查看[独立联合复核](../../review/C39_ONEHOT_JOINT_RESOURCE_CDC_REVIEW_20260915.json)，不能把静态合同里的未测量字段当成运行结果。

2026-09-15最终验收：one-hot三模型及六帧系统回归、量化原始短测、512/1024窗口逐拍短测均完成并清理，选为当前开发入口；C37不覆盖，作为回退。纯host最差间隔6,433,652周期，标称150MHz下约23.315fps；不代表100MHz联合系统或板卡实测。[完整验收记录](../../review/C39_THREE_OBJECTIVES_FINAL_ACCEPTANCE_20260915.md)。`c39_window_factor`仍是额外未测资源实验，不在本组合中。

## 最初combined实验的本目录文件

| 文件 | 功能与关系 |
| --- | --- |
| `c39_requant_bank8_narrow.sv` | 新名量化模块，32×18输入规则不变，五级弹性/II=1；窄舍入已通过独立RTL及叶级PNR对照 |
| `c37_compute6_indexed.sv` | 保留原计算模块名和MAC/参数所有权，仅把量化实例接到新模块 |
| `c39_operand_codec.sv` | 无状态432位操作数编码/解码，覆盖PW/RGB/DW/残差/两种encoder；PW保留跨像素两向量 |
| `c1_r2_cnn_row_shadow_engine.sv` | 采用1264位请求记录，并保存模式；调用codec后向原96乘积MAC提供完整输入 |
| `c1_r2_spatial_partitioned_feeder.sv` | 将空间操作数暂存压成432位，保持原权重延迟、握手及encoder分支 |
| `c1_r2_partitioned_window_store.sv` | 共享银行译码与静态位平面，保留两槽、窗口周期、512/1024容量及共享分区 |

使用[明确源闭包](../../golden/c39_candidate_sources.py)的`sources()`，它在C37/指定模型基础上替换五项源，并加入codec，总计49源。四个生成候选默认可复现检查；原C37和企业源不修改。

拆项工程位于`case1/efinity/c1_ti60_c39_host_{quant,operands,window,combined}.xml`；真实CPU联合工程位于`c1_ti60_c39_joint_<CPU配置>_<host版本>.xml`。前者是原C37探针的公平对照，后者是100MHz逻辑联合资源边界，都不是可直接下载的完整板级工程。

下一步必须完成全部算子、拆项综合/布局布线、联合接口和整机回归后再选择最终替换源；本目录存在不代表这些验收已完成。
