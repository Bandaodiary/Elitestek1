# 普通缓存 seam 的维护完成碰撞

本轮审查 `c1_tensor_window_cache_seam`，生产 RTL 未改。它在前端、逻辑
所有者、下游所有者和 refill 排空后，通过串行状态机向一个缓存子层发
维护脉冲，不是 exact shell 的两个子确认汇合架构。

## 新增验证

扩展 `tb_c1_tensor_window_cache_seam.sv`：在原有真实数据/背压/取消检查
完成后，增加四组请求，第二个请求恰在子 cache done 有效、父层 done
尚未注册时到达：flush→flush、flush→abort、abort→flush、abort→abort。
测试读取子层完成只用于对齐刺激，不 force 内部信号。

检查每种被请求的完成各一次、相同 pending 请求合并、混合请求不丢失、
最后 busy=0/quiescent=1；额外等待 12 周期检查无重复完成。四种组合均
通过。该新增段从原数据测试最终取消后的空闲/未配置状态开始，不能用它
替代“仍有在途数据时的所有重复请求相位”验证。

## 执行证据

- `nonburst_maintenance_collision_20260911`：10.268 秒，退出码 0。
- 增加四个唯一标记门槛后，`nonburst_maintenance_final_20260911`：
  9.239 秒，退出码 0。

均使用 WMI detached xsim，原有正常读取、回填、旁路、写入和背压检查
也保留并通过。本轮未跑全量 Icarus（最近 597）或 Efinity。

## 临时文件改进

该较早的 runner 原先没有 finally 清理。本轮增加：已有运行目录拒绝
复用；清理前确认解析后的目录恰是 sim 下的本次唯一 RunId 目录，再用
PowerShell 原生命令删除。两个新运行临时目录均已确认不存在，仅保留
日志与状态；没有清理历史运行目录或其他会话产物。

## 后续

本轮不需要套用 exact shell 的优先级补丁。下一步应将重复/混合请求放到
普通 seam 的前端背压、在途回填及等待逻辑响应阶段，核对数据保持和取消
完成的先后关系；同时避免把空闲事件测试扩大解释为所有传输场景证明。
