# Cache-refill scheduler seam

`rtl/dma/c1_cache_refill_scheduler.sv` is a board-independent, read-only
front end for the line-cache refill path.  It is intentionally not connected
to the default portable SoC yet.

## Interface contract

Each accepted command describes one row:

| signal | meaning |
|---|---|
| `cmd_base_addr` | physical address of word 0 |
| `cmd_stride_bytes` | byte increment per logical word (normally 8 for C8) |
| `cmd_row` | cache row sideband |
| `cmd_word_count` | number of logical words; zero is rejected |
| `cmd_epoch` | generation associated with the row |

Commands are stored in a small FIFO (`CMD_FIFO_DEPTH`), while only one row is
active.  `cmd_ready` supports a full-FIFO simultaneous pop/push.  The active
row emits logical requests on `leaf_req_*`; `leaf_req_epoch` is carried with
every request.  A registered pending slot holds a request until handshake,
including across an abort/flush edge, so a stalled `VALID` is never withdrawn.

`MAX_OUTSTANDING` is a hard credit limit on accepted leaf requests.  The
metadata FIFO stores the corresponding epoch, row, index and `last` bit.  The
leaf is ID-less, so responses must return in request order; the scheduler
asserts this assumption in simulation and uses the metadata head to tag each
word.

The leaf must provide:

* `leaf_req_occupancy`: logical request FIFO occupancy (the reader's
  `perf_req_occupancy` is suitable);
* `leaf_quiescent`: no builder, issued descriptor, response FIFO or other
  state belonging to this scheduler.

After the final request, and after a maintenance edge, the scheduler waits for
`leaf_req_occupancy==0` and pulses `leaf_req_flush` for one cycle.  This maps
directly to the existing read-burst client's `req_flush` input and prevents a
new row from merging with an older builder.

## Epoch/maintenance fence

`abort_req` and `flush_req` are edge-qualified.  The first edge while idle or
active stops new command/request admission; the epoch transition is deferred
if a current-epoch word is stalled (`word_valid && !word_ready`), so its
ready/valid payload remains stable until handshake.  Otherwise the fence
advances `current_epoch` and clears queued/active work, and drains all already
accepted leaf responses.  Stale
responses are consumed but never asserted as `word_valid`.  The fence closes
only when metadata, pending request, leaf close pulse, leaf response and
`leaf_quiescent` are all clear; then the corresponding `*_done` pulse is
issued.  A second distinct edge during that same drain is folded into the
existing fence (its done pulse is remembered) and does not advance the epoch a
second time.  Held-high requests do not repeat.

If `leaf_rsp_valid` arrives with an empty metadata FIFO, it is consumed as an
orphan and increments `perf_orphan_rsp_count` and `perf_error_count`; this
keeps a malformed ID-less leaf from deadlocking the fence while exposing the
protocol violation.  Epoch wrap is saturated: a maintenance edge at the all-
ones epoch sets an internal exhausted flag and blocks future command
admission, requiring reset rather than allowing old responses to alias a new
epoch.

### Deferred fence and canceled-response stream

The fence is ordered with the normal word stream.  If a maintenance edge is
observed while a current-epoch word is already presented, that word remains
`word_valid` until `word_ready` accepts it.  The scheduler then starts the
epoch fence on the following cycle; a response already waiting at that point
cannot become a second normal word and is either consumed as stale
(`EMIT_DRAIN_WORDS=0`) or presented on the canceled-response stream
(`EMIT_DRAIN_WORDS=1`).  This `deferred_start_q` boundary prevents a VALID
withdrawal or a post-fence current-word leak.

With `EMIT_DRAIN_WORDS=1`, connect and backpressure the separate
`drain_word_valid/ready/data/error/last/row/index/epoch` stream.  Normal and
drain streams are mutually exclusive.  A drain word is marked `error=1` and
is retired only when the drain sink handshakes; leaving
`drain_word_ready=0` intentionally holds the leaf response and delays fence
completion.  A line-cache mux may OR the two valid signals and feed the same
ready back to both streams, provided it preserves the drain metadata/error
semantics.

