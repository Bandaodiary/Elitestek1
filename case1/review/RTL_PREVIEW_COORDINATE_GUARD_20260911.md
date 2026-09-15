# 预览/CNN 分叉前的坐标契约修复

日期：2026-09-11。

## 复现与根因

`c1_r1_preview_dma` 将 Resize token 的 x/y 原样交给 fork，预览 writer
只依据像素顺序和帧行标志写入，不检查这些坐标。因此一个坐标错误但像素
数据及标志合法的 token 可以进入 CNN，而预览写入仍表现为正常顺序。

先扩展原真实 preview DMA testbench，在首像素分别注入 x=1 与 y=1。
修复前定向回归失败：`CNN token mismatch n=0`，时间 2075000；不是仅
根据源码推断。此次失败的 Icarus 临时文件已由 runner 清理。

## 生产 RTL 修复

在 `c1_r1_preview_dma.sv` 中：

- start 时锁存 width/height，同时清零期望 x/y；
- 仅在正常输入握手后推进期望坐标，按锁存 width 换行；背压期间不推进；
- 分叉前比较输入坐标与期望值，并检查期望坐标未超出尺寸；
- 错误 token 可被源接口握手一次以锁存 error，但不会置 fork 的输入 VALID，
  所以不送往 CNN 或预览 writer；后续输入因 sticky error 停止接收；
- 沿用既有契约，由上层取消整个任务；不把错误自动视作成功 DONE，不复位
  AXI writer，不撤销已有 AXI 承诺或已有 CNN 停顿 token。

配置检查和取消优先规则不变。本修复增加坐标寄存器及比较逻辑，没有声称
零资源开销、物理时序通过或带来吞吐收益。它也不是 SOF/EOL/EOF 完整前置
检查器：原 writer 的标志错误检查仍保留，未改变其错误通知契约。

## 验证范围

默认地址区间与上一轮受限区间两配置分别完成 8/11 个任务，均通过：

- 两类首像素坐标故障：输入恰好接受 1 个，CNN 输出/AW/W 均为零；
- error 后仍 busy，收到取消后 done+aborted，error 保留；
- 两次故障后不复位，再完成一帧正确数据，验证计数器/error 重置；
- 原正常帧、晚 B、CNN EOF 停顿、取消、BRESP 错误、配置拒绝继续通过；
- 正常任务在 start 后立即修改实时 width/height，验证坐标检查使用快照。

runner 对两配置均要求 `C1_PREVIEW_COORDINATE_GUARD_PASS`，不能仅凭通用
PASS 漏掉新增场景。此定向测试目前为单行帧，不宣称完整多行故障注入覆盖，
也没有证明任意时刻、任意下游故障组合的形式性质。

修复后重新执行全量回归：142 配置全部通过。queued-write 整机 Icarus
编译：131 sources、0 errors、608 条工具诊断，并非 warning-free。本轮
未启动 Vivado、未生成波形；Icarus 临时编译文件及生成向量由 runner 清理。

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_r1_preview_dma -Python <python.exe>
```

第三预览通道仍是待整机集成的基础模块，不能据此声称已经接好共享 DDR、
动态帧所有权与显示选择。该架构目标仍保持开放。
