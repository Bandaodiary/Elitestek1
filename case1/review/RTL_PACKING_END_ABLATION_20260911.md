# Packing 与 end-marker 的独立收益

Run `apb_engine11_pack_noend_20260911`（独立 worker 20340）保持 DW 缓存、
MAC 预取、结果写流水化、packing 开启，只关闭 TensorWriteEnd。最终
complete/done、exit_code=0，完整 numerical golden 与 APB/延迟源确认
恢复检查通过：22 阶段、836 C8、64 DDR 像素及 120+64 显示像素匹配。
临时工程目录已确认不存在。

## 成功小图任务对比

| 配置 | elapsed | ST_WRITE_RSP | 整段 AXI AW/B | 整段 W beats |
|---|---:|---:|---:|---:|
| 写流水化，无 packing | 71363 | 14310 | 874/874 | 924 |
| 写流水化 + packing，无 end | 68547 | 22477 | 628/628 | 770 |
| 写流水化 + packing + end | 65670 | 19913 | 628/628 | 767 |

首尾两行引用前一轮已验证 runs。packing 相对流水化减少 2816 周期
（约 3.95%）；在 packing 上加 end 再减少 2877 周期（约 4.20%）。
逻辑 tensor 请求仍为读 3620/写 836，feed=896，后两项结果背压均为
120。统计窗口不同：elapsed/state 属于成功 job=2；AXI 总数属于整段
场景，不应用两者直接计算单事务平均延迟。

## 尾包契约检查

当前 packing bridge 给写引擎配置 BUILD_TIMEOUT_CYCLES=8，并通过
USE_REQUEST_END 控制 marker。因此缺 marker 不会无限等下一项；这里
的 8 是构包超时参数，不是 end-to-end 总线响应上界。

重新执行 `tb_c1_tensor_packing_memory` 4 配置通过，涵盖两种 AW/W
顺序与 end 开/关。既有激励包含部分字节写、同 lane 重复写、跨边界、
未提供 end 的尾批次、显式结束的相邻不同批次、读等待全部写确认和
非对齐请求拒绝。该单元尾包测试没有直接执行系统 abort；本次整机
恢复验证也不等同于穷尽每种半包取消相位。

## 结论

end-marker 在此输入下减少了等待，但不能通过 AW 数量单独解释全部
差值；少量 W beat 差异也表明时序相位会影响构包结果。保留 marker
及超时兜底是当前候选配置，尚不修改默认开关。下一阶段需更大输入和
计算过程中取消、参数切换等验证，不能据小图直接声称 15 fps。

本轮没有修改生产 RTL，仅完成对照实验并更新证据。