The drain stream represents **accepted** leaf requests only.  If a row
declares 1280 words but an abort occurs after only 40 requests entered the
leaf, there are no metadata entries for the remaining 1240 words.  The
existing `c1_window_line_cache_c8` contract nevertheless requires exactly the
declared count before it leaves `ST_REFILL_DATA`.  Therefore a direct
`word_*` connection is not a complete line-cache integration: it still needs
a cancellation-token/completion adapter (or a line-cache ABI change that can
cancel the unissued suffix).  This limitation is deliberate and remains
visible in the staged seam.

## Existing-path connection

For a staged integration with a read-burst leaf, connect:

```text
c1_window_line_cache_c8.refill_req_*  -> scheduler command source
scheduler leaf_req_*                  -> c1_tensor_mem_axi128_read_burst_client.req_*
reader perf_req_occupancy              -> scheduler leaf_req_occupancy
reader perf_busy==0                    -> scheduler leaf_quiescent
reader rsp_*                           -> scheduler leaf_rsp_*
scheduler word_*                       -> normal side of a refill-word mux
scheduler drain_word_*                 -> canceled side of that mux
refill-word mux ready                  -> both scheduler word/drain ready inputs
scheduler leaf_req_flush               -> reader req_flush
```

The scheduler does not alter ordinary tensor writes/bypass traffic and does
not replace `c1_tensor_window_cache_axi_client`; an epoch-aware read/write
mux is still required before enabling it in the final SoC.

The reusable boardless composition
`rtl/dma/c1_cache_refill_scheduler_read_client.sv` packages the scheduler and
AXI128 read leaf.  Its `SCHED_MAX_OUTSTANDING` (default 16) is logical-word
metadata credit, while `READER_MAX_OUTSTANDING` (default 4) is AXI burst
descriptor credit; `REQ_FIFO_DEPTH` is the reader's logical request FIFO.
They are intentionally independent so a burst leaf can keep its descriptor
pipeline full without reducing scheduler ordering metadata to four words.
The wrapper exposes reader counters but does not instantiate vendor IP or
change the default SoC.

## Boardless validation

`sim/tb_c1_cache_refill_scheduler.sv` uses a tiny delayed in-order leaf BFM.
It covers a stalled request held across `abort_req`, command FIFO
cancellation, two-request credit, stale-response drain, new-epoch row
ordering/`last`, one-shot held-high flush, and an orphan response.  The
detached runner is
`scripts/run_cache_refill_scheduler_xsim_detached.ps1`; it launches Vivado
through `Win32_Process.Create`, keeps raw output in a private run directory,
and retains only bounded marker/tail logs.

Observed marker:

```text
C1_CACHE_REFILL_SCHEDULER_PASS cmd_accept=3 req=4 rsp=5 words=3 stale_drop=1 orphan=1 max_outstanding=2 epoch=2 abort_done=1 flush_done=1 flush_pulse=1 cycles=68
```

The additional boardless gates are:

```text
C1_CACHE_REFILL_SCHEDULER_FENCE_STALL_PASS req=2 rsp=2 words=2 flush_done=2 epoch=2 cycles=31
C1_CACHE_REFILL_SCHEDULER_DRAIN_PASS req=2 rsp=2 drain=2 stale=2 max_outstanding=2 epoch=1 flush=1 cycles=23
C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_PASS commands=2 words=25 req=25 rsp=25 ar=13 axi_beats=13 max_outstanding=2 flush=1 cycles=156
C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_WRAPPER_PASS words=3 bursts=1 beats=2 cycles=18
```

