# SoC 预览 DDR 独立 golden 验证

## 本轮补强

上一轮真实 SoC 的预览记分板以 CNN 入口 C8 恢复的 RGB 为参考，能够检查
分流/打包/DDR 写回，但没有在 Python 中直接核对预览内存。本轮从 BFM
物理 DDR 读回并输出 64 条 `C1_NUM_PREVIEW_DDR x y word`；这些不是预期值。

`golden/check_portable_soc_numerical_trace.py` 新增 `--require-preview`。
参考值直接来自既有彩色 RAW10、ISP 与 Resize 软件算法的 resized_image，
不从 RTL 预览输出或 CNN 输出生成。按行序逐像素核对 XRGB8888，包括高
8-bit 必须为零。检查器同时验证唯一完成标记、8-client/8-AW/16-W/8-B、
完成前退休，以及固定 BFM 双槽地址与索引绑定。

当前验证协议是单帧完成，可以在停止前准入第二槽；不能把第二槽的准入
误报为第二帧完成。完成地址必须对应第一个准入的槽。该约束是本测试的
窄范围协议，不是通用多帧日志解析器。旧的无预览日志仍兼容；包含预览
标记却缺少像素的新检查不予认可，不能用历史标记代替缺失的数值证据。

## 证据

运行 `review_soc_preview_golden_20260911`，complete / exit 0，79.927 s。

- Python 独立预览 golden：64 个 DDR 像素通过。
- 原有 golden：64 输入、22 层、836 个 C8 结果、64 个处理图 DDR 像素、
  120 个原图显示像素和 64 个处理图显示像素均通过。
- 共享 AXI：872 AW / 928 W / 872 B，峰值 outstanding=3，W-ahead=44。
- 并发 capture：2 次采集，计算期间 capture AW=10。
- 检查器负向验证 54 项通过，其中新增预览 17 项：错误数值、未知位、缺失、
  重复、乱序、坐标错误、全部删除、完成标记缺失/重复、B 未退休、客户端
  数错误、错用待执行槽、准入缺失/重复、槽地址绑定错误、红蓝交换、以
  风格化结果替代预览图。全部日志变异仅在内存中完成。
- 无预览历史运行 `review_preview_barrier_soc_20260911` 的既有 37 项负向
  测试仍通过，兼容模式保持可用。

命令：

```powershell
& <python.exe> case1/golden/check_portable_soc_numerical_trace.py `
  case1/logs/portable_soc_cache_ddr_bfm_runs/review_soc_preview_golden_20260911 `
  --require-preview --require-video --require-queued-write --require-concurrent-capture
& <python.exe> case1/golden/test_portable_soc_numerical_trace.py `
  case1/logs/portable_soc_cache_ddr_bfm_runs/review_soc_preview_golden_20260911
```

## 边界与清理

本轮未改生产 RTL，只改端到端 testbench 和 Python 检查器；没有重新运行
全量 155 配置，也没有新增 Efinity 资源/时序结论。xsim 由现有 WMI 路径
脱离 Windows Job 启动，无波形，临时目录已自动删除。

仍需完成八客户端环境下的两槽连续完成、预览末 B 阻塞取消、BRESP 错误
恢复，以及预览显示元数据/显示源切换。单帧小图 golden 不证明 15 fps。
