# Tensor scheduler 握手、维护与 epoch 协议审计

更新时间：2026-08-27

本文针对现有 `c1_r1_microstyle_tensor_adapter`、
`c1_tensor_window_cache_seam`、`c1_window_line_cache_c8_burst_shell`、
`c1_tensor_mem_axi128_read_burst_client`、`c1_tensor_mem_axi128_bridge` 和
`c1_tensor_mem_axi128_write_mlp_adapter` 的实际 RTL 行为，冻结下一阶段
read-only cache-refill scheduler 的协议边界。本文只讨论板前可验证的
ready/valid、顺序、flush/abort 和错误收口，不把 AXI 性能模型当作板卡
签核。

## 1. 已有模块的真实合同

### 1.1 单请求 tensor adapter

`c1_r1_microstyle_tensor_adapter` 是严格的单 outstanding producer：

* `mem_req_valid && mem_req_ready` 接收一个 64-bit 读/写；随后必须有且仅有
  一个 `mem_rsp_valid && mem_rsp_ready`；
* `mem_req_valid` 所在状态与 `mem_rsp_ready` 所在状态互斥，RTL 断言不允许
  同周期请求和退休；
* memory request、cache stage config、engine operand 在 READY 为 0 时保持
  全部 payload；
* bridge 没有 cancel 输入。因此 abort 不是撤回，而是禁止新的 source/
  engine/result transfer，并等待已呈现或已接受的 memory transaction 完成；
* adapter 在请求状态收到 abort 时，仍先完成 request handshake，再进入 response
  状态；响应到达后产生 `adapter_aborted` 并回到 IDLE。配置/计算等没有 memory
  transaction 的状态则可直接回 IDLE。

结论：任何性能 scheduler 都不能把这个 `req/rsp` ABI 当成可取消队列；若要
允许多个 request，必须新增事务 metadata、credit 和 drain 状态，而不是只把
`req_ready` 接到 burst client。

### 1.2 64-bit AXI bridge

`c1_tensor_mem_axi128_bridge` 只允许一个 request 在途。地址必须 8-byte 对齐，
AXI 侧为一个 128-bit INCR beat（`LEN=0`）；AXI 没有 ID。AW/W 可独立握手，
BREADY 仅在两者完成后拉高。R/B 错误被转成一个稳定的 logical response，
直到 `mem_rsp_ready`。

该 bridge 没有 flush/abort。因而上游的维护操作只能在 bridge 完全 quiescent
后完成，或由外层 fence 保证已接受的事务排水；绝不能清除 bridge state 后把
旧 R/B 当作新 epoch 的响应。

### 1.3 三行 cache seam 与 line cache

`c1_tensor_window_cache_seam` 的 front-end、cache owner 和 downstream owner
都是单槽：

* 先在 `s_req_valid && s_req_ready` 快照一个完整 logical request，再做地址
  分类；cache hit 产生本地 response，miss 启动整行 refill；
* `LOGICAL_CACHE/LOGICAL_BYPASS` 与 `DOWN_REFILL/DOWN_BYPASS` 是互斥 owner；
  已取得 cache owner 的请求不能因随后 runtime error 再发 direct request；
* abort/flush 是 drain 操作。已接受的 request、下游 request、refill word 和
  已呈现 response 均不撤回；完成排水后才向 `c1_window_line_cache_c8` 发维护
  请求；
* line cache 的 flush 清 row tags 但保留 stage geometry，abort 还清
  `config_valid`；partial/error refill 永远不能标记为 valid row；
* `quiescent` 不依赖环境中尚未握手的 `tap_valid`/`group_start_valid`，但
  seam 的 `quiescent` 还要求 front、owner、refill、maintenance 全部为空。

### 1.4 burst read client

`c1_tensor_mem_axi128_read_burst_client` 接受 logical address FIFO，将相邻
64-bit request 合并为 128-bit beat，并允许多个 AR descriptor outstanding。
AXI 仍是 ID-less，因此 descriptor 的 R 响应严格按 AR 发射顺序消费；每个
descriptor 的 lane map 决定 logical response 顺序。

