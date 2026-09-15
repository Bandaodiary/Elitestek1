# 阶段配置银行提交/取消/读取边界

对 32-bit × 16-word 描述符序列化分支新增两个定向场景：

1. write_word=15，最后一个字即将写入时取消。
2. narrow_write_prepared=1，全部字已写完、即将接纳命令并提交时取消。

均使用真实 valid/abort 输入，不 force 内部状态；内部信号仅用于定位
激励相位。测试要求 ready 被取消压低，serializer/prepared/loading 清除，
没有 commit/error，旧 active bank/count/generation 不变。

取消同一拍还提交对旧银行第 0 个描述符的真实读请求，检查恰好返回一次
正确描述符和旧 generation。之后观察 20 周期没有延迟提交，完整检查旧
银行内容；两个场景结束后无复位提交新批次，并检查新内容。

Icarus 定向 1 配置通过，退出码 0；新增两个 boundary PASS 和 restart
PASS 均观察到。既有测试继续覆盖协议错误、普通提交与读取重叠、代数
回绕。本轮只增强 testbench/runner，没有发现需修改的生产逻辑。

范围仅为当前 testbench 使用的同步窄 RAM 分支；未重跑全量、整机或综合。
取消不承诺 shadow RAM 每一位不被写入：本模块依赖不发布被取消的银行，
而不是对已经写入的无效 shadow 数据执行回滚。
