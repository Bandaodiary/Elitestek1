# 方法与证据追溯

2026-09-15优先映射：C39窄舍入→原始9,775接受/9,762退休RTL miter与六lane PNR；操作数共享解码→11,016比较、187作业双回压和纯host PNR；双窗口→512/1024原始103配置/10,680请求；行融合/AXI/帧租约→三模型与640×480六帧；Sapphire裁剪→同版S0/S2 MAP及真实联合PNR/公开接口检查。来源统一为E20—E24。下面旧R1映射只作为历史，不能支撑当前架构描述。

| 方法内容 | 实现模块 | 既有证据 | 报告位置 | 可作结论 |
|---|---|---|---|---|
| RAW/ISP定点 | r1_isp、RTL video | E04/E09 | §3、§6 | 合成输入的算术/重建验证，不是镜头标定 |
| INT8与BN折叠 | model/quant/engine | E05/E10/E11/E12 | §3、§4、§6 | 功能训练与有限位精确，不是最终风格质量 |
| 共享计算与固定bank | engine/tensor adapter | E06/E07/E12 | §4、§5 | 22阶段有界交接，不是native15fps |
| AXI与帧管理 | reader/writer/arbiter/control | E08/E13/E16 | §5、§6 | 已测协议路径和小帧生命周期 |
| 平台移植 | vendor seam/packed affine | E15/E16 | §6、§7 | 部分C4探针map/PNR，I3全板待补 |
| 高吞吐候选 | cache/burst/MLP | E17 | §6、§7 | 模型方向与局部验证，未闭合端到端 |
