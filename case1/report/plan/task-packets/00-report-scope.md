# Task Packet：架构报告范围确认

- Scope：将用户的报告请求转换为可确认的中文比赛工程报告框架，不生成正文。
- Files to read：`case1/IMPLEMENTATION_STATUS.md`、`case1/ARCHITECTURE.md` 的定向片段；科研写作助手入口、编排、头脑风暴及模板。
- Files allowed to edit：`case1/report/plan/` 下的本任务计划文件。
- Required skills：research-writing-assistant、using-research-writing、paper-orchestration、brainstorming-research。
- Evidence/data inputs：当前用户请求及已核对的架构/实现状态边界。
- Required artifacts：`project-overview.md`、`outline.md`、`progress.md` 和本任务包。
- Rejection checks：不得编写报告正文；不得声称用户已经确认；不得改 RTL 或生成仿真/综合输出；不得把板前功能门当成板级性能门。
- Validation commands：PowerShell 文件存在、内容与 Markdown 标题检查；不使用哈希。

## 确认后的写作约束

报告论证必须按输入到输出的数据流展开，说明控制与存储如何支撑这一过程。章节不能仅由模块清单构成，现有记录缺失的指标不得补造。最终仅交付用户要求的 Markdown 报告，计划材料不写入比赛报告正文。