`req_flush` 只是 burst builder 的 frame-close 控制：它关闭当前构建中的
descriptor（必要时产生 local/error descriptor），不是全局取消，也没有
`flush_done`。没有 active builder 时单独的 `req_flush` 不会产生完成 token。
early/missing RLAST 会设置错误；missing RLAST 后额外物理 beat 无法与下一
descriptor 可靠区分，外层必须把该链路视为协议故障并重新建立 fence。

### 1.5 write MLP adapter/backend

写通路与 read client 不是同一个 ABI：先接受 descriptor command，再接受该
descriptor 的完整 logical payload stream。`req_flush`/`payload_flush` 可以
结束当前 payload frame 并把 descriptor 标为 local error；在 AW-before-payload
模式下，已发出的 AW 不能撤回，未捕获 beat 必须确定性 zero-fill，随后仍要
完成 W/B 和 ordered response。W/B 在 descriptor head 顺序退休，AW 可以提前。

因此不能把一个单请求 read/write adapter 直接替换为 write MLP：必须显式表示
descriptor、payload length、`last`、strobe、tag 和 frame epoch。

## 2. 当前 `c1_cache_refill_scheduler` 的审计结果

新 scheduler 已正确覆盖了许多基础项：command FIFO、active-row 限制、每个
accepted leaf request 的 row/index/last/epoch metadata、旧 epoch response
丢弃、outstanding credit、命令完成 pulse，以及维护期间排空 metadata FIFO。
但在接入现有 burst client 前需要修正以下协议问题。

### 2.1 维护事件会撤回已阻塞的 leaf request（高优先级）

当前 `leaf_req_valid` 的组合条件包含 `!maintenance_event`。若时序如下：

```text
cycle N:   leaf_req_valid=1, leaf_req_ready=0  // VALID 已被呈现并阻塞
cycle N+1: abort_req 上升沿，maintenance_event=1
           leaf_req_valid 被组合逻辑拉低，尚未握手
```

这违反 source-side ready/valid 合同。修复方式二选一：

1. 新增 `leaf_req_pending_q`/`leaf_req_epoch_q`，维护事件到来时保持 request
     VALID/payload，直到 `leaf_req_ready` 握手，再把该事务加入 metadata 并
   进入 drain；或
2. 在独立 abort fence 中等待 `!leaf_req_valid || leaf_req_ready`，只在安全
   边界向 scheduler 发维护事件。

不能通过“直接丢掉 active command”解决，因为 leaf 端可能已经把 VALID 采样
到自己的 skid/观察断言中。

### 2.2 无 metadata 的 orphan response 会永久阻塞

当前 `leaf_rsp_ready` 只有在 `meta_count_q != 0` 时才可能为 1。若 leaf 因
下游异常、复位边界或 arbiter 错误产生无 metadata 的 response，scheduler 不
会消费它，也没有 `orphan_rsp_error`，最终可能把整个 ID-less R 通道锁死。

建议：

* 增加 sticky `orphan_rsp_error`/`perf_error_count`；
* `leaf_rsp_valid && meta_count_q==0` 时仍拉高 `leaf_rsp_ready`，将该 beat
  drain 丢弃；
* 若产品合同选择“orphan 必须由下游永不产生”，也要在仿真中 `$fatal`，而不
  是静默等待。

### 2.3 epoch 回绕必须有明确门槛

8-bit epoch 在 256 次 maintenance 后会回到旧值。若旧 metadata、旧 AXI beat
或共享 fabric 中残留响应跨越回绕，`stale_head` 可能误判为当前 epoch。
可接受的实现策略是：

* 将 EPOCH_W 提升到 16/32，并把“最大可能未排水维护次数”写入系统合同；或
* 在 epoch 即将回绕时禁止新的维护/启动，直到 metadata、fabric owner 和
  downstream response FIFO 全部为空，再执行 wrap；
* 对真实 AXI ID-less 路径，epoch 不能替代物理 transaction fence；它只是
  scheduler 内部的逻辑 token。

### 2.4 同周期 request/response 的边界未冻结

若 leaf 允许 combinational zero-latency response，`meta_count_q==0` 时可能同时
发生 `req_fire` 和 `rsp_fire`，而 `final_response_event` 使用的是旧的
`meta_count_q`，导致 response 被消费但 command 永不 `cmd_done`。当前 burst
client/bridge 实现通常至少有一拍延迟，因此建议在接口合同中明确：