The bare scheduler proxy synthesis (Artix-7 `xc7a200tsbg484-1`, 100 MHz,
`CMD_FIFO_DEPTH=8`, `MAX_OUTSTANDING=4`, `EPOCH_W=4`) reports 839 LUT, 1647
registers, 0 BRAM tile, 0 DSP and WNS +1.274 ns (TNS 0).  This is a small
control-only proxy including the optional drain ports; it is not a Ti60/
Efinity mapping or a native frame timing claim.

This is a protocol/ordering gate, not a 15-fps signoff.  Native frame QoS and
the read/write epoch scheduler remain later integration steps.

## Exact-count completion bridge (2026-08-27)

`rtl/dma/c1_cache_refill_completion_adapter.sv` now closes the remaining ABI
gap between this scheduler and `c1_window_line_cache_c8`.  It merges the
normal and canceled `drain_word_*` streams into one `refill_word_*` stream and,
when a scheduler terminal token arrives before the declared count, emits
zero/error poison words for the unissued suffix.  The poison words preserve
the line-cache count contract; they are not recovered tensor data and must
cause the row to be discarded.

The adapter keeps `active` asserted and `cmd_ready` low until **both** the
declared word count and one terminal token (`cmd_done`, `abort_done`, or
`flush_done`) have been observed.  This correctness-first wait closes a late
`cmd_done`/next-command race.  Therefore all three terminal outputs must be
wired; tying them off leaves a normal row permanently active.  It also adds a
small row-to-row bubble while the reader reports quiescent.

The reusable composition
`rtl/dma/c1_cache_refill_scheduler_read_client_exact.sv` packages the adapter
around the scheduler→AXI128 reader wrapper.  Its detached boardless gates are:

```text
C1_CACHE_REFILL_COMPLETION_ADAPTER_PASS words=5 drained=2 synthetic=3 req=2 rsp=2 flush=1 cycles=23
C1_CACHE_REFILL_COMPLETION_ADAPTER_NORMAL_PASS normal=5 synthetic=2 done=4 error_done=2 req=5 rsp=5 cycles=46
C1_CACHE_REFILL_SCHEDULER_READ_CLIENT_EXACT_PASS words=5 drained=2 synthetic=3 req=2 rsp=2 ar=1 beats=1 flush=1 cycles=25
```

The normal gate holds a second command immediately after the first row rather
than waiting for `refill_done`, covering the late-terminal-token hazard.  A
zero-length command is an error-only diagnostic case; line-cache integration
must guarantee `word_count>=1`, because the line cache exits its refill state
from the final word handshake rather than the adapter's diagnostic `done`
pulse.

The current Artix-7 proxy for the exact composition (`CMD_FIFO_DEPTH=8`,
logical scheduler credit 16, reader burst credit 4, 32-entry request FIFO,
16-beat bursts) reports 35,435 LUT, 11,743 registers, 0 BRAM tile, 0 DSP,
WNS +0.799 ns and TNS 0 at 100 MHz.  This is a wrapper-only upper/reference
number, not a Ti60/Efinity or full-SoC estimate.  The adapter is a combinational
ready/valid bridge; if the target timing report exposes a long
`refill_word_ready→AXI RREADY` path, insert a mode/sideband-preserving one-entry
skid at this seam before enabling it.

At the time of this 2026-08-27 snapshot, neither the exact composition nor the
adapter was connected to the default SoC.  The row/base mapping was subsequently
closed in the independent 2026-08-28 exact shell; the remaining integration gate
is a single read/write owner+epoch mux, followed by native long-frame QoS.

## Exact shell接入真实 line-cache（2026-08-28）

`rtl/dma/c1_window_line_cache_c8_exact_burst_shell.sv` 现已把上述 exact
composition 接到实际的 `c1_window_line_cache_c8` refill ABI，仍保持只读、
boardless 和默认 SoC 隔离。字段映射如下：

