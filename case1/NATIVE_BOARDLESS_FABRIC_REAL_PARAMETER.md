# Native 640×480 fabric slice: real parameter loader client

## Purpose

This is the next board-independent risk slice after the six-procedural-peer
fabric preflight.  With `-RealParameter`, client slot 1 of the existing
seven-client `c1_axi_n_serial_arbiter_128` is occupied by the production
`c1_axi_parameter_loader` and a local production `c1_r1_parameter_bank`.
The remaining slots 2–6 are the already-used procedural AXI stress clients;
slot 0 remains the real `c1_r1_boardless_frame_system` at 640×480.

The parameter loader fetches a complete 16,896-byte (1,056-beat) arena from
`PARAM_BASE=0x0080_0000` using at-most-16-beat, 4-KiB-safe bursts.  The shared
DDR BFM returns a deterministic per-word pattern and applies the same
opposite-edge AR/R backpressure as the canonical fabric test.  After the
loader commits the shadow bank, the test reads back words 0, 528, and 1,055
through the bank's engine port.

## Invocation

The runner remains WMI-detached so Vivado/xsim is not tied to the interactive
Windows job:

```powershell
& .\case1\scripts\run_r1_native_boardless_fabric_xsim_detached.ps1 `
  -RunId native_fabric_param_<date> -RealParameterClient
```

Use `-CompileOnly -RealParameterClient` first.  The expected simulation marker is:

```text
C1_R1_NATIVE_BOARDLESS_FABRIC_PARAM_PASS
```

## Verified runs

The WMI-detached compile/elaboration run
`native_fabric_param_elab_20260825` completed in 7.2 s.  The full run
`native_fabric_param_full_20260825` completed in 27.4 s; xvlog, xelab and
xsim all exited with code 0 and all three stderr logs are empty.  Its markers
were:

```text
C1_R1_NATIVE_BOARDLESS_FABRIC_PARAM_PASS frame=640x480 total_clients=7
real_param=1 synthetic_clients=5 param_ar=66 param_r=1056
param_generation=1 client_aw=15 client_w=60 client_b=15
client_ar=15 client_r=60 job_aw=4800 job_w=76800 job_b=4800
job_ar=4800 job_r=76890 input_ar=4800 input_r=76800
output_pixels=307200 arb_aw_stalls=470 arb_ar_stalls=594
r_gaps=193614 b_delays=12207

C1_R1_NATIVE_BOARDLESS_FABRIC_PARAM_CLIENT_STATS
c2=3/12/3/3/12/158 c3=3/12/3/3/12/162
c4=3/12/3/3/12/160 c5=3/12/3/3/12/169
c6=3/12/3/3/12/167
```

The companion client statistics marker names synthetic clients c2–c6.  The
main marker reports `total_clients=7`, `real_param=1`, `synthetic_clients=5`,
the parameter AR/R totals, bank generation, boardless frame coverage, and
DDR/arbiter stall coverage.

## Verification boundary

This slice proves that one real AXI
read-only leaf can coexist with the real boardless job and five other clients
through the actual seven-client ID-less arbiter under delayed/back-pressured
DDR traffic.  It does **not** prove the portable SoC's seven *real* leaves run
simultaneously, CNN/tensor/display QoS, Efinity timing/resource closure,
camera/DDR PHY behavior, or the 15-fps board requirement.  The local parameter
bank is a test boundary; it is not a board memory model or a claim that the
final software image has been integrated.

The default runner without `-RealParameter` and without the macro remains the
previous canonical six-procedural-client regression.
