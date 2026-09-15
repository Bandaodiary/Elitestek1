# 原生显示预取复测与验证脚本修复

日期：2026-09-10。检查当前 `c1_display_prefetch_pair`、两路 XRGB reader、双时钟 line store，以及可选 response FIFO。未修改生产 RTL。

## 当前结果

| 配置 | 像素响应（原图/风格图） | AR（每路） | R（每路） | underflow |
|---|---|---|---|---|
| [默认，无 response FIFO](../logs/native_display_prefetch_runs/review_display_native_base_v2_20260910/status.json) | 307200 / 307200 | 4800 | 76800 | 0 / 0 |
| [response FIFO 开启](../logs/native_display_prefetch_runs/review_display_native_fifo_v2_20260910/status.json) | 307200 / 307200 | 4800 | 76800 | 0 / 0 |

两次均 complete / exit 0，正常完成且 `primed=0`（结束后行缓冲已消费）。测试逐响应比较地址导出的 RGB 图案、检查每行和 4 KiB burst 边界、完整像素数量及地址规划结束行，不是仅依据 AXI 请求次数判定成功。

默认 R 回压周期为 237665/237597，FIFO 配置为 216000/216000；两者均实际覆盖 AR/R 停顿。这些是该 BFM 下的统计，不外推为系统吞吐增益。

## 与真实持续显示的区别

testbench 用 100 MHz core clock、约 71.43 MHz pixel clock；primed 后逐拍同时请求两路完整 640×480 像素，没有强制内部信号。两个 AXI BFM 独立提供数据，没有共享 DDR 仲裁争用、CNN 访存、CPU、真实视频消隐/TMDS 或 DDR PHY。因此本轮证明原生 pair/line-store/FIFO 的正常全帧消费，不证明真实 720p 输出时钟签核、并发显示 QoS 或 15 fps。

## Runner 修复与清理

首轮两个运行在 xvlog 启动前失败：旧脚本将全部 RTL 路径直接放入一条命令，超过 Windows 命令行长度限制，编译器未实际处理 HDL。失败摘要保留，不算通过。

`run_r1_native_display_prefetch_xsim_detached.ps1` 改用私有 `xvlog_sources.f`；新增 finally，删除前核对父目录为 `case1/sim`、目录名符合该 runner 的特定格式。复跑两个配置均成功，并直接检查完整 `run_directory` 已不存在。失败运行也已由 finally 清理。

Vivado/xsim 通过已有 Windows PowerShell breakaway helper 启动，未绑定当前 Windows Job；未请求波形，只保留小型状态和日志。未删除其他历史工程。

下一项关键缺口仍是把合法原生显示需求与 CNN 活动放到实际共享 fabric 中，测量最大服务空窗及帧周期；本次两个独立 BFM 的通过不能代替这项验证。
