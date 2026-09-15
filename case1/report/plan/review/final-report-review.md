# 最终报告复核记录

## 2026-09-15 C39 草稿双阶段审查

规范审查：用户确认框架下的单份中文Markdown，八节正文，未完成项M01/M02/P01—P07，共9项；未擅自生成Word或虚构补齐板测结果。草稿允许占位，不使用Submission门槛宣布比赛最终验收。

质量审查：控制代理逐段阅读。实际模型18阶段、11/13/17视图、14/15行融合，四AXI主客户端、四输入/三输出租约与当前源一致；RGB入口没有被说成已覆盖RAW/CSI/Debayer。150MHz纯host六帧与100MHz真CPU/DDR资源清楚区分；默认分频2与仿真分频1分别注明。叶级收益未与整体收益相加；工具CDC内部失败、旧解析错误、CPU未执行等限制保留。29个本地链接有效，主要报告的原始工具日志链接已改为可发布指标摘要入口。

实际检查：verify_current_report.ps1通过（8节/6660含摘要汉字/29链接/9占位/18阶段）；skill style_check第1—5b项全为OK。其段落间距提示均为合法Markdown表格相邻行，人工审查不作为错误。写作者已运行草稿质量门，控制代理另在验收provenance更新后复跑。旧verify_report.ps1/source-metrics.json是R1历史证据，不用于当前C39验收。

结论：当前工程报告草稿可交付，板级系统和比赛最终文档尚未验收。未产生新的EDA或画质测量。

复核日期：2026-08-31。状态：报告草稿可交付；板级系统尚未验收。

## 1 规范合规

用户已确认现有框架并允许为未完成工作预留空位。本次交付中文 Markdown 单一主稿，采用八节工程报告结构，未生成 Word、LaTeX 或虚构实验数据。报告包含摘要、算法与软硬件架构、验证与资源边界、后续工作、资料来源及核心 RTL 索引。

正文使用 12 个唯一占位编号：M01—M03 为作者信息及图像材料，P01—P09 为资源、时序、原生网络、吞吐、DDR、采显稳定性、画质、功耗与多风格测试。占位既有索引又有测试口径；因用户授权，不作为草稿质量失败项。没有使用正式提交模式的门禁，不能称为投稿/比赛最终验收文档。

## 2 独立复核意见与修订

| 独立发现 | 主稿最终处理 |
|---|---|
| Resize 实际位于输入帧 DDR 读取之后；当前步进 1.0、相位 0 | 数据流图及正文按源码重画，并说明 leaf 宽度能力不代表主顶层已接入该宽度 |
| 三张量 bank 与 stage index 固定，不是任意 CNN 执行器 | 明确 22 阶段 MicroStyle 路由、残差和拓扑的适用范围 |
| native echo 与 8×8 真参数 handoff 不能合成原生网络 PASS | 分行报告测试对象、规模与限制；不声称 640×480 真网络达到 15 fps |
| 理想带宽模型不是实际总线流量 | 标记 tensor-only、全局复用/打包假设；说明 outstanding 不降低数据字节数 |
| DW 窄壳输入重复且输出观察不足，28 DSP 可能低估 | 不将其作为完整 DW 资源或系统余量依据，不与其他探针相加证明全板可放下 |
| packed 窄壳时序不是运行态 SoC 时序 | 仅保留兼容性通过的结论，不以其高 Fmax 宣称系统时序闭合 |
| 统一 64 MAC/拍模型不等于混合引擎严格下界 | 将其定位为归一化敏感性估计，说明 DW 与 dot 的硬件结构不同 |
| 状态 OSD 不是实测 FPS；有限缓冲无法永久吸收速率差 | 明确 FPS 测量、丢帧/保留策略与重复显示均须独立验证 |

原始独立审核文件保留 DONE_WITH_CONCERNS；本表记录主代理对意见的处理，不伪称独立审查者复批。

## 3 实际执行的检查

自定义报告检查从 UTF-8 文本加载执行，避免 Windows PowerShell 5 对无 BOM 中文脚本的编码差异：

```powershell
$checker = Get-Content -Raw -Encoding UTF8 -LiteralPath 'case1/report/plan/verify_report.ps1'
& ([scriptblock]::Create($checker)) -ReportRoot 'D:/contest/2026FPGA/yilingsi/case1/report'
```

实际输出：

```text
REPORT_CHECK_PASS sections=8 local_links=55 references=22 placeholders=12 prose_han=7322 bytes=46231
METRIC_CHECK_PASS ISP/QAT/model values agree with existing source JSON; no FPGA runs performed.
```

技能的草稿质量门禁以独立 PowerShell 进程执行，以其进程退出码判断结果，不使用前一条原生命令遗留的 `$LASTEXITCODE`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:/Users/30982/.codex/skills/research-writing-assistant/scripts/research_quality_gate.ps1' -ProjectPath 'D:/contest/2026FPGA/yilingsi/case1/report'
```

实际结果为 `Research quality gate passed.`，退出码 0。

执行 `style_check.ps1` 后，粗体、列表、禁用连接词、英文套话、主观表述及写作流程泄漏检查均为 OK。其第 6 项按连续非空行提示人工检查，表格、公式和 ASCII 框图自然产生提示；补充状态化检查排除这些合法块后，实际结果为 `PROSE_SPACING_ISSUES=0`。表格列数、标题空行、围栏与显示公式定界符也通过自定义检查。

55 个本地引用均存在；22 项参考资料由 19 项工程证据和 3 项原始论文组成。论文标题/作者/年份核查使用原始论文页面，第三项按所引用 arXiv 预印本年份 2017 著录。报告只借其支持方法背景，不借用论文指标作为本项目结果。

## 4 事实与数值边界

ISP PSNR 来自合成 Bayer 重建，不能代表最终风格质量。QAT 与整数模型的六图验证不是独立留出测试集。既有 Vivado 数据为历史代理设计，Efinity 数据为不同探针或失败/超时状态，均不是完整 Ti60F225I3 板级实现。

理论帧流量、MAC 与帧率预算单独标为计算值；缓存、打包、多 outstanding 和并行 MAC 的优化方向不等于已部署且达到目标。实际 CPU、DDR3 PHY、MIPI、HDMI、PLL 与引脚集成仍属于板级待完成项。

本轮没有新训练、仿真、综合、布局布线或板卡测量，也没有修改 RTL。报告交付完成仅指文档任务完成。