```text
accepted leaf request 的 response 不得在同一时钟周期返回
```

若未来要允许 fall-through，则必须加入 one-entry response bypass，或以
`req_fire` 同周期生成 metadata 并专门处理 count=0 的 response。

### 2.5 维护请求合并/优先级需要冻结

abort 与 flush 同周期到来时应只递增一次 epoch、只建立一个 drain fence，
但分别记录两个 completion bit，排水后同周期或定义顺序地产生两个 done pulse。
维护期间再次出现 abort/flush 时不应每次递增 epoch；应 OR 到当前 fence，或
排队成下一个明确 ticket。推荐规则：

* `abort` 优先于 `flush` 清配置；
* 当前 fence 只递增一次 epoch；
* `abort_done`/`flush_done` 只有在该 fence 的 metadata 与 downstream owner
  全部为空后才产生；
* done pulse 产生前禁止新 command/request；done 后才允许新 epoch command。

## 3. 建议冻结的 scheduler 协议

### 3.1 命令输入

每条 row command 包含：

```text
cmd_valid/ready
cmd_base_addr, cmd_stride_bytes
cmd_row, cmd_word_count (1..65535)
cmd_epoch
```

只有 `cmd_epoch == current_epoch`、不在 maintenance fence、FIFO 有空间时才
置 `cmd_ready`。零长度、epoch 不匹配、地址溢出/对齐错误不能静默丢弃；应
生成一个带 row/epoch 的 `cmd_done_error` token。

### 3.2 leaf request

scheduler 是 leaf request 的 source；每个 request 在
`leaf_req_valid && leaf_req_ready` 时取得唯一 `txn_seq`（建议增加显式
`leaf_req_seq`，至少在仿真保留内部计数），并把以下 metadata 原子写入 FIFO：

```text
{epoch, row, word_index, last}
```

`leaf_req_valid` 一旦在无 reset 条件下拉高，直到握手前不得撤回或改变地址、
epoch、seq。维护事件只能阻止尚未呈现的新 request；对已经呈现的 request 必须
先握手，再排水。

### 3.3 leaf response / word output

* leaf response 必须与 metadata FIFO 一一对应且保持顺序；
* current epoch 且 `word_ready=0` 时，`leaf_rsp_ready=0`，response payload
  由 leaf 保持稳定；
* stale epoch、maintenance drain 中的 response 和 orphan response 由
  scheduler 主动消费但不产生 `word_valid`；
* current epoch response 只有在 `word_valid && word_ready` 时才退休 metadata；
* `word_last` 仅由 metadata 产生，不能由 leaf 的 RLAST 直接替代；
* 一个 command 的最后一个 current-epoch response 被接受后，才产生
  `cmd_done`；若其间有任一 `leaf_rsp_error`，`cmd_done_error` 置位。

### 3.4 maintenance 状态机

建议使用显式四态，而不是仅用一个 `maintenance_q`：

```text
RUN
  -> FENCE_REQUEST   // 停止新 command；保持已呈现 leaf VALID
  -> DRAIN_RESPONSE  // 消费所有 metadata 对应 response，抑制 word output
  -> COMPLETE        // 清 active/命令队列，更新 epoch，pulse done
```

更严格的时序是：维护请求在 RUN 被锁存；当前已呈现 leaf request 握手后，才
把它加入 metadata；随后将 active/queued command 标为 abandoned，进入
DRAIN_RESPONSE。若维护请求与 response 同周期，response 归旧 epoch 并被
消费，不得泄漏到 `word_*`。

### 3.5 flush 与 abort 的语义差异

* `flush`：排水并丢弃当前 row/cache tags，保留外层 stage geometry/config；
  已接受但未完成的 command 以 canceled/error token 收口，不能留下等待者。
* `abort`：排水、丢弃 row/cache tags，并清除 active stage/config；所有未完成
  command 以 canceled/error token 或统一 abort completion 收口（需在软件 ABI
  中二选一）。
* 两者同时到来：一次 epoch transition，abort 清理范围覆盖 flush；两个 done
  输出都必须可观测。

## 4. 必须加入的 RTL 断言

以下断言应放在 scheduler 的 `ifndef SYNTHESIS` 区域，并在 burst client
连接的 xsim 中打开：

