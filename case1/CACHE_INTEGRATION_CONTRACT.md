# 赛题一：C8 三行缓存接入合同

## 1. 目标与当前边界

本合同冻结 `c1_r1_microstyle_tensor_adapter`、三行 C8 数据缓存和
64-bit tensor memory path 之间的行为。第一版目标是先证明位精确、缓存
一致性和外部请求下降；它仍是单 outstanding、逐 word refill，不代表
640×480@15 fps 已闭合。

当前独立缓存实现为 `rtl/cnn/c1_window_line_cache_c8.sv`。正常路径 xsim
已覆盖 8×8 stride-1/stride-2、2 个 C8 group 交织、SAME/replicate、
refill/request/response 回压、stage 失效、flush 和 abort。

桥接实现为 `rtl/dma/c1_tensor_window_cache_seam.sv`。最终 detached xsim
run `1e6f562adbc34ea383932840b97aa0e4` 已完成 17 个逻辑 req/rsp、5 次
row refill/40 个 refill reads、8 个 bypass reads、2 个 writes 和 50 个
downstream transaction，并覆盖地址/容量 fallback、coherence、flush、配置
计算期间请求受阻后 abort、miss/refill drain 与三向回压。新增的
`cfg_rejects=1 runtime_fallbacks=1` 定向证明配置拒绝和路由后错误可安全
收口；adapter/seam 的 stalled payload、分类、对齐、owner/refill 断言全程
启用。最终 proxy synth run `6dc7d474aff34448ba590ff615927a53`
为 1,236 LUT、792 FF、7.5 BRAM tile、0 DSP，100 MHz
WNS/TNS=+1.086/0 ns；相对历史 run `209b68d9b8c9429ba659d32b399a0911`
的 1,234 LUT/787 FF 只增加 2 LUT/5 FF。

该 seam 已通过 `ENABLE_TENSOR_WINDOW_CACHE` 可选插入
`c1_r1_portable_soc`；参数默认 0，保持原 adapter→bridge 直通时序，置 1
才生成缓存支路。除结构 smoke 外，当前源码 shape-scaled gate 矩阵
`c1_8x8_gate_20260825`（8×8 单帧）、`c1_16x8_two_gate_20260825`（16×8 两帧）、
`c1_64x48_single_gate_20260825`（64×48 单帧）和
`c1_64x48_two_gate_20260825`（64×48 两帧）已覆盖真实 stage/refill、client-6、
七客户端仲裁、DDR BFM 和 display prefetch；两帧均完成 `swaps=2 drops=0`。
64×48 两帧又完成 `AW/W/B=80448/83328/80448`、`AR/R=96793/102295`；
gate 同时验证 display prefetch quiescence，避免共享 ID-less AXI 读响应被 display
reader 反压时阻塞 foreground CNN。shape compile 前置证据为
`c1_64x48_gate_compile_20260825`。所有动态证据仍使用小帧/零参数功能性 arena，
不代表 native 640×480 帧率。

组件级 64-bit 与真实 AXI 动态链均已闭合。run
`9212d5a042ae4d9895a3162869e3815f` 复用原 adapter 22-stage bit-exact
scoreboard，把真实 sideband-enabled adapter 接到 seam、C8 cache 和单
outstanding 64-bit BFM；它完成 2,230/2,230 logical req/rsp、1,810 reads/
420 writes、1,493 hit/19 miss 与 19 次 refill/204 words，外部读为
`298 bypass + 204 refill = 502`，减少 72.3%。

run `be4977424d9d484e80340f970d9904d0` 在相同 scoreboard 下继续串入真实
`c1_tensor_mem_axi128_bridge` 和严格 AXI128 BFM，完成 502/502 AR/R、
420/420/420 AW/W/B、上下 lane 462/460、AW-first/W-first/same 318/81/21、
AR/AW/W stall 1577/1583/1580、R/B gap 1194/915、B hold 2、memory error 1
和 abort drain 5。两条 run 都保持 448 operands/32 final beats，双 marker
唯一且三阶段 stderr 为空。

以上组件链仍是 4×4/8×4、小尺寸、单拍、单 outstanding 证据；顶层 gate 矩阵
另外证明 8×8/16×8/64×48 功能性全链已经经过 portable SoC 第七客户端、七客户端
仲裁和 DDR BFM，并在两帧中得到 `swaps=2 drops=0`，但不能替代 native 640×480
全帧、burst、多 outstanding 或真实 DDR 性能验证。最终 enabled wiring smoke
`30658446f3d4442fb7f7a442bd5f9fe2` 仍用于结构、空闲诊断和 busy fence。

