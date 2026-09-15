# 当前R2 host的S2 Lite只读探测程序

使用实际生成的Sapphire 3.4.1 S2 BSP，不使用旧C1加速器ABI。程序仅调用`c1_r2h_status_read()`读取0xf8100000窗口中的主机ID/版本/状态；不启动CNN、不配置摄像头、不写MMIO、不自动下载板卡。

生成S2配置的ISA为RV32IM并支持CSR/fence，不包含C/F/D。因此这里明确使用`-march=rv32im_zicsr_zifencei -mabi=ilp32`，不能照搬旧`software/efinity_smoke/Makefile`的`rv32imc`默认值；该旧smoke还使用较早C1寄存器ABI，不能作为当前R2 host的识别程序。

编译入口：

```powershell
& D:/miniconda/miniconda/envs/SWPC_ENV/python.exe -X utf8 -B `
  case1/golden/c39_s2_software_probe.py --run-id <新的运行标识>
```

脚本使用已安装的官方GCC 13.4.0、实际S2 `soc.h`，检查ELF32/入口0x1000/ISA扩展、32位指令编码、当前驱动和fence。私有编译目录自动清理，只保留小ELF及summary。首次实测文本228字节、BSS12字节，ELF5436字节；链接器为栈预留4KiB，应用区域为DDR中的124KiB，**不是**0xf9000000处另一个4KiB片上bootloader RAM。

启动汇编设置栈、清零BSS、关闭全局中断并设置默认trap循环。当前没有PLIC安装、UART输出、DDR加载流程、缓存维护或真实CPU启动证明。以后通过GUI/JTAG实际加载前，必须先完成真实DDR校准/地址规划和CPU启动集成；不能把这次构建成功写成板测成功。

## 完整当前驱动的S2编译检查

另有`golden/c39_s2_driver_build.py --run-id <新标识>`，使用当前生成的S2 BSP和[driver_contract.h](driver_contract.h)，编译`c1_r2_rgbx_video.c`、`c1_r2_host_video.c`及`c1_r2_rgb2_camera.c`。它不使用`--gc-sections`，对三个单元执行可重定位链接，保证全部六个当前R2V2/R2H1/R2C2公开API保留；不把旧C1/R2C1/R2V1驱动误当当前联合host驱动。

2026-09-15实际检查：[c39_s2_driver_20260915a](../../logs/c39_s2_driver_runs/c39_s2_driver_20260915a/summary.json)。六API全部存在，无未解析符号，文本916字节、229条32位指令，结果对象2,988字节。每个输入及链接后对象的ISA均为RV32IM+CSR/fence；带C或F扩展的两个真实错误编译被同一个源码合同拒绝。所有临时编译目录已清理。

此对象是链接组件，**不是可下载的完整ELF程序**；六API中包含写控制/IRQ接口，但本次没有执行任何API或写MMIO。PLIC处理、缓存维护、CPU启动、物理DDR和板卡验证仍未完成，原`main.c`只读探测行为也没有改变。
