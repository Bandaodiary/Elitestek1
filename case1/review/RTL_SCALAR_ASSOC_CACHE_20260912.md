# 残差双输入的双条目读缓存

日期：2026-09-12。阶段范围：板卡无关RTL、真实AXI行为内存、独立整数golden。
本轮板卡无关验证已闭环；未运行本阶段Efinity综合/P&R、原生640×480吞吐或板测。

## 1. 问题与方案

上一阶段64×48训练模型配置为310,689拍。stage5/9/13三个残差层合计44,569拍，
其标量逻辑读总量3,456，物理128-bit AR/R也各3,456；原单条目缓存没有命中。
实际bank映射为：

| 残差层 | 主输入bank | skip bank | 输出bank |
| --- | ---: | ---: | ---: |
| 5 | 1 | 0 | 2 |
| 9 | 0 | 2 | 1 |
| 13 | 2 | 1 | 0 |

两个输入地址交替出现，使单条目反复被对方替换；已经从DDR取得的另一个64-bit
半字在下一次使用前就丢失。输出位于第三bank，适合保留两路输入beat。本轮没有
绕过engine做残差运算，也没有重新安排adapter读写顺序，而是在通用scalar桥增加
可选的两条目全相联读缓存，让同一缓存结构也能服务其他普通RAM的交替读取。

实际残差顺序是**收齐一个像素的3组主输入/skip，再写3组结果**，不是每读一组便
写一组。测试同时保留逐组写的压力序列和真实像素序列，不能把前者的粗失效命中率
套到实际RTL。该区别在本轮源码复核中更正，未修改生产残差调度。

## 2. 生产文件与协议边界

| 文件 | 改动 |
| --- | --- |
| `rtl/dma/c1_tensor_mem_axi128_bridge.sv` | 新参数`READ_BEAT_CACHE_ENTRIES=1`，允许1/2；两条目全28位tag比较，优先无效槽，满时按LRU替换 |
| `rtl/dma/c1_tensor_mem_axi128_packing_bridge.sv` | 向legacy/packed两个read leaf传递容量；保持原写退休及读准入屏障 |
| `rtl/top/c1_r1_portable_soc.sv` | 新参数`TENSOR_SCALAR_READ_CACHE_ENTRIES=1`，在列读分支传递；非法容量和未启用缓存的双条目配置明确拒绝 |

默认缓存开关仍关闭、容量仍1。无新外部端口、指令或CPU/描述符ABI；不增加MAC、
行RAM、读FIFO或物理read outstanding。两条目命中查询并行，但仍只有一笔被接纳
的逻辑读owner；miss仍发单个16-byte AXI beat，hit仅替代这笔物理访问。

填充目标way在接纳miss时保存，不能由随后变化的请求地址决定；读hit和成功fill
更新LRU。无效way优先，避免在另一条目已空时不必要地逐出有效数据。保持的响应
使用独立response寄存器，因此失效不会改写已呈现的数据。

| 事件 | 行为 |
| --- | --- |
| 精确失效模式下，写到两个tag之外的对齐地址 | 保留两条目 |
| 写命中任一tag，包括零WSTRB/任意半字 | 保守清空全部条目；没有仅清某一字节的旁路 |
| 粗失效模式下接纳任一写 | 清空全部条目 |
| 坏写对齐、任意非OKAY B、任意非OKAY R/缺失单beat RLAST | 清空；错误R不安装 |
| stage/abort owner fence | 清空所有way，并锁存禁止在途miss晚到填充 |
| fence发生在已呈现响应期间 | 响应数据、valid/error保持，正常交付旧请求 |
| 普通RAM由其他CPU/DMA重新使用 | 仍须遵守原所有权和显式失效约定；不是硬件一致性缓存 |

原`read_cache_addr_match`成为两条有效tag的OR，不依赖invalidate输入，避免
hit→invalidate→hit组合环。packing wrapper仍在真实B和逻辑写响应全部退休之前
拒绝任何读，包括已经能够命中的读。INVALIDATE不是取消AXI或提前ACK的替代品。

## 3. 结果与独立预算

相同最终RTL、64×48训练artifact、彩色RGGB、列回填窗口32/连续交接、DW整层流水、
末端融合等其他配置完全相同，只改变scalar缓存容量：

