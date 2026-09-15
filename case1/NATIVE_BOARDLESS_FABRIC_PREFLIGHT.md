# Native boardless 7-client fabric preflight

This is the next board-independent gate after the single-client native job.
It instantiates the real `c1_r1_boardless_frame_system` at 640x480 as client 0
of the real `c1_axi_n_serial_arbiter_128`.  Clients 1..6 are small procedural
AXI masters; each performs three four-beat writes followed by readback.  The
master-side BFM is one ID-less associative DDR model with independent random
AR/AW/W back-pressure and delayed R/B responses.

Run from the case directory (the outer invocation uses WMI `Win32_Process.Create`
and therefore does not bind Vivado/xsim to the interactive Windows Job):

```powershell
& .\scripts\run_r1_native_boardless_fabric_xsim_detached.ps1 `
  -RunId native_fabric_full2_20260825
```

Compile/elaboration only:

```powershell
& .\scripts\run_r1_native_boardless_fabric_xsim_detached.ps1 `
  -RunId native_fabric_elab_final_20260825 -CompileOnly
```

## Verified run

`native_fabric_full2_20260825` completed with exit code 0.  The xsim markers were:

```text
C1_R1_NATIVE_BOARDLESS_FABRIC_PASS frame=640x480 clients=6
client_aw=18 client_w=72 client_b=18 client_ar=18 client_r=72
job_aw=4800 job_w=76800 job_b=4800 job_ar=4800 job_r=76890
input_ar=4800 input_r=76800 output_pixels=307200
arb_aw_stalls=615 arb_ar_stalls=512 r_gaps=191192 b_delays=11979
max_aw_waits=31/24/24/35/44/56 max_ar_waits=104/105/103/107/117/118
```

Per-client handshake and worst-channel wait (`AW/W/B/AR/R/max_wait`) were:

```text
C1_R1_NATIVE_BOARDLESS_FABRIC_CLIENT_STATS
c1=3/12/3/3/12/104 c2=3/12/3/3/12/105
c3=3/12/3/3/12/103 c4=3/12/3/3/12/107
c5=3/12/3/3/12/117 c6=3/12/3/3/12/118
```

`xvlog.stderr.log`, `xelab.stderr.log`, and `xsim.stderr.log` are all empty.
The run took about 27.4 s (xvlog 2.0 s, xelab 5.0 s, xsim 20.1 s), and the
detached worker left no Vivado/xsim processes after completion.

The boardless job additionally checks the ordered 22-stage descriptor stream,
the external CNN ready/valid echo, all 640x480 input beats, all output pixels,
SOF/EOL/EOF coverage, and the terminal output associative-memory readback.
The six synthetic clients check every returned data beat and RLAST, so the
reported client transaction counts are end-to-end readback handshakes rather
than merely issued requests.

## Scope and boundary

This is a fabric/traffic preflight, not a portable-SoC signoff.  The main marker's
`clients=6` counts only the six synthetic peers; the real fabric width is seven
because the boardless job occupies client-0.  The synthetic
clients stand in for the remaining SoC traffic classes, and the external CNN
is still a one-entry echo model.  It does not yet prove the seven real
portable-SoC clients concurrently (capture, parameter/tensor, display and
compute), CSI/MIPI timing, Efinix device inference, DDR controller calibration,
or a 15-fps board throughput target.  The next integration step is to replace
the synthetic clients with the actual portable-SoC client ports while retaining
this BFM's randomized latency and per-client wait instrumentation.
