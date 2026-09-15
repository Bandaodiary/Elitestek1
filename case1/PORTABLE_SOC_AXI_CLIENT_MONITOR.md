# Portable SoC seven-client AXI monitor gate

`sim/c1_axi_client_traffic_monitor.sv` is a testbench-only SystemVerilog
monitor bound to the internal `axi_s_*[0:6]` vectors of
`c1_r1_portable_soc`. It does not add ports, state, or logic to the production
SoC. The optional gate is enabled through the existing detached runner:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\case1\scripts\run_r1_portable_soc_cache_ddr_bfm_xsim_detached.ps1 `
  -Frame 64x48 -ClientTrafficGate -RunId portable_client_gate_64x48_20260825
```

The runner still executes the real cache-DDR BFM testbench. The monitor then
requires the traffic directions that are architectural for a 64x48 full-chain
job:

| client | leaf | required handshakes |
|---:|---|---|
| 0 | boardless frame job | AW/W/B and AR/R |
| 1 | capture XRGB writer | AW/W/B |
| 2 | parameter loader | AR/R |
| 3 | capture table reader | AR/R |
| 4 | display original reader | AR/R |
| 5 | display styled reader | AR/R |
| 6 | tensor/cache bridge | AR/R; writes are reported but optional for a descriptor image |

For each client the monitor counts accepted AW, W, B, AR and R handshakes,
and records the maximum consecutive cycles of `VALID && !READY` on AW, W and
AR. It also emits separate maximum B/R response-hold counters, which help
distinguish an arbiter grant delay from a leaf that has accepted a read but is
not yet ready to consume the response. The response-hold line is the key
diagnostic for this ID-less serial fabric: a long `rN` value identifies the
leaf that is locking the read direction. The gate bound is one million
core-clock cycles; this is a starvation
sanity bound, not a 15-fps performance claim. On success it emits
`C1_R1_PORTABLE_SOC_AXI_CLIENT_MONITOR_PASS` and a per-client stats marker.

This gate is intentionally narrower than a full portable-SoC signoff. It does
not prove Efinix synthesis, board I/O, DDR controller timing, resource usage,
real CNN numerical accuracy, or 15-fps throughput. It also does not require
client 6 writes because the optional window-cache path can legally be
read-only for a given stage/descriptor image.

## First 64x48 observation

The first detached run (`portable_client_gate_64x48_20260825`) reached the
monitor report, and all required client directions were present. It was
correctly rejected by the one-million-cycle guard because client 5 (styled
display reader) reached a maximum AR wait of **1,243,738 core cycles**. The
same run measured a **1,243,662-cycle R response hold on client 4** (the
styled reader's own R hold was only 368 cycles), directly identifying the
original-display reader as the lock source. This is a real portable-SoC
QoS/performance finding, not a missing-traffic failure. Until the arbitration
and/or display/tensor scheduling is improved, this gate must remain recorded
as a diagnostic FAIL rather than a seven-client PASS.

## Protocol-safe display response FIFO experiment

The optional `-DisplayResponseFifo` build inserts a 59-bit token FIFO after
each display XRGB reader. The test configuration uses depth 128 and reserves
64 token entries before admitting another reader burst. The admission check
is inside the reader's pre-AR state; once `ARVALID` is presented, the reader
keeps both VALID and payload stable until the arbiter handshake. A simulation
guard in `c1_display_prefetch_pair` checks this rule explicitly.

The protocol-safe full run
`portable_display_fifo_reader_gate_full_64x48_20260825` is a strict PASS:

```text
C1_R1_PORTABLE_SOC_AXI_CLIENT_MONITOR_STATS
c4=0/0/0/48/768/0/0/76/273
c5=0/0/0/48/768/0/0/83/361
C1_R1_PORTABLE_SOC_AXI_CLIENT_MONITOR_RESPONSE_HOLD_MAX ... r4=2 r5=2
C1_R1_PORTABLE_SOC_AXI_CLIENT_MONITOR_PASS clients=7 max_wait_bound=1000000
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_PASS frame=64x48 ...
  axi_aw=40224 axi_w=41664 axi_b=40224 axi_ar=48427 axi_r=51643
```

The same FIFO branch was checked independently by
`native_display_fifo_full_20260825`: both 640×480 streams passed the
address/4-KiB/row checks and pixel RGB comparison (`307200/307200` responses
per path, `underflow=0/0`). The default bypass remains available and its
functional 8×8 run `portable_display_fifo_bypass_functional_8x8_20260825`
passes; its monitor gate intentionally reproduces the old HOL starvation, so
that diagnostic failure is not counted as a regression. FIFO storage is an
unmapped resource estimate only (59×128×2 = 15,104 bits); no Efinity/Ti60 or
15-fps claim follows from this preflight. Full details are in
`DISPLAY_RESPONSE_FIFO_QOS_PREFLIGHT.md`.

For `C1_TWO_FRAME` builds the monitor now waits for two job completions before
reporting, so `portable_display_fifo_twoframe_monitor2_64x48_20260825` provides
an aggregate two-frame snapshot rather than the earlier first-frame-only
snapshot:

```text
c0=96/1536/96/144/1716 ...
c4=0/0/0/100/1600/0/0/89/866
c5=0/0/0/100/1600/0/0/83/961
C1_R1_PORTABLE_SOC_AXI_CLIENT_MONITOR_RESPONSE_HOLD_MAX ... r4=2 r5=2
C1_R1_PORTABLE_SOC_AXI_CLIENT_MONITOR_PASS clients=7 max_wait_bound=1000000 job_completions=2
C1_R1_PORTABLE_SOC_CACHE_DDR_BFM_TWO_FRAME_PASS frame=64x48 done=2 swaps=2 drops=0 ...
```

The BFM marker remains the authoritative lifecycle check (`done=2`,
`swaps=2`, `drops=0`); the monitor's `job_completions=2` makes its traffic
counts cover both jobs.
