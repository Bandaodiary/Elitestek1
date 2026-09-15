# Read-refill tail flush (boardless optional optimization)

`c1_window_line_cache_c8_burst_shell` now has the optional
`REFILL_TAIL_FLUSH` parameter.  The default remains `0`, so existing cache
integration contracts are unchanged.

When enabled, the shell remembers the handshake of the final 64-bit word in a
row refill.  It waits until the read client's logical-request FIFO reports
empty, then pulses `req_flush` for one clock.  Waiting for an empty FIFO is
important: a final request in the opposite 64-bit lane can still be consumed
and packed into the preceding AXI-128 beat.  No AXI address, burst length,
response order, or cache row commit rule changes.

The optimization removes the generic `BUILD_TIMEOUT_CYCLES` wait from a row
tail.  It does not overlap two cache-row refills; the shell still serializes
rows until the current row's responses are committed.  Therefore it is a
small latency reduction, not a claim of 640x480@15 fps.

## Boardless evidence

The compact arithmetic model can be run without Vivado:

```text
python case1/model/read_tail_flush_model.py
```

It emits one `READ_TAIL_FLUSH_MODEL_PASS` marker and checks even/odd row
lengths.  For the six-tap shell smoke geometry (five 8-word rows,
`BURST_BEATS=4`, `BUILD_TIMEOUT_CYCLES=3`) the model predicts unchanged
`beats=20`, `bursts=5`, and `packed=20`, with 10 request/descriptor cycles
removed (`baseline_cycles=55`, `fast_cycles=45`).

The detached RTL smoke uses the existing cache BFM and defines
`C1_CACHE_TAIL_FLUSH_TB`:

```text
case1/scripts/run_window_line_cache_c8_burst_shell_tailflush_xsim_detached.ps1
```

The test checks the same cache data and multi-outstanding response contract as
the baseline, and additionally requires one internal tail-flush pulse per
refill.  The worker is WMI-detached and deletes its private `xsim.dir` in a
`finally` block; only `status.json`, a one-line marker summary, and bounded
failure context are retained.

The current small A/B markers are:

```text
baseline: C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_PASS taps=6 refills=5 words=80 bursts=10 beats=40 max_outstanding=2 tail_flush=0 flush_closes=0 closes=10 close_cycle_sum=1329 flush_cycle_sum=0 cycles=303
fast:     C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_PASS taps=6 refills=5 words=80 bursts=10 beats=40 max_outstanding=2 tail_flush=5 flush_closes=5 closes=10 close_cycle_sum=1319 flush_cycle_sum=682 cycles=303
```

Thus descriptor close edges move 10 cycles earlier (the model prediction),
while this deliberately delayed BFM's total tap-test wall cycles remain 303;
the latter is dominated by response latency and is not a frame-rate claim.

The mode is intended for a boardless A/B measurement first.  Before selecting
it in the final SoC, repeat the smoke with the target Efinity reader settings
and verify that any downstream request FIFO occupancy signal has the same
empty-cycle interpretation.
