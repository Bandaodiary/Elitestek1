# Native 640x480 capture/DMA writer staged preflight

This stage validates the real `c1_axi_xrgb_frame_writer` without involving the camera frontend, frame manager, CNN, shared AXI arbiter, or display.  A core-clock source sends three serialized native frames through the writer, using the three input slots from the native map.  An independent AXI write BFM applies AW/W/B backpressure and stores each complete 128-bit line by its full address.

## Native map and checks

- Frame geometry: `640x480`, XRGB stride `0xA00`, active bytes `0x12C000` per frame slot.
- Input slots: `0x00100000`, `0x0022C000`, `0x00358000`.
- Every AW is checked for the expected row-contiguous address, 16-byte alignment, INCR/128-bit attributes, no 4-KiB crossing, and no active-row crossing.
- Every W beat is checked for full `WSTRB`, correct `WLAST`, and all four packed XRGB lanes.  The source pattern is address-derived but uses a different tone for each slot.
- After each frame's B completion, all `307,200` pixels are read back from the associative DDR line store.  The aggregate readback count is `921,600`, proving that the three slots remain distinct.
- The BFM intentionally stalls AW/W and delays B; the source hold contract is also checked while `s_ready=0`.

## Reproduction

Run the detached WMI worker so xsim is not attached to the desktop agent's Windows Job:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\case1\scripts\run_r1_native_capture_writer_xsim_detached.ps1 `
  -RunId c1_native_capture_writer_final_20260825
```

The successful run is recorded under `logs/native_capture_writer_runs/c1_native_capture_writer_final_20260825/`.  Its unique marker is:

```text
C1_R1_NATIVE_CAPTURE_WRITER_PASS frames=3 frame_pixels=307200 aw=14400 w=230400 b=14400 readback_pixels=921600 aw_stalls=964 w_stalls=39362 b_delays=43686 source_holds=371944 slots=00100000/0022c000/00358000
```

The xsim timestamp is about `12.936 ms`; the detached wall time was about ten seconds.  The high source-hold and W-stall counts are deliberate protocol stress, not a throughput claim.

The earlier run ID `c1_native_capture_writer_20260825` is not evidence: its
unsized `3_000_000_000` ns timeout overflowed and produced a time-zero FAIL
alongside the functional marker.  The timeout literal and runner `_FAIL`
screen were corrected before the final run above; the old status is marked
failed so it cannot be mistaken for a valid PASS.

## Scope boundary

The result proves writer-side native address generation, XRGB packing, AXI write-channel protocol, slot separation, and byte/pixel readback.  It does not prove RAW10 capture timing, ISP/debayer/resize behavior, shared seven-client arbitration, CNN execution, display consumption, DDR controller calibration, or board-level frame rate.