1. **VALID hold**：`leaf_req_stalled_q` 时，`leaf_req_valid`、addr、epoch、
   seq 不变；维护事件不能撤回 VALID。
2. **response hold**：current epoch `leaf_rsp_valid && !word_ready` 时，
   leaf response data/error 保持；stale/drain 分支允许 ready 改为 1。
3. **计数守恒**：`accepted_req - retired_rsp == meta_count_q`，并分别统计
   stale drop、word output、orphan drop。
4. **owner 排他**：不得同时存在 request fence pending 与可接收新 command；
   不得在 `meta_count_q==0` 标记 current response。
5. **last 唯一性**：每个 accepted command 只有一个 metadata `last=1`，且它
   是该 command 的最后一个 `word_index`。
6. **epoch 隔离**：`word_valid` 必须满足 `meta_epoch == current_epoch`；维护
   事件当拍不得产生 word output。
7. **done fence**：`abort_done/flush_done/cmd_done` 只能在对应 metadata、
   active owner 和必要的 downstream drain 条件满足后产生。
8. **orphan response**：`leaf_rsp_valid && meta_count==0` 必须产生错误计数，
   并在有限周期内被 ready 消费。

## 5. 最小 xsim 定向用例矩阵

建议先用小参数（`CMD_FIFO_DEPTH=2`、`MAX_OUTSTANDING=2`、每行 5 words）
验证，不启动 native 大帧：

| 用例 | 激励 | 必须观察 |
|---|---|---|
| 基本行 | 5 个连续 request，R 有随机 stall | 5 words、唯一 last、1 个 cmd_done |
| request stall + abort | VALID 拉高后 leaf_ready 保持 0，再拉 abort | VALID/payload 不撤回；握手后旧 response 被 drain；abort_done |
| response stall + flush | word_ready=0 时 flush | response 被消费但不输出；flush_done 仅在 metadata=0 |
| 队列清空 | active row 中再排 2 条 command，发 abort | queued command 不泄漏到新 epoch；每条都有定义的 canceled/error 收口 |
| 同时 abort+flush | 两信号同周期脉冲并保持数拍 | epoch 只增 1；两个 done 均出现；无重复 done |
| orphan response | meta_count=0 时强制 leaf_rsp_valid | `orphan_rsp_error`，ready 拉高，仿真不死锁 |
| early/missing RLAST | 通过 burst client 注入 | client error sticky；scheduler 不把后续 beat 当新 epoch |
| epoch mismatch/zero row | command epoch 错或 words=0 | cmd_done_error，不发 leaf request |
| epoch wrap guard | 重复维护到边界 | 禁止危险回绕或在完全 quiescent 后安全回绕 |
| response same-cycle | 可选 fall-through leaf | 若不支持则断言/拒绝；若支持则 bypass 计数守恒 |

推荐 scoreboard 只保存每个小用例的 `{epoch,row,index,data,error}`，不要抓取
完整 xsim 波形或大型日志。测试 runner 应把 Vivado/xsim 工作目录放入私有
runRoot，持久化只保留 PASS marker、错误 marker 和末尾少量日志。

## 6. 与现有 AXI fabric 的接入限制

当前 read burst client 和 `c1_axi_n_read_burst_arbiter_128` 在 AXI 侧均为
ID-less。scheduler 的 epoch/seq 只存在 logical seam，不能在共享 fabric
中凭空恢复；因此第一阶段必须满足：

* scheduler 直接连接一个保持 AR/R descriptor 顺序的 leaf；
* 或在 fabric 内为每个 AR 保存 `{client, epoch/seq, arlen}` owner FIFO，
  并保证一个 burst 的 R beat 不与其他 owner 交错；
* early/missing RLAST、orphan R、reset/disable 后残留 R 都必须触发全链路
  fault fence，而不是仅在 scheduler 内增加 epoch；
* 若未来启用 AXI ID，应把 `txn_seq/epoch` 映射到 ID，并仍保留 logical
  response reorder/retire FIFO。

因此本阶段可安全实现的是“单 active row + 有限 read outstanding + 明确
maintenance fence”。跨多个 tensor read/write client 的统一 MLP，需要在
上述 owner/epoch contract 通过后另行设计。

## 7. 结论与下一步

