# 未修复缺陷：捕获表项别名可覆盖当前显示区域

日期：2026-09-11。状态：**已复现，尚未修复**。

## 证据

检查 `c1_r1_soc_control.sv` 的 `CAP_TABLE_RESPONSE`：表项错误、64 位地址高位和输入尺寸检查通过后，直接锁存 writer 配置并拉高 `capture_writer_start` / `capture_begin_frame`。该路径不比较当前显示区域。

在 `tb_c1_r1_soc_control.sv` 增加默认关闭的 `CAPTURE_DISPLAY_ALIAS` 参数。先由真实帧管理器完成首帧显示，再启动第二次捕获；只改变新捕获表项的物理基址，不改变槽位分配及合法尺寸。观察到实际 writer-start / begin-frame 控制信号后立即报错，不通过强制内部状态制造故障。

| 显示模式 | alias 参数 | 新捕获地址 | 被覆盖的当前显示区域 | 实测 |
| --- | --- | --- | --- | --- |
| 原图 | 1 | 0x00100000 | 原图起址 | UNPROTECTED |
| 原图 | 2 | 0x00200000 | 风格图起址 | UNPROTECTED |
| 原图 | 3 | 0x00200010 | 风格图内偏移 16 字节 | UNPROTECTED |
| Resize 预览 | 1 | 0x00300000 | 预览起址 | UNPROTECTED |
| Resize 预览 | 2 | 0x00200000 | 风格图起址 | UNPROTECTED |
| Resize 预览 | 3 | 0x00200010 | 风格图内偏移 16 字节 | UNPROTECTED |

六次均以 `C1_CAPTURE_DISPLAY_ALIAS_UNPROTECTED` 精确失败。外层诊断命令验证的是“缺陷可复现”，不代表安全测试通过。此测试使用控制器的行为外设模型，没有执行真实 DDR 覆盖；证据范围是危险写入命令已经被放行。

原控制器 26 个常规配置重新通过。未修改生产功能逻辑；新失败模式没有加入常规 PASS 清单。已删除本次唯一临时编译镜像 `case1/sim/capture_alias_probe_20260911.vvp`，没有波形或 Vivado 项目。

## 运行方式

用 Icarus 按现有脚本的四个 package 优先顺序编译全部 RTL 和 `tb_c1_r1_soc_control.sv`，top 为 `tb_c1_r1_soc_control`，额外传入：

```text
-Ptb_c1_r1_soc_control.CAPTURE_DISPLAY_ALIAS=1
-Ptb_c1_r1_soc_control.PREVIEW_DISPLAY=0
```

分别测试 alias=1/2/3、preview=0/1。当前预期是安全断言失败，不应配置成常规期望通过用例。修复后应拒绝写入、报告一次错误、保留当前显示，测试才会输出 `C1_CAPTURE_DISPLAY_ALIAS_GUARD_PASS`。正常配置默认 alias=0，不改变已有测试路径。

## 修复要求

1. 在真实捕获 writer-start 之前做范围检查。不能等 CNN 输入预检，因为捕获 DMA 此时已经可能覆盖旧帧。
2. 比较完整有效行范围，不能只比较基址；明确 stride padding 是否允许共享，保持与现有布局规则一致。
3. 使用不会溢出的地址/末端运算，合法 exclusive end=2^32 应被正确表示，越界配置应 fail-closed。
4. 捕获表项及被保护区域必须有稳定快照。检查期间若发生显示换帧，仍须保护尚未退休的旧读范围与新持有范围，不能只看随时变化的 current 元数据。
5. 新检查参与 cancel、table-response 背压、捕获 cleanup 和错误上报，不能产生半启动或吞失表项。
6. 同样审查处理图、预览和 tensor 写入的保护入口。仅修复 capture 不等于实现全系统内存隔离。

预期实现方向是有明确生命周期的活动区域快照与启动前顺序范围检查，而不是在单拍关键路径加入多组大乘法器。后续还需增加邻接不重叠、stride padding、边界溢出、检查中取消/换帧以及拒绝后的恢复测试。

## 当前使用约束

在硬件保护完成前，软件必须为所有同时活动的帧槽与其它内存用途分配互不重叠的合法区域，并在显示仍持有内存时避免将其它槽表项映射至该区域。已有槽号所有权、current 元数据快照和单任务三帧布局检查不能替代这一要求。
