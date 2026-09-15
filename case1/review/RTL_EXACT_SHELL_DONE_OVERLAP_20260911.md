# exact-burst 完成脉冲与新请求重叠

本轮扩展真实 exact-burst testbench，不修改生产 RTL。

完成原有数据/取消/重试检查后，先发起一次维护请求并拉低请求重新武装。
等其真实注册 done 为高的周期，再发起第二次请求；在接纳上升沿断言旧
done 仍为高，确保不是普通的间隔很久后重试。之后要求完成计数增加 2，
再等待 12 周期检查无重复完成且最终 quiescent。整个过程不 force 内部
完成信号。

## 结果

- `exact_done_flush_20260911`：flush，10.269 秒，退出码 0。
- `exact_done_abort_20260911`：abort，前置包含混合维护场景，10.242 秒，
  退出码 0。

两项 detached xsim 均通过，runner 强制检查对应模式唯一的
`C1_EXACT_SHELL_DONE_OVERLAP_PASS ... requests=2 completions=2`。临时
工程目录均已确认清理。未重跑全量 Icarus（最近 597）或 Efinity。

## 语义与范围

与前两轮的 pending 期间重复请求不同，旧操作已产生完成脉冲后的新请求
应当作为新的操作完成，不能吞掉它。本轮证明了这个注册完成重叠边界。
它不等于“子层最后一个 ACK 正被父层汇合的同一沿又来请求”，后者更早
一拍；也未覆盖所有数据在途和子层确认错开组合。普通非 burst seam 的
维护调度仍需单独审查。
