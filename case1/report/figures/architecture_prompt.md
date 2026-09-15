# 架构图重绘规范

依据figures-diagram技能生成，供后续Word报告绘制可编辑矢量图使用；不要求调用外部生图服务。

绘制白底、中文标注、横向的工程系统架构图。蓝色表示输入/输出，橙色表示计算，灰色表示控制与存储。主边框内是c1_r1_portable_soc，边框外是尚待生成的Sapphire、CSI/D-PHY、DDR3 Controller/PHY和HDMI发送IP。

数据主线必须为：camera RAW10 pixel stream→CDC→BLC/Debayer/AWB/CCM/Gamma→capture XRGB writer→DDR framebuffer→input DMA→Resize/C8→tensor adapter与共享22-stage engine→final RGB→output XRGB writer→DDR output framebuffer→双路display prefetch→compositor/OSD/720p timing→RGB/DE/HS/VS→HDMI wrapper。

engine与tensor adapter之间双向连接配置、操作数和结果；adapter经可选三行C8 cache/AXI128 bridge访问DDR三bank，不能画成22个独立层级同时流式运行。参数loader从DDR读descriptor/arena并在active bank提交后向engine供数。七个DDR客户端汇入一个AXI128事务锁定仲裁器。

Resize框标注“当前顶层为恒等缩放，MAX_WIDTH=640”，避免把leaf默认2048输入宽度当作当前SoC能力。

Sapphire经APB配置CSR、ISP、帧管理并接收IRQ；控制连线用虚线。camera/core/pixel三个时钟域用浅色背景分区，DDR UI时钟关系标注为由IP最终配置确认。可选cache/burst功能用虚线框，未集成vendor IP也用虚线框。不得在图中写15fps已达标、100MHz已签核或没有中间DDR访问。
