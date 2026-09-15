# Read long-burst boardless profile

## Selected profile

The existing AXI128 reader already supports `BURST_BEATS` from 1 through 256
and splits every descriptor at a 4-KiB boundary.  The new focused boardless
profile is `BURST_BEATS=16`, `MAX_OUTSTANDING=4`, `RSP_FIFO_DEPTH=64`, selected
by `C1_LONG_BURST_TB`.  It is exposed through the detached runner as:

```powershell
.\case1\scripts\run_tensor_mem_axi128_read_burst_client_xsim_detached.ps1 -LongBurst
```

The normal configuration remains the smaller `BURST_BEATS=4` test profile; no
default SoC instance or board pin/DDR setup changed.

## Why 16 beats first

A 16-beat AXI128 burst transfers 256 bytes.  This is sufficiently long to
reduce AR descriptor pressure materially while remaining short enough to share
an ID-less fabric fairly.  `MAX_OUTSTANDING=4` allows up to 1 KiB of issued read
payload before the response channel retires a descriptor.  The response FIFO
is sized as `2 * BURST_BEATS * MAX_OUTSTANDING = 128` logical slots in the most
conservative generic formula; the focused TB uses 64 slots because its small
stream cannot create four fully filled bursts at once.  Board integration must
restore the conservative size unless the actual controller latency/credit
analysis proves the smaller depth sufficient.

`BURST_BEATS=32` now has a separate compact RTL profile beside the 16-beat
profile.  It is still an opt-in boardless experiment: the default SoC and all
legacy runners retain their original parameters.  A 32-beat burst occupies
512 bytes and therefore needs a larger response-record envelope; the profile
uses `RSP_FIFO_DEPTH=256` and does not claim that this depth is sufficient for
an arbitrary DDR latency.

Run the two A/B cases with detached workers:

```powershell
& .\case1\scripts\run_tensor_mem_axi128_read_burst_profile_xsim_detached.ps1 `
    -RunId burst16_profile_v2_20260827
& .\case1\scripts\run_tensor_mem_axi128_read_burst_profile_xsim_detached.ps1 `
    -Burst32 -RunId burst32_profile_20260827
```

The private Vivado/xsim tree is deleted by each worker.  The test stream has
189 logical requests and 94 packed AXI beats.  It includes a 64-beat
contiguous region, an explicit `0x2f00→0x3000` page split, a gap, a malformed
address and a repeated lane, so the A/B comparison checks geometry and
ordering rather than only counting generated ARs.

## Geometry evidence

`model/read_burst_profile_model.py` counts packed AXI beats and 4-KiB splits
for three `MAX_ROW_WORDS=1280` cache rows.  It reports 640 AXI128 beats per row
and descriptor counts of 160 / 40 / 20 for burst lengths 4 / 16 / 32.  The
model's deliberately optimistic `R beats + AR opportunities` proxy is
2400 / 2040 / 1980 cycles for those three rows.  It therefore measures
address-channel pressure only—not actual DDR cycles, fps or system QoS.

`model/test_read_burst_profile_model.py` additionally checks a base at `0xff0`
to ensure a configured 16-beat profile is split as one beat before the page
boundary and 16 after it.

The cache-shell pressure profile now uses the same 16-beat/4-outstanding
parameters with a 64-pixel × 2-group row (128 logical words, 64 AXI beats).
Its detached XSim BFM holds the first response long enough to fill the reader
descriptor queue and reports:

```text
C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_PASS taps=6 refills=5 words=640
  bursts=20 beats=320 max_outstanding=4 ... cycles=1883
```

The earlier small smoke remains `BURST_BEATS=4/MAX_OUTSTANDING=3` and reports
`80 words/10 bursts/40 beats/max_outstanding=2`.  The long profile therefore
proves parameter propagation and an actual four-descriptor burst window, but
does not by itself measure a native-frame DDR rate.

The combined optional profile (`-LongBurst -BeatFifo -TailFlush -ReqPopRefill`)
also passes:

```text
C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_PASS taps=6 refills=5 words=640 bursts=20 beats=320 max_outstanding=4 tail_flush=5 req_pop_refill=1 flush_closes=5 closes=20 cycles=1883
```

The cycle count is unchanged because this smoke is refill/response-latency
dominated; it proves that packing, four outstanding descriptors, beat-record
drain, known-tail close and full request FIFO replacement can coexist without
changing cache data or row ordering.

### Compact RTL A/B result

| profile | AR bursts | AXI beats | packed requests | full/short bursts | max outstanding | page split | cycles |
|---|---:|---:|---:|---:|---:|---:|---:|
| `BURST_BEATS=16` | 9 | 94 | 94 | 5 / 4 | 3 | 1 | 397 |
| `BURST_BEATS=32` | 7 | 94 | 94 | 2 / 5 | 3 | 1 | 397 |

The 32-beat candidate removes two AR descriptors in this mixed stream while
leaving payload and logical response order unchanged.  Equal cycle counts are
expected here: the deterministic producer and BFM response cadence dominate
the 397-cycle smoke.  This is not a native frame-rate or DDR service-time
measurement.  Before enabling 32 beats on a board, check EBR depth, AXI
controller maximum burst length, read turnaround/QoS and the longer descriptor
hold time under display/capture traffic.

### Native maximum-row cache-shell profile

The same burst shell now has an opt-in `-MaxRow` mode.  It configures
`W=640`, `H=1`, `G=2` (`MAX_ROW_WORDS=1280`), `BURST_BEATS=32`,
`MAX_OUTSTANDING=4`, and a 16-entry BFM descriptor queue.  The BFM checks
contiguous AR address order, rejects any 4-KiB crossing, and counts the two
expected page-boundary starts at `0x2000` and `0x3000`.  Eight taps at both
packed lanes and around those boundaries then verify that the resident row is
not refilled.

```text
C1_WINDOW_LINE_CACHE_C8_BURST_SHELL_MAXROW_PASS taps=8 refills=1 words=1280
  bursts=20 beats=640 packed=640 ar=20 ar_beats=640 page_splits=2
  max_outstanding=4 tail_flush=0 cycles=1636
```

Run it with the existing detached runner:

```powershell
& .\case1\scripts\run_window_line_cache_c8_burst_shell_xsim_detached.ps1 `
    -MaxRow -RunId maxrow_burst32_compact_20260827
```

This is a boardless maximum-row geometry/protocol gate.  The 1,636-cycle
count is dominated by the deterministic BFM and request stream; it must not be
extrapolated to native 640x480@15 fps.  The default shell and portable SoC
parameters remain unchanged.

The same maximum-row stream was also rerun with `-BeatFifo -TailFlush
-ReqPopRefill -RspPopRefill`.  It retained `20/640/640/4` burst/beat/packed/
outstanding counts and emitted `tail_flush=1` at the same `cycles=1636`, so the
optional record layout and maintenance/request boundary compose for this
geometry.  This is a protocol-compatibility result; it does not establish an
EBR mapping or a frame-rate improvement.

## Follow-up validation

Before enabling the profile in a native build, run the small detached XSim
profile and then check, in Efinity: R channel ordering with four descriptors,
DDR controller accepted AR length, WNS/TNS, EBR mapping for the response FIFO,
and QoS while video/capture are active.  A positive geometry model result alone
is not evidence of 640x480@15 fps.