现有模块的基本 ready/valid 和单 outstanding 合同已经足够支撑 boardless
read-only cache refill；但在修复 request VALID 撤回、orphan response、epoch
wrap 和 maintenance 合并语义前，不应把 `c1_cache_refill_scheduler` 接入
真实 adapter 或 portable SoC 默认路径。

建议顺序：

1. 先在 scheduler standalone TB 中补齐上述 10 个定向用例和断言；
2. 修复 request fence 后连接 read burst client，验证 16/32 beat、4-KiB split、
   RLAST fault 和 2/4 outstanding；
3. 再连接 line-cache burst shell，验证 row commit、partial-row invalid、
   flush/abort drain；
4. 最后才设计 read/bypass mux 与 write MLP 的统一 epoch/owner table。

## 8. v5 修订复审（2026-08-27）

`c1_cache_refill_scheduler.sv` 与 standalone TB v5 已重新审阅；原 2.1/2.2
所列的两个高优先级问题已经在 RTL 中得到对应修复：

* `req_pending_q` 保存已经呈现但尚未握手的 request，维护边沿不会撤回
  `leaf_req_valid` 或改变其 payload；握手后该 request 仍进入旧 epoch 的
  metadata FIFO 并在 fence 中排水。
* `meta_count_q==0` 时 `leaf_rsp_ready` 仍为 1，orphan response 被消费并
  计入 `perf_orphan_rsp_count/perf_error_count`，不会把 ID-less 通道锁死。

v5 detached xsim（`run_cache_refill_scheduler_xsim_detached.ps1`）已通过：
stalled pending 跨 abort、stale drop、held-high flush one-shot、new-epoch
row ordering/last 与 orphan drain；Vivado worker 由 `Win32_Process.Create`
启动，私有 run tree 在结束时清理，持久日志只保留 marker 和尾部少量行。

接入真实 `c1_tensor_mem_axi128_read_burst_client` 前仍需把以下项目写入
接口合同或另行修正：

1. **禁止同周期 response**：当前 scheduler 在 `req_fire` 与 response 同周期
   且 `meta_count_q==0` 时会将 response 记为 orphan，丢失该事务。现有
   burst client 为注册式 FIFO，通常满足“至少下一拍返回”；应加断言/约束，
   或实现 request-to-response bypass 后再允许 fall-through leaf。
2. **occupancy/quiescent 分工**：`leaf_req_occupancy` 只接 logical request
   FIFO 计数（reader 的 `perf_req_occupancy`）；`leaf_quiescent` 必须覆盖
   builder、descriptor、AXI R 状态和 response FIFO（reader 的
   `!perf_busy`）。scheduler 会在 occupancy 归零时发 one-cycle
   `leaf_req_flush` 关 builder，随后仍等待 `leaf_quiescent` 才发 done；若
   下游把 occupancy 定义成“所有内部事务”，需避免重复或过早 flush。
3. **取消通知**：abort/flush 清除 active/queued command，但只产生统一的
   `abort_done/flush_done`，不为每条被取消的 command 发 `cmd_done_error`。
   软件若需要逐命令收口，需增加 canceled token 或在 ABI 中明确统一 fence
   完成即代表取消。
4. **地址合法性**：stride 乘法目前按 `ADDR_W` 截断；上游必须保证对齐与
   不溢出，或增加 overflow/alignment reject 与错误完成 token。
5. **统计与断言**：v5 版本的 `perf_error_count` 曾在同一时钟多次
   nonblocking assignment，现已改成组合增量后单点写回。仿真
   response-hold 断言仍应继续覆盖 `leaf_rsp_error`（以及必要的 sideband），
   而不只比较 data。
6. **word 输出撤回（高优先级）**：当前 `word_valid` 的组合条件包含
   `!maintenance_start && !maintenance_q`。若一个 current-epoch response
   已被呈现而 `word_ready=0`，随后 abort/flush 边沿会立即拉低
   `word_valid`，同时 `leaf_rsp_ready` 被置 1 并把该 response 当 stale 消费。
   这违反 source-side ready/valid hold，也与 `c1_window_line_cache_c8` 的
   “不得撤回 stalled tap response”合同不一致。应在维护边沿先保持该 word
   直到 `word_ready`，再开始 epoch fence，或加入独立 output skid/取消握手；
   standalone v5 TB 尚未覆盖该场景。
