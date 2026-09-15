# R2图执行参数映像

由原`../microstyle24_starry_functional`训练参数导出，未训练新模型、未修改原工件。
这是固定MicroStyle-24拓扑的C6参数装载命令，不是R1参数arena或CPU寄存器ABI。

- `parameters.bin`：180,224字节，可按字节原样上传到图核`parameter_base`。
- `manifest.json`：每stage的8192字节槽偏移、实际命令数与128位传输数。
- 实际读取2,333个128位字，共37,328字节；空槽/槽尾无需FPGA加载。

64位命令采用小端：高16位为0，47:46为kind（1权重/2bias/3affine），45:32为
算子SRAM地址，31:0为数据；一份128位内存响应先消费低64位，再消费高64位。
`parameter_base`须8MiB对齐且与输入、输出、三槽工作区互斥。

生成器验证权重形状、bank容量和量化字段。还与实际RTL回归向量生成器独立构造的
2,333个参数字逐项比较；不使用校验和。该验证不等于训练质量或板卡推理已经达标。

```powershell
& D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe -B case1/golden/export_r2_graph_parameters.py --verify
```

重新导出需指定新的`--output`目录，生成器不会覆盖已有文件。
图接口、P2C8特征布局及总线适配边界见`../../review/R2_GRAPH_HANDOFF_20260913.md`。
