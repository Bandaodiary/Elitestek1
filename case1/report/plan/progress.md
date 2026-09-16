# 架构报告写作进度

## 2026-09-16：C40 生产验收同步

主报告已从 C39 历史基线更新到 C40 生产版 host，补入四行 Resize 的设计作用、15 项专项回归、三模型 18 项 100 MHz 矩阵、640×480 六帧 xsim、Ti60F225/I3 资源及独立 STA 数据。报告保留 C37/C39 同边界结果作为历史比较，并把 S2+C39 联合资源明确限定为集成参考，未把行为 CPU/DDR 的 15.12909658 fps 写成官方 CPU 联合验收。

新增 `tables/current-c40-metrics.json` 作为公开的小型指标索引，报告验证脚本改为检查 C40 数值、18 阶段模型及历史联合边界。发布 README、便携工程定位脚本、导出日期和 C40 发布记录同步更新。GitHub 同步只使用严格过滤的独立赛题一快照，不读取或纳入大型运行日志、波形与工具生成目录。

## 2026-09-15：当前 C39 更新与能力使用审计

用户要求工具链方法MD、当前工程报告MD，然后仅发布赛题一。沿用已确认八节框架；概览、证据映射E20—E25、蓝图、实验协议、表格schema与图数据manifest先更新，随后由report_author独立编写、controller做规范及质量两阶段复核。正文是阶段性工程草稿，九项空位明确授权，未宣称提交就绪或板级验收。

| 能力 | 使用与输出 |
|---|---|
| research-writing-assistant / using-research-writing | 主控制器完整读取并路由当前工程报告，不重开已确认结构 |
| paper-orchestration / brainstorming-research | 保留八节单一交付单元，更新范围、任务包与证据门；按技能要求独立写作与复核 |
| writing-chapters / writing-core | 连续中文技术正文，6,222净正文汉字，明确未知部分，独立作者provenance |
| evidence-driven-writing / experiment-results-planning | 使用当前源码、模型及小型真实结果；历史与当前、150MHz仿真与100MHz资源、叶级与整机严格分开 |
| verification / peer-review | 真实运行当前报告核验与风格/草稿质量门，主控制器逐段审查，不用旧22层检查器证明C39 |

主稿检查为8节、29有效本地链接、9编号空位；含摘要/占位的检查器口径为6,660汉字。两份主要文档链接已定向检查；工具链指南21个本地入口均存在。完整工具日志不发布，正文链接改用已选指标摘要，原始证据仍在本地开发树。

刻意未使用：新EDA运行、波形/大型mem/数据库全文读取、文献检索、Word/PDF/图片生成。此次不新增外部学术论据，文件格式仅Markdown；没有计算哈希。对工具链方法采用本机安装脚本与已运行调用核验，不冒称本次重新执行。

后续发布使用独立赛题一源码快照，不改变当前另一个Git仓库历史，不夹带case2/case4、Xilinx生成物或受保护厂商IP。发布结果另记发布记录。

## 2026-08-31：S0 范围与结构确认

- 用户已明确：为当前赛题一架构编写中文 Markdown 比赛报告，后续自行转为 Word。
- 已使用科研写作助手入口、paper-orchestration 和 brainstorming-research，读取结构模板。
- 已检查项目中的既有报告计划，未发现本次报告的已确认大纲。
- 已拟定题目、篇幅、八节正文及参考资料/RTL 索引，写入 `project-overview.md` 与 `outline.md`。
- 已定向检查 `case1/IMPLEMENTATION_STATUS.md` 前 121 行与 `case1/ARCHITECTURE.md` 前 69 行，确认当前功能与证据边界。
- 本节为最初范围确认记录；用户随后回复“按当前框架写，可以对尚未完成的工作预留空位”，范围门禁已满足。
- S0 时尚未编写正文；本轮最终状态见下文。

### Capability-use audit