| 指标 | 单条目 | 双条目 |
| --- | ---: | ---: |
| 完整任务周期 | 310,689 | 299,189 |
| stage5周期 | 14,854 | 11,015 |
| stage9周期 | 14,848 | 11,035 |
| stage13周期 | 14,867 | 11,019 |
| 标量逻辑读/响应 | 3,456 / 3,456 | 3,456 / 3,456 |
| 标量cache hit | 0 | 1,728 |
| 标量实际AR/R beat | 3,456 / 3,456 | 1,728 / 1,728 |
| tensor实际AW/W/B | 3,939 / 14,592 / 3,939 | 3,939 / 14,592 / 3,939 |
| 其中全WSTRB的128-bit W beat | 14,016 | 14,016 |
| C8结果 | 28,608 | 28,608 |
| 最终DDR像素 | 3,072 | 3,072 |

总任务节省11,500拍（约3.70%）。上述“减半”只指**scalar通路**，不是整机DDR
流量：列回填仍26,880 C8、864笔AR、13,440个128-bit R，MAC及逻辑工作量未删。
完整22层、DDR及两路显示均与独立golden一致。实际写事务也相同，不能把本次收益
归为改动写packing。上一阶段列回填报告误抄的AW/W/B数已根据其四组原始日志更正
为3,939/14,592/3,939；修正文档数值，不改原始日志或此前周期结果。

检查器从descriptor计算残差输入，而不是使用拟合周期。每层设像素数P、C8组数G、
单路word数N=P×G；当前残差G=3且tensor bank按本SoC布局对齐：

- 单条目：两路交替，2N逻辑读均miss。
- 双条目＋精确失效：整个输入流保留相邻半字，命中`2×floor(N/2)`；奇数尾也单独计数。
- 双条目＋粗失效：每个像素写回后失效，但像素内仍复用，命中`2P×floor(G/2)`。

69项Python单元测试包括4×4单像素残差的奇数尾、单/双帧、所有容量/失效模式、
独立AXI总数、逐层守恒、跨层重新分配但总和相同的伪造，以及热缓存取消记录缺失/
错序。真实64×48记录另通过196项逐层/模式/计数变异检查。

## 4. RTL验证

共79种Icarus配置完成预期核验：20组专项＋32组原read-cache兼容＋16组失效＋
10组SoC结构（8正常、2非法拒绝）＋1组原bridge协议测试。不能将2个非法拒绝
计作正常功能通过。关键覆盖为：

- 两条有效tag的全部28个地址位、16种低位offset；A/B交替后第三地址替换、hit
  更新LRU、不同半字先读、三bank写回和逐组写压力。
- 逐组写时48次逻辑读：单条目/双条目粗失效均48 AR，双条目精确失效24 AR；
  真实每像素3组调度则分别48/32/24 AR。
- 每组原失效测试覆盖1,024种同/异地址、半字和WSTRB组合，包括零WSTRB；对B
  错误不假设写入未发生，而是按独立字节内存的实际提交检查结果。
- 两条已热时RRESP/BRESP全部非OKAY值、坏RLAST、失效同时/先于R、AR保持、
  保持的缓存命中响应及排空复位。
- 写配置1/2/4；两笔逻辑写尚未退休时尝试cache hit，真实B保持10拍期间禁止
  返回/越过逻辑写响应。此BFM不证明四笔物理写同时在途，不能把配置4混称实测峰值4。

调试过程中发现并修正了测试自身的三个问题：比较/字面量拼写错误；BRESP错误
注入早于BFM提交、随后被覆盖；尚未呈现读VALID时误禁止PACKED通路继续接收写。
这些没有导致修改生产事务准入规则；失败原因及早期诊断日志保留在开发记录。

系统运行目录均在`logs/portable_soc_cache_ddr_bfm_runs/`：

| 运行ID | 结果 |
| --- | --- |
| `soc_scalar_assoc_off_64x48_20260912_a` | 最终单条目兼容，310,689拍，完整golden；507项负测试 |
| `soc_scalar_assoc_on_64x48_20260912_a` | 双条目精确失效，299,189拍，完整golden；507项负测试 |
| `soc_scalar_assoc_read_abort_20260912_a` | 热替换miss取消，23,749拍恢复，完整golden；544项负测试 |
| `soc_scalar_assoc_write_abort_20260912_a` | stage18写债务取消，23,741拍恢复，完整golden；550项负测试 |
| `soc_scalar_assoc_twoframe_20260912_a` | 两种输入22,720/22,703拍，1,192 C8/128 DDR及两路视频正确，2次切帧0丢帧；623项负测试 |
| `soc_scalar_assoc_coarse_8x8_20260912_a` | 粗失效实际像素调度，22,794拍，72读/24 hit/48 AR，完整golden；486项负测试 |
| `soc_scalar_assoc_minimal_8x8_20260912_a` | 关闭其他性能选项且不做packed写，43,108拍，596读/342 hit/254 AR，原22层836 C8/64 DDR及视频正确；258项负测试 |

