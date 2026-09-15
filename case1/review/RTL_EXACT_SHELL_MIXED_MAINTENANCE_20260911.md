# exact-burst 混合维护顺序验证

本轮扩展独立 exact-burst testbench 和 detached runner，生产 RTL 未改。
新增 `-MixedMaintenance`：默认先 flush 后 abort；与 `-RepeatAbort` 组合
时先 abort 后 flush。第二个请求在第一个请求仍 pending、AR 服务关闭
12 周期之后发出，随后开放 AXI 排空。

## 已通过

- `exact_flush_then_abort_20260911`：10.266 秒，退出码 0。
- `exact_abort_then_flush_20260911`：10.251 秒，退出码 0。

两次运行均由现有 WMI detached worker 启动，不绑定 Codex Windows job。
均通过模式唯一标记检查：abort_done=1、flush_done=1、reconfigured=1。
这里是两种完成各一次，不能套用同类重复请求“总共完成一次”的说法。

复用原有真实 AXI BFM 和数据检查：验证 accepted/stale/synthetic 数据
计数、配置失效期间 12 周期无 tap 接纳或新增输出、重新配置后数据正确、
最后 quiescent。两个临时工程目录均已确认不存在。

## 边界

本轮仅覆盖在途请求尚未完成时的两种混合顺序；没有穷举请求与完成同周期、
子层完成错开、重复多次及全部配置组合。未重跑全量 Icarus（最近 597）
或 Efinity。下一步优先检查完成边界的新请求归属及普通非 burst seam 的
维护调度，不能因本轮通过就宣称所有维护路径完成。
