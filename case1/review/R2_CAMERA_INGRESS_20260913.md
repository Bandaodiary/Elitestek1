# R2-C25：不可回压相机入口、ROI与跨时钟缓冲

日期：2026-09-13。原R1/C18/C21/C22/C24生产源码保留。**当前完整CNN主机入口仍为C24；本轮新增前端已接到真实Resize/Capture，但尚未接入完整帧池/CNN/CPU主机。**

## 1. 实现与接口

新增 [c1_r2_camera_ingress.sv](../rtl/r2/c1_r2_camera_ingress.sv) 和 [c1_r2_async_pixel_fifo.sv](../rtl/r2/c1_r2_async_pixel_fifo.sv)：

```text
cam_clk：不可回压RGB流 → 全源帧标记检查 → 固定ROI → 双时钟同步读RAM
                                      └─ 暂存ROI末像素，等待全源帧校验
clk：任务接纳/取消/排空控制 ←───────────────┘
                 ↓ 可回压ROI像素
        C24 Resize → Capture打包/AXI写 → 实际B响应排空
                 ↓ job_done
        前端排空确认 → result_valid/admitted/failed/code/tag
```

默认源1920×1080，RGB域居中裁剪1440×1080（X=240、Y=0），接640×480双线性Resize。尺寸/ROI是综合参数，不是新增CPU寄存器。一个`cam_valid`表示一个24位RGB像素，源没有ready输入；不包含RAW10解包、Debayer或官方2-pixel/clock适配器。

| 接口组 | 所属时钟与合同 |
| --- | --- |
| `cam_valid/sof/eol/eof/error/rgb` | 相机域；标记附在有效像素上，源不等待下游。空白期的上游error也能终止未完成帧 |
| `job_valid/ready/tag`、`s_valid/ready/rgb/x/y/sof/eol/eof` | 核心域；一次任务拥有一帧ROI，像素遵守背压。接纳前失败可撤销未握手任务 |
| `job_cancel`、`job_done/job_failed` | 核心域；done必须是下游真实完成握手，不能用“已发最后一个W”代替B排空 |
| `result_valid/admitted/failed/code/tag` | 核心域；FIFO与已接纳下游任务均结束后发布一拍事件。接收方必须能接事件，不能任意背压 |
| `cam_seen/skipped/peak/busy` | 相机域观察量，不能直接当CPU域一致计数器读取；CPU遥测需另加快照CDC |

异步FIFO用同步读双时钟SDP和一个预取输出寄存器。RAM容量是DEPTH，另有一个预取像素；写域`cam_peak`是由同步读指针估算的保守RAM水位，不包含该寄存器。数据存储不复位，只同步复位两端指针；运行中的错误恢复靠读取排空，**不单独复位任一时钟域**。全局复位要求两域都采到复位，两个时钟必须运行。

## 2. 帧原子性与恢复

一帧在途时，新SOF整帧跳过，不允许把后一个相机帧拼进前一任务。关闭enable只禁止新帧，不取消已接纳帧。超时、源标记错误、上游error、FIFO满、外部取消或下游失败会停止该源帧并取消下游；错误状态采用独立保持/握手跨域，不依赖已满的像素FIFO传送错误消息。

ROI的最后一个像素保留在源域寄存器，只有完整源图的最后像素及EOF正确后才写入FIFO。因此ROI外的右侧/底部尾部发生错误时，下游不会提前拿到完整ROI EOF。即便已写出部分DDR数据，也不会发布成功帧。

错误码：1=栅格标记不符，2=像素FIFO溢出，3=源帧超时，4=外部取消，5=上游error，6=下游失败/过早完成。`result_admitted`区分失败前是否获得下游任务所有权。最后排空拍出现取消时，failed与code一同更新，避免failed=1但code仍为0。

## 3. 实际仿真证据

### FIFO与错误恢复

