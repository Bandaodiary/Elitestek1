# `c1_tensor_mem_axi128_read_burst_client`

This is a board-independent read-only traffic client for the case-1 tensor
path.  It is an experiment beside the existing single-request bridge; it is
not wired into the SoC by default.

## Local request/response seam

* `req_valid/req_ready/req_addr` accepts one 32-bit byte address.  Addresses
  must be 8-byte aligned (`addr[2:0]==0`); a malformed address is consumed and
  produces one ordered `rsp_error` response with zero data.
* `req_flush` closes the currently accumulating burst.  It does not discard
  requests already accepted into the FIFO.  A producer should pulse it after a
  frame/tensor stream (or use the bounded `BUILD_TIMEOUT_CYCLES` timeout).
* `rsp_valid/rsp_ready/rsp_error/rsp_rdata` is an in-order response FIFO.  A
  packed AXI beat can emit two responses; the lane order is the order in which
  the two requests were accepted.

## AXI read seam

The port emits `AR` with `ARSIZE=4` (16 bytes), `ARBURST=INCR`, and
`ARLEN=beats-1`.  Requests are grouped when their aligned addresses are the
same beat or consecutive 16-byte beats, never across a 4-KiB boundary, and
never beyond `BURST_BEATS`.  By default two repeated reads of the same 64-bit
half may also share one beat (`ALLOW_SAME_LANE_DUP=1`); set that parameter to
zero when an upstream contract forbids duplicate lanes.  At most
`MAX_OUTSTANDING` descriptors may have an
accepted AR.  There are no AXI IDs: the connected fabric/interconnect must
return `R` beats in AR acceptance order.  `RREADY` is deasserted when the local
response FIFO cannot hold both halves of the next beat.

`RRESP!=OKAY`, an early `RLAST`, or a missing `RLAST` marks the affected
response(s) as errors.  For an early `RLAST`, the client synthesizes ordered
error responses for the unreturned lanes so a malformed slave cannot leave the
local stream permanently busy.

## Parameters and sizing

`REQ_FIFO_DEPTH` absorbs producer bursts; `BURST_BEATS` trades AR overhead for
descriptor lane-map storage; `MAX_OUTSTANDING` hides DDR/AXI latency.  Set
`RSP_FIFO_DEPTH >= 2*BURST_BEATS*MAX_OUTSTANDING` when full burst absorption is
required.  The default values are intentionally conservative for simulation;
board integration should rerun synthesis with the target device and actual
cache miss rate.

## Instrumentation

`perf_req_accept_count` counts accepted local requests;
`perf_axi_burst_count` and `perf_axi_beat_count` count accepted AR/R
transactions; `perf_rsp_count` counts responses consumed by the local client;
`perf_packed_request_count` counts logical requests eliminated by 128-bit
packing; and `perf_error_count` counts error responses.  Occupancy and maximum
outstanding counters are for performance tuning, not flow control.

The companion `tb_c1_tensor_mem_axi128_read_burst_client.sv` exercises packing,
4-KiB splitting, multiple outstanding descriptors, backpressure, a local
alignment error as both a descriptor head and a successor to a legal request,
and the corresponding no-pack behavior.  Use the detached runner in
`scripts/run_tensor_mem_axi128_read_burst_client_xsim_detached.ps1`; its private
simulator directory is removed when the worker exits.

The cache-shell pressure test uses a 20-cycle first-read delay and an AXI-valid
hold BFM.  It has observed 5 refills / 80 words / 10 bursts / 40 beats with
`max_outstanding=2`.  This is a boardless client/fabric result only: the current
`c1_axi_n_serial_arbiter_128` still locks one read burst at a time, so a final
SoC must bypass or extend that arbiter before expecting the same overlap on the
board.

For the 15-fps throughput phase, the separate
`sim/tb_c1_tensor_mem_axi128_read_burst_profile.sv` drives the same leaf with
`BURST_BEATS=16` and `32` (runner switch `-Burst32`).  It checks pack2, an
explicit 4-KiB page split, malformed-address ordering and four-descriptor
admission on a 189-request stream.  The compact A/B result is `9→7` AR bursts
with `94` AXI beats in both cases; see `READ_LONG_BURST_PROFILE.md`.  This
profile is not wired into the default SoC and its BFM cycle count is not a DDR
or frame-rate measurement.