热替换取消不是仅在空缓存启动时取消：stage5已有2次命中，第5次逻辑读即第3次
物理读正在替换way，另一个way仍有效。真实client6 R保持64拍后，valid向量OR归约
确认两条均失效、fill资格清零，逻辑owner仍保留到旧请求排空；恢复源12×10缩为
8×8、无复位，完整596 C8/64 DDR及120 raw/64 styled像素与golden一致。

最小/粗失效用来检查适用范围，不能把它们不同配置的周期直接与优化双帧结果相减
当作单因素加速。单因素收益只用上面的64×48对照。

六种单帧场景共2,852次检查器负测试，双帧623次；这是不同场景的测试执行数，
不是3,475种互不重复故障。负测试先要求原记录通过，再在内存中变异，未落盘生成
大量伪造图像或仿真工程。全量检查均使用最终Python合同；粗失效的像素内命中预算
修正后已重新完成其独立golden和486项负测试。

## 5. 复现与GUI集成参数

统一配置入口保留默认单条目，不静默改变之前的回填对照。开启新能力：

```powershell
./case1/scripts/run_r1_column_refill_profile.ps1 -ScalarReadCacheEntries 2 -DryRun
./case1/scripts/run_r1_column_refill_profile.ps1 -ScalarReadCacheEntries 2 -RunId my_scalar_two
./case1/scripts/run_r1_column_refill_profile.ps1 -Scenario TwoFrame -ScalarReadCacheEntries 2 -RunId my_scalar_two_frames
./case1/scripts/run_r1_column_refill_profile.ps1 -Scenario ReadAbort -ScalarReadCacheEntries 2 -WarmScalarAbort -RunId my_scalar_warm_abort
```

全部真实运行仍经既有WMI外层，不能直接调用Worker，不与当前会话Windows Job绑定。
32种普通配置对象＋热取消选项、错误前提拒绝均通过DryRun检查；这类配置检查不冒称
功能仿真。最终图像检查需显式增加`--expect-scalar-cache-entries 2`，热取消再增加
`--require-read-abort --require-scalar-read-abort --require-scalar-assoc-abort`；其他
frame/video/DW/fusion/column-refill要求保持相应场景原有设置。

GUI里的增量参数是`TENSOR_SCALAR_READ_CACHE_ENTRIES=2`；前提是
`ENABLE_TENSOR_COLUMN_READS=1`及`TENSOR_SCALAR_READ_BEAT_CACHE=1`，本轮最佳
组合另用`TENSOR_SCALAR_PRECISE_WRITE_INVALIDATION=1`。请区分：

| 参数 | 含义 |
| --- | --- |
| scalar缓存2条目 | 总32 byte读数据，保留两个输入地址；仍1笔物理读owner |
| column回填窗口32 | 另一条DDR客户端中32个C8逻辑请求的metadata容量；不是32条缓存 |

## 6. 资源、尚未证明的部分与下一步

相对单条目新增128-bit数据＋28-bit tag＋1-bit valid，加fill-way/LRU两个控制位，
静态约159个逻辑存储位。还增加tag比较及读数据选择，不能只按存储位声称无时序
代价；单条目配置中的常量way/LRU预计可被剪除，但本轮没有综合证据。

相同时钟下周期减少约3.70%；若新配置的可达Fmax下降超过该比例，物理吞吐可能
没有改善。普通RAM与无地址镜像、外部writer所有权/fence约定仍必须满足，不能将
该结构当成通用CPU一致性cache或缓存MMIO。

原生640×480/15fps、目标资源/Fmax、板级DDR/摄像头/显示仍未验证。残差算术和
结果写回仍未做整层连续流水；stage20/19/0还有较多计算/取数准备开销。后续应
继续按逐层实际等待选择改变，而非无限扩大缓存条目数。当前三层实测分别44,095、
38,038、31,704拍，仍是优先分析对象；本轮不宣称已解决它们。

7次WMI运行均为complete/exit0，worker均已退出、私有临时工程全部清理，只保留
合计3.591MiB的运行文本/JSON；未保存波形。当天Icarus临时映像和向量目录无残留，
其他日期的临时项未动。最终证据为
[闭环审计](../logs/scalar_assoc_closure_audit.log)和
[开发日志](../DEVELOPMENT_LOG.md)。这只结束本轮优化，不代表整个RTL/板级系统已完成。
