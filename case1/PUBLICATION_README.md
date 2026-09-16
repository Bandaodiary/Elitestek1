# Elitestek1 — Ti60 赛题一图像风格迁移工程

本仓库是赛题一的独立源码快照（2026-09-16，C40 生产版 host；计算子系统沿用 C39 one-hot）。不包含其他赛题、原开发仓库历史、厂商安装包/IP载荷或任何 Xilinx 生成文件。它不是已经完成板卡接口与下载验证的成品工程。

## 先读这三份文档

- [当前工程报告](case1/report/chapters/赛题一_RTL架构设计与验证报告.md)：八节介绍算法、RTL协作、资源和验证，未完成工作保留编号空位。
- [Efinity自动化开发方法](case1/EFINITY_AUTOMATION_PLAYBOOK.md)：本机工具配置、官方IP生成、仿真、MAP/PNR/STA、脱离Windows Job及安全清理。
- [C40生产验收与边界](case1/review/C40_PRODUCTION_RESIZE_100MHZ_20260916.md)：生产 Resize 合入、33 项回归、100 MHz 六帧吞吐及 Efinity 资源/时序结果。

## 当前结果

C40 完整 host 在 Ti60F225/I3、100 MHz 下为 41,394 XLR / 129 RAM / 121 DSP，核心域 setup/hold 裕量为 +2.046/+0.026 ns。640×480 六帧 xsim 的最差完成间隔为 6,609,780 周期，对应 15.12909658 fps；欠流和显示遗漏均为零。该仿真使用行为 CPU 流量与行为 DDR。历史 C39 的 Sapphire S2+唯一 DDR 联合资源探针为 51,900 XLR / 165 RAM / 125 DSP，但尚未换入 C40 四行 Resize，也未证明真实 CPU 程序或板级持续吞吐；两种测试边界不可合并。

## 目录和选源

| 路径 | 用途 |
|---|---|
| `case1/rtl` | 当前模块及保留的历史对照实现，不能通配导入 |
| `case1/golden`、`case1/model` | 位精确参考、训练/导出、执行计划、验证器 |
| `case1/sim`、`case1/tb`、`case1/tests` | 手写测试台、行为模型与测试源，不含运行产物 |
| `case1/software` | 当前APB/AXI驱动及S2软件探针源 |
| `case1/efinity` | 手写顶层、XML/SDC/Tcl；官方IP须在本地重建 |
| `case1/outputs/c36_qat_b_*_20260915a` | 三个已测模型的精选小型部署输入，不是EDA输出 |
| `case1/review`、`case1/report` | 阶段审查、指标摘要和工程报告 |
| `case1/scripts` | 本地回归、工具隔离、资源评估与发布辅助脚本 |

当前 Efinity host 入口为 `c1_ti60_c40_host_100`；通过 `case1/golden/c39_onehot_sources.py`选择 49 个生产源，C40 四行 Resize 已位于原生产源码路径，资源顶层另计。旧实现包含同名模块，不能将整个 RTL 目录直接加入 GUI。

## 克隆后的最小检查

XML中的本机绝对源码路径在发布时替换为`@CASE1_ROOT@`，防止意外编译原电脑旧目录。先定位，后打开Efinity GUI；以下定位操作仅重写工程XML路径，不生成IP、不运行EDA、不修改RTL。

```powershell
# 在仓库根目录执行；定位命令仅对发布副本有效。
& ./case1/scripts/configure_publication.ps1

# 普通Python 3.11+；执行计划检查需要numpy等项目Python依赖。
python -X utf8 -B case1/golden/c39_onehot_sources.py
python -X utf8 -B case1/golden/c37_capacity_contract.py --self-test
& ./case1/report/plan/verify_current_report.ps1
```

定位后 XML 出现本机路径变更是预期行为；不要把该本地配置差异当作新的 RTL 优化结果。需要再次发布或迁移前，可运行 `configure_publication.ps1 -Portable` 恢复路径标记，到新位置再定位。发布自检会验证 C40 host XML 的设计源和 SDC 均位于当前副本；历史/联合项目的外部厂商依赖不由该检查承诺。

基础Python算法通常使用NumPy/Pillow，训练还需要PyTorch及相应特征网络。当前快照不附带虚拟环境、教师权重、训练图像或版权不明的Lenna等图片。模型`.pt`是项目产生的小型学生检查点，加载任何来源的检查点都应采用所用PyTorch版本支持的安全加载方式。模型清单的画质验收标记仍未完成。

Efinity和RISC-V工具路径、企业Demo位置在部分历史脚本中保留本机值，使用前按[工具链指南](case1/EFINITY_AUTOMATION_PLAYBOOK.md)核对。官方CPU/DDR联合工程必须先从合法本地安装和企业Demo生成IP、BSP，再更新对应输入配置；本仓库不含该受保护实现。不要直接执行全部历史脚本或把所有XML当作开箱即用项目。

## 发布范围与证据

保留手写xsim/Vivado测试脚本以便复现，但排除工具生成的`.Xil`、`xsim.dir`、`.dcp`、`.wdb`、`.vvp`、波形、日志、快照、网表和综合数据库，也排除Efinity的work/outflow/bitstream及官方生成IP目录。可重建向量和运行目录不纳入Git。

历史评估文档中的 `logs/`、某些 `outputs/` 或本机企业资料链接仅在原开发树可用。公开报告指向 [C40 当前指标摘录](case1/report/tables/current-c40-metrics.json)和派生审查，不伪装成完整原始日志归档，也不能在缺少日志时声称重跑了历史验收。

数据/IP权利与重建边界见[第三方材料说明](THIRD_PARTY_NOTICES.md)。本快照未擅自选定开源许可证；未声明授予第三方材料再分发权。
