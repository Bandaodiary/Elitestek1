# R2-C30：企业双像素入口与 Resize 调度优化

日期：2026-09-14。本文为开发验证记录，不是板级验收报告。

## 1. 本阶段结论

企业 v1 的真实 Debayer RTL 已接入独立前端仿真；新前端完成不可回压双 RGB 输入、完整视频帧校验、奇数边界 ROI、跨域拆包、Resize 和 RGBX32 AXI 写回。已通过 Icarus、xsim 及 Ti60 MAP。

发现并解决一个真实的调度瓶颈：旧 Resize 串行占用采样槽，使双像素视频输入持续积压；将 FIFO 从 512 加到 1024 仍溢出。允许响应退休与下一请求同拍交接后，512 个双像素记录已通过完整 1920×1080 视频时序的连续两帧测试，峰值 404。

**完整主机候选仍是 C29；C30 是待合入的新前端，不是新的整网性能结果。** R1/C21/C26/C28/C29 源闭包保留，旧设计没有被覆盖。最终审计入口：[检查器](../golden/check_r2_demo_rgb2_evidence.py)、[门禁日志](../logs/r2_c30_gate_20260914_c.log)。

## 2. 企业例程接口：按活动源码核实

基线目录：`D:/contest/Ti60F225_DemoBoard_v4/10_Ti60f225_sc431hai2hdmi_demo/Ti60f225_sc431hai2hdmi_v1`。按 `ti60f225_oob.xml` 直接编译以下五个企业文件，未修改企业目录：

- `rtl/true_dual_port_ram.v`，不是同名的 `rtl/debayer/` 副本。
- `rtl/debayer/rgb_gain.v`、`line_buffer.v`、`raw_to_rgb.v`、`debayer_top_2to1.v`。

实际合同如下：

| 项目 | 已核实结果及接入要求 |
|---|---|
| RAW 输入 | 顶层存在字节交换，Debayer 输入高字节对应先到的 RAW 像素 |
| RGB 输出 | 48 位，低 24 位是左像素、高 24 位是右像素；各自为 RGB，不按 BGR 注释交换 |
| 控制延迟 | 活动路径为 5 级寄存器；DE 与 VALID 重合，没有行内 valid 气泡合同 |
| VS | 正有效消隐同步脉冲，不是首有效像素 SOF |
| 源时钟/节拍 | 工程 SDC 约 70 MHz，每有效拍两个 RGB；不存在 ready |
| 视频周期 | H 为 2+44+960+60=1066 拍，V 为 2+20+1080+20=1122 行，1,196,052 拍/帧，按名义 70 MHz 约 58.53 帧/秒 |
| HDMI 拆分 | 原顶层在另一时钟域交替选择 24 位，不能直接复制这个相位相关选择器作为可靠 CDC |

以上频率来自例程配置/约束及仿真，不是示波器测量。仿真采用相机半周期 7.143 ns、核心半周期 3.333 ns，均有小数舍入。

企业 ISP 的内部灰度结果存在一对像素的水平延迟和左边界瞬态。因此，仅确认上述接口和内部测试区域，不宣称其与项目 Python Debayer 全图位精确等价。真实企业 RTL 测试用灰度斜坡和 RGGB 基色两个输入，独立校验 120 对/240 个内部 RGB 像素；错误 RAW 打包的实际仿真负控被检出。控制检查覆盖 4 帧、256 对输入/输出、810 次沿检查。见[企业合同测试](../golden/run_r2_official_debayer_contract.py)及[结果](../logs/r2_official_debayer_contract_20260914_c.log)。

## 3. 新增模块及数据关系

```text
企业 Debayer：RGB48 + VS/DE/VALID（相机时钟域）
  → c1_r2_rgb2_raster_source：视频行/帧校验，转换 SOF/EOL/EOF
  → c1_r2_camera_pair_ingress：ROI、错误/任务生命周期
      └ c1_r2_async_pixel_fifo_guarded：49 位记录跨域
  → 核心域逐像素 RGB888、坐标、ready/valid
  → c1_r2_resize_overlap_capture
      ├ c1_r2_resize_overlap_pipeline
      │   ├ 既有 pair RAM / line sampler
      │   └ c1_r2_resize_overlap_system：采样交接 + 原双线性插值
      └ 既有 video_capture_rgbx32 / axi_row_write
  → AXI128 DDR 写口及最终 B 排空结果
```

[raster_source](../rtl/r2/c1_r2_rgb2_raster_source.sv) 在源域注册输出。启动时忽略无 VS 的半帧；核验每行像素对数和总行数，并将最后一对源像素扣留到下一个 VS 确认，防止超长末行、额外行或末尾 VS/DE 冲突发生后仍发布成功帧。没有增加 PLL，也没有行内反压。

