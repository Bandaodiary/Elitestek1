# Read response beat-FIFO prototype

## Scope

`rtl/dma/c1_tensor_mem_axi128_read_burst_client.sv` now has an optional
`RSP_FIFO_BEAT_MODE` parameter.  The default (`0`) is unchanged.  With the
parameter set to `1`, one FIFO slot represents one AXI `R` beat:

```text
128-bit beat data + lane_count[1:0] + first_lane + second_lane + error
```

The local 64-bit response interface remains unchanged.  `rsp_lane_q` holds the
selected sub-lane while `rsp_valid` is stalled; a two-lane record is retired
only after two successful handshakes.  A one-lane local-error or synthesized
error is represented by a zero-data, `lane_count=1`, `error=1` record.

For a safe no-overflow bound, beat mode checks
`RSP_FIFO_DEPTH >= BURST_BEATS*MAX_OUTSTANDING`; a typical configuration can
therefore change the historical depth from `2*BURST_BEATS*MAX_OUTSTANDING` to
`BURST_BEATS*MAX_OUTSTANDING`.  `rsp_capacity` is deliberately conservative
(it does not use same-cycle `rsp_pop`) to keep the local response backpressure
out of AXI `RREADY` timing.

## Verification without a board

The existing read-client scoreboard is parameterized by `C1_BEAT_FIFO_TB` and
uses depth 12 for `BURST_BEATS=4`, `MAX_OUTSTANDING=3`:

```powershell
& .\scripts\run_tensor_mem_axi128_read_burst_client_beatfifo_xsim_detached.ps1
```

Observed marker (detached WMI worker, private xsim tree removed):

```text
C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_BEAT_FIFO_PASS req=19 ar=6 beats=10 packed=7 fifo_depth=12
```

The malformed-path regression drives an early `RLAST` on descriptor 0 and no
`RLAST` on descriptor 1.  It checks ordered data/error responses, synthesized
tail errors, terminal missing-`RLAST` errors, and counters:

```powershell
& .\scripts\run_tensor_mem_axi128_read_burst_client_beatfifo_malformed_xsim_detached.ps1
```

```text
C1_TENSOR_MEM_AXI128_READ_BURST_CLIENT_BEAT_FIFO_MALFORMED_PASS req=16 ar=2 beats=6 errors=8 fifo_depth=8
```

The default logical-entry regression still passes (`req=19 ar=6 beats=10
packed=7`).

The option is now forwarded by `c1_tensor_mem_axi128_read_fabric_2c` as
`LEAF_RSP_FIFO_BEAT_MODE`, and by `c1_window_line_cache_c8_burst_shell` as
`RSP_FIFO_BEAT_MODE`.  The two-client fabric regression with leaf depth 16
passes the same `req=16 ar=6 beats=8 packed=6 max_inflight=5` scoreboard, and
the cache shell passes `taps=6 refills=5 words=80 bursts=10 beats=40` with
depth 12.  Both wrappers retain mode zero by default.

## Resource interpretation

The FIFO *record depth* is halved, but storage bits are not: a logical mode
pair is approximately `2*(64+1)=130` bits per beat, while a beat record is
`128+2+1+1+1=133` bits.  Thus the expected gain is fewer entries/address
bits and simpler two-write bookkeeping, not a 2× bit-capacity reduction.
Actual EBR/BRAM mapping is device/tool dependent; run the small proxy with
the beat parameter in Efinity before changing the default fabric.

For a same-parameter Artix-7 proxy (`REQ16/BURST16/MAX4/RSP64`), logical mode
uses 12,045 LUT / 5,378 FF / WNS +1.046 ns, while beat mode uses 1,714 LUT /
1,182 FF / WNS +1.380 ns.  With the mode forwarded through two leaves and the
record depth reduced from 64 to 16, the integrated fabric is 2,194 LUT /
1,630 FF / WNS +1.815 ns (logical comparison: 31,905 LUT / 10,075 FF /
WNS +1.928 ns).  The latter comparison includes the intentional depth
reduction, so it is a sizing result rather than a pure encoding-only delta.

## Integration recommendation

Keep `RSP_FIFO_BEAT_MODE=0` in the current SoC/fabric until a Ti60/Efinity
proxy confirms EBR inference and timing.  The beat mode is an interface-
compatible seam and can be selected per leaf; no AXI ordering, early/missing
`RLAST`, local-error, or software-visible response semantics are changed.
