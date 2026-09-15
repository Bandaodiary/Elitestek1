# 大容量显示参数下的坐标扩展修复

## 复现与原因

源尺寸接入顶层后，显示 subsystem 的 FRAME_WIDTH 容量参数可能大于 1024。它的默认 X_BITS 由该容量计算；例如 FRAME_WIDTH=2048 时 X_BITS=11。但固定 640×480 显示布局产生的 prefetch_original_x/styled_x 只有 10 位。

原连接 `prefetch_*_x[X_BITS-1:0]` 此时取到不存在的 bit 10，导致请求坐标含 X，而不是合法的零扩展。新增 STORE_WIDTH=2048 的布局用例在原 RTL 上立即复现：mode=0、x=0、y=120 的首个原图读取坐标不匹配。

## 修复

`c1_r1_display_subsystem` 两路坐标连接改用 `X_BITS'(prefetch_*_x)`。源信号为 unsigned：宽端口明确零扩展，窄端口按位截断。已有完整坐标范围检查保持在截断之前，没有放宽有效坐标或画面容量。

此修复只解决位宽连接，不提供 2048 像素宽的显示能力。prefetch 的 MAX_WIDTH 仍是 min(FRAME_WIDTH,640)，最大高度仍为 480；大图预览仍需独立缩放或完整消费方案。

## 验证

`tb_c1_display_geometry` 对容量 >=640 的构建都检查小图及完整 640×480 边界，不再只对容量恰好等于 640 执行大面板案例。新增 STORE_WIDTH=2048 配置登记默认回归。

修复后四个布局配置全部通过：

- STORE_WIDTH=2048：174,080 次采样，四种模式，8×8 和完整面板边界；
- 异尺寸配置：261,120 次采样；
- 旧 STORE_WIDTH=640：174,080 次采样；
- 小容量 STORE_WIDTH=8：87,040 次采样。

每次采样检查请求有效性、完整源坐标、响应对齐和黑色补边；测试仍为强制 raster/行缓存响应的布局边界验证，不是大分辨率 DDR 吞吐或板级证明。完整 portable SoC Icarus 编译/展开通过：128 源文件、0 errors、603 条工具诊断。

随后全量 Icarus **124 配置符合预期**（包括预期失败检查）。本轮临时镜像和向量已清理，没有 xsim、综合、波形或板测产物。

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_display_geometry -Python D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe
```
