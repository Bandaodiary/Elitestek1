# Tensor adapter 列读取路径

日期：2026-09-11。本阶段新增 adapter 的可选列接口，并将其与真实三行列缓存
连接验证。此前已验证的列缓存→exact-count AXI 路径保持不变；本阶段尚未将
两个验证环境连成完整的 adapter→AXI→SoC 路径。

## 1. 生产 RTL 修改

`rtl/cnn/c1_r1_microstyle_tensor_adapter.sv` 增加末尾参数
`ENABLE_COLUMN_READS=0`。开启时必须同时启用 `ENABLE_WINDOW_CACHE_SIDEBAND`，
以逐 stage 传递输入 tensor 的 base、宽高和 C8 group 数。

仅 `CONV3X3` / `DWCONV3X3` 走新接口。source/result 写入、1×1、上采样、
残差和输出阶段仍使用原标量 memory port，不改变写完成和 stage 切换屏障。

新接口为单在途、非同拍响应的请求/响应通道：

- 请求：`column_req_valid/ready`、signed17 x/center_y、3-bit group。
- 响应：`column_rsp_valid/ready`、192-bit data、error。
- 三个返回 lane 分别是 top/center/bottom，每个 lane 含一个 C8。
- 每次被接纳的请求必须恰好退还一次响应，包括错误和取消。

状态机复用 `ST_READ_REQ/ST_READ_RSP`，没有增加或改变原 5-bit 状态编码。
列模式中 `tap_q` 在这两个状态表示列号 0..2；标量模式仍表示 tap 0..8。
列请求期间不会额外在标量端口发出伪 tap 请求。

192-bit 响应写入现有 576-bit `window_q`：

| 请求列 | top → tap | center → tap | bottom → tap |
| --- | ---: | ---: | ---: |
| 0 | 0 | 3 | 6 |
| 1 | 1 | 4 | 7 |
| 2 | 2 | 5 | 8 |

列坐标由逻辑输出位置直接生成：
`x = output_x * stride_x + column - 1`，`center_y = output_y * stride_y`。
不能由已经钳位的 top tap 反推 center_y；即使原标量预钳位选项开启，新接口
也仍输出逻辑列坐标，由列缓存分别处理三个行坐标的 SAME_REPLICATE 边界。

## 2. 与已有优化的关系

- 没有水平复用：取第 0、1、2 列，共 3 个列事务。
- stride1 水平复用：保留旧窗口的两列，只取新第 2 列。
- stride2 水平复用：保留旧窗口最右列，只取新第 1、2 列。
- 旧 scalar tap 地址预取在窗口列路径中不执行；非窗口标量地址流水保留。
- 可与 pipelined result writes 共存，但任何未完成写都不能越过列读取屏障。

默认参数仍为 0，SoC 当前默认接线及原标量请求 ABI 不变。没有声称新增宽口
本身能提高 DDR 带宽，也没有新的物理资源或频率测量。

## 3. 取消与错误所有权

adapter_abort 到来时：

1. 若列请求已经提出但 ready=0，保持 valid、x、center_y、group；不能撤回。
2. 接纳后继续等待响应，不再向 engine/result/final 发布新的工作。
3. 响应实际握手后才输出 adapter_aborted、清除历史有效位并恢复启动准备。
4. 没有 abort 时，列错误进入 `ERR_MEMORY=0x07`，保持隔离直到软件/控制器
   发出 abort。响应中的无效数据不写入对外可见的新 engine operand。

**下游所有者必须配合**：不能在 adapter 仍持有未接纳请求时，先复位 cache
或把它的请求接纳永久关掉。本阶段 testbench 让 cache 完成该请求，再在
下一 stage/job 配置时失效标签；没有将 adapter_abort 不加处理地接到 cache。

SoC 接入时还需实现相应的请求保持/错误响应前端及维护汇合。这部分不能用
直接连线代替，也不能把本阶段通过解读为整机 abort 连接已完成。

## 4. 验证范围与实测请求数

`tb_c1_adapter_column_cache.sv` 复用现有 22-stage 独立 operand/result
scoreboard，并实际实例化 `c1_column_line_cache_c8`。只有 refill 源与标量
存储器为行为模型，数据均取自测试 arena；cache RAM 不是数值参考源。

对全部阶段核对窗口、group、bank、坐标、边界、残差、上采样及输出标记。
另检查完整 22 次 stage 配置与独立请求预算。以下为成功单 job 的握手数：

| 图像尺寸 | 水平复用 | 列请求 | 标量读取 | 合计读事务 | C8 payload |
| --- | --- | ---: | ---: | ---: | ---: |
| 8×4 | 关 | 504 | 298 | 802 | 1810 |
| 8×4 | 开 | 256 | 298 | 554 | 1066 |
| 4×4 | 关 | 252 | 149 | 401 | 905 |
| 4×4 | 开 | 166 | 149 | 315 | 647 |
| 12×8 | 关 | 1512 | 894 | 2406 | 5430 |
| 12×8 | 开 | 692 | 894 | 1586 | 2970 |
| 20×12 | 开 | 1578 | 2235 | 3813 | 6969 |
| 8×8 | 开 | 512 | 596 | 1108 | 2132 |

第九种配置在 8×4/开启复用的基础上同时开启流水写回、两级地址准备、
tap 地址预取参数及标量预钳位选项，结果仍为 256 列＋298 标量读取；
额外通过已有写错误/取消排空检查。开启的 scalar tap 预取不会误用到列请求。

每种配置还包括：

- 未接纳列请求与已经产生的列响应两种持有点，各交叉正常/错误 refill。
- abort 后继续保持请求、等待响应，最终 accepted=retired=1。
- 每个取消场景之后无全局复位，完整重跑 22 阶段并核对最终像素数。
- 独立的非取消 refill 错误：报告 0x07、隔离新事务、abort 后完整重启。
- 复用历史已填充后的取消与重启（开启水平复用的配置）。

九种定向配置均通过，随后完整 Icarus 套件返回
`C1_REVIEW_FIXES_REGRESSION_PASS configurations=678`、exit 0。其中包括既有
标量路径的回归；完整运行期间没有再改动生产逻辑，仅修订了头部说明。
Python 新列预算及既有性能模型测试也均通过。

测试中的 engine 是独立行为 scoreboard，不是训练模型
的完整数值推理；新路径的 trained-artifact/整机视频 golden 尚待后续验证。

## 5. 可复现预算，不外推帧率

`model/tensor_perf_model.py` 新增独立函数 `column_window_read_budget`，其测试
已与上表八个实测点一致。原有性能估算函数的默认结果未改变。

原生 640×480、水平复用开启的固定网络预测：

- 1,737,120 次列请求。
- 2,860,800 次其余标量读取。
- 合计 4,597,920 次读事务，仍承载 8,072,160 个逻辑 C8。

这不是 AXI beat 数或 DDR 字节数；不能再乘一个理想 cache reuse 因子来
重复扣减。当前列缓存命中服务间隔仍为上一阶段实测的 5 拍/列，故请求数
降低不能直接换算成帧率，更不能宣布已达到 15 fps。

## 6. 复现

```powershell
& case1/scripts/run_iverilog_review_fixes.ps1 -TestTop tb_c1_adapter_column_cache -Python 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe'
& 'D:\miniconda\miniconda\envs\p300_task3_bci3\python.exe' -B case1/model/test_tensor_perf_model.py
```

本阶段没有启动 Vivado/Efinity，不生成波形，沿用 Icarus runner 的临时
VVP/向量清理流程。完整套件已正常终止。
