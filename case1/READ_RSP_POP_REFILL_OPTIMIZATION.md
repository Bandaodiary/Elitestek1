# Read response FIFO pop/refill option

## Purpose

`c1_tensor_mem_axi128_read_burst_client` normally keeps response FIFO capacity
and `m_axi_rready` independent of a local `rsp_ready` handshake.  This was the
timing-safe result used by the existing Artix-7 proxy.  It can, however, create
a one-cycle R-channel bubble when a shallow FIFO has one free logical slot and
the next AXI128 beat carries two 64-bit logical responses.

`ALLOW_RSP_POP_REFILL=1` is a board-selectable experiment.  It reuses the slot
retired by `rsp_valid && rsp_ready` in the same cycle.  The implementation has
two explicit safety rules:

- Logical-entry FIFO: a two-lane beat is accepted only if the FIFO was already
  below full before the pop; one released slot cannot make space for two new
  entries.
- Beat-record FIFO: a new record can reuse capacity only when the current
  local handshake actually retires that record (the second lane of a two-lane
  record), not merely its first local lane.

The default remains `0`.  The option adds a local `rsp_ready` contribution to
the AXI `RREADY` timing cone, so it must not be enabled globally before the
target Efinity timing report and DDR interface contract are available.

## Boardless evidence

`model/read_rsp_pop_refill_model.py` keeps an always-valid AXI source and an
always-ready local sink, with a depth-two logical response FIFO and eight
packed beats plus a one-lane tail.  It reports:

```text
READ_RSP_POP_REFILL_MODEL_PASS depth=2 beats=9 logical=17 baseline_cycles=25 refill_cycles=17 saved=8 same_cycle_packed=7
```

This is a FIFO scheduling result, not a claim about DDR bandwidth or complete
network fps.  With normal response FIFO depth sized for `BURST_BEATS ×
MAX_OUTSTANDING`, the FIFO should rarely reach this corner; the gain is expected
only under response-pressure/QoS conditions.

## RTL regression hook

`sim/tb_c1_tensor_mem_axi128_read_burst_client.sv` accepts
`C1_RSP_POP_REFILL_TB`.  That macro sets a depth-two logical FIFO and continuous
local readiness, then asserts that a packed R beat is accepted while one local
response is popped from the penultimate occupancy.  It retains all existing
packing, ordering, 4-KiB, local-error and AXI hold scoreboards.

Suggested later detached XSim invocation (not run in this change):

```powershell
.\case1\scripts\run_tensor_mem_axi128_read_burst_client_xsim_detached.ps1 -PopRefill
```

The runner must define `C1_RSP_POP_REFILL_TB`; if the current runner has not
yet exposed that switch, pass the define through its existing macro mechanism.

## Integration exposure

The same parameter is forwarded as:

- `LEAF_ALLOW_RSP_POP_REFILL` in `c1_tensor_mem_axi128_read_fabric_2c`;
- `ALLOW_RSP_POP_REFILL` in `c1_window_line_cache_c8_burst_shell`.

No default SoC instance is changed.  Enable one leaf at a time only after
checking: no AXI RVALID/RREADY combinational-loop violation, fabric-level
response ordering under backpressure, and the Ti60/Efinity WNS/TNS result.
