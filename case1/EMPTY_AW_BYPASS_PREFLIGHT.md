# Empty-FIFO AW bypass preflight

## Scope

c1_axi_n_write_burst_arbiter_128 now has an optional EMPTY_AW_BYPASS
parameter. The default remains 1'b0, so existing wrappers keep the original
enqueue-then-issue timing. The standalone regression is enabled with the
C1_EMPTY_AW_BYPASS_TB compile macro:

    case1/scripts/run_axi_n_write_burst_arbiter_empty_aw_bypass_xsim_detached.ps1

The runner is boardless and detached; it removes its private Vivado run tree
and retains only compact step logs/status.

## Handshake behavior

When the descriptor FIFO is empty and the option is enabled, the selected
client's AW payload is presented directly to the downstream AW channel.
s_awready remains asserted for the selected client even when downstream
m_awready is low. In that case the same edge captures the descriptor into
the empty FIFO slot; from the following cycle the memory-backed path freezes
the payload until downstream acceptance. Therefore:

* downstream-ready on the first cycle: input AW and downstream AW can
  handshake in the same cycle (first_aw_latency=0);
* downstream stall on the first cycle: the input can still be accepted, and
  the descriptor is issued as soon as m_awready returns;
* no extra state is needed, and the ordinary FIFO count/issue-count cases
  handle simultaneous enqueue and issue (count_q and issued_count_q each
  increment once).

The existing non-synthesis assertion and the directed TB check that AW
payload remains stable while m_awvalid && !m_awready. Round-robin owner
selection, W serialization, and B retirement are unchanged.

## Expected cost and benefit

With EMPTY_AW_BYPASS=1, the empty-state path adds no storage. It adds only
the optional input-to-output AW mux/control (45 payload bits: address, LEN,
SIZE, BURST) and the existing grant decode. With the parameter tied low,
synthesis can constant-fold the path and the legacy timing is retained.
The main timing risk is a new combinational source-AW to downstream-AW path
when the queue is empty; this must be checked in the first board-targeted
timing run. The expected benefit is removal of one empty-queue AW bubble,
not a change to the one-AW-per-cycle steady-state limit.

The TB prints first_aw_latency, AW/W/B counts, maximum descriptor occupancy,
and observed AW/W/B stalls. A Vivado/xsim run is intentionally deferred while
another detached simulation is active; source and PowerShell-AST checks are
the current preflight evidence.