```text
stage_base_valid/addr + group_start_*  -> 原子捕获 stage_base_q
frame_width * frame_groups             -> row_words
row_words << 3                         -> row_stride_bytes_q
cache refill_req_row/word_count       -> exact cmd row/word_count
stage_base_q + row*row_stride_bytes_q  -> exact cmd base
8 bytes                                -> exact cmd stride（每个 C8 word）
exact current_epoch                    -> exact cmd epoch（握手时锁存）
exact refill_word_*                    -> cache refill_word_* 单流
abort_req/flush_req                    -> cache 与 exact 双路扇出
cache_done + exact_done                -> 外部 *_done 双路 join
exact m_axi_*                          -> 外部 AXI4 read master
```

壳内的一项 command holding register 在 cache 请求与 scheduler 命令之间
解耦 ready/valid，并锁存 row-specific base、8-byte word stride 和 epoch；
因此 fence 在请求等待期间递增 epoch 时，不会改变一个已经呈现的 stalled
command。`group_start_ready` 还要求
`stage_base_valid`、exact reader quiescent、无 pending command/fence，避免
新 stage 的基址或几何覆盖旧 epoch 的排水过程。

exact stream 与 cache 之间另有 `REFILL_SKID_DEPTH`（默认 2）的注册 FIFO，
输入 ready 只看 FIFO occupancy，不回看 cache 的 `refill_word_ready`。它切断
cache→adapter→reader 的长 RREADY 组合路径，同时保存 data/error/last/row/
index/epoch 全部 sideband；代价是最多两词的额外缓冲和固定的行间延迟。

真实 line-cache 的 `refill_word_*` 只消费 valid/data/error/last；row/index/
epoch sideband 在 exact adapter 内校验。正常行必须收到 declared count 和
scheduler terminal token；取消行收到已接受 prefix 的 drain words 后，再由
adapter 发 zero/error poison suffix，line-cache 因 error 丢弃该行并重试挂起
tap。`word_count` 必须大于 0。

小型端到端 gate（`sim/tb_c1_window_line_cache_c8_exact_burst_shell.sv`）的
最新 marker 为（run id `line_cache_exact_counter_v2_20260828`）：

```text
C1_WINDOW_LINE_CACHE_C8_EXACT_BURST_SHELL_PASS responses=4 refills=3 words=24 ar=5 beats=10 flush=1 epoch=1 cancel_req=3 cancel_source=3 cancel_drain=3 cancel_synthetic=5 cancel_unified=8 cycles=143
```

其中被取消的 8-word 行实际观察到 3 个已接受逻辑请求/3 个 drain words 和
5 个 synthetic words，统一 refill stream 仍严格为 8 个 handshake。测试在
flush edge 后的下一拍恢复 AXI AR 服务；若外部长期禁止 AR，reader 中已经
接受的请求无法形成/完成 descriptor，scheduler 会按协议等待 leaf
quiescent，最终表现为预期的 drain back-pressure，而不是可安全忽略的
超时。板级 QoS 必须保证已接受读请求最终得到 R channel 服务。

该 shell 的 Artix-7 proxy（`MAX_ROW_WORDS=1280`、`LINE_ROWS=3`、
`REFILL_SKID_DEPTH=2`）在加入注册 FIFO 后已通过综合：35,639 LUT /
11,930 FF / 7.5 BRAM tile / 0 DSP，100 MHz WNS +0.302 ns、TNS 0。
未插 FIFO 的对照 run 为 35,543 LUT / 11,923 FF、WNS -1.622 ns / TNS
-97.709 ns；因此这次改善是实际的时序收敛而非工具报告波动，代价是约
96 LUT、7 FF 和最多两词缓冲。Vivado 仍提示 7 个 data_mem BRAM 未合并
可选输出寄存器（data_mem_reg_1..7）；后续应在目标 Efinity/EBR 上重新
评估 RAM wrapper 和 tap-read pipeline。
默认 SoC、读写 owner mux 和 legacy client-6 仍未切换。
