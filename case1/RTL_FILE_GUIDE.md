# Case-1 RTL 文件与模块关系说明

2026-09-15 00:29补记：C35小图xsim原生时钟验证已通过，原模型640×480六帧实际xsim启动，尚无新FPS。下方“小图在途”为旧快照；模块连接及资源边界不变。[运行记录](review/R2_ROW_FUSED_TAIL_20260914.md)。

2026-09-15 00:24最新：下述C35融合host→video→AXI→graph→共享MAC/影子行链路已通过真实AXI主机5配置10CNN矩阵和Efinity PNR，并非仍未编译。实测44,352 XLR/129 RAM/130 DSP，150MHz核心setup/hold +0.579/+0.026ns；完整CDC和官方平台联合实现仍未完成。宽度/故障/复位门禁已收口，原生xsim小图验证在途，尚无C35整机FPS。架构入口仍为下列独立候选，未覆盖C31/C33/C34。详见[C35最新结果](review/R2_ROW_FUSED_TAIL_20260914.md)。

2026-09-14 23:56最新：C34完整短回归和PNR已通过（43,286 XLR / 129 RAM / 130 DSP）；C35行算术、整图小尺寸及640×4配对已通过，640×4周期约少5.23%，不是原生fps。新的[整图执行器](rtl/r2/c1_r2_row_fused_graph.sv)接[共享行算术引擎](rtl/r2/c1_r2_cnn_row_shadow_engine.sv)，由[融合计划生成器](model/r2_row_fused_plan.py)选择独占DW16→PW8配对并延长输入DDR槽生存期。共享MAC先把DW行写入现有RAM影子分区，再由PW读取；仅PW写回DDR，两个逻辑节点在写响应排空后顺序提交。640×12配对正在补测，融合故障和主机测试串行等待。详见[C35最新记录](review/R2_ROW_FUSED_TAIL_20260914.md)。

独立主机候选关系：[c1_r2_fused_rgb2_host_system.sv](rtl/r2/c1_r2_fused_rgb2_host_system.sv) → [c1_r2_video_fused_rgb2_system.sv](rtl/r2/c1_r2_video_fused_rgb2_system.sv) → [c1_r2_fused_rgbx_axi_graph.sv](rtl/r2/c1_r2_fused_rgbx_axi_graph.sv) → `c1_r2_row_fused_graph`。前三层保留C34的CPU/APB、视频租约、AXI DMA和外设接口，仅连接新图。对应[Efinity候选工程](efinity/c1_ti60_r2_fused_rgb2_host96.xml)已准备，尚未RTL编译/主机仿真/PNR。它选择新的槽分配与融合配对两张ROM；`c1_r2_row_fused_microstyle_plan.sv`仍定义`c1_r2_microstyle_plan`，不可同时加入旧`execution_plan.sv`。勿覆盖稳定主线，也不要把两个连续逻辑提交的周期差误解为PW单层只耗1拍——融合跨度包含DW与PW两者。

以下22:35及更早追加段落是历史快照，未验证表述不再代替上述最新结论。

