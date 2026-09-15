# C39 文档与独立源码发布记录

整理日期：2026-09-16；硬件与模型证据基线：2026-09-15。

## 实际交付状态

两份文档和独立发布副本均已完成，本地Git已提交，分支为`codex/c39-source-publication`。副本位于原工作区的`case1/publish/Elitestek1-20260915`，共2010项受版本管理文件，约18.2 MiB源码/文档/精选模型输入（不含Git数据库）。

GitHub推送尚未成功：实际HTTPS请求返回403，当前凭据账号`StephenWangZhevsky`对`Bandaodiary/Elitestek1`无写权限。凭据管理器只列出该账号；现有SSH也认证为同一账号。没有更改全局登录、没有新增密钥或覆盖远端。需要用户登录有权限的账号，或授予当前账号目标仓库写权限，再重试普通推送。目标仓库读取可达不代表拥有写权限。

## 两份主要文档

[Efinity开发方法](../EFINITY_AUTOMATION_PLAYBOOK.md)依据本机安装脚本和实际运行方法编写，21个本地链接已检查。内容包含环境、IP Manager、RISC-V、MAP/PNR/STA、CDC边界、独立Windows worker和定向清理。

[当前工程报告](../report/chapters/赛题一_RTL架构设计与验证报告.md)调用本地research-writing-assistant及其编排/写作/证据/验证能力，沿用已确认的八节框架。独立写作者与控制器双阶段审查完成，净正文6,222汉字（含摘要等的检查器口径6,660），29个有效链接，9项未完成空位；草稿质量门通过。详细能力审计和provenance在report/plan中。

## 隔离发布策略

原工作区属于另一个Git仓库且存在其他赛题修改，因此不更改其远端、不暂存其文件、不复制其历史。新仓库仅含case1、根README/忽略规则/第三方说明/文件清单。目标为`https://github.com/Bandaodiary/Elitestek1.git`，开发分支`codex/c39-source-publication`。实际远端可见性以Git推送和后续读取结果为准，本记录不以计划代替推送成功。

发布包包含手写RTL、测试与xsim运行脚本、软件、模型/Golden代码、Efinity XML/SDC/Tcl、审查及报告，以及三个已测模型的精选小型部署输入。没有Xilinx生成的日志、波形、快照、DCP或网表，也没有Efinity中间数据库、官方受保护CPU/DDR载荷、其他赛题、图像数据集或教师权重。没有替用户选择开源许可证。

XML的旧源码绝对路径改为`@CASE1_ROOT@`标记；`configure_publication.ps1`在克隆处定位，`-Portable`还原可迁移形式。联合工程的厂商IP和BSP仍须合法本地重建，不把纯host闭包检查冒充板级工程完整性。

## 在发布副本中实际执行的检查

`configure_publication.ps1`验证纯host50项设计源（49生产源加资源顶层）及SDC存在且均位于新副本。`c39_onehot_sources.py`通过实际49源生成内容一致性检查；`c37_capacity_contract.py --self-test`完成三个18阶段模型容量检查并拒绝三个负例。`verify_current_report.ps1`在不含原始工具日志的副本中仍通过。

`audit_publication.ps1`对允许的目录、扩展名、精选二进制输入、单文件大小、厂商保护标记和常见凭据格式执行检查；Git暂存路径另检查其他赛题与EDA产物。未读取大仿真文件，未计算文件哈希，未启动新EDA或改动RTL。

原始运行证据保留在本地开发树，公开报告使用指标摘录和派生审查；历史文档中的部分日志/数据链接仅在原开发树可用。后续真正需要完成的任务仍为真实CPU运行、100MHz联合吞吐、物理摄显/DDR/PLL/引脚与整机板测，不因发布而自动完成。