7. **与现有 line-cache refill ABI 的冲突**：文档连接示例把 `word_*` 直接
   接到 `c1_window_line_cache_c8.refill_word_*`，但 scheduler 在 maintenance
   中会消费 stale response 而不产生 `word_valid`。line cache 的既有合同却
   要求 accepted refill 即使 abort/flush 也继续接收完整的
   `refill_word_count`（内部以 `discard_refill_q` 丢弃数据），否则会永久停在
   `ST_REFILL_DATA`，维护也无法完成。集成必须选择：维护期间继续向 cache
   输出每个 stale word（让 cache discard），或增加独立 drain sink/取消 token
   并修改 cache ABI；不能按当前示例直接连线。

### 8.1 推荐的 drain stream 适配

在不改变 `c1_window_line_cache_c8` 既有“完整计数排水”合同的前提下，推荐
给 scheduler 增加一组独立的取消流端口：

```text
drain_word_valid/ready
drain_word_data, drain_word_error, drain_word_last
drain_word_row, drain_word_index, drain_word_epoch   // 可选诊断 sideband
```

普通流与取消流必须互斥。`meta_count_q==0` 的 orphan 仍由 scheduler 直接
消费并计错；有 stale metadata 时，`leaf_rsp_ready` 改为
`drain_word_ready`，只有取消流握手才弹出 metadata。这样把 backpressure
传回 reader，避免在 line cache 尚未 ready 时丢掉一个 declared word。
直连 line cache 时可将两组 valid 做 OR、两组 ready 接同一个
`refill_word_ready`（互斥保证 data mux 无歧义）；取消流的 error 可固定为
1 或 OR 原始 leaf error，使 cache 的 `discard_refill_q`/poison 路径显式生效。

建议同时导出 `drain_word_mode`（或由两组 valid 互斥推导），并加入断言：

* `word_valid && drain_word_valid` 永不同时成立；
* 任一流 valid 且 ready=0 时，data/error/last/sideband 保持；
* 每个 stale metadata 恰好对应一个 drain handshake，`last` 只在行尾出现；
* `maintenance_complete` 不能早于 drain stream 空闲与 `leaf_quiescent`。

最小新增 TB 应覆盖：response sink stall 后 abort（普通流 hold）、进入 fence
后 drain sink stall/恢复、line-cache 计数少于/多于 stale response、abort+flush
同时边沿，以及 orphan 在 drain sink 不 ready 时仍能独立消费。该方案只增加
组合 mux/少量 sideband 寄存器，正常 RUN 的 15-fps 数据路径不必增加额外
存储；若目标器件时序不允许 `drain_ready→AXI RREADY`，可在取消流前插入
一深度 skid，但不要牺牲 metadata/响应计数守恒。

剩余推荐定向用例：fall-through response（应被断言拒绝）、error response
在 word sink stall 下保持、epoch all-ones 饱和、地址非法 command，以及
leaf 独立 reset/残留 R 的 fault fence。未完成这些用例前，v5 PASS 只代表
standalone 协议门禁，不代表共享 AXI fabric 或 15-fps 性能签核。

## 9. 当前实现复审（2026-08-27）

本轮已把第 8 节中最高优先级的 stalled-word 问题落到 RTL：
`deferred_start_q` 在 word handshake 后启动 fence，因而当前 word 的 VALID/
payload 不会因 abort/flush 边沿撤回，紧随其后的旧响应也不会再作为 normal
word 泄漏。新增 `EMIT_DRAIN_WORDS=1` 及 `drain_word_*` 端口后，已接受的
stale metadata 只有在 drain sink handshake 时才退休；`drain_word_ready=0`
会正确反压到 leaf 并延迟 fence 完成。

对应的 detached 小回归现已覆盖 deferred fence、drain sink stall、AXI128
burst leaf 的 4-KiB split/pack2/response order，以及封装 wrapper 的端口
连通性。当前 marker 为：

```text
C1_CACHE_REFILL_SCHEDULER_FENCE_STALL_PASS ...
C1_CACHE_REFILL_SCHEDULER_DRAIN_PASS ...
C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_PASS ...
C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_WRAPPER_PASS ...
```

