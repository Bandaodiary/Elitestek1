# Native 640x480 display/DDR staged preflight

This is a board-independent stage between compile-only and the full portable-SoC run.  It instantiates the real `c1_display_prefetch_pair` with `640x480`, two independent `c1_axi_xrgb_frame_reader` instances, and the dual-clock two-line stores.  It intentionally does not instantiate the CNN, frame manager, camera capture, or the shared SoC AXI arbiter.

## What is checked

- Original frame base `0x0010_0000` and styled frame base `0x0060_0000`, stride `0xA00`.
- Every AXI read burst is checked for 16-byte alignment, INCR/128-bit attributes, the expected row-contiguous address sequence, 4-KiB boundary compliance, and no crossing of a 640-pixel row.
- The BFM returns a deterministic XRGB word derived from its byte address.  A synthetic pixel clock scans both 640x480 stores and compares all `307,200` RGB responses.
- Both readers must complete exactly `4,800` AR bursts and `76,800` R beats; underflow and reader/prefetch errors are fatal.
- Read-channel backpressure is deterministic and non-zero, so the test also exercises held R responses and line-store ownership CDC.

## Reproduction

Use the detached runner so Vivado/xsim are created through `Win32_Process.Create` rather than inheriting the desktop agent's Windows Job:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\case1\scripts\run_r1_native_display_prefetch_xsim_detached.ps1 `
  -RunId native_prefetch_run2_20260825
```

The successful run is recorded in `logs/native_display_prefetch_runs/native_prefetch_run2_20260825/status.json` and its detached xsim output.  The unique marker was:

```text
C1_R1_NATIVE_DISPLAY_PREFETCH_PASS frame=640x480 done=1 primed=0 responses=307200/307200 axi_ar=4800/4800 axi_r=76800/76800 ar_stalls=612/479 r_stalls=237665/237597 underflow=0/0
```

`primed=0` at the marker is expected: the final pixel requests have released both line-store banks by the time the completion check runs.  `done=1`, exact response counts, and zero underflows are the relevant completion conditions.

## Scope boundary

This result proves native display-reader addressing, DDR read protocol handling, full-frame line-store drain, and the pixel-domain CDC in isolation.  It does not prove the full SoC's capture-to-CNN-to-output path, shared ID-less AXI arbitration/QoS, CNN stage watchdog budget, 720p raster timing, or Efinix/EasyFPGA pin/DDR calibration.  Those remain the next staged tests before a native full-chain xsim or physical-board claim.