[pair_ingress](../rtl/r2/c1_r2_camera_pair_ingress.sv) 按 `{有第二像素, 第二RGB, 第一RGB}` 写 49 位 FIFO，可处理奇数 ROI 起点、奇数宽度和单像素尾记录；核心域低像素先出、第二像素随后握手，整条记录最后一个像素消费后才出队。取消会丢弃剩余半条记录，等待源状态与真实 AXI B 排空，不使用逐帧复位清 FIFO。

`FIFO_DEPTH` 和 `cam_peak` 的单位现在是**双像素/单尾记录**，不是标量像素。选用 512 深度，最多容纳约 1024 标量像素。未来接 CPU 页时必须显式标注此单位，不能沿用 C29 的标量像素解释。

[overlap_system](../rtl/r2/c1_r2_resize_overlap_system.sv) 只有两处功能变化：有旧响应可以退休时允许新请求发出；响应退休后，pending 位由同拍新请求是否被接纳决定。旧 metadata 先进入响应缓冲，新 metadata 同拍写入 pending 寄存器。量化、坐标、双线性插值和原有行 RAM 不变。

该优化要求采样器是**寄存响应**，不支持组合零延迟 request→response 接口。两层新 [pipeline](../rtl/r2/c1_r2_resize_overlap_pipeline.sv) / [capture](../rtl/r2/c1_r2_resize_overlap_capture.sv) 只替换对应子模块类型；独立源派生检查已确认这两层没有其他逻辑变化。

## 4. 瓶颈复现与原生尺寸验证

以下均是真实 RTL 运行；保留失败状态，不将失败包装成 PASS：

| 输入/实现 | FIFO 记录数 | 结果 |
|---|---:|---|
| 双像素规范流，旧 Resize | 512 | 第 6,499 核心周期溢出；614 次请求/响应 |
| 双像素规范流，旧 Resize | 1024 | 第 280,710 周期溢出；34,560 次请求/响应，说明仅加 FIFO 不解决持续积压 |
| 双像素规范流，新 overlap Resize | 256 | 第 5,694 周期溢出，容量仍不足 |
| 双像素规范流，新 overlap Resize | 512 | 两帧正确，峰值 404 |
| 完整 VS/DE 消隐波形，新 overlap Resize | 512 | 两帧正确，峰值 404，无帧间 ready/busy 等待 |

最终原生视频测试 RunId：`c30_demo_rgb2_native512_20260914_a`，耗时 286.31 秒，见 [status](../logs/r2_demo_rgb2_regression_runs/c30_demo_rgb2_native512_20260914_a/status.json)。

输入为 1920×1080，裁剪 `(240,0,1440,1080)`，输出 640×480。监视器逐标量检查 3,110,400 个 ROI 像素的 RGB/坐标；实际 AXI W 口逐字检查 153,600 个 128 位 RGBX32 数据，总共 9,600 次 AW 和 9,600 次 B。两帧完成周期为 2,565,490 和 5,128,766，源 SOF 间隔严格等于 1,196,052 个相机周期。见[原始小日志](../logs/r2_demo_rgb2_regression_runs/c30_demo_rgb2_native512_20260914_a/result.log)。

此测试有真实 Resize、Capture 和 AXI memory BFM（合计每两个核心周期一个 128 位服务拍、基础延迟 20、AW 等待 W 模式 2），**没有 CNN、CPU、双路 scanout 或 DDR PHY 争用**。404/512 是该条件下峰值，不是任何负载下的容量保证。

## 5. 正确性、异常与工具验证

- 最终 Icarus 普通 ROI / 奇数 ROI 各两种背压，每组 30 好帧、28 个预期坏帧。14 类故障分别覆盖短行、超长行、DE/VALID 错配、FIFO 溢出、带 B 债务取消、无结束 VS 超时、未接纳源错、AXI B 错、未接纳溢出、晚取消、半记录取消、早 VS、额外行、VS/DE 冲突；每次错误后无复位恢复。
- B 债务特意保持 64 拍，完成不得提前；第二像素保持 4 拍后取消；三类末尾错误不得提交最后 ROI 像素。实际写数据与 Python golden 比较，不是只看 done。
- 真正企业五文件路径：Icarus 两种背压共 4 好帧，xsim 一种背压 2 好帧。选 20×20 测试图内部 ROI `(4,4,12,12)`→8×8，避免将已知 ISP 左边缘瞬态伪装为 golden 一致。
- xsim 另跑 14 故障/29 结果，数据/结果周期与相同配置 Icarus 一致。最终 RunId 为 `c30_demo_rgb2_vendor_xsim_20260914_c`、`c30_demo_rgb2_fault_xsim_20260914_c`，均 Job=false。
- Resize 独立 Python golden：11 配置×两种 abort-reset 接法，每种 207 输出、3 配置拒绝、4 次 abort，并实际观察 124 次同拍替换。见[Resize 结果](../logs/r2_resize_overlap_20260914_b.log)。
- 源域独立沿级 oracle：宽 2/6、高 1/3、VS 正/负极性共 8 配置，覆盖启动半帧、VS 与最后 DE 下降同拍、尾记录跨消隐保持及 reset 清除。每配置 6 成功帧、3 错误。见[边界结果](../logs/r2_rgb2_raster_edges_20260914_a.log)。
- 审计同时拒绝六种内存中日志篡改；原 C29 44 源派生门禁继续通过。