- [FIFO专项](../logs/r2_camera_fifo_20260913_a.log)：深度2/4/32/1024、写快/读快两组异步时钟；22,404次独立数据/顺序核对、24个协调复位轮次，覆盖满、指针回绕、DEPTH+1有效容量和保持输出。复位轮次在已排空边界进行，不声称覆盖任意单边热复位。
- [实际Resize/Capture矩阵](../logs/r2_camera_capture_matrix_20260913_b.log)：两组AXI背压，各11次成功、10次预期失败；核对真实ROI像素、独立Python双线性golden和452个RGBX AXI写beat。10类路径包括标记错、源尾部错、上游error、已接纳/接纳前FIFO溢出、带真实B债务的取消、缺尾超时、接纳前上游错、SLVERR，以及最后排空拍取消。每次失败后不复位恢复；带B取消保持响应64拍。
- [完整帧生命周期](../logs/r2_camera_lifecycle_20260913_a.log)：16个源帧、6个整帧跳过、8次成功、2次中途新SOF错误。实际Capture完成被保持时仍发送下一完整源帧，验证不覆盖；另验证disable不打断已拥有的帧，异常SOF后从后续新SOF恢复。结果tag为0/2/4/5/7，跳过的1/3/6不冒充成功。
- [小尺寸xsim](../logs/r2_camera_capture_xsim_runs/c25_camera_capture_xsim_small_20260913_b/result.log)：同样11成功/10预期失败，9.315秒，worker不在Windows Job中。

输入是确定性非平凡RGB合成图。golden先裁剪，再执行独立Python双线性Resize，预期数据仅供检查器使用，不灌入DUT替代处理；本轮不评估风格效果。

### 完整1920×1080连续输入

使用单像素RGB源时钟约74.25 MHz、核心约150 MHz，仿真半周期6.734/3.333 ns；每行2200拍、每帧1125行，实际两次SOF相隔2,475,000个相机周期，即33,333,300 ns。时钟有仿真时间精度舍入，不是板卡测量值。

两个源帧之间没有等待ready/busy或人为延长帧周期。每个成功帧实际校验1,555,200个ROI像素，缩放后76,800个128位RGBX写beat，即307,200个输出像素；单次两帧合计153,600写beat、9,600笔AW/B。DDR模型为MEMORY_DIV=2、延迟20拍，含AW等W测试；**没有CNN、CPU或显示器同时竞争DDR**。

| FIFO深度 | AXI背压 | 两帧结果 | 最高RAM水位 | 独立xsim证据 |
| ---: | ---: | --- | ---: | --- |
| 1024 | 0 | 2成功、0丢帧 | 193 | [1080主测](../logs/r2_camera_capture_xsim_runs/c25_camera_capture_xsim_1080_20260913_b/result.log) |
| 512 | 1 | 2成功、0丢帧 | 193 | [512容量](../logs/r2_camera_capture_xsim_runs/c25_camera_capture_xsim_1080_fifo512_20260913_a/result.log) |
| 256 | 1 | 2成功、0丢帧 | 193 | [256容量](../logs/r2_camera_capture_xsim_runs/c25_camera_capture_xsim_1080_fifo256_20260913_a/result.log) |
| 128 | 0 | 2次预期溢出，均整帧作废并排空 | 128 | [欠容量对照](../logs/r2_camera_capture_xsim_runs/c25_camera_capture_xsim_1080_fifo128_20260913_a/result.log) |

128深度对照不是“成功处理图像”：两帧只有部分ROI被消费，没有写出完整图像；错误码均为2。它验证容量不足不会伪造成功或在下一帧拼接数据。512/256的成功只证明此一像素/拍、固定消隐的模型，不能用于未经审计的官方双像素/突发接口。

这证明前端在指定连续约30 fps源模型下能处理两帧，**不证明当前CNN整机达到15 fps**，也不证明CDC的物理实现安全。

## 4. Efinity MAP资源：容量不能只按比特数推算

三个工程均是13生产源加低引脚资源探针，实际连接Ingress→Resize→Capture，双时钟未合并。仅执行MAP，不运行缺失CDC约束的PNR，不把静态同步器属性当时序签核。

