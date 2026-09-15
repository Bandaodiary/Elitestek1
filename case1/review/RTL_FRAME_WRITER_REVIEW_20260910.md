# 帧写入 DMA 的 AW/W 独立握手补修

日期：2026-09-10。对应复审 R1 的叶级主机检查。保留现有计算、缓存和软件 ABI，仅修改帧写入 DMA 的发送控制及测试。

## 问题与影响

`rtl/dma/c1_axi_xrgb_frame_writer.sv` 的文件头原本写明 AW/W 独立，但实现仍按 `ST_AW → ST_W → ST_B` 顺序发送。若从机等待 WVALID 才给 AWREADY，主机无法前进。修复外层仲裁器并不能消除叶级主机的这种依赖。

该模块用于 `c1_r1_capture_subsystem` 的采集写入、`c1_r1_boardless_frame_system` 和 `c1_r1_integration_skeleton` 的结果写回，不是孤立的资源探针。

## 修改

- 完整 burst 缓冲完成后，同时具备发送 AW/W 的条件；新增 `aw_done` 和 `w_done`，分别关闭已经完成的通道。
- 数据可以先于地址完成。发送索引仅在 W 握手时推进，末拍以后不重复发送。
- 地址与全部数据都完成后，才进入 B 响应阶段；只有 B 完成才允许结束帧或准备下一 burst。
- 取消不撤回已呈现的 VALID。即使数据已发送而地址尚未被接收，也必须完成地址和 B 排空。
- 保留最多 16 beats、4 KiB 边界切分、XRGB8888 格式、配置预检、错误和取消合同。没有新增 RAM、MAC 或 outstanding 能力，也不改变寄存器映射。

## 验证

`sim/tb_c1_frame_writer_aw_w_independent.sv` 新增独立的地址/数据计分板，不依赖先收到 AW 才检查 W：

1. 从机的 AWREADY 依赖 WVALID。
2. 全部 W 先完成，地址继续停顿 8 个周期。
3. AW 先完成，W 延迟。
4. AW/W 同拍可接受。
5. W 已完成、AW 尚未完成时取消，再正常重启。

正常帧从 `0xFF0` 起写 64 个像素，要求精确拆成 1+15 beats 两个 burst；逐拍检查数据、WSTRB、WLAST、地址、长度、停顿保持和完成计数。

新增测试通过：`cases=6 cancel=1 w_before_aw=23`。

原有 `tb_c1_axi_xrgb_frame_writer` 的存储模型没有早到 W 的缓冲，却随机给 WREADY 并把早到 W 判为错误。现明确把它设为“先接地址”的合法从机模型，只有地址已知才给 WREADY；不删除数据、取消、边界和响应检查。早到 W 由上述独立测试覆盖。

原有测试通过：`normal_frames=3 cancel_cases=6 restart=1 bursts=16`。

统一入口 `scripts/run_iverilog_review_fixes.ps1` 已加入两个用例，本轮结果：

```text
C1_REVIEW_FIXES_REGRESSION_PASS configurations=47
```

两个整系统 xsim 运行的结果见下节。轻量测试不生成波形，临时 VVP 和生成向量由脚本清理。

## 整系统回归

两个 worker 均通过，Vivado/xsim 经既有 breakaway 启动机制脱离当前 Windows Job：

| 运行 | 结果与范围 |
|---|---|
| [真实参数 8×8](../logs/portable_soc_cache_ddr_bfm_runs/writer_independent_trained_20260910/status.json) | complete / exit 0，72.929 s；22 descriptors，weight AR=66，done=1、swap=1、drop=0；AXI AW/W/B=852/868/852，AR/R=1119/2199 |
| [显示错误恢复 8×8](../logs/portable_soc_cache_ddr_bfm_runs/writer_independent_recovery_20260910/status.json) | complete / exit 0，82.963 s；FIFO 与 read skid 开启，injected=1、errors=1、done=2、descriptors=44，验证报错后排空及第二任务恢复 |

上述秒数是工具运行耗时，不是硬件帧时间。真实参数用例证明小图参数加载和整系统生命周期，不是 native 全图逐像素数值签核。运行结束后直接检查，两处 `run_directory` 均已不存在，只保留小型状态与日志。

## 边界

这项优化去除了协议死锁和地址/数据串行等待，没有改变“缓存一个 burst、等待其 B 后再处理下一个”的结构。不能据此宣称达到 15 fps，也不能替代 native 640×480 的逐像素 golden、持续显示服务或 Ti60 全系统资源/时序验证。