## 6. Ti60 资源测量与未完成边界

对照固定相同 512 深度、原生 ROI/Resize，MAP 探针的所有外部数据/握手保持可观察，不用常量图删掉通路。

| MAP 前端探针 | LUT4 | FF | RAM block | DSP |
|---|---:|---:|---:|---:|
| C28 guarded 单像素入口 + 旧 Resize | 1,887 | 1,642 | 19 | 18 |
| C30 raster + 双像素入口 + overlap Resize | 2,067 | 1,772 | 20 | 18 |
| 差额 | +180 | +130 | +1 | 0 |

新 FIFO 本体映射为 3 RAM，旧标量 FIFO 为 2 RAM。新探针闭包为 14 个生产源加 probe；入口见[SV](../efinity/c1_ti60_r2_rgb2_capture512.sv)、[XML](../efinity/c1_ti60_r2_rgb2_capture512.xml)。对照/新 RunId 分别为 `c30_capture_safe512_map_20260914_a` / `c30_rgb2_capture512_map_20260914_a`。

**这只是 MAP，不含 C30 PNR/CDC 签核，也不含企业 Debayer/CPU/PHY。LUT4 差额不能当作 XLR 差额加到 C29 PNR。** C29 主机仍为 42,777 XLR/144 RAM/130 DSP；与必要官方平台粗加后只余 662 XLR/7 RAM，联合工程仍有实质容量风险。

## 7. 整网帧率更新与下一步

另行保留的 C26 原生六帧 xsim 已在原隔离进程下完成，耗时 9,903.078 秒，13 个 1080p 源帧/13 次 Capture、6 次正确 CNN、12,902,400 显示像素，最慢完成间隔 9,793,756 核心周期。按 150 MHz 模型约 **15.31588 fps**，见[独立审计](../logs/r2_c26_native_gate_20260914_a.log)。这不是 C30/C29 原生帧率，也不消除 C26 当时的物理 CDC 风险。

下一阶段 C31 按以下顺序推进：

1. 保留 C29，创建独立双像素完整主机封装；相机源时钟约 70 MHz，核心约 150 MHz，明确 FIFO 统计单位/能力寄存器，继续按最终结果完成帧池 lease。
2. 对约 58.5 fps 的真实输入做显式帧接纳方案，评估每隔一帧接纳（约 29.26 fps）和负载跳帧。不能假设旧约 30 fps 源的 15.32 fps 整网裕量在采集流量近翻倍后仍成立；不在帧内反压摄像头。
3. 联合 CNN/CPU/双 scanout 的 BFM 小图与故障回归，再测原生稳态间隔；同时做新完整闭包 Ti60 PNR、逐端点 CDC/时序及容量检查。
4. 基于活动企业工程接入 Sapphire/DDR/视频时钟和外设，避免直接拼接视频与 SoC 全工程或新增 PLL；实际 CSI/DDR PHY/HDMI/复位和板测仍待完成。

## 8. 调试记录与存储管理

早期 128 字符向量路径被长私有目录截断，随后 xsim 对动态 string 拼接的 `$readmemh` 路径又出现问题。最终统一 512 字符 packed 路径，并在仿真开始前检查文件可打开、源/期望数组没有 X。早期无效向量失败不用于瓶颈归因；后续有效输入下的 512/1024 溢出才是证据。

xsim b 数值通过，但运行器漏保留半记录取消标记；统一门禁因此正确拒绝。只修正小日志筛选/实际配置验收，使用新 RunId c 重跑，不改写旧 status 或补造旧日志。

本阶段 20 个成功/失败运行均已终结，私有仿真工程和 MAP 临时目录已清理，仅保留 88 个运行文本、214,415 字节（约 209.4 KiB；不含源码、独立叶日志及本报告）。没有波形，未删除用户源文件或旧基线。最新可重跑门禁会重新核实这些路径，详见持续[开发日志](../DEVELOPMENT_LOG.md)。
