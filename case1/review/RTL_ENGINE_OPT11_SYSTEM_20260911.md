# DW 缓存 + MAC 预取重叠整机验证

## 实现与身份验证

整机 detached runner 新增 CacheDwWeightTiles、MacPrefetchOverlap 开关，
传递到 worker 编译宏、bench 参数和 SoC。bench 直接检查真实 engine
参数；runner 对启用组合要求唯一且匹配的 `C1_NUM_ENGINE_OPTIONS` 记录，
避免仅解析选项却未真正启用。

Run ID：`apb_recovery_engine11_20260911`，独立 worker PID 12936。
最终 complete/done、exit_code=0；实际记录 dw_cache=1、mac_overlap=1。
默认开关不变。本轮未修改 engine 算法。

## 功能结果

完整 numerical golden（要求 APB 恢复和延迟源确认）退出码 0：22 阶段、
836 C8、64 DDR 像素、原图 120/处理图 64 显示像素均匹配。RAW timeout
0x46、64 周期延迟写响应、32 周期延迟源确认、一次 flush、无全局 reset
恢复通过。AW=B=874，W=924，峰值 2 outstanding。

临时工程目录已确认不存在；精简输出保留在对应 logs 目录。

## 周期比较

参考关闭配置 run `apb_recovery_current608_20260911`，两次使用同样的
训练工件、12×10→8×8 输入及恢复/总线扰动选项。比较成功的 job=2：

| 核心时钟统计 | 关闭两项 | 开启两项 |
|---|---:|---:|
| elapsed | 73452 | 71826 |
| bridge busy | 72473 | 70847 |
| feed | 896 | 896 |
| input_wait | 34798 | 34915 |
| engine_hold | 13087 | 13078 |
| neither valid nor ready | 23692 | 21958 |
| mem read/write 接纳数 | 3620/836 | 3620/836 |
| request stall | 1912 | 1926 |
| result stall | 10527 | 12233 |

任务周期减少 1626，约 2.21%。这是小图真实 RTL 周期，不是墙钟耗时。
feed/input_wait/engine_hold/neither 是 bridge busy 内互斥分类；request/
result stall 是另一观察维度，不能再与前四项相加。neither 也不能直接
解释为纯 MAC 工作时间。时序变化会改变确定性 BFM 的背压相位，因此
不能把周期差全部归因于某一个内部状态。

## 剩余工作

分开跑 (DW=1,MAC=0)、(DW=0,MAC=1) 以区分单项收益；再进行更大图像、
不同参数 generation 和故障发生于计算阶段的验证。当前恢复场景没有
证明所有 MAC/权重预取相位的取消行为。此次结果不是 640×480/15 fps、
Efinity 时序/资源或板级带宽证明，也不作为修改默认开关的依据。
