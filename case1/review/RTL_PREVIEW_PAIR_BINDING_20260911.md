# 第三路预览的配对所有权接入方案与控制验证

日期：2026-09-11。本轮确定可复用现有 output-slot 所有权，新增真实控制
组合测试；没有把第三路接入 portable SoC，未改生产 RTL。

## 选择：同一槽索引，两块不同内存

现有 `c1_frame_manager` 管理三个采集槽和两个输出槽。输出槽已有
PROCESSING → READY_DISPLAY → DISPLAY → FREE 的生命周期，并通过
source index/frame ID 绑定采集原图。预览不需要独立分配器：

- `preview_slot = nn_output_index`，处理后图像也使用此输出索引；
- preview[0/1] 与 processed[0/1] 是四块不同 DDR 区域，不是同一地址；
- 一次任务的预览与计算一起启动，只有联合完成且相关写事务全退休，才
  向 manager 提交 nn_done；
- `display_output_index` 同时选择 processed 和 preview 的元数据；
- 旧显示读流量完全排空、准许换帧后，两块内存随同一输出槽释放。

这样既保留原始采集图，也能增加缩放后、进入 CNN 前的预览图，并避免独立
分配器之间帧号和释放顺序不一致。不能因“索引相同”而省略地址范围检查。

## 源码依据与不可绕过的限制

`c1_frame_manager.sv` 的 nn_grant 同时锁住 input/output，nn_done 将二者
置为待显示；display_vsync 才释放旧显示 pair 并选择新 pair。
`c1_r1_runtime_join.sv` 要求双方 done 且 busy 均为零才成功完成。

manager 不知道物理 AXI 或地址：abort 会逻辑释放非显示槽，不能用该 FREE
状态证明可立即重写。仍须沿用 SoC 外层取消/排空准入屏障，把 preview_busy
纳入屏障，且禁止尚未排空的旧预览/显示事务跨入新任务。

现有 `c1_r1_soc_control.sv` 已有受条件限制的 manager_display_vsync 与
pending pair 元数据，后续应扩展这条路径，不向 manager 直接接裸 VSYNC。
同时需处理 grant 后子模块 readiness 变化：槽已分配不等于双方启动握手
已经发生，实际顶层必须保留待启动状态或使用已有联合准入协议。

## 新增控制测试

`tb_c1_preview_pair_ownership.sv` 实例化真实 frame manager 和 runtime join。
计算/预览 busy/done 以及已排空的显示换帧事件为行为模型，不包含 DMA/DDR。
测试三个任务：

1. 首任务计算先完成，预览持续 busy；八次显示事件不得发布这对图像。
2. 双方完成后显示第一对；第二任务必须获得另一个输出/预览槽。
3. 第二对完成待显示，第三帧已采集；显示+待显示占满两个槽，八周期不得
   再发 grant。允许换帧后才给第三任务分配旧显示槽，frame ID 仍匹配。

实测 exit=0：

`C1_PREVIEW_PAIR_OWNERSHIP_PASS jobs=3 swaps=2 held_preview=8 held_slots=8 paired_index=1 reuse_after_swap=1`

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_preview_pair_ownership -Python <python.exe>
```

新增配置已加入全量 runner，强制要求专属 PASS。本轮仅执行这个配置；
未重跑全量或物理实现。Icarus 临时编译文件和向量由 runner 清理，无波形。
此测试不覆盖 abort 后所有权恢复，也不以行为 preview_busy 替代之前真实
DMA 在途 B 取消的证据；它只验证共享索引的发布/持有/复用顺序。

## 下一步实际接线清单

- 为两个 preview 槽提供独立基址/stride/尺寸元数据，start 和显示发布时
  做快照；与采集、processed、tensor、参数/描述符区域检查互不覆盖。
- Resize 输出接 preview DMA，CNN 接 fork 另一支；新增 preview AXI 写
  master，纳入共享写仲裁、busy/error、QoS 与取消排空。
- 保留单一输出槽分配；把真实计算与 preview 完成接入 joint completion，
  错误/取消禁止发布，所有 DMA 排空前禁止重新分配。
- pending/display pair 增加 preview 元数据与显示源选择，换帧继续经过
  旧显示读事务排空屏障，不能只依赖帧号或 VSYNC。
- 跑完整 SoC golden：同时比较 raw、preview、styled，至少跨两个输出槽
  并覆盖显示换帧、计算取消、晚 B 与恢复。完成这些之前不得宣称整机接入。