- 应用技能：research-writing-assistant、using-research-writing、paper-orchestration、brainstorming-research。
- 实际使用：上述四项；读取 brainstorming 的 `templates.md` 以确定工程报告采用适配结构。
- 仅预读未执行：writing-chapters；其正文门禁尚未满足，未据此撰写正文。
- 已消费资料：用户当前请求、已明确的赛题一开发上下文、现有实现状态和架构文档的定向片段。
- 暂未使用资料：大型仿真/综合日志、波形和 checkpoint；本阶段不需要，也避免不必要读取。详细 RTL、固定点规格和资源表留在结构确认后核对。
- 产物：本目录的项目概览、拟定大纲、进度和范围任务包。
- 验证方式：检查计划文件存在、Markdown 标题和未确认状态；不计算哈希。
- 剩余风险：报告结构尚未由用户确认；既有文档含不同日期和不同层级的验证结果，正式写作必须逐项核对，不能混用。

## 2026-08-31：确认后完成 S2/S4/S5

- S2 证据准备完成：按源码、算法规格、模型 manifest 和紧凑结果文件建立 E01—E19 工程证据映射。对更正版赛题指南的赛题一页进行文字提取与页面目视检查。必要学术背景仅查询三项原始论文摘要及书目信息。
- S4 正文编写完成：唯一正文为 `chapters/赛题一_RTL架构设计与验证报告.md`；包含八节正文、摘要、资料来源、24 项核心 RTL 索引以及 12 个获准保留的空位。
- S5 复核完成：独立证据审核发现的范围问题已修订，主代理再核对源码和数字；详见 `review/final-report-review.md`。
- 交付定位：供后续编辑为 Word 的比赛技术报告初稿，不是已完成板级验收的正式实验报告。
- 本轮没有修改 RTL、训练模型或运行 Vivado/Efinity/iverilog；没有读取大型波形、checkpoint 或整份仿真综合日志。

### 本轮 Capability-use audit

| 适用能力 | 实际使用与依据 | 产物或验证 |
|---|---|---|
| research-writing-assistant、using-research-writing | 根据用户调用论文编写技能的要求进入写作流程 | 已确认概览、大纲及范围 |
| paper-orchestration、brainstorming-research | 按单一工程报告组织八节内容，用户已确认结构；使用一个有界独立证据复核代理 | task-packets、blueprint、独立复核与 provenance |
| writing-chapters、writing-core | 在确认后编写单一主稿，区分实现、已有结果、目标和计划 | 唯一 chapters 文件，正文约 7,322 中文字 |
| evidence-driven-writing、literature-review | 先核对工程事实，再对前馈风格迁移、深度可分离卷积与整数量化添加必要文献支持 | evidence-map、22 项工程/学术来源；不扩展为综述章 |
| experiment-results-planning | 预定义原生网络、帧率、带宽、画质与功耗的后续测量口径；不生成虚构结果 | experiment-protocol、table-schema、source-metrics、traceability |
| figures-diagram | 形成可追溯的数据流图及后续矢量图绘制要求 | 正文 ASCII 架构图、architecture_prompt、data-manifest；未调用图像生成 |
| peer-review、verification | 规范审查、独立事实审查、修订后质量门禁与定向检查 | review 文档、verify_report.ps1；命令和结果见最终复核记录 |
| pdf | 读取更正版指南赛题一，核对页码、表格和图文 | 定向文本及第 10—13 页目视检查；渲染图仅为临时检查材料 |

已消费资料：当前核心 RTL 的定向片段、接口/定点规格、Python Golden 与 manifest、ISP/QAT 的小型 JSON、既有 Vivado/Efinity 简报、用户提供板卡信息、更正版指南赛题一及三篇原始论文摘要。所有关键事实按来源分层，没有把不同平台和测试规模的结果拼接为系统验收结论。

刻意未使用：大型仿真临时目录、波形、设计 checkpoint、完整工具日志；不需要新运行结果即可完成架构报告。未使用 LaTeX、Word、PPT 和图片生成能力，因为用户只要求 Markdown，且已允许未完成图表预留空位。未计算文件哈希。

本轮验证：自定义检查通过，确认 8 节、55 个有效本地链接、22 项参考资料、12 个独立占位、正文 7,322 中文字；ISP/QAT/model 数据与既有源 JSON 一致。写作技能草稿质量门禁通过；语言检查 1—5b 项均为 OK，过滤表格、公式与代码图后的段落间距问题为 0。

剩余工程风险：I3 全系统资源与时序尚无闭合证据；真实原生尺寸网络、持续 15 fps、板级 IP/CPU 集成、模型泛化画质和多风格切换尚待实现或测试。正文保留这些问题及对应占位，不因报告交付而标记硬件任务完成。