| FIFO深度/工程 | 全探针LUT4 | 寄存器 | 全探针RAM | FIFO RAM | DSP |
| --- | ---: | ---: | ---: | ---: | ---: |
| [1024](../efinity/c1_ti60_r2_camera_capture.xml) | 1,919 | 1,673 | 20 | 3 | 18 |
| [512](../efinity/c1_ti60_r2_camera_capture512.xml) | 1,892 | 1,656 | 19 | 2 | 18 |
| [256](../efinity/c1_ti60_r2_camera_capture256.xml) | 1,885 | 1,650 | 19 | 2 | 18 |

以上LUT4、寄存器不是布局布线后的XLR。512与256深度均用2块实际RAM，因此在该映射下512提供更多缓冲余量，只多7 LUT4/6寄存器，适合下一步联合测试；**默认前端参数仍保留1024，没有凭两帧测试直接减小正式平台缓冲**。

单独前端的512/256配置使用2 RAM；按C24联合核心146 RAM加前端2、再加官方CPU/DDR/CSI/Debayer105的粗预算为253/256 RAM。1024配置则为254/256。这些仍是跨工程预算，不能说完整板级资源已闭合；逻辑、时钟与其他缓冲尚待联合实现。固定ROI/Q16参数会带来常量裁剪，也不能把探针的逻辑变化直接加减成整机XLR。

## 5. 如何接入当前主机，而不破坏帧所有权

下一阶段应新增独立camera-host候选，保留C24原接口：

1. `job_valid/ready/tag`接帧池预约入口，预约后由原Capture描述符启动Resize/Capture；pending期间取消保持到实际Capture完成。源ROI配置为固定参数，后续再做帧边界锁存的CPU可编程接口。
2. 原Capture的真实完成只返回给Ingress的`job_done/job_failed`，**不能直接发布为帧池READY**。必须等Ingress的最终`result_valid`；仅`result_admitted=1`时才完成/回收已有lease。接纳前失败没有lease，不能伪造cap_done给帧池。
3. 原始图、CNN输出和配对显示仍用现有RGBX32/帧所有权协议；增加相机侧溢出/跳帧的可读状态与IRQ，不把源域计数多位总线直接接CPU域。
4. 用不可回压源重新跑完整CNN/CPU/显示并发、失败帧隔离和原生周期；不能继承C18或C24的周期。再在同一个工程核对资源与时钟。

物理CDC还需约束Gray指针总线到首级同步器的最大延迟/位间偏斜，以及request/status保持的tag/code多位总线到目标采样寄存器的到达时间。两级同步器、数字仿真或全异步false-path都不是这些约束的替代物。实际CSI/DDR/HDMI IP、复位释放、Bayer相位及官方像素并行度仍需平台审计与板测。

## 6. 复现、失败与清理

入口：[run_r2_camera_capture_probe.py](../golden/run_r2_camera_capture_probe.py)、[FIFO测试](../golden/run_r2_async_pixel_fifo_probe.py)、[生命周期测试](../golden/run_r2_camera_lifecycle_probe.py)、[WMI xsim运行器](../scripts/run_r2_camera_capture_xsim_detached.ps1)。完整尺寸用`-Native`，指定`-FifoDepth`；128深度对照另用`-ExpectOverflow`。每次用唯一RunId。

最初两次xsim（small/1080的a运行）因Vivado不接受同一声明混用“已初始化/未初始化net”而编译失败，拆开TB声明后b运行通过。失败状态及短日志保留，没有覆盖成功；生产数据通路不因此改变。最后排空拍取消的错误码问题由源码审阅发现并修复，再增加实际边界取消测试。

最终检查器 [check_r2_camera_ingress_evidence.py](../golden/check_r2_camera_ingress_evidence.py) 核对源闭包、FIFO/恢复/原生源/容量负控、MAP实际RAM层次与清理，另拒绝6项证据变异。门禁见 [r2_c25_gate_20260913_b.log](../logs/r2_c25_gate_20260913_b.log)。本轮无波形归档，所有结束的私有向量、快照和EDA工程由运行器删除，保留必要文本与[清理快照](../logs/r2_c25_cleanup_20260913.json)。C21/C22仍在运行的原生任务及目录不动。

本阶段完成前端候选的数字协议与实际Resize/Capture验证，整体CNN执行架构重构与平台联合目标仍未完成。
