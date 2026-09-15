# 优化引擎正常任务间的权重代数切换

原 testbench 检查运行中 generation 改变报错，但没有“正常完成后更换
权重、再次成功计算”的完整数值场景。本轮在第一任务完成后、所有故障
注入之前加入第二任务，中间没有 reset 或 abort。

generation 从 9 改为 10，DW stage 18 的各通道中心权重由 +1 改为 −1。
scoreboard 的该层预期算术同步按新权重计算，其他层仍用原期望；完整
运行 22 阶段，检查每层累计输出为原来的两倍，总计 44 阶段/1672 输出。
此 bench 为逐层独立输入的 engine 测试，不是将上一层输出逐层送入下一
层的整机训练模型 golden。之后恢复原 fixture，继续既有故障/取消检查。

## 已验证

- `engine_generation_direct11_20260911`：DW cache=1，MAC overlap=1。
- `engine_generation_direct00_20260911`：两项关闭对照。

两项独立 xsim 均 complete/done、exit_code=0；runner 强制要求唯一
changed-weight reload 标记。旧有 8 次取消、6 次故障检查仍通过。
对应临时工程已清理。最初探索 run `engine_generation11_20260911`
把新任务放在故障注入后，证据较弱，已用上述直接正常切换结果替代。

没有发现需修改生产逻辑的失效问题。本轮只修改 testbench 与 DW-cache
runner；未重跑全量或整机。该结果不证明任意层中途换权重合法，也不
等同于实际参数银行、CPU 和 DDR 的跨任务切换联合验证。