## 2. 不可改变的数据顺序

真实 adapter/engine 的遍历顺序是：

```text
output_y -> output_x -> input_group -> 9 taps
```

因此缓存不能在 `input_group` 变化时清空。一个 resident row 必须保存该
物理行的全部 C8 groups，行内顺序与 tensor ABI 一致：

```text
row_word_index = x * input_groups + group
byte_address   = input_bank_base
               + ((y * input_width * input_groups + row_word_index) << 3)
```

整行 refill 顺序固定为：

```text
x0/g0, x0/g1, ..., x1/g0, x1/g1, ...
```

## 3. 缓存资格与安全旁路

只有 Conv3×3/DWConv3×3 的输入 tap read 可标为 cacheable。以下请求必须
保持 direct bypass：

- source tensor 写和中间 tensor 写；
- Conv1×1 read；
- upsample read；
- residual-bank read；
- final stream/read；
- stage 禁用缓存、配置非法、地址未 8-byte 对齐或容量超限的请求。

底层 cache 若拒绝 group/stage 配置，seam 必须以 `CONFIG_REJECT` 完成本次
stage 配置并关闭 cache route，而不是等待一个永远不会成立的 cache owner。

容量超限必须自动旁路，而不是截断行宽或返回陈旧数据。冻结 native
640×480 图中，相关层的最大 `width * groups` 为 1280：

| Stage | `width * groups`（64-bit words/row） |
|---|---:|
| 0 | 640 |
| 1 | 640 |
| 3 / 7 / 11 | 960 |
| 15 | 960 |
| 18 | 1280 |
| 20 | 640 |

Stage 19 同样可达到 1280，但它是 1×1 路径，应旁路。descriptor validator
没有把所有合法输入锁死为 640×480，所以 1280 只是冻结模型上限，不是
通用 RTL 不变量。

## 4. 推荐模块边界

```text
tensor adapter logical req/rsp
             |
             v
tensor window-cache seam
  |-- cacheable 3x3 read --> 3-row all-group C8 cache
  |                           |-- hit: local response
  |                           `-- miss: whole-row refill
  `-- direct request ------------------------------+
                                                       v
                               64-bit tensor memory seam -> AXI128
```

每层配置至少包含：`stage_enable`、`input_base`、`width`、`height`、
`groups`。每个上游请求在原有 req/rsp 之外增加 `req_cacheable`、signed
`req_cache_x/y` 和 `req_cache_group`。使用 x/y/group sideband 可直接复用
缓存的钳位和索引逻辑，避免由动态 group 数执行除法。

stage 配置必须在 adapter 锁存 descriptor 后的独立状态发送；不能在同一
个 `always_ff` 边沿直接使用刚以非阻塞赋值写入的 `*_q`。stage 边界只
失效一次，group、像素和行切换都不失效。

seam 在 stage 配置握手后用 16-cycle shift-add 计算整个 tensor 地址范围，
避免综合出通用乘法器/DSP；期间第一个逻辑请求可以被 backpressure。
`stage_start_done` 是该检查结束的诊断脉冲，不是 adapter 的第二次握手。
seam 必须等待底层 cache 的配置完成结果；只有 guard 与底层配置都成功时
才可置 `stage_cache_active`，配置拒绝则整层 direct bypass。

## 5. 请求、响应与 owner 规则

- adapter 继续保持最多一个逻辑请求 outstanding；
- seam 的注册前端先在 `s_req_valid && s_req_ready` 时完整接收并快照一个
  逻辑请求，再用流水化 shift-add 做 sideband/物理地址一致性分类；因此
  上游不需要在 cache miss 期间继续保持原请求；
- cache hit 产生本地响应；miss 在 seam 内启动整行 refill，并由已保存的
  逻辑请求在填充后自动重试；
- direct 和 refill 共享同一窄内存下游，响应必须依据已注册 owner 路由；
- cache route 必须在前端请求分类后寄存锁定；若 dispatch 前 cache 失效，
  该请求永久转为 direct。若已经取得 `LOGICAL_CACHE` owner，则任何随后
  error 都不得重新发 direct request，以免同一逻辑请求产生重复事务；
- 已声明且受阻的 request/response 不得撤回或改变 payload；
- 每个 accepted 逻辑请求必须恰好产生一个逻辑响应；
- 没有 owner 时出现下游响应属于协议错误。