C34新增未验证候选：`c1_r2_ring_rgb2_host_system` → `c1_r2_video_ring_rgb2_system` → `c1_r2_ring_rgbx_axi_graph` → `c1_r2_ring_pingpong_graph` → `c1_r2_tensor_credit_ring_writer`。前四层仅为C33命名派生，唯一行为修改是叶模块的整行环形空间预留/同步读后复用；原C33信用DMA、模型、算子和外设接口保留。文件表和独立Efinity入口见[C34报告](review/R2_RING_WRITE_STORAGE_20260914.md#4-独立-rtl-与工程入口)。尚未RTL编译/仿真/PNR，不应在GUI覆盖稳定主线。

C33 新增独立候选入口 `c1_r2_credit_rgb2_host_system` → `c1_r2_video_credit_rgb2_system` → `c1_r2_credit_rgbx_axi_graph` → `c1_r2_credit_pingpong_graph`。执行器中的 `c1_r2_tensor_burst_credit_writer` 发布完整字数，经 `c1_r2_rgbx_credit_row_write` 换算后由 `c1_r2_axi_credit_row_write` 准入物理突发；授权范围反向送回 RAM 写回器，保证补行暂停时继续排空。七个文件和单独47源（含探针）Efinity工程见[C33文件表与验证结果](review/R2_BURST_CREDIT_WRITER_20260914.md#2-新-rtl-与关系)。C31继续保留，当前不要把两个同层入口一起连入系统。

最新入口见[C31报告](review/R2_RGB2_HOST_INTEGRATION_20260914.md)：`rtl/r2/c1_r2_rgb2_host_system.sv`封装CPU ID/APB/IRQ；`c1_r2_video_rgb2_system.sv`连接视频/CNN/共享DDR；`c1_r2_camera_decimated_ingress.sv`实现不可回压双像素源的整帧接纳、ROI、跨域与最终排空。它复用C30 raster/overlap Resize和C29 capacity执行器，不替换原备用文件。以下C29/C30“当前入口/未联合”仅描述各自保留阶段。

独立试验文件[c1_r2_tensor_cutthrough_writer.sv](rtl/r2/c1_r2_tensor_cutthrough_writer.sv)允许一行的完整数据字提前写回，已通过22单元和24写侧AXI数据配置，但会在数据不足时提前占有共享W。它**不在C31的45源活动闭包中**，当前GUI集成不要直接替换原`c1_r2_tensor_pingpong_writer.sv`；原因与下一阶段准入合同见[C32报告](review/R2_CUTTHROUGH_WRITER_20260914.md)。

2026-09-14新增C30的5个独立SV及关系见[双像素前端报告第3节](review/R2_DEMO_RGB2_INGRESS_20260914.md)：`rgb2_raster_source`校验视频时序，`camera_pair_ingress`负责ROI/49位记录CDC及逐像素拆包，`resize_overlap_capture`→`resize_overlap_pipeline`→`resize_overlap_system`负责同拍采样交接与既有插值/写回。全名均带`c1_r2_`。C29完整主机文件保留；新前端尚未接进它，不能把两套XML直接合并当成板级集成。

本文只描述 `case1/rtl` 下的 SystemVerilog 文件，目的是在接入 Efinity
IP Manager 生成的 Sapphire、DDR3、PLL、MIPI/HDMI 外设前，帮助理解当前
厂商无关 RTL 的层次、数据流和控制流。

2026-09-14当前R2联合候选为`c1_r2_camera_capacity_host_system.sv`，其9层新增模块关系树见[C29模块与验证报告](review/R2_CAMERA_CAPACITY_20260914.md)，完整源列表见[Ti60探针XML](efinity/c1_ti60_r2_camera_capacity96.xml)。量化和窗口RAM改变实现，CPU/AXI/CDC/Resize接口保留；已完成板卡无关主机，不等于接通官方IP的板级top。旧C21的compact_engine与新C29的capacity_engine是不同文件。

历史R2-A初期新增独立`rtl/r2`目录，当时尚未联合主机：`c1_r2_dot16_array.sv`实现6/8行
独立输入的连续16项归约；`c1_r2_array_host_probe.sv`负责可独立加载/观察的资源评估
接口，不是tile存储或总线DMA。功能、I3资源与未完成项见[R2接口说明](rtl/r2/README.md)。

最新双条目缓存改动三个生产SV，不增加文件或外部接口：

- `c1_r1_portable_soc.sv`：新参数`TENSOR_SCALAR_READ_CACHE_ENTRIES`默认1，允许2；
  列读分支的scalar客户端负责残差等普通张量读取，并转发容量和原失效配置。
- `c1_tensor_mem_axi128_packing_bridge.sv`：向legacy或packed read leaf传递容量；
  保留写响应退休与实际B屏障，查询任一缓存tag匹配后保守清空两条。
- `c1_tensor_mem_axi128_bridge.sv`：两条128-bit数据、全28位地址tag、无效优先/LRU；
  hit免去一笔物理AR/R，miss仍只有一个owner。stage/abort fence抑制晚到填充，
  写冲突/总线错误清空，保持中的逻辑响应不受失效扰动。

双条目共32 byte读数据，不是列回填窗口的32个C8信用，也不是新增读并发。
默认开关不变；同64×48配置310,689→299,189拍，完整golden及取消恢复通过，
目标时序/资源未测。配置和验证见[双条目缓存报告](review/RTL_SCALAR_ASSOC_CACHE_20260912.md)。

此前列回填集成不新增生产SV，也不改生产逻辑/default；以下是实际工作关系：

- `c1_r1_portable_soc.sv`：列读分支接收`TENSOR_BURST_SCHED_REQ_HANDOFF`与
  `TENSOR_BURST_SCHED_MAX_OUTSTANDING`；本轮纠正运行器只允许旧标量路径的限制。
- `c1_column_cache_owned_exact_burst_shell.sv`：持有上游列请求/响应，转发配置并
  等待完整maintenance join，不能因下游cache先完成而提前允许重配置。
- `c1_column_line_cache_c8.sv`：判断三行命中/缺失，声明待回填行，采样已有效的行RAM。
- `c1_cache_refill_scheduler_read_client_exact.sv`及completion adapter：保证已声明
  行的精确word数量，错误/取消时补齐并排空；不能靠丢弃请求快速完成。
- `c1_cache_refill_scheduler.sv`：保存已接收请求metadata，给待发送pending预留
  容量；可选连续交接消除请求间空拍。16→32增加的是C8容量，不是AXI并发数。
- `c1_tensor_mem_axi128_read_burst_client.sv`：打包C8请求、限制突发/4 KiB边界、
  发送AR、收R并还原按序响应。当前reader仍最多4笔物理事务、每笔最多16 beat。

新增监视器仅在testbench中。完整64×48由329,619降至310,689拍，golden/取消恢复/
双帧通过；无新目标时序证据。复现入口及本轮证据见
[列回填集成报告](review/RTL_COLUMN_REFILL_INTEGRATION_20260912.md)。

上一轮性能改进不新增SV文件，`STREAM_DW_FRAME`默认0：

- `c1_r1_microstyle_engine.sv`：冷像素保持原权重预热/排空；暖像素复用同一DW batch，
  不再每像素重发START，只在真实层尾送batch EOF；原独立输出游标与取消机制保留。
- `c1_r1_portable_soc.sv`→`c1_r1_microstyle_system_bridge.sv`→
  `c1_r1_microstyle_cnn_top.sv`：把新参数传给engine，不增加外部总线或CPU接口。
- `c1_dwconv3x3_c8_requant_core.sv`：既有PER_BEAT_CONFIG流水不改动，继续在实际输入
  握手时绑定数据/权重/偏置/量化/坐标，支持旧结果背压时新像素留在弹性流水中。
- tensor adapter、pixel writer、DDR路径和完成控制器本轮不变，仍负责真实写退休及
  层/帧发布屏障；不因DW算完某个像素就假定整个batch或图像已结束。

未新增生产寄存器或MAC/RAM数组。同64×48配置342,287→329,619拍，完整golden和
双帧/取消恢复通过；原生15fps及目标资源/时序未证明。详见
[DW连续调度报告](review/RTL_DW_FRAME_STREAM_20260912.md)。

上一阶段修复涉及公共任务完成协议，只有`c1_r1_job_controller.sv`的生产逻辑改变：

- `c1_r1_job_controller.sv`：收齐四个完成事件后先排空busy；真正发布DONE之前仍检查
  取消/运行错误，失败则沿原协议排空并报告取消/错误。此前该边界会误报DONE。
- `c1_r1_job_frontend.sv`→`c1_r1_boardless_frame_system.sv`：前者调用控制器，后者
  连接input/output DMA、descriptor executor与compute/runtime，提供实际完成和忙状态。
- `c1_r1_soc_control.sv`：依赖boardless job_done发布待显示帧；新修复防止未发布的
  取消任务被当作成功帧。这些父模块未被替换，只补齐子控制器的终态合同。

无新SV模块、接口、寄存器或配置开关。已验证预览开/关真实DMA链路的最后发布边沿
取消与无复位恢复；正常64×48仍342,287拍。详见[成功排空审查报告](review/RTL_SUCCESS_DRAIN_PUBLICATION_20260912.md)。

上一阶段末端输出融合不新增SV文件，`FUSE_FINAL_OUTPUT`默认0：

| 文件 | 新模式职责 |
| --- | --- |
| `c1_r1_portable_soc.sv` | 同时给adapter和计算链传递融合参数；不改外部CPU/APB/AXI端口 |
| `c1_r1_microstyle_tensor_adapter.sv` | 校验并捕获stage20真实结果，直接交final stream；不再写末端C8张量或读stage21输入；保持最后EOF，使用原view接口提交stage21；错误/取消仍排空已呈现或接纳的读 |
| `c1_r1_microstyle_engine.sv` | 卷积/量化照常，stage21仍完成原descriptor/参数准备，校验view stage/generation后报告cnn_done；该identity层不产生dummy C8结果 |
| `c1_r1_microstyle_system_bridge.sv`、`c1_r1_microstyle_cnn_top.sv` | 透传参数与原view握手；bridge已有“cnn_done前不放行最终EOF”逻辑保持原样 |

关键顺序是“捕获真实EOF→stage21提交→engine完成→bridge放行EOF→原DMA/帧完成”。
仅消除中间存储，并未把卷积、signed-RGB转换或物理输出写回删去；私有输出帧在原
完成屏障前不能交给显示。adapter复用原final payload寄存器，新增2位控制和比较逻辑，
不新建结果RAM，不改三bank地址/权重/描述符ABI。只适用于当前固定22层网络末端identity。

同配置64×48为370,509→342,287拍，完整22层golden、DDR/显示、双帧、取消恢复与最小
scalar-only组合均通过。保持默认关闭，尚无新Efinity资源/Fmax/板测；原生15fps未证明。
修改和验证失败的修正过程均记录在[DEVELOPMENT_LOG.md](DEVELOPMENT_LOG.md)。

上一阶段列缓存行映射复用不新增SV文件，`TENSOR_COLUMN_REUSE_ROW_MAP`默认0：

- `c1_r1_portable_soc.sv`：将新选项传入已有列缓存分支，禁用列读时拒绝开启它。
- `c1_column_cache_owned_exact_burst_shell.sv`→
  `c1_window_line_cache_c8_exact_burst_shell.sv`：继续承担原owner、维护和真实AXI
  refill/排空职责，只透传`COLUMN_REUSE_ROW_MAP`，不新增外部端口或posted响应。
- `c1_column_line_cache_c8.sv`：新增`REUSE_ROW_MAP`，按上次成功lookup与精确signed Y
  复用行bank/lane映射，新请求接纳时读取本笔x/group。换行、重配置、非法group及
  维护失效资格；已呈现响应保持原值。没有改变`c1_row_banked_ram.sv`或增加RAM容量。

它不改变engine、tensor adapter、MAC或软件ABI。新路径每列仍读一次RAM，只减少
标签查找；相同64×48配置从375,029降至370,509拍，物理DDR流量不变。新增RAM地址
选择可能影响Fmax，默认不启用，需目标综合后再确定板卡配置。完整回归与失败调用
纠正见[开发日志](DEVELOPMENT_LOG.md)。

前一阶段虚拟UPS视图提交也不新增SV文件，`ELIDE_VIRTUAL_UPSAMPLE`默认0：

| 文件 | 新模式下的职责 |
| --- | --- |
| `c1_r1_portable_soc.sv` | 同时配置adapter和计算链，连接内部view握手；外部CPU/AXI端口不变 |
| `c1_r1_microstyle_tensor_adapter.sv` | stage14/17完成cache配置握手并排空自身旧事务后，发送stage/generation视图提交；不读取或发送UPS的C8数据 |
| `c1_r1_microstyle_system_bridge.sv`、`c1_r1_microstyle_cnn_top.sv` | 将参数和view valid/stage/generation传至engine，反向返回ready |
| `c1_r1_microstyle_engine.sv` | 保留拓扑/连续性/参数准备检查；验证视图身份、core空闲后握手并报告stage_done，错误身份按原07错误拒绝 |

同一握手使adapter和engine同步换层，后继DW仍读取物理bank0并使用既有虚拟坐标
映射；bank3只是未物化的输出标记。没有新增MAC、RAM或像素结果队列，不改dot/DW
算术核。逻辑网络仍22层，物理C8输出阶段20层，完整golden仍计算全部22层。
只支持当前固定拓扑，并依赖virtual tensor和列cache接口；单独集成子模块时，开启
此参数必须同时接好内部view握手，不能误认为它只是一项可悬空的性能参数。
同配置64×48开启/关闭为375,029/435,864拍；不是原生15fps或新综合结论。
完整回归与失败修正记录见[开发日志](DEVELOPMENT_LOG.md)，下文保留前序架构变更。

最新RGB reduction打包仍不新增SV文件，`PACK_RGB_CONV_REDUCTION`默认0：

- `c1_r1_portable_soc.sv`→`c1_r1_microstyle_system_bridge.sv`→
  `c1_r1_microstyle_cnn_top.sv`：只透传此参数到engine，外部端口不变。
- `c1_r1_microstyle_engine.sv`：Cin=3的3×3卷积保持原OIHW加载，在原64个权重bank内
  将tap/channel展平重排；每输出C8组由9beat变4beat，最后beat仅3lane有效。
  激活来自同一九tap窗口，不改量化核、dot core或张量写回接口。
- tensor adapter、dot core、pixel writer：不新增此参数，也无需更改它们的端口或SV。

同一engine中另修正旧ALL_DOT功能：COLLECT退休旧结果时也按独立退休group屏蔽
输出尾lane，避免下一计算group的尾mask截掉旧group0的有效通道。这与打包开关独立。
64×48打包开启/关闭为435,864/443,465拍，详细测试和当前边界见[开发日志](DEVELOPMENT_LOG.md)。

最新多输出组DOT扩展同样不新增SV文件，`PIPELINE_ALL_DOT_GROUPS`默认0，依赖已有
`PIPELINE_DOT_PIXELS`及其量化/列读写重叠前提：

| 文件 | 新选项开启后的职责 |
| --- | --- |
| `c1_r1_portable_soc.sv` | 同时向计算bridge和tensor adapter传递选项；外部CPU/AXI端口不变 |
| `c1_r1_microstyle_system_bridge.sv`、`c1_r1_microstyle_cnn_top.sv` | 将选项继续传至engine，原配置/层控制协议不变 |
| `c1_r1_microstyle_engine.sv` | 最后输出group的完整reduction接纳后准备下一像素，按独立dot group游标及core坐标退休旧结果 |
| `c1_r1_microstyle_tensor_adapter.sv` | 符合列读/独立bank条件的多group卷积也交独立sink，继续约束层末及取消排空 |
| `c1_pixel_result_writer.sv` | 复用上一轮多group NHWC-C8顺序写入；本轮该文件无需修改，只由新选项启用其MULTI_GROUP |

关键关系是“输入像素准备”与“旧结果退休”独立，而不是把一个窗口提前丢弃：前一像素
所有输出group都完成MAC输入后才能覆盖旧窗口；最后group的真实结果及写响应仍限制换层。
旧6笔core事务全部被阻塞时，pointwise streaming仅能提前接纳下一像素group0；没有新增
完整窗口bank或无限队列。默认不开启时，后文单输出组DOT路径的说明仍成立。
同条件64×48完整golden为470,765→443,465拍，具体文件/测试/失败修正见[开发日志](DEVELOPMENT_LOG.md)。

最新DW像素准备流水不新增SV文件，`PIPELINE_DW_PIXELS`默认关闭，涉及以下关系：

```text
c1_r1_portable_soc
  ├─ c1_r1_microstyle_system_bridge → c1_r1_microstyle_cnn_top → c1_r1_microstyle_engine
  │    暖DW像素全部group送入core后准备下一像素；按独立坐标/group退休旧结果
  └─ c1_r1_microstyle_tensor_adapter → c1_pixel_result_writer（MULTI_GROUP=1）
       列读/输入调度与结果写回分离 → 原packing bridge → AXI写通路
```

engine复用DW core已有输出坐标，新增独立退休group游标，不能用下一像素的输入metadata
标记旧结果；下一DW START仍等core逐像素EOF退休。adapter只在符合列读、独立bank和算子
条件时启用sink，最后结果、写响应及在途列事务共同约束换层/取消。writer的`start_groups`
在START锁存1..8组，按NHWC-C8检查地址/坐标/group/帧标志；默认`MULTI_GROUP=0`忽略该端口，
旧单group调用保持兼容。错误/取消后不能撤回已呈现的请求，也不能提前发写完成。
不新增MAC、窗口bank或CPU寄存器；依赖DW group streaming、权重缓存和列读/写重叠。
完整验证和64×48的513,059→470,765拍A/B见[开发日志](DEVELOPMENT_LOG.md)，不是板卡15 fps结论。

小批次参数不新增计算模块：`portable_soc.PIXEL_WRITE_BATCH_WORDS`→
`tensor_adapter.PIXEL_WRITE_BATCH_WORDS`→`pixel_result_writer.BATCH_WORDS`。
writer新增与写地址/数据共同寄存的`mem_req_end`，经adapter原end端口送packing bridge；
按2/4/8个C8 word或行尾关闭（单group时才等于像素数），默认1兼容旧行为。
多group版本新增3-bit word计数器，不能再仅取x低位。它不是ACK，错误/取消不能改写保持的end。
`portable_soc.TENSOR_WRITE_BUILD_TIMEOUT`→`packing_bridge.WRITE_BUILD_TIMEOUT`
→串行/MLP writer的`BUILD_TIMEOUT_CYCLES`，默认8，范围1..255；有限超时负责无末尾end的
部分批次排空。参数不进入CNN engine、CPU或描述符，也不改变最终结果格式。
16/17宽的真实writer→packer→物理byte memory测试覆盖行尾、EOF、SLVERR和取消恢复。

张量写MLP的接线如下（`TENSOR_WRITE_OUTSTANDING`默认1，2/4仅用于packed column分支）：

```text
c1_r1_portable_soc → c1_tensor_mem_axi128_packing_bridge
  ├─ 1：g_serial.u_write = c1_tensor_mem_axi128_write_burst_client（旧路径）
  └─ 2/4：g_mlp.u_write = c1_tensor_mem_axi128_ordered_write_client（新增SV）
             └─ c1_axi128_write_mlp，PIPELINE_WRITE_DATA=1
                  → 原SoC共享AXI写fabric → DDR接口
```

新ordered client承担动态C8打包、4 KiB分割、descriptor顺序和逐逻辑写ACK；backend
承担实际AW/W/B的多事务缓存与调度。W游标在WLAST后推进，B游标仍等真实响应。
两个模块都保持有界slot寿命，不能提前ACK或覆盖背压中的响应。重复地址写入不会
跨descriptor重排；配置/端口不涉及新的CPU寄存器。此能力在长B等待时有收益，
当前默认延迟下略慢，因此不是默认替换旧路径；基于真实板卡数据再决定容量。

跨像素流水选项`c1_r1_portable_soc.PIPELINE_DOT_PIXELS`同时传入两个分支：

```text
portable_soc
├─ microstyle_system_bridge → microstyle_cnn_top → microstyle_engine
│  最后MAC输入后采集下一像素；旧结果依dot退休元数据输出
└─ microstyle_tensor_adapter → c1_pixel_result_writer（新增SV）
   输入继续取列/送engine；结果独立校验并写输出bank，等待真实写响应
```

默认0；仅覆盖列读模式下单输出C8组卷积，当前stage19/20，1×1需启用对应列读选项。
不改CPU、描述符和C8/column外部端口，不新增MAC或窗口bank。输入EOF后adapter停在
ST_RESULT等writer排空，engine也必须等最后结果退休才能换层。取消时独立writer和
column所有者各自保持/排空已呈现请求；禁止把提前的输入坐标用于旧输出写地址。
writer最多15笔总逻辑预留，scalar packing桥默认只有一笔物理AXI事务，可选上方2/4槽实现。
必须分别理解输入/结果握手、逻辑写接纳、物理AW/W/B和真实响应，不能把它们等同。
以下旧选项说明其独立行为，未开启跨像素流水时仍按原像素边界运行。

全输入组预取的接线较短：`c1_r1_portable_soc.PREFETCH_ALL_PIXEL_GROUPS`
直接传入`c1_r1_microstyle_tensor_adapter`，默认0，依赖已有下一像素预取选项。
adapter将单个192-bit暂存扩展为最多8个按输入组索引的槽，逐组请求下一像素首列，
每组独立valid/error，已返回的组可以先消费；未改变column端口，也没有增加外部
多outstanding。共享缓存/AXI模块、CNN engine和CPU接口均无需为此改动。
普通后续列请求与预取请求共享通道：缓冲区非空不代表当前通道由预取拥有，错误和
取消必须按照实际请求/响应所有者排空。这是取数提前，不是下一像素计算提前。

MAC/量化重叠的接线为`c1_r1_portable_soc.OVERLAP_MAC_REQUANTIZATION`
→`c1_r1_microstyle_system_bridge`→`c1_r1_microstyle_cnn_top`
→`c1_r1_microstyle_engine`→`c1_dot8x8_requant_core.OVERLAP_REQUANTIZATION`。
各层默认0，未改变外部端口。engine将同像素output group的发射/退休计数分开，
下一组START、权重预取和MAC期间也可输出前一组结果。输出组号、尾mask和last依退休
组生成，防止使用已提前的权重组号；整个像素输出完毕才采集下一像素或换层。
底层复用原8路dot和`c1_requant_bank8`的5级流水，最多5笔量化＋1笔活动累加。
此模式中busy表示所有未退休事务，不能用`!busy`代替start_ready；overflow_seen
是连续busy期间汇总状态，不与单个结果一一对应。旧默认模式语义保持不变。
该量化重叠开关本身不改tensor adapter、CPU/描述符接口及模型权重；跨像素计算由上方独立开关控制。

1×1提前归约的接线为`c1_r1_portable_soc.STREAM_POINTWISE_REDUCTION`
→`c1_r1_microstyle_system_bridge`→`c1_r1_microstyle_cnn_top`→`c1_r1_microstyle_engine`。
默认0；开启后，engine对多输入组1×1的第一个output group边接收边调用原dot core，
每组接纳后等待下一组；全部输入到齐才产生最终结果。后续output groups继续使用原
window_cache和MAC调度。tensor adapter的端口和状态流程无需改动，仍逐组提交窗口、
等待并校验结果；因此scalar/column两种取数方式均可使用。本选项不等于跨像素流水
或并行双MAC，没有增加计算阵列或窗口bank。取消和错误必须清除尚未完成的累加事务。

源帧上传的可选接线：`c1_r1_portable_soc.PIPELINED_SOURCE_WRITES`直接传入
`c1_r1_microstyle_tensor_adapter`，默认0。adapter不再逐C8等待写响应，而用最多15笔
信用继续接收源流；每8个C8或EOL产生`mem_req_end`，下游仍是原scalar写路由和可选
`c1_tensor_mem_axi128_write_burst_client`，没有新外部端口或新数据FIFO。
源帧全部接纳不代表可开始CNN：最后写响应退休后才进入首层配置/取操作数。
取消或迟到写错必须保留已呈现请求并排空信用；后端也须能提交未等到end的部分批次。
本选项与结果流水写独立，在单outstanding后端仍正确但不保证吞吐收益。

`c1_r1_portable_soc.PREFETCH_NEXT_PIXEL_COLUMN`传入
`c1_r1_microstyle_tensor_adapter`，默认0，依赖已有跨像素列读/写重叠。
adapter用一个192-bit项提前保存下一像素首列，保留stage/坐标/tap归属；请求和响应
可与旧像素计算/不同bank写并行，消费时仍按原engine窗口ABI提交。所有DDR访问仍经
既有column owner/cache/AXI通路，没有新增外部端口。取消或错误必须同时排空此项
和已呈现/已接纳的写，不能直接清VALID或把响应留给下一任务。

`c1_r1_microstyle_system_bridge`另修复取消后的迟到错误问题：只有新launch能置active，
晚到adapter错误不会使已取消任务永久busy；错误诊断本身不屏蔽。启动缓冲、双目标
独立握手协议保持不变，SoC继续单独汇总所有底层事务的busy/排空状态。

列响应的新增可选接线：`c1_r1_portable_soc.TENSOR_COLUMN_RESPONSE_BYPASS`
→`c1_column_cache_owned_exact_burst_shell.COLUMN_RESPONSE_BYPASS`
→`c1_window_line_cache_c8_exact_burst_shell.COLUMN_RESPONSE_BYPASS`
→`c1_column_line_cache_c8.RESPONSE_BYPASS`。默认均0，启用需要已有列接口。
cache直接转发同步RAM输出，若背压则保持到原有response寄存器；owner继续负责
请求/响应归属与取消排空，tensor adapter和CNN engine不需要新端口。
接口组合路径包含行选择mux，因此默认寄存实现仍保留供物理时序比较。

2026-09-11新增可选1×1列缓存通路：在`c1_r1_portable_soc`上同时设置
`ENABLE_TENSOR_COLUMN_READS=1`、`POINTWISE_COLUMN_READS=1`，顶层把选项传给
`c1_r1_microstyle_tensor_adapter`。adapter复用既有column端口和
`c1_column_cache_owned_exact_burst_shell`，每组只取三行响应的中间C8，仍以
原tap4/零填充窗口送给`c1_r1_microstyle_engine`，因此engine、MAC、权重ABI不用修改。
新参数默认0；不需要另接CPU寄存器或新的AXI端口。若开启已有跨像素重叠，
1×1与3×3一样仍遵守不同bank、写信用和层间/取消排空规则。开发过程与实测结果见
[DEVELOPMENT_LOG.md](DEVELOPMENT_LOG.md)。

最外层 `c1_r1_portable_soc.DISPLAY_RESIZED_PREVIEW=1` 已可选择预览/风格图
显示，并自动打开 preview capture。独立双槽基址配置与准入保护保持不变。
已通过真实 SoC 视频 golden；默认 0 仍显示原图/风格图，不新增运行时 CSR。
见 [预览视频接线与验证](review/RTL_SOC_PREVIEW_DISPLAY_20260911.md)。

新增显示元数据接口：boardless 的 `resolved_preview_base/stride` 输出任务
准入快照，portable SoC 传给控制器。`c1_r1_soc_control.DISPLAY_RESIZED_PREVIEW`
可把第一显示支路改用预览快照及输出尺寸；默认关闭，最外层已公开同名构建选择。
成功快照继续经过 pending → prefetch request → current，保留背压和取消
后的旧帧重复显示行为。见 [预览显示元数据](review/RTL_PREVIEW_DISPLAY_METADATA_20260911.md)。

`c1_frame_triple_layout_check` 的 `FAST_DISJOINT_ENVELOPE` 默认开启：保存
已验证的三个 33-bit 末端，整体范围不相交时跳过逐行扫描；范围相交时
仍检查精确有效行，允许共享 padding。典型独立分区只需 54 个预检周期。
见 [布局预检快捷路径](review/RTL_LAYOUT_ENVELOPE_FAST_PATH_20260911.md)。

验证补充：SoC 预览 DDR 已逐像素通过独立 RAW/ISP/Resize Python golden，
包括完成槽绑定与退休信息的负向检查；不再仅依赖 SV 与 CNN 入口一致性。
见 [预览独立 golden](review/RTL_SOC_PREVIEW_GOLDEN_20260911.md)。

最新 SoC 接线：`c1_r1_portable_soc.ENABLE_PREVIEW_CAPTURE=1` 增加 client 7
预览写通道，`PREVIEW_BUFFER0_BASE/1_BASE` 绑定 processed 输出槽索引，
固定 stride=`FRAME_WIDTH*4`，两槽各预留 `FRAME_WIDTH*FRAME_HEIGHT*4` 字节。
同一共享总线负责仲裁/协议锁定，boardless 联合完成负责等待预览末 B。
已跑真实 CNN 和物理预览 DDR 核对；显示源选择和预览显示元数据尚未接入。
下文旧阶段“未接入 SoC 写 master”的描述由此条更新。
见 [SoC 预览写回集成](review/RTL_SOC_PREVIEW_CAPTURE_20260911.md)。

最新：三帧检查已通过 `c1_r1_job_frontend.CHECK_PREVIEW_LAYOUT` 串入 pair
预检响应；boardless 开启预览时自动开启，成功前不放行运行时启动。新增
错误码 0x31/0x32/0x33 分别为几何、跨度或预览分区、三帧重叠。
boardless 的 `PREVIEW_REGION_BEGIN/END` 同时传入 frontend 检查器和预览
writer：完整预览跨度超出静态区间时，在运行时启动前拒绝。分区检查先于
重叠检查；不提供其他活动帧、tensor 或参数区的动态所有权保护。
见 [布局准入接线](review/RTL_PREVIEW_LAYOUT_ADMISSION_20260911.md)。

新增 `control/c1_frame_triple_layout_check.sv`：锁存 input/processed/preview
三组布局，检查 XRGB 几何、地址跨度和三对实际像素行区间互斥；结果支持
背压和取消。已由 frontend 集成；下文最初独立模块报告为历史记录。
见 [三帧布局预检](review/RTL_TRIPLE_FRAME_LAYOUT_20260911.md)。

Boardless 描述符屏障现在在任务接收、运行时启动和取消当拍关闭，不再沿用
上一任务的完成位。预览开启时已验证末 B 阻塞取消、拒绝新准入及无复位恢复；
最外层 SoC 预览接线仍未完成。见 [取消与屏障修复](review/RTL_BOARDLESS_PREVIEW_CANCEL_20260911.md)。

最新接线：`c1_r1_boardless_frame_system.ENABLE_PREVIEW=1` 已可实例化
preview runtime，将 Resize 输出分给预览/CNN，并通过联合接口等待预览 B
退休。预览有独立写 AXI 与任务基址/stride 快照。最外层 portable SoC 尚未
扩展该写 master、预览元数据或显示选择；默认关闭。
见 [Boardless 接入记录](review/RTL_BOARDLESS_PREVIEW_INTEGRATION_20260911.md)。

新增 `top/c1_r1_preview_runtime.sv`：将 runtime join 与 preview DMA 组合，
对父控制器统一提供启动/忙/完成/错误接口，对外保留 compute 生命周期、
Resize 输入、CNN 输出和预览 AXI 写口。已通过控制器联测，但尚未接入 SoC。
详见 [运行时封装](review/RTL_PREVIEW_RUNTIME_COMPOSITION_20260911.md)。

`c1_r1_preview_dma` 现在在分叉前依据 start 时的尺寸快照检查栅格坐标与
SOF/EOL/EOF。错误 token 握手一次报错但不进入 CNN/preview，等待上层取消；
已有输出和 AXI 承诺继续遵守停顿/排空契约。见 [帧行标志修复](review/RTL_PREVIEW_MARKER_GUARD_20260911.md)。

预览基础模块 `c1_r1_preview_dma` 可通过 `DEST_REGION_BEGIN/END` 将真实
`c1_axi_xrgb_frame_writer` 限制在静态专属地址区间；默认仍允许完整 32-bit
地址空间，需顶层显式配置才具备分区保护。它不是动态 frame ownership，
第三预览通道仍未完成整机集成。见 [区域保护记录](review/RTL_PREVIEW_DEST_REGION_20260911.md)。

补给调度新增可选 `TENSOR_BURST_SCHED_REQ_HANDOFF=1`：沿 tensor burst
client → cache shell → exact wrapper → scheduler/read-client → scheduler
传递，允许已寄存请求握手时补入下一请求，严格保留信用与取消栅栏。
默认关闭。长行收益明显，但小图整机计算仅减少 0.271%，不代表 15 fps；
参数逐层名称及验证见 [请求交接记录](review/RTL_REFILL_REQUEST_HANDOFF_20260911.md)。

最新可选接线：portable SoC 已开放 `FABRIC_WRITE_FIFO_DEPTH`、
`FABRIC_WRITE_W_AHEAD_OF_B` 和 `FABRIC_WRITE_EMPTY_AW_BYPASS`，默认仍为原串行写。
队列模式的协议故障接入控制器并锁住新任务，APB 错误码 `0x14`，需共同复位解除；
已验证真实外部 orphan B 的整机故障上报，以及 12×10→8×8 样例的真实 22-stage
CNN/DDR/显示数值回归。进一步的第二帧真实采集与第一帧 CNN 重叠测试，在 direct/ticket
两模式均达到 outstanding 峰值 2、W-ahead 32 beats，第一帧数值及显示仍正确、
所有写事务退休；第二帧未完成 CNN，尚无同负载速度对照或 15 fps 结论。

取消契约补充：frame manager 的逻辑 FREE 不能单独作为 DDR 可重用依据；
外围准入关闭与 busy/清理栅栏保证在途 AXI 排空前不重分配。整机已验证两笔
写在途时 ABORT、拒绝 START、排空后无复位恢复及恢复帧完整 golden。
控制器同时修复了 ABORT/DONE 同拍时的假成功通知，取消优先，不交付被丢弃帧。
寄存 fatal ticket 模式也在错误分类当拍阻止成功通知和 pending pair 发布，
不等待下一拍取消广播；参数/显示错误碰撞定向回归与正常整机 golden 已通过。

性能选择已有同负载证据：小图双采集/CNN 场景中，仅启用 W-ahead 的计算周期
收益约 0.354%，再启用既有 burst 缓存补给收益约 16.122%；显示交付时刻不变。
因此不能将多 outstanding 能力等同于整机加速，后续优先扩展读补给/缓存验证。
burst 补给的 logical/beat 响应 FIFO 均已通过整机待 B 取消及真实四拍 refill
待 R 取消：原事务排空前拒绝 START，随后无复位恢复帧的完整 golden 正确。
这仍不是任意 beat 位置、连续原生图像或实际 DDR 控制器的验证结论。
另开放 `TENSOR_BURST_REQ_FIFO_DEPTH`（默认 32）：可与既有响应深度参数配合
选用 16/16 逻辑 FIFO 候选。小图正常/读取消恢复均保持原周期与数值，减少
7,792 bit 有效数组容量，但尚无物理 BRAM/LE 节省证明，默认配置不变。
`TENSOR_BURST_SCHED_MAX_OUTSTANDING` 另控制逻辑补给窗口（默认 16），与物理
reader outstanding 不同。32 窗口在当前小图中无收益、峰值仍 16；独立组合已
验证真实 32 请求 flush 排空，尚不代表原生长行吞吐验证，默认不扩大。
后续独立正常长行测试已补齐：3840 words 下窗口 16→32，使实际 burst 8→16
beats、测试周期减少约 9.54%，完整 64-bit 数据正确；仍不是当前 CNN/cache/
共享 fabric 的端到端结果，生产默认窗口保持 16。

截至 2026-09-11，`case1/rtl` 共 131 个 `.sv` 文件，分为：

```text
top       系统组合和回归层级
control   CSR、descriptor、frame/lifecycle 控制
cnn       22-stage MicroStyle 算术与 tensor 适配
video     RAW10 ISP、debayer、resize、色彩处理
dma       AXI/DDR reader、writer、arbiter、cache client
display   framebuffer prefetch、合成、720p timing
common    FIFO、CDC、RAM、定点公共定义
vendor    未来接入 Efinity IP 的适配边界/stub
```

## 1. 先看最终主路径

最终板卡无关组合顶层是 `top/c1_r1_portable_soc.sv`。Efinity GUI 生成的
Sapphire APB、DDR3 AXI、camera、video/pin 外壳应当在这个边界外连接。

```text
Sapphire APB/UART/IRQ
        │
        ▼
 c1_apb_r1_mux ── c1_apb_csr + c1_apb_isp_config
        │                         │
        ▼                         ▼
 c1_r1_soc_control        c1_r1_parameter_subsystem
        │                         │
        │                         └─ descriptor/parameter AXI reader
        │                            → atomic parameter bank
        ▼
 c1_frame_manager / frame pair ownership
        │
        ├─ camera RAW10 → CDC FIFO → R1 ISP → capture XRGB writer
        ├─ input framebuffer reader → resize/C8 → tensor adapter
        │                                      │
        │                                      ├─ optional 3-row C8 cache
        │                                      └─ 64-bit tensor path → AXI128
        │
        ├─ 22-stage MicroStyle engine
        │       descriptor dispatcher → parameter scheduler
        │       → Conv/DW/upsample/residual/final → RGB stream
        │
        └─ output XRGB writer → display pair prefetch → line stores
                                                → compositor → 720p timing

 所有 DDR client
        └─ c1_axi_n_serial_arbiter_128 → Efinity DDR3 controller
```

当前七个共享 AXI client 的约定：

| client | 来源 | 方向 | 用途 |
|---:|---|---|---|
| 0 | boardless/frame job | R/W | framebuffer table、输入读、输出写 |
| 1 | capture subsystem | W | camera 捕获后的 XRGB 写回 |
| 2 | parameter subsystem | R | descriptor/weight/parameter arena |
| 3 | capture subsystem | R | framebuffer table |
| 4 | display subsystem | R | original framebuffer prefetch |
| 5 | display subsystem | R | styled framebuffer prefetch |
| 6 | tensor adapter/cache client | R/W | 中间 tensor、window cache、AXI bridge |

## 2. `top/`：系统组合层

| 文件 | module | 功能和上下游 |
|---|---|---|
| `top/c1_r1_portable_soc.sv` | `c1_r1_portable_soc` | 最终厂商无关 SoC 顶层；组合 APB、ISP、capture、parameter、frame manager、CNN、tensor、display 和七客户端 AXI。 |
| `top/c1_r1_microstyle_system_bridge.sv` | `c1_r1_microstyle_system_bridge` | 将 descriptor/config 快照同时送入 CNN top、boardless frame job 和 tensor adapter；统一 done/error/abort/drain。 |
| `top/c1_r1_soc_control.sv` | `c1_r1_soc_control` | lifecycle 控制器；处理 START、single-shot/continuous、capture admission、NN job、display pair、abort 和 busy。内部实例化 `c1_frame_manager`。 |
| `top/c1_r1_capture_subsystem.sv` | `c1_r1_capture_subsystem` | camera RAW10 输入到 R1 capture frontend、frame-table reader 和 XRGB writer 的完整捕获通路。 |
| `top/c1_r1_capture_frontend.sv` | `c1_r1_capture_frontend` | camera clock 到 core clock 的 CDC、RAW10 接收、SOF/EOL/EOF 和帧边界恢复。 |
| `top/c1_r1_parameter_subsystem.sv` | `c1_r1_parameter_subsystem` | descriptor/weight/parameter arena 的 AXI 读取、双 bank 原子提交和 active generation 管理。 |
| `top/c1_r1_compute_shell.sv` | `c1_r1_compute_shell` | compute ingress→CNN engine→compute egress 的流接口封装；适合独立仿真或替换外部 CNN。 |
| `top/c1_r1_display_subsystem.sv` | `c1_r1_display_subsystem` | original/styled framebuffer 预取、line-store CDC、pair ownership、compositor、OSD 和 timing。 |
| `top/c1_r1_rgb_source_mux.sv` | `c1_r1_rgb_source_mux` | 在原图、风格图、分屏或 fail-black 源之间按 display mode 选择像素。 |
| `top/c1_r1_boardless_frame_system.sv` | `c1_r1_boardless_frame_system` | 不依赖 Sapphire/IP 的 640×480 boardless job；用于 table/descriptor、DMA、CNN echo、输出回读长帧验证。 |
| `top/c1_r1_integration_skeleton.sv` | `c1_r1_integration_skeleton` | 早期系统骨架和接口回归层级；不是最终主顶层。 |
| `top/c1_portable_top.sv` | `c1_portable_top` | 较早的厂商无关 capture/compute/display 组合边界，用于过渡回归。 |
| `top/c1_pixel_pipeline_top.sv` | `c1_pixel_pipeline_top` | 早期端到端像素数据通路，主要用于 ISP/resize/stream smoke。 |

### 主顶层工作顺序

1. 软件写 shadow CSR，`c1_apb_csr` 在合法条件下接受 START。
2. `c1_r1_soc_control` 锁存本次 framebuffer、descriptor、weight、tensor、尺寸和模式。
3. `c1_frame_manager` 分配 3 个输入 slot、2 个输出 slot，形成 capture/NN/display ownership。
4. parameter subsystem 完成 descriptor/arena 读取后发布 active generation。
5. capture、input reader、CNN、output writer 和 display 根据 ownership 并行工作。
6. abort 不是立即撤回 VALID，而是排空已经接受的 AXI/stream transaction 后回到安全边界。

## 3. `control/`：控制面、descriptor 和帧生命周期

| 文件 | module/package | 功能和关系 |
|---|---|---|
| `control/c1_apb_csr.sv` | `c1_apb_csr` | 主 APB3 CSR；保存 frame/table、descriptor、weight、tensor、display、IRQ、status、QoS 等寄存器。 |
| `control/c1_apb_isp_config.sv` | `c1_apb_isp_config` | ISP shadow/commit CSR；Bayer/ROI/BLC/AWB/CCM/gamma 配置在 COMMIT 后原子生效。 |
| `control/c1_apb_r1_mux.sv` | `c1_apb_r1_mux` | APB 地址路由；`0x000..0x1ff` 到主 CSR，`0x200..0x2ff` 到 ISP CSR。 |
| `control/c1_descriptor_pkg.sv` | `c1_descriptor_pkg` | 64-byte descriptor ABI、opcode、shape、stride、tensor/parameter 字段和常量定义。 |
| `control/c1_descriptor_decoder_pkg.sv` | `c1_descriptor_decoder_pkg` | descriptor 校验结果、错误码和验证辅助定义。 |
| `control/c1_frame_buffer_pkg.sv` | `c1_frame_buffer_pkg` | 16-byte framebuffer table entry、slot 状态和像素格式定义。 |
| `control/c1_layer_command_decoder.sv` | `c1_layer_command_decoder` | 将 512-bit descriptor 解码为 Conv/DW/1×1/upsample/residual command，并执行 ABI/range/区域校验。 |
| `control/c1_layer_scheduler.sv` | `c1_layer_scheduler` | 早期/通用 layer scheduler；按 descriptor 顺序发布 layer command。 |
| `control/c1_descriptor_scheduler_subsystem.sv` | `c1_descriptor_scheduler_subsystem` | 将 descriptor reader、decoder 和 layer scheduler 组合成可独立验证的子系统。 |
| `control/c1_r1_config_loader_subsystem.sv` | `c1_r1_config_loader_subsystem` | 读取并缓存 22 个 descriptor，完成连续性、几何和 generation 检查。 |
| `control/c1_r1_config_dispatcher.sv` | `c1_r1_config_dispatcher` | 从 active descriptor bank 向 engine/adapter 分发当前 stage 配置。 |
| `control/c1_r1_stage_config_bank.sv` | `c1_r1_stage_config_bank` | 双 bank stage configuration；整批成功后切换 active bank，避免运行中撕裂。 |
| `control/c1_r1_job_frontend.sv` | `c1_r1_job_frontend` | 对 START 做配置快照、合法性检查、job launch 和 terminal/error 处理。 |
| `control/c1_r1_job_controller.sv` | `c1_r1_job_controller` | 单次 R1 job 的 FSM；连接 frontend、engine、adapter、output 和 abort/drain。 |
| `control/c1_r1_runtime_join.sv` | `c1_r1_runtime_join` | 双运行单元原子启动、分别记忆完成、联合空闲退休及错误/取消管理；已与真实任务控制器/预览 DMA 做组合验证，尚未接入生产 SoC。 |
| `control/c1_frame_manager.sv` | `c1_frame_manager` | 3 输入/2 输出 slot ownership；状态包括 FREE、CAPTURING、READY_NN、PROCESSING、READY_DISPLAY、DISPLAY。 |
| `control/c1_frame_pair_resolver.sv` | `c1_frame_pair_resolver` | 选择可显示的 original/styled framebuffer pair，并处理 frame-id 顺序。 |

控制面与数据面的关系是“控制快照先行”：descriptor/config 未完成时不放行首个
C8 像素；job 运行期间 APB shadow 修改只影响下一次 START。

## 4. `cnn/`：MicroStyle 计算和 tensor 数据面

### 4.1 最终 22-stage 路径

| 文件 | module | 功能和关系 |
|---|---|---|
| `cnn/c1_r1_microstyle_cnn_top.sv` | `c1_r1_microstyle_cnn_top` | 22-stage runtime 顶层；连接 config dispatcher、engine、descriptor validation 和 tensor sideband。 |
| `cnn/c1_r1_microstyle_engine.sv` | `c1_r1_microstyle_engine` | 真实 signed-INT8 stage engine；参数重排、Conv/DW/1×1、bias、requant、saturation、upsample/residual/final。`STREAM_DW_GROUPS`可把同一像素暖缓存DW组连续送入同一个核，输出独立顺序退休。 |
| `cnn/c1_r1_microstyle_tensor_adapter.sv` | `c1_r1_microstyle_tensor_adapter` | 将输出像素坐标映射为 SAME/stride/tap/C8 group/tensor bank 地址；默认单 outstanding 64-bit 请求。可选独立列读；`POINTWISE_COLUMN_READS`让1×1复用列缓存并仅取中间C8送tap4。`VIRTUAL_UPSAMPLE_TENSORS`消除stage14/17中间写回并映射下游窗口，不跳过计算。`OVERLAP_COLUMN_WRITEBACK`允许不同bank的列读/写重叠；`PIPELINE_DOT_PIXELS`把单输出组卷积结果交独立writer，输入调度不再逐像素等结果。层切换/取消仍等真实应答。内部`column_allow_pending_writes`供SoC门控，不是CPU寄存器。 |
| `cnn/c1_pixel_result_writer.sv` | `c1_pixel_result_writer` | 单C8/像素的顺序结果写回器，由tensor adapter启动并提供输出bank基址/宽高；核验group、坐标及帧标志，用97-bit保持寄存器发出64-bit写请求及end，最多15笔总逻辑预留。`BATCH_WORDS`默认1，可选2/4/8，批次末尾或EOL关闭。错误码06表示配置/元数据错误，07表示写响应错误。EOF/错误/取消均须排空已呈现及接纳的写事务；不是AXI桥，不提供提前ACK，部分批次依靠下游有限超时排空。 |
| `cnn/c1_r1_c8_parameter_scheduler.sv` | `c1_r1_c8_parameter_scheduler` | 从 128-bit parameter arena word 顺序读取并重排为当前 stage 的 weight/bias/multiplier/shift。 |
| `cnn/c1_r1_parameter_bank.sv` | `c1_r1_parameter_bank` | 参数双 bank 存储和 generation 提交；失败或半批次加载不污染 active bank。 |
| `cnn/c1_r1_compute_ingress.sv` | `c1_r1_compute_ingress` | RGB8/XRGB 输入转为 engine 使用的 centered signed-8 C8 stream。 |
| `cnn/c1_r1_compute_egress.sv` | `c1_r1_compute_egress` | engine 输出 C8/signed 数据转回 RGB/XRGB stream，并处理 terminal/abort。 |
| `cnn/c1_rgb_s8_center_codec.sv` | `c1_rgb_s8_center_codec` | RGB888 与 centered signed-8 三通道之间的单项弹性编码转换。 |

### 4.2 计算叶和辅助模块

| 文件 | module | 功能和关系 |
|---|---|---|
| `cnn/c1_s8_dot8_accum.sv` | `c1_s8_dot8_accum` | 8 lane signed-INT8 乘加基础树。 |
| `cnn/c1_s8_dot8_accum_pipelined.sv` | `c1_s8_dot8_accum_pipelined` | dot accumulator 的可选一拍流水版本。 |
| `cnn/c1_s8_dot8_accum_treepipe.sv` | `c1_s8_dot8_accum_treepipe` | product→pair→quad→sum 的完整分级 dot tree，实验开关使用。 |
| `cnn/c1_dot8x8_requant_core.sv` | `c1_dot8x8_requant_core` | 8 个输出通道×8 lane dot/requant 核心；是 Ti60 DSP 资源的主要消费者。 |
| `cnn/c1_dot8x8_requant_bank.sv` | `c1_dot8x8_requant_bank` | 多个 8×8 dot core 的 lock-step bank。 |
| `cnn/c1_dot8x8_requant_pingpong.sv` | `c1_dot8x8_requant_pingpong` | inter-pixel overlap/ping-pong 实验壳，不是当前默认主路径。 |
| `cnn/c1_dwconv3x3_c8_requant_core.sv` | `c1_dwconv3x3_c8_requant_core` | 8-channel depthwise 3×3 MAC、requant 和输出。默认start快照参数；`PER_BEAT_CONFIG`令配置随输入窗口进入弹性流水，支持不同通道组连续运算。 |
| `cnn/c1_conv3x3_rgb3.sv` | `c1_conv3x3_rgb3` | 3 输入/3 输出的早期 RGB 3×3 convolution leaf。 |
| `cnn/c1_dwconv3x3_rgb3.sv` | `c1_dwconv3x3_rgb3` | 3-channel depthwise 3×3 早期 leaf。 |
| `cnn/c1_pwconv1x1_rgb3.sv` | `c1_pwconv1x1_rgb3` | 3 输入/3 输出 pointwise 1×1 早期 leaf。 |
| `cnn/c1_requant_s8.sv` | `c1_requant_s8` | 单个 signed-8 affine multiplier/shift、round 和 saturation。 |
| `cnn/c1_requant_bank8.sv` | `c1_requant_bank8` | 八通道并行 affine requant bank。 |
| `cnn/c1_residual_add_s8.sv` | `c1_residual_add_s8` | 单通道 signed-8 residual add。 |
| `cnn/c1_residual_add_c8.sv` | `c1_residual_add_c8` | C8 向量 residual add，供 stage 间 skip path 使用。 |
| `cnn/c1_s8_upsample2_c8.sv` | `c1_s8_upsample2_c8` | C8 nearest-neighbour 2× upsample。 |
| `cnn/c1_s8_window3x3_same_c8.sv` | `c1_s8_window3x3_same_c8` | C8 SAME/replicate 3×3 window 生成。 |
| `cnn/c1_window_line_cache_c8.sv` | `c1_window_line_cache_c8` | 三行、全 group C8 payload cache；属于 cache seam 的本地存储核心。 |
| `cnn/c1_window_line_cache_ctrl.sv` | `c1_window_line_cache_ctrl` | 早期 boardless line-cache 控制原型，用于 refill/row-tag 回归。 |
| `cnn/c1_style_cnn3.sv` | `c1_style_cnn3` | 功能性 streaming CNN baseline，用于较早的模型/接口验证。 |

当前最终 engine 的主要关系是：

```text
c1_r1_microstyle_cnn_top
  ├─ c1_r1_config_dispatcher
  ├─ c1_r1_microstyle_engine
  │    ├─ c1_r1_c8_parameter_scheduler
  │    ├─ c1_layer_command_decoder
  │    ├─ c1_dot8x8_requant_core
  │    └─ c1_dwconv3x3_c8_requant_core
  └─ tensor sideband → c1_r1_microstyle_tensor_adapter
```

engine 负责“算什么”，tensor adapter 负责“从哪里取窗口/中间 tensor”；二者
通过 stage config、C8 group、valid/ready 和 error/abort sideband 对齐。

## 5. `video/`：RAW10 ISP 和 resize

| 文件 | module | 功能和关系 |
|---|---|---|
| `video/c1_raw10_unpack4.sv` | `c1_raw10_unpack4` | CSI-2 RAW10 五字节解包为四个 10-bit sample。 |
| `video/c1_black_level_raw10.sv` | `c1_black_level_raw10` | RAW10 黑电平扣除，带饱和/截断。 |
| `video/c1_debayer_rggb10_valid.sv` | `c1_debayer_rggb10_valid` | 早期 RGGB10 bilinear debayer，仅在完整 3×3 数据有效时输出。 |
| `video/c1_r1_debayer_bilinear.sv` | `c1_r1_debayer_bilinear` | R1 四 Bayer phase、ROI phase-aware 的 bilinear debayer。 |
| `video/c1_color_correct.sv` | `c1_color_correct` | AWB gain、3×3 CCM、offset 和 u10/u8 颜色变换。 |
| `video/c1_gamma_lut16.sv` | `c1_gamma_lut16` | 17 点分段线性 gamma LUT。 |
| `video/c1_isp_pipeline.sv` | `c1_isp_pipeline` | 早期 RAW/ISP 组合链。 |
| `video/c1_r1_isp_pipeline.sv` | `c1_r1_isp_pipeline` | 最终 R1 RAW10→BLC→debayer→color pipeline。 |
| `video/r1_blc_bayer4_u10.sv` | `r1_blc_bayer4_u10` | 四 Bayer phase 独立黑电平修正。 |
| `video/r1_rgb10_color_pipeline.sv` | `r1_rgb10_color_pipeline` | RGB u10 post-debayer color processing。 |
| `video/r1_bilinear_interp_rgb888.sv` | `r1_bilinear_interp_rgb888` | RGB888 bilinear 插值算术，当前有四级流水优化版本。 |
| `video/r1_resize_request_q16.sv` | `r1_resize_request_q16` | 生成 Q16 resize 坐标和权重。 |
| `video/c1_r1_resize_line_sampler.sv` | `c1_r1_resize_line_sampler` | 两行 RGB sampler，提供 bilinear 所需邻域。 |
| `video/c1_r1_resize_pipeline.sv` | `c1_r1_resize_pipeline` | RGB888 输入到目标尺寸的完整 R1 streaming resize。 |
| `video/c1_r1_preview_fork.sv` | `c1_r1_preview_fork` | Resize 后 C8 双消费者分流；保留 CNN 的 64 位数据并恢复预览 RGB888，分别跟踪握手和背压。独立单元，尚未接入 SoC。 |
| `video/c1_r1_preview_dma.sv` | `c1_r1_preview_dma` | 组合 preview fork 与 `c1_axi_xrgb_frame_writer`；预检、EOF 入口封锁、取消和完成共同等待流消费/AXI 退休。尚未接入 SoC。 |
| `video/c1_r1_resize_system.sv` | `c1_r1_resize_system` | resize request、line sampler、interpolation 的系统封装。 |
| `video/c1_rgb_decimate.sv` | `c1_rgb_decimate` | 固定整数比例最近邻 decimator，用于输入尺寸预处理。 |

主路径为：

```text
RAW10 → unpack4 → BLC → R1 debayer → AWB/CCM/gamma
      → resize request/line sampler/bilinear → RGB888/XRGB
```

实际 MIPI CSI-2 packet/CRC/PHY 不在这些文件中，由 vendor adapter 和 Efinity IP
提供合法 RAW10 stream。

## 6. `dma/`：AXI、DDR client、cache 和仲裁

### 6.1 主系统使用的 AXI 模块

| 文件 | module | 功能和关系 |
|---|---|---|
| `dma/c1_axi_n_serial_arbiter_128.sv` | `c1_axi_n_serial_arbiter_128` | ID-less AXI128 共享 fabric；默认串行读写，`WRITE_FIFO_DEPTH` 非零可选多描述符写分支并支持 W ahead，读通道不变；SoC 尚未开启新分支。 |
| `dma/c1_axi_n_read_burst_arbiter_128.sv` | `c1_axi_n_read_burst_arbiter_128` | 可选读 burst 仲裁/组合，用于性能实验。 |
| `dma/c1_axi_n_write_burst_arbiter_128.sv` | `c1_axi_n_write_burst_arbiter_128` | 可选多描述符写仲裁；新增默认关闭的 `W_AHEAD_OF_B`，独立推进 W 与 B 游标，数据不交织、响应按序退休。尚未在整机启用该选项。 |
| `dma/c1_axi2_serial_arbiter_128.sv` | `c1_axi2_serial_arbiter_128` | 两客户端小型 AXI 仲裁器，常用于局部 proxy/smoke。 |
| `dma/c1_axi_read_abort_fence.sv` | `c1_axi_read_abort_fence` | 将任意 abort 转换为可排空的读事务 fence，保证 R/RLAST 边界。 |
| `dma/c1_axi_write_skid_bridge.sv` | `c1_axi_write_skid_bridge` | 单项 AW/W/B skid buffer，保持 VALID 稳定和写响应顺序。 |
| `dma/c1_axi_shared_owner_epoch_arbiter_128.sv` | `c1_axi_shared_owner_epoch_arbiter_128` | 可选 owner/admit gating 壳，为维护边界和 epoch fence 提供显式 busy/quiescent。 |
| `dma/c1_axi_shared_owner_epoch_fence.sv` | `c1_axi_shared_owner_epoch_fence` | 独立维护/flush/epoch 控制 seam，当前未接入默认主顶层。 |
| `dma/c1_axi_shared_qos_monitor.sv` | `c1_axi_shared_qos_monitor` | 汇总各 client AR/AW/R/W/B busy、等待、deadline、underflow 和 owner hold 统计。 |
| `dma/c1_axi128_write_mlp.sv` | `c1_axi128_write_mlp` | 有界burst descriptor/payload与AW/W/B调度器，已被SoC可选2/4槽张量写路径复用。默认W与B共用head；新`PIPELINE_WRITE_DATA=1`按WLAST独立推进W，B仍严格有序退休并控制slot复用。物理outstanding只计真实AW/B，不含本地错误。 |

### 6.2 Frame/parameter DMA

| 文件 | module | 功能和关系 |
|---|---|---|
| `dma/c1_axi_descriptor_reader.sv` | `c1_axi_descriptor_reader` | 从 DDR 读取 64-byte descriptor。 |
| `dma/c1_axi_parameter_loader.sv` | `c1_axi_parameter_loader` | 从 parameter arena 读取 128-bit words，送入 `c1_r1_parameter_bank`。 |
| `dma/c1_axi_frame_buffer_table_reader.sv` | `c1_axi_frame_buffer_table_reader` | 读取 16-byte framebuffer table entry。 |
| `dma/c1_axi_xrgb_frame_reader.sv` | `c1_axi_xrgb_frame_reader` | DDR XRGB8888 读回并转换为 RGB raster stream。 |
| `dma/c1_axi_xrgb_frame_writer.sv` | `c1_axi_xrgb_frame_writer` | RGB raster 转 XRGB8888 AXI 写通道。 |
| `dma/c1_table_response_elastic_fifo.sv` | `c1_table_response_elastic_fifo` | framebuffer table response 的一项注册弹性边界。 |
| `dma/c1_cache_refill_scheduler.sv` | `c1_cache_refill_scheduler` | cache miss 后安排 line refill。 |
| `dma/c1_cache_refill_scheduler_read_client.sv` | `c1_cache_refill_scheduler_read_client` | 将 refill scheduler 接到窄 read client。 |
| `dma/c1_cache_refill_scheduler_read_client_exact.sv` | `c1_cache_refill_scheduler_read_client_exact` | 严格 exact-count 的 refill/read client 组合。 |
| `dma/c1_cache_refill_completion_adapter.sv` | `c1_cache_refill_completion_adapter` | refill completion、error、flush 和 owner 路由适配。 |

### 6.3 Tensor AXI 和性能实验路径

| 文件 | module | 功能和关系 |
|---|---|---|
| `dma/c1_tensor_mem_axi128_bridge.sv` | `c1_tensor_mem_axi128_bridge` | 64-bit tensor req/rsp 映射成单拍 AXI4-128；`addr[3]` 选择上下 64 bit，写 strobe 对齐。 |
| `dma/c1_tensor_mem_path_seam.sv` | `c1_tensor_mem_path_seam` | legacy direct path 与 optional performance path 的选择边界。 |
| `dma/c1_tensor_mem_axi128_packer.sv` | `c1_tensor_mem_axi128_packer` | 相邻窄请求合并为 AXI128 beat 的 boardless 原型。 |
| `dma/c1_tensor_mem_axi128_read_burst_client.sv` | `c1_tensor_mem_axi128_read_burst_client` | tensor read burst client。 |
| `dma/c1_tensor_mem_axi128_packing_bridge.sv` | `c1_tensor_mem_axi128_packing_bridge` | 有序tensor读写边界：packed写默认用单事务leaf；`WRITE_OUTSTANDING=2/4`选择新ordered client。所有真实B及逻辑应答退休后才放行后续读；读beat cache的写失效和读响应所有权不变。 |
| `dma/c1_tensor_mem_axi128_ordered_write_client.sv` | `c1_tensor_mem_axi128_ordered_write_client` | 新动态C8打包前端：有界slot保存最多4-beat payload、strobe和逻辑响应echo；超时/end/地址边界结束批次，不合并冲突lane。分离command、payload和响应游标但保持全程顺序，接MLP backend形成真实多AW/W/B。上层取消时停止新请求、排空已接纳请求，不提供提前ACK。 |
| `dma/c1_tensor_mem_axi128_write_burst_client.sv` | `c1_tensor_mem_axi128_write_burst_client` | FIFO中的64-bit请求合并为128-bit burst，不跨4 KiB。单物理写事务在途，AW/W独立。启用`USE_REQUEST_END`时末项同拍关闭，IDLE且FIFO为空的末项直接装载descriptor寄存器；AXI仍从寄存器驱动，真实B后逐项应答。无end时保留超时排空。 |
| `dma/c1_tensor_mem_axi128_read_fabric_2c.sv` | `c1_tensor_mem_axi128_read_fabric_2c` | 两客户端 read fabric。 |
| `dma/c1_tensor_mem_axi128_write_mlp_adapter.sv` | `c1_tensor_mem_axi128_write_mlp_adapter` | 逻辑写请求到多 outstanding 写接口的适配。 |
| `dma/c1_tensor_mem_axi128_write_mlp_fabric_2c.sv` | `c1_tensor_mem_axi128_write_mlp_fabric_2c` | 两客户端写 MLP boardless fabric。 |
| `dma/c1_tensor_mem_axi128_write_parallel_fabric.sv` | `c1_tensor_mem_axi128_write_parallel_fabric` | 多 lane 并行写路径实验。 |
| `dma/c1_tensor_window_cache_seam.sv` | `c1_tensor_window_cache_seam` | adapter 与 tensor memory 之间的三行 C8 cache；只缓存 Conv3×3/DW tap read。 |
| `dma/c1_tensor_window_cache_axi_client.sv` | `c1_tensor_window_cache_axi_client` | 将 window-cache seam 封装成 portable SoC client-6。 |
| `dma/c1_tensor_window_cache_burst_axi_client.sv` | `c1_tensor_window_cache_burst_axi_client` | 下一阶段 burst refill/client-6 实验封装。 |
| `dma/c1_window_line_cache_c8_burst_shell.sv` | `c1_window_line_cache_c8_burst_shell` | boardless line-cache burst refill 壳。 |
| `dma/c1_window_line_cache_c8_exact_burst_shell.sv` | `c1_window_line_cache_c8_exact_burst_shell` | exact-count burst/refill 壳。 |

当前默认 tensor 路径是：

```text
c1_r1_microstyle_tensor_adapter
  → c1_tensor_window_cache_seam (默认 bypass)
  → c1_tensor_mem_axi128_bridge
  → client-6
  → c1_axi_n_serial_arbiter_128
```

`packer`、burst client、MLP fabric 和 shared owner/epoch 模块均是可选性能路线，
不能因为独立仿真通过就认为已经替换默认生产路径。

已完成整机数值验证的可选列读路径由同一个tensor adapter驱动
`c1_column_cache_owned_exact_burst_shell.sv`；内部owner负责请求/响应退休和取消，
exact burst壳负责三行缓存与真实AXI读取。`c1_r1_portable_soc.sv`负责接入独立列读
客户端，标量请求仍走client-6，可选读拍缓存和精确写失效。

在此分支打开`VIRTUAL_UPSAMPLE_TENSORS`时，最近邻上采样的存储优化只改adapter：
stage14/17校验结果后不写DDR；stage15/18从较小的源bank取得物理列，经奇偶行选择
形成逻辑3×3窗口。`c1_s8_upsample2_c8.sv`、DW核、引擎和22阶段描述符均不改。
stage15/16的输出bank相应换位，防止覆盖小图源。详见[架构说明](ARCHITECTURE.md)
及[开发记录](DEVELOPMENT_LOG.md)。默认路径、CPU寄存器接口和三bank空间预留不变。

上面“不改DW核/引擎”仅指虚拟张量优化；独立的`STREAM_DW_GROUPS`选项确实扩展了
这两个模块，要求DW权重cache，与上采样布局开关不绑定。它通过已有`cnn_top`和
`microstyle_system_bridge`透传，不新增CPU寄存器或外部总线端口。核的新模式把
`start_weights/bias/mult/shift/activation`视为逐输入拍payload，集成时不能仍按
默认“只在start有效”驱动；当前引擎已完成该适配与寄存预取。

## 7. `display/`：显示输出

| 文件 | module | 功能和关系 |
|---|---|---|
| `display/c1_display_prefetch_pair.sv` | `c1_display_prefetch_pair` | original/styled 两路 framebuffer prefetch 和 pair ownership。 |
| `display/c1_display_line_store_cdc.sv` | `c1_display_line_store_cdc` | core/reader 域到 pixel 域的双 bank RGB line store CDC。 |
| `display/c1_display_flush_reset.sv` | `c1_display_flush_reset` | 显示 flush、underflow、pair swap 的局部复位/清空。 |
| `display/c1_split_compositor.sv` | `c1_split_compositor` | 风格图居中、原图居中、左右分屏、fail-black 四种布局。 |
| `display/c1_hex_osd_overlay.sv` | `c1_hex_osd_overlay` | 将状态、错误和计数编码为十六进制 OSD overlay。 |
| `display/c1_video_timing_720p.sv` | `c1_video_timing_720p` | 1280×720@60Hz 的 HS/VS/DE/pixel timing。 |

显示链为：

```text
DDR original/styled reader
  → display_prefetch_pair
  → line_store_cdc
  → rgb_source_mux
  → split_compositor
  → hex_osd_overlay
  → video_timing_720p
```

HDMI/TMDS PHY、PLL 和实际 pin 不在这些文件中。

## 8. `common/`：公共基础模块

| 文件 | module/package | 功能和主要使用者 |
|---|---|---|
| `common/c1_fixed_pkg.sv` | `c1_fixed_pkg` | 定点 round、饱和、signed/unsigned 转换公共函数。 |
| `common/c1_async_stream_fifo.sv` | `c1_async_stream_fifo` | 双时钟 ready/valid FIFO；capture/display CDC。 |
| `common/c1_stream_fifo.sv` | `c1_stream_fifo` | 单时钟 ready/valid elastic FIFO。 |
| `common/c1_event_cdc.sv` | `c1_event_cdc` | toggle/ack 单事件 CDC；清错、underflow、frame event。 |
| `common/c1_reset_sync.sv` | `c1_reset_sync` | 异步 assert、同步 deassert reset synchronizer。 |
| `common/c1_ram_sdp_read_first.sv` | `c1_ram_sdp_read_first` | 可推断的同步 single-read/single-write RAM，read-first 语义。 |
| `common/c1_window3x3.sv` | `c1_window3x3` | 通用三行 3×3 streaming window generator。 |
| `common/c1_r1_unified_output_fifo.sv` | `c1_r1_unified_output_fifo` | CNN result 的可选统一输出 FIFO，默认关闭。 |
| `common/c1_r1_unified_output_skid.sv` | `c1_r1_unified_output_skid` | 一项输出 skid/abort boundary，默认关闭。 |

这些模块不携带 Ti60 专用原语，优先用于 Icarus/XSim 和 Efinity map 兼容性验证。

## 9. `vendor/`：Efinity IP 接入边界

| 文件 | module | 当前作用 |
|---|---|---|
| `vendor/c1_sapphire_apb_master_adapter.sv` | `c1_sapphire_apb_master_adapter` | 将 Sapphire APB master 接到 Case-1 APB CSR seam；需用最终 `soc.h`/地址映射复核。 |
| `vendor/c1_sapphire_irq_adapter.sv` | `c1_sapphire_irq_adapter` | Case-1 level IRQ 到 Sapphire PLIC/外部中断输入的适配。 |
| `vendor/c1_sapphire_vendor_adapter_stub.sv` | `c1_sapphire_vendor_adapter_stub` | 无 Sapphire IP 时的仿真 stub；拿到 IP Manager 输出后替换/旁路。 |
| `vendor/c1_memory_vendor_adapter_stub.sv` | `c1_memory_vendor_adapter_stub` | AXI memory vendor boundary stub；未来连接 DDR3 controller。 |
| `vendor/c1_camera_vendor_adapter_stub.sv` | `c1_camera_vendor_adapter_stub` | camera RAW10 vendor boundary stub；未来连接 MIPI CSI/传感器 IP。 |
| `vendor/c1_video_vendor_adapter_stub.sv` | `c1_video_vendor_adapter_stub` | parallel RGB/DE/HS/VS video boundary stub；未来连接 HDMI/TMDS。 |

GUI 集成时，不应把 vendor stub 内的地址、时钟或 pin 假设直接带到板级工程；
必须以 Efinity 生成的 `project.xml`、`peri.xml`、SDC 和 BSP 为准。

## 10. 文件之间的工作原理

### 10.1 控制通路

```text
Sapphire APB
  → c1_sapphire_apb_master_adapter
  → c1_apb_r1_mux
  → c1_apb_csr / c1_apb_isp_config
  → c1_r1_job_frontend
  → c1_r1_soc_control
  → c1_frame_manager + c1_r1_job_controller
```

软件配置是 shadow 写入；START 时只锁存一次，运行期间修改 shadow 不影响当前
job。DONE/ERROR/IRQ 在所有 DMA、CNN、display owner 排空后才允许软件复用内存。

### 10.2 参数和 descriptor 通路

```text
DDR parameter arena
  → c1_axi_descriptor_reader / c1_axi_parameter_loader
  → c1_r1_config_loader_subsystem
  → c1_layer_command_decoder
  → c1_r1_stage_config_bank / c1_r1_parameter_bank
  → c1_r1_config_dispatcher
  → CNN engine + tensor adapter
```

参数采用双 bank 和 generation：当前运行使用 active bank，新配置在 shadow bank
完整校验后一次性提交。descriptor 的 64-byte ABI 决定 opcode、通道、尺寸、stride
和区域边界，decoder 错误会阻止 stage launch。

### 10.3 图像捕获通路

```text
MIPI/RAW10 vendor stream
  → c1_camera_vendor_adapter_stub（未来替换为官方 IP）
  → c1_r1_capture_frontend
  → c1_async_stream_fifo / c1_event_cdc
  → c1_r1_isp_pipeline
  → c1_axi_xrgb_frame_writer
  → DDR input framebuffer
```

capture FIFO 只是 CDC/弹性缓存，不是整帧缓存。无 owner 或 abort 时，frontend
继续消费并静默丢弃到 EOF，避免半帧残留阻塞下一帧。

### 10.4 CNN/tensor 通路

```text
DDR input XRGB
  → c1_axi_xrgb_frame_reader
  → c1_r1_compute_ingress / resize system
  → c1_r1_microstyle_tensor_adapter
  → window cache（可选）
  → c1_tensor_mem_axi128_bridge
  → DDR tensor bank0/1/2

同一 stage command
  → c1_r1_microstyle_engine
  → dot/DW/requant/upsample/residual
  → c1_r1_compute_egress
  → output XRGB writer
```

三块 tensor bank 的软件约定是：

```text
bank0 = tensor_base + 0 MiB
bank1 = tensor_base + 8 MiB
bank2 = tensor_base + 16 MiB
```

默认 adapter 为 correctness-first 的单 outstanding 64-bit 事务；window cache、
AXI packing、burst 和 multi-outstanding 文件目前都是可选性能路线。

### 10.5 显示通路

```text
output framebuffer / original framebuffer
  → c1_display_prefetch_pair
  → c1_display_line_store_cdc
  → c1_r1_rgb_source_mux
  → c1_split_compositor
  → c1_hex_osd_overlay
  → c1_video_timing_720p
  → video vendor adapter
```

display 只在 frame boundary/VSYNC 提交新 pair；没有完整 pair 时保持当前 pair，
从而避免撕裂。真实 HDMI/TMDS 和 PLL 需要 Efinity IP 生成物。

## 11. 哪些文件是“主路径”，哪些是“实验/回归路径”

### GUI 集成时优先接入

```text
top/c1_r1_portable_soc.sv
top/c1_r1_soc_control.sv
top/c1_r1_capture_subsystem.sv
top/c1_r1_parameter_subsystem.sv
top/c1_r1_display_subsystem.sv
top/c1_r1_microstyle_system_bridge.sv
cnn/c1_r1_microstyle_cnn_top.sv
cnn/c1_r1_microstyle_engine.sv
cnn/c1_r1_microstyle_tensor_adapter.sv
dma/c1_axi_n_serial_arbiter_128.sv
dma/c1_tensor_mem_axi128_bridge.sv
vendor/*.sv
```

### 暂不作为默认生产路径

```text
c1_tensor_mem_axi128_packer.sv
c1_tensor_mem_axi128_*_burst_client.sv
c1_tensor_mem_axi128_*_mlp*.sv
c1_tensor_window_cache_burst_axi_client.sv
c1_r1_unified_output_fifo.sv
c1_r1_unified_output_skid.sv
c1_axi_shared_owner_epoch_*.sv
c1_dot8x8_requant_pingpong.sv
c1_s8_dot8_accum_pipelined.sv
c1_s8_dot8_accum_treepipe.sv
```

这些文件可以单独仿真或综合探针通过，但是否启用必须同时检查 AXI 事务计数、
abort/drain、缓存一致性、资源和真实帧率。

## 12. 建议的理解/集成顺序

1. 先阅读 `control/c1_descriptor_pkg.sv`、`control/c1_frame_buffer_pkg.sv` 和 `control/c1_apb_csr.sv`，理解软件 ABI。
2. 再阅读 `top/c1_r1_soc_control.sv`、`control/c1_frame_manager.sv`，理解 frame ownership。
3. 阅读 `cnn/c1_r1_microstyle_cnn_top.sv`、`cnn/c1_r1_microstyle_engine.sv` 和 `cnn/c1_r1_microstyle_tensor_adapter.sv`，理解一层计算和 tensor 地址分工。
4. 阅读 `dma/c1_axi_n_serial_arbiter_128.sv`、`dma/c1_tensor_mem_axi128_bridge.sv`，理解 AXI owner、半字选择和响应路由。
5. 阅读 `top/c1_r1_capture_subsystem.sv`、`top/c1_r1_display_subsystem.sv`，理解输入输出 framebuffer。
6. 最后再把 Efinity 生成的 Sapphire APB、DDR3 AXI、PLL、MIPI/HDMI 和 pin/peri wrapper 接到 `vendor/` 边界。

当前默认生产配置仍为：`PACKED_AFFINE_CACHE=0`、tensor window cache bypass、
单 outstanding tensor path。任何实验开关都应通过对应的 Icarus/XSim regression
后再接入 Efinity 工程。

相关验证和资源报告：

- [ARCHITECTURE.md](D:/contest/2026FPGA/yilingsi/case1/ARCHITECTURE.md)
- [IMPLEMENTATION_STATUS.md](D:/contest/2026FPGA/yilingsi/case1/IMPLEMENTATION_STATUS.md)
- [TEST_RESULTS.md](D:/contest/2026FPGA/yilingsi/case1/TEST_RESULTS.md)
- [Efinity RESOURCE_MAP_RESULTS_20260829.md](D:/contest/2026FPGA/yilingsi/case1/efinity/RESOURCE_MAP_RESULTS_20260829.md)
