# 子确认汇合与新请求碰撞：提前完成修复

## 复现与原因

新增真实接口定向测试：父层 pending，两个子确认已到达/被记住，但注册
done 尚未输出；在下一上升沿发出同类新请求。请求重新武装后直接转发给
两个子层，它们会开始或继续维护。旧 RTL 却在同一沿用旧确认清 pending、
输出 done，导致父层完成时子维护仍 busy。

修复前 `exact_join_flush_before_20260911`、`exact_join_abort_before_20260911`
均失败，诊断为 `parent completed while newly forwarded maintenance was still busy`。
这不同于上轮已验证的“注册 done 已经为高后再发请求”。

## RTL 修改

`rtl/dma/c1_window_line_cache_c8_exact_burst_shell.sv`：新 abort/flush 边沿
出现时，优先清除本类旧子确认记录、保持 pending；该周期不采入旧子 done，
也不完成父层汇合。随后等待这次转发请求对应的子确认后再完成。

这与上层 burst client 的修复不同：上层在 pending 期间把子请求持续拉高，
因此必须保留已有 ACK；本层直接转发新的请求边沿，因此必须更新确认归属。
不能把一层的策略机械套到另一层。

## 验证

修复后以下四项 detached xsim 均 complete、退出码 0，包含旧数据路径、
重试数据、取消计数、重复/混合请求、注册 done 重叠及新增汇合重叠检查：

- `exact_join_flush_fixed_20260911`。
- `exact_join_abort_fixed_20260911`。
- `exact_join_mixed_fa_20260911`。
- `exact_join_mixed_af_20260911`。

新增检查要求 pending 内两次同类请求只完成一次、done 时已排空；前一轮
done 脉冲出现后新发请求的检查仍要求两个独立完成。这两条契约同时通过。
runner 强制检查本模式唯一的 `C1_EXACT_SHELL_JOIN_OVERLAP_PASS`。

上层回归 `cache_join_parent_default_20260911` 和
`cache_join_parent_packed_20260911`（PackedWrites+BeatFifo）也均通过，
包含重复 abort/flush 确认保持验证。八个运行临时工程目录均已确认清理，
不影响其他会话进程。

## 尚待完成

本轮生产 RTL 已改，未重跑全量 Icarus（最近 597 是修改前结果）、整机
APB 恢复 golden 或 Efinity。任意子确认错开、多次请求连续到达和普通
非 burst cache seam 仍需审查，不能因六项定向通过而宣称整个架构完成。