第一版 refill 每次只发一个 64-bit read 并等待 response。它可验证功能，
但不能直接连接需要等待相邻配对的 `PERF_MODE=1` packer，否则可能互等。
后续性能版需要至少能连续排入两个相邻 word，并在行尾显式 flush；冻结
模型行长 640/960/1280 都是偶数，适合 128-bit pairing 或 burst。

## 6. abort、flush 与错误

最安全的第一版 abort 语义是 drain，不是 cancel：

1. 已呈现的下游请求保持到 handshake；
2. 已接受的 direct/refill 读等待对应 response；
3. 已被 seam 前端接受的逻辑请求完成分类；若发生 miss，则完成当前整行
   refill，并返回该逻辑请求；
4. abort/flush 到达时若 adapter 已呈现一个尚未被 seam 接受的请求（例如
   seam 正在做 16-cycle stage 地址范围计算），`drain_front` 必须让该请求
   最终握手并返回，不能让 adapter 永久等待；
5. 逻辑响应排空后再清 cache/config，并报告 abort 完成。

若在 miss 或配置计算期间立即清除 cache config，adapter/已接受逻辑请求
可能永久得不到完成，因此桥接层必须锁存 abort 并按上述顺序处理。更快的
“停止剩余 refill +
本地 dummy response”可以后续实现，但仍需先排空已呈现/已接受的下游事务。

任何 refill data error 或 `last` 位置错误都会污染整行；partial row 始终
保持 invalid。新 stage 可以清除 sticky cache error。flush 清 tags 但保留
有效 stage 配置；abort 最终还要清配置。

runtime cache error 若发生在请求尚未取得 cache owner 的 dispatch 阶段，
必须清除其 cache route 并安全旁路；若 owner 已取得，则保持 owner 并按原
响应/错误路径退休，绝不能同时产生 direct transaction。最终 seam run 已
分别定向覆盖配置拒绝与该 runtime fallback。

portable SoC 当前把 `adapter_abort` 同时送入 seam，并把
`tensor_cache_busy` 纳入软件可见的 `system_busy` 外存复用栅栏。顶层
`flush_req` 暂绑 0；独立 seam 已验证 flush，但软件/全局 flush 的系统接线
仍是后续项。

## 7. 容量与性能估算

三行最大 payload 为：

```text
3 * 1280 * 64 bit = 245,760 bit = 30 KiB
```

仅按容量估算，Ti60 下界约 24 个 M10K；考虑常见 `512x20` 映射，展平
`3840x64` 约为 32 个 M10K（约占 256 块的 12.5%）。Artix-7 proxy 实测
为 7.5 BRAM tile、288 LUT、203 FF、0 DSP，100 MHz WNS/TNS=+1.086/0 ns
（run `d07c3a3c7348474ea465ff73f765707a`）。最终 Ti60 数字仍必须以
Efinity 映射为准。

包含地址 guard、owner、coherence、maintenance 与上述 payload cache 的
最终完整 seam proxy run `6dc7d474aff34448ba590ff615927a53` 为 1,236 LUT、
792 FF、7.5 BRAM tile、0 DSP，100 MHz WNS/TNS=+1.086/0 ns；这是整个
seam 的总量，不能再与独立 cache 数字相加。相对历史 1,234 LUT/787 FF
基线仅增加 2 LUT/5 FF。

按当前全 group 行 refill 模型，native 3×3 tap 外部 64-bit read 可从
14,515,200 降至 1,958,400 words/frame，减少约 86.51%。但逐 tap 本地读、
逐 word refill、单 outstanding 和串行 MAC 仍是实时性能瓶颈。

## 8. 板卡前验收门槛

- 正常路径：group 交织、stride-1/2、四边钳位、bit-exact 数据；
- 配置边界：zero geometry、groups 超限、`row_words > 1280`；
- refill fault：memory error、early/late `last`、partial row 不可命中；
- maintenance：request stall、response stall、refill 中途 flush/abort；
- bridge：cache hit/miss、direct read/write、owner 路由、容量旁路；
- 最大行：至少验证 1280-word refill 的地址终点和计数；
- proxy synth：确认 BRAM 推断、0 DSP 目标和 100 MHz 结构时序；
- 动态顶层验证：确认前层最后一个 write response 返回后才能配置下一层，
  并确认 abort 后 `system_busy` 保持到 seam `quiescent`。

这些项目都可在拿板前用 RTL+xsim/Vivado proxy 完成。Ti60 的实际 M10K
映射、DDR 时序/效率、MIPI、显示、CDC、功耗和长时间稳定性仍需要 Efinity
与实体板。
