# 可复用列读 AXI 端点

日期：2026-09-11。

新增生产文件 `rtl/dma/c1_column_cache_owned_exact_burst_shell.sv`，将此前测试平台的所有者与缓存/补行连接迁移为可实例化 RTL。该封装不包含厂商原语、DDR PHY、CPU 或外部 AXI 仲裁器。

## 接口与责任

- 默认 `ENABLE_OWNER=1`，内部包含 `c1_column_transaction_owner` 和 `c1_window_line_cache_c8_exact_burst_shell`。后者强制 COLUMN_MODE=1、PRECLAMPED_TAP_COORDS=0。
- `tap_x/tap_y` 是有符号逻辑列坐标和中心 y，不是预夹取后的标量 tap；每个成功请求返回 top/center/bottom 三个 C8，共 192 bit。
- 请求被缓存接纳前不向缓存发送维护脉冲；维护期间迟到请求可本地错误退休；维护完成联合后端 ACK、后端排空与上游响应退休。
- 配置 VALID 与 READY 同时门控。`config_valid` 反映后端配置，不等价于端点 idle；缓存取消后可能已经清除配置，但端点仍在保持上游响应。
- AXI 只有 AR/R，是 ID-less 保序读取接口。独立逻辑事务、burst outstanding 和 refill 计数继续分别输出。
- `perf_cache_rsp_count` 继承旧后端定义，统计补行字而非 192-bit 列响应，不应拿它当列事务数。
- `ENABLE_OWNER=0` 仅保留直接列连接作为对照，不切换为标量 ABI。DATA_W 仍仅支持 64，由内部后端参数检查约束。
- 只支持整个域排空后的共同复位，不提供带 AXI 债务的独立热复位恢复。

## 实现与验证

`tb_c1_column_cache_exact_axi` 删除了重复的所有者接线，直接实例化新端点。端点内部唯一 `u_backend` 同时用于开启和关闭所有者配置，便于保留原有补行、epoch、实际 bank 并行读的检查。

四个最终 xsim 运行均 complete、exit 0：

| RunId | 覆盖 |
| --- | --- |
| owned_shell_word_20260911_final | 所有者开启、word FIFO、skid=2；12种取消、2种RRESP错误及正确列数据 |
| owned_shell_beat_20260911_final | 所有者开启、beat FIFO、skid=3；相同功能覆盖 |
| owned_shell_epoch_20260911_final | 所有者开启、2-bit epoch 耗尽不回绕、99字排空、整域复位后恢复 |
| owned_shell_direct_20260911_final | 所有者关闭的直接列连接兼容性 |

运行器继续验证唯一 OWNER 配置标记和各场景标记，不以退出码单独认定通过。全部通过 WMI 隐藏 worker 脱离 Codex Windows job 运行，结束清理临时工程，只保存小型状态/日志。本轮未重跑完整 Icarus 套件，未运行综合、布局布线或板测；“可综合 RTL”指实现形式，不是新增物理综合通过的声明。

## 下一集成边界

生产 SoC 仍使用既有标量/缓存桥。本端点不是该桥的直接替换：它只有列读取，而 adapter 的非窗口读取、结果写回、packed write、描述符访问等仍需要原通路。

后续需将 adapter 列接口接到本端点，给列端点与普通读写桥建立显式 AXI 所有权；维护完成需包含两条通路、写响应及 adapter 的共同排空。不能把单端点的 abort_done 直接当作整机完成。需再做单一测试中 adapter→端点→AXI 的完整算子/帧数据验证，然后才评估整机吞吐。当前未证明 15 fps，未有新增 Efinity 资源或时序结果。
