# C39 native 紧凑操作数实验

在`c39_direct`版本上进一步取消空间feeder内的通用打包器：RGB直接构造两组128位操作数，DW直接构造六组72位有效tap，然后选择432位紧凑格式写入原弹性级。请求时序、MAC数量、通道数和算子不改变。

这是独立候选，不覆盖C37/C39/direct。完整显式49源工程见`case1/efinity/c1_ti60_c39_host_native.xml`；它使用`c39_direct`的engine、本目录空间feeder、C39窗口/计算/量化及其余保留源。不要把这些同名模块的多个版本同时加入GUI工程。

`case1/golden/c39_native_sources.py`检查生成来源与工程一致性；`run_c39_native_datapath_probe.py`绑定实际候选，复用原数值、周期、回压、复位和负控检查。已通过DW/PW融合短测，以及`c39_native_fallback_20260915b`全算子两种回压配置（每轮187作业/167,635向量、六种复位）。RGB/encoder完整图、原生整机吞吐与真实CPU/DDR运行仍待。

纯host实际PNR41,085 XLR，相对同边界C37仅少233 XLR（0.56%），setup/hold为+0.377/+0.026ns。Lite CPU+native+唯一DDR联合PNR51,742 XLR，但资源SDC下最差跨摄像头/核心setup为−0.845ns，不能称作联合时序通过。完整模型验证队列按此门槛暂停；当前没有C39原生帧率结论。

资源以`case1/logs/efinity_resource_runs/c39_host_native_pnr_20260915a/summary.json`的真实终态为准。MAP/LUT4不能当成最终XLR，时序通过也不能替代功能或板级签核。