仍然保留以下未闭合边界，不能把本轮 PASS 解读为 line-cache 或 15-fps
签核：

1. drain 只对应已 accepted 的 metadata；line-cache 的 declared-word
   refill 若在 fence 前尚有未发出的 suffix，现已由独立
   `c1_cache_refill_completion_adapter` 以 zero/error poison 补齐，但该
   adapter 尚未接入 default SoC，且 synthetic suffix 不是有效 tensor 数据；
2. scheduler 与现有 reader 约定 response 至少晚于 request 一个周期，
   fall-through 同周期 response 目前会被计作 orphan，应在集成层禁止或另加
   bypass；
3. stride/base 的对齐与 ADDR_W 溢出由上游保证，非法 command reject 尚未
   扩展为完整错误协议；abort/flush 只提供统一 done token，不为每个被取消
   command 生成独立 cancel completion；
4. `perf_error_count` 已改为每周期单点增量，避免多个同时发生的错误事件
   互相覆盖；它仍属于诊断计数，不参与数据通路握手决定。

## 10. Exact-count adapter 复审（2026-08-27）

`c1_cache_refill_completion_adapter.sv` 已将 scheduler 的 normal/drain 两流
转换为 line-cache 的单一 declared-count 流。取消或 command error 在计数未
收满时会切换到 synthetic mode，逐词输出 zero/error，并把 `last` 归一到
声明的最终 index；因此 line-cache 可以沿用 `discard_refill_q` 完成排水。

本轮还修复了 late terminal token 竞态：最后一个正常词握手后，adapter 不再
立即清 `active`，而是等待 `cmd_done`/`abort_done`/`flush_done`。`cmd_ready`
同时屏蔽 terminal pulse，避免旧 token 与下一命令重叠。正常 back-to-back、
zero-length reject、epoch-mismatch synthetic、AXI128 取消排水均已通过：

```text
C1_CACHE_REFILL_COMPLETION_ADAPTER_NORMAL_PASS normal=5 synthetic=2 done=4 error_done=2 req=5 rsp=5 cycles=46
C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_EXACT_PASS words=5 drained=2 synthetic=3 req=2 rsp=2 ar=1 beats=1 flush=1 cycles=25
```

集成合同必须明确：

* `sched_cmd_done`、`sched_abort_done`、`sched_flush_done` 三类 token 都要
  接线；缺任何一个，正常命令可能一直保持 active；
* `word_count>=1`，因为 zero-length 只产生错误 completion，不能驱动现有
  line-cache 从 `ST_REFILL_DATA` 退出；
* synthetic suffix 只用于协议收口/触发 discard，不得写入有效行或送入 CNN；
* scheduler 不得在 adapter 关闭后产生过量 response；若目标 leaf 的错误
  行为不能保证这一不变量，应先增加 fault-drain/overrun 保护；
* 当前 ready 是组合反压链，若 Ti60/Efinity 时序不收敛，应插入同时保存
  mode、error、last、row/index/epoch 的一深度 skid，而不能只延迟 data。

该 adapter/组合已经在独立 optional shell 中接上真实 line-cache 的
`refill_req_row/count` 与 stage-base 映射，并通过 boardless exact-shell 回归；
它仍未接入默认 SoC。下一阶段是在统一 read/write owner+epoch mux 下做
native 长帧 abort/drain/QoS 回归，并确认共享写流量不会破坏已接受 AR/R 的
最终服务合同。

### 2026-08-28 控制面推进

第 8 节及其 8.1 中关于“尚未接入 line-cache”“必须另加
cancellation-token”的句子属于 2026-08-27 历史审计快照；后续 exact-count
adapter 已把 normal/drain/synthetic suffix 收口为 exact-count stream，且
由 `c1_window_line_cache_c8_exact_burst_shell` 完成真实三行 cache 的
boardless 接线。当前仍未完成的边界限定为 optional shell 到默认 SoC 的
共享 read/write owner+epoch mux、native 长帧 QoS 和 Ti60/Efinity 资源复测。
新增 `c1_axi_shared_owner_epoch_fence.sv` 已先以独立 xsim gate 锁定维护期
admission、双向 quiescent 与 epoch bump 合同；它尚未改变默认 SoC 接线。
