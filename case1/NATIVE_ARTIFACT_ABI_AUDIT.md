# Native 640×480 trained artifact ABI audit

更新时间：2026-08-28

## 目的

该审计检查 `model/microstyle24_starry_functional/` 中的原生尺寸训练工件是否
能够被当前 RTL 的 descriptor decoder、parameter scheduler、parameter bank 和
MicroStyle engine 接收。它只做静态/文件级检查，不运行 640×480 CNN 数据平面，
也不创建长帧仿真工程。

入口脚本：

```text
case1/golden/test_native_artifact_abi.py
```

默认检查：

```powershell
python case1/golden/test_native_artifact_abi.py
```

## 检查内容

脚本以 `descriptor_format.py` 和 `microstyle_layout.build_layout(640, 480)` 为
软件参考，并逐项镜像当前 RTL 的约束：

1. `descriptors.bin` 的 22×64 B 长度、little-endian 16-word 布局、版本/字数、
   opcode、activation、保留 flag、几何、SAME/残差规则和 stage 级尺寸连续性；
2. scheduler 的 `MAX_CHANNELS=48`、`MAX_WEIGHT_BYTES=2592`、16 B 地址对齐、
   11-bit parameter word address、四类 region 的长度和 arena 边界；
3. `parameter_arena.bin` 中 weight(OIHW s8)、bias(s32 LE)、multiplier(signed18
   stored in s32 LE) 和 shift(u8, 0..47) 的编码及 manifest 元数据；
4. 参数 region 之间无重叠，逻辑 payload 与 16-byte scheduler read-word 数量一致，
   对齐间隙/尾部保持零填充；
5. `vectors/microstyle_artifact/descriptors.mem` 与 `parameter_arena.mem` 反向
   还原后逐字节等于原始二进制文件，确认 `$readmemh` 的反转字节视图没有偏移。

## 结果

```text
C1_NATIVE_ARTIFACT_ABI_PASS native_geometry=640x480 descriptor_count=22 descriptor_bytes=1408 arena_bytes=16896 payload_bytes=16379 scheduler_read_words=1030 scheduler_last_word=1052 affine_values_checked=926 descriptor_mem_records=22 parameter_mem_words=1056 boundary=descriptor/parameter ABI only; native data-plane CNN remains unrun
```

关键结论：

- `descriptors.bin` 与冻结的 RTL layout **逐字节一致**（1408 B）；
- arena 长度为 **16,896 B**，四类有效参数 payload 共 **16,379 B**，scheduler
  需要 **1,030 个 128-bit read words**；
- 所有参数 region 16-byte 对齐且落在 `PARAM_ARENA_BYTES=16896` 内，最高有效
  word address 为 1052（剩余对齐尾部为零）；
- 926 个 bias/multiplier/shift affine 值通过 signed18/shift 范围检查，little-
  endian extrema 与训练 manifest 一致；
- 仿真 `.mem` 镜像可无损还原，故现有 ABI runner 读取的不是另一份或错序工件。

另外，对临时副本故意修改 descriptor 首字节的负向试验返回
`C1_NATIVE_ARTIFACT_ABI_FAIL`，说明护栏能阻止明显的 ABI/几何破坏。

## 边界

该结果确认的是 **descriptor/parameter 文件 ABI 与 RTL loader/scheduler 的兼容性**。
它不等价于：

- native 640×480 的逐像素 RTL/Python bit-exact；
- portable SoC 七客户端共享 DDR 在原生长帧下的无饿死/QoS；
- burst、多 outstanding、并行 MAC 或 15 fps；
- Ti60/Efinity 的 DDR3、MIPI、HDMI、P&R、时序和实板验证。

原生训练工件的参数读取边界已有独立 detached xsim 证据；小尺寸逐阶段算术和
adapter→engine→writeback 也已有独立 8×8 证据。下一步仍应在受控周期/日志预算下
推进 native 长帧的分阶段数据平面验证，而不是把本审计标记解释为 native CNN 完成。
