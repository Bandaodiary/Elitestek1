"""Check bounded, size-matched trained SoC traces against the integer golden.

Check the fixture's gray or colored modulo-1024 RAW10 ramp through identity ISP and
unit or explicitly tagged reverse/fractional Resize, then use
the observed CNN input for all 22 integer-golden stages. This is not arbitrary
camera/ISP coverage. Also compare the physically written final XRGB frame.
No files are generated; X/Z or incomplete traces fail.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

import numpy as np
from generate_r1_resize_line_sampler_vectors import explicit_phase_rgb
from r1_isp import demosaic_bilinear_valid_raw10
from microstyle_workload import workload
from check_column_write_overlap_trace import check_column_write_overlap
from check_pointwise_column_trace import check_pointwise_columns
from check_column_response_bypass_trace import check_column_response_bypass
from check_column_row_map_trace import check_column_row_map
from check_pixel_column_prefetch_trace import check_pixel_column_prefetch, all_pixel_groups_enabled
from check_dot_pixel_pipeline_trace import check_dot_pixel_pipeline,all_dot_groups_enabled,check_all_dot_abort
from check_rgb_reduction_trace import check_rgb_reduction
from check_view_elision_trace import check_view_elision
from check_final_fusion_trace import final_fusion_mode,check_final_fusion
from check_source_write_pipeline_trace import check_source_writes
from check_pointwise_reduction_trace import check_pointwise_reduction
from check_mac_requant_overlap_trace import check_requant_overlap
from check_tensor_write_mlp_trace import check_tensor_write_mlp
from check_pixel_write_batch_trace import check_pixel_write_batch
from check_dw_pixel_pipeline_trace import check_dw_pixel_pipeline
from check_stage_fsm_trace import check_stage_fsm
from check_dw_frame_trace import check_dw_frame
from check_column_refill_trace import check_column_refill
from check_scalar_assoc_trace import check_scalar_assoc,check_scalar_assoc_abort

from generate_microstyle_engine_bitexact_vectors import (
    STAGE_NAMES, _center_group, integer_infer_rgb,
)


def camera_fixture_rgb(width: int, height: int, fixture: str, tone: int = 0) -> np.ndarray:
    """Independent camera CFA -> rounded valid-crop Debayer -> identity Gamma.

    Small frames coincide with the old centre-plane formula. Larger frames
    cross RAW10 wrap boundaries, where interpolation and wrapping do not commute.
    Width/height are the cropped source dimensions, not CNN stage dimensions.
    """
    if width <= 0 or height <= 0 or fixture not in ("gray", "color_rggb"):
        raise ValueError("invalid camera fixture dimensions or Bayer mode")
    y, x = np.indices((height + 2, width + 2), dtype=np.int64)
    offset = np.where((x % 2 == 0) & (y % 2 == 0), 96,
                      np.where((x % 2 == 1) & (y % 2 == 1), 0, 40)) if fixture == "color_rggb" else 0
    raw10 = ((64 + 17*x + 29*y + tone + offset) & 1023).astype(np.uint16)
    return (demosaic_bilinear_valid_raw10(raw10, "RGGB") >> 2).astype(np.uint8)


def check_stage0_profile(log: str, required: bool=False) -> dict:
    records=[s for s in log.splitlines() if s.startswith("C1_PERF_STAGE0_FSM")]
    if not records and not required:return {}
    stage0=[s for s in log.splitlines() if s.startswith("C1_PERF_STAGE ") and re.search(r"\bstage=0\b",s)]
    target=re.search(r" job=(\d+) stage=0 cycles=(\d+) ",stage0[0]) if len(stage0)==1 else None
    if not records or target is None:raise ValueError("stage0 profile missing job/stage witness")
    counts={"engine":{},"adapter":{}}
    for line in records:
        row=re.fullmatch(r"C1_PERF_STAGE0_FSM job=(\d+) side=(engine|adapter) state=(\d+) cycles=(\d+)",line)
        if row is None:raise ValueError("malformed stage0 profile")
        job,side,state,cycles=int(row[1]),row[2],int(row[3]),int(row[4])
        if job!=int(target[1]) or not 0<=state<32 or cycles<=0 or state in counts[side]:
            raise ValueError("stage0 profile duplicate/wrong job/state/cycle count")
        counts[side][state]=cycles
    if any(sum(part.values())!=int(target[2]) for part in counts.values()):
        raise ValueError("stage0 profile does not cover every cycle exactly once per FSM")
    return counts


def check_stage_performance(log: str, width: int, height: int, *, virtual_upsample: bool = False) -> None:
    header = [s for s in log.splitlines() if s.startswith("C1_NUM_STAGE_PERF")]
    if header != ["C1_NUM_STAGE_PERF version=1 includes_setup=1"]:
        raise ValueError("missing/duplicate/malformed per-stage performance header")
    records = [s for s in log.splitlines() if s.startswith("C1_PERF_STAGE ")]
    if len(records) != 22:
        raise ValueError("per-stage performance must contain exactly 22 successful stage records")
    rows = []
    packed_rgb = check_rgb_reduction(log,width,height,1)
    views=check_view_elision(log,width,height,1)
    expected = workload(width, height, virtual_upsample=virtual_upsample,pack_rgb_reduction=packed_rgb,elide_views=views,fuse_final=final_fusion_mode(log))
    for line, target in zip(records, expected["stages"]):
        match = re.fullmatch(r"C1_PERF_STAGE job=(\d+) stage=(\d+) cycles=(\d+) dot_beats=(\d+) dw_beats=(\d+) mem_read=(\d+) mem_write=(\d+) columns=(\d+)", line)
        if match is None:
            raise ValueError("malformed per-stage performance record")
        job, stage, cycles, dot, dw, reads, writes, columns = map(int, match.groups())
        if (stage != target["stage"] or cycles < target["minimum_cycles"] or
                dot != target["dot_beats"] or dw != target["dw_beats"] or writes != target["scalar_writes"]):
            raise ValueError(f"stage {stage} handshake counts disagree with the descriptor-derived workload")
        rows.append((job, stage, cycles, dot, dw, reads, writes, columns))
    jobs = [s for s in log.splitlines() if s.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b", s)]
    if len(jobs) != 1:
        raise ValueError("stage performance requires exactly one successful job summary")
    totals = dict(re.findall(r"([a-z_]+)=(\d+)", jobs[0]))
    if not all(key in totals for key in ("job", "elapsed", "mem_read", "mem_write")):
        raise ValueError("incomplete performance job summary")
    if (any(row[0] != int(totals["job"]) for row in rows) or
            sum(row[2] for row in rows) != int(totals["elapsed"]) or
            sum(row[5] for row in rows) != int(totals["mem_read"]) or
            sum(row[6] for row in rows) != int(totals["mem_write"])):
        raise ValueError("per-stage cycles/read/write counts do not reconcile with the job")
    column_lines = [s for s in log.splitlines() if s.startswith("C1_PERF_COLUMNS ")]
    column = re.fullmatch(r"C1_PERF_COLUMNS job=(\d+) accepted=(\d+) retired=(\d+)", column_lines[0]) if len(column_lines) == 1 else None
    if (column is None or int(column[1]) != int(totals["job"]) or
            int(column[2]) != int(column[3]) or sum(row[7] for row in rows) != int(column[2])):
        raise ValueError("per-stage column counts do not reconcile with retired requests")
    dominant = sorted(rows, key=lambda row: row[2], reverse=True)[:3]
    check_stage0_profile(log)
    check_stage_fsm(log)
    print(f"C1_SOC_STAGE_PERFORMANCE_PASS stages=22 min_work_cycles={expected['minimum_cycles']} job_cycles={totals['elapsed']} top_stages=" +
          ",".join(f"{row[1]}:{row[2]}" for row in dominant))


def check(run: Path, artifact: Path, require_video: bool = False,
          require_queued_write: bool = False, require_concurrent_capture: bool = False,
          require_compact_refill: bool = False, require_preview: bool = False,
          require_preview_recovery: bool = False, require_preview_cancel_recovery: bool = False,
          require_preview_display: bool = False, require_distinct_recovery: bool = False,
          require_raw_fault_recovery: bool = False,
          require_missing_eof_recovery: bool = False,
          require_idle_timeout_recovery: bool = False,
          require_explicit_recovery: bool = False,
          require_late_source_ack: bool = False,
          require_apb_recovery: bool = False, require_read_abort: bool = False,
          require_write_abort: bool = False,
          expected_bfm_extra: tuple[int, int, int] | None = None,
          require_scalar_read_abort: bool = False,
          expected_frame: str | None = None,
          require_stage_perf: bool = False,
          require_precise_write_invalidation: bool = False,
          require_virtual_upsample: bool = False,
          require_virtual_upsample_abort: bool = False,
          require_dw_stream: bool = False,
          require_column_write_overlap: bool = False,
          require_pointwise_columns: bool = False) -> None:
    status = json.loads((run / "status.json").read_text(encoding="utf-8-sig"))
    if status.get("state") != "complete" or status.get("exit_code") != 0:
        raise ValueError("simulation did not complete successfully")
    inputs = []
    outputs = []
    ddr = []
    preview = []
    video_raw, video_styled = [], []
    # Compact logs retain the final tail as well as trace matches. The runner
    # must exclude trace lines from the tail so duplicates remain detectable.
    log = (run / "xsim.stdout.log").read_text(encoding="utf-8-sig")
    overlap = check_column_write_overlap(log, 1, require_column_write_overlap)
    if overlap:
        print("C1_SOC_COLUMN_WRITE_OVERLAP_PASS jobs=1 ordered_writes=1")
    virtual_lines = [s for s in log.splitlines() if s.startswith("C1_NUM_VIRTUAL_UPSAMPLE")
                     and not s.startswith("C1_NUM_VIRTUAL_UPSAMPLE_ABORT")]
    virtual_upsample = False
    if require_virtual_upsample or require_virtual_upsample_abort or virtual_lines:
        virtual = re.fullmatch(r"C1_NUM_VIRTUAL_UPSAMPLE enabled=([01])", virtual_lines[0]) if len(virtual_lines)==1 else None
        if virtual is None or ((require_virtual_upsample or require_virtual_upsample_abort) and virtual[1] != "1"):
            raise ValueError("missing/invalid/duplicate virtual upsample configuration")
        virtual_upsample = virtual[1] == "1"
        if virtual_upsample:
            column_lines = [s for s in log.splitlines() if s.startswith("C1_NUM_COLUMN_OPTION")]
            if len(column_lines)!=1 or not re.fullmatch(r"C1_NUM_COLUMN_OPTION enabled=1 clients=[89]",column_lines[0]):
                raise ValueError("virtual upsample requires the column branch")
    abort_lines = [s for s in log.splitlines() if s.startswith("C1_NUM_VIRTUAL_UPSAMPLE_ABORT")]
    if require_virtual_upsample_abort or abort_lines:
        if not virtual_upsample or abort_lines != ["C1_NUM_VIRTUAL_UPSAMPLE_ABORT stage=18 width=4 height=4 input_bank=0 output_bank=1"]:
            raise ValueError("missing/invalid/duplicate virtual upsample physical refill abort point")
        require_read_abort = True
    precise_lines = [s for s in log.splitlines() if s.startswith("C1_NUM_PRECISE_WRITE_INVALIDATION")]
    if require_precise_write_invalidation or precise_lines:
        precise = re.fullmatch(r"C1_NUM_PRECISE_WRITE_INVALIDATION enabled=([01])", precise_lines[0]) if len(precise_lines)==1 else None
        if precise is None or (require_precise_write_invalidation and precise[1] != "1"):
            raise ValueError("missing/invalid/duplicate precise write-invalidation configuration")
        if precise[1] == "1":
            cache_lines = [s for s in log.splitlines() if s.startswith("C1_NUM_SCALAR_READ_CACHE")]
            column_lines = [s for s in log.splitlines() if s.startswith("C1_NUM_COLUMN_OPTION")]
            if cache_lines != ["C1_NUM_SCALAR_READ_CACHE enabled=1"] or len(column_lines)!=1 or not re.fullmatch(r"C1_NUM_COLUMN_OPTION enabled=1 clients=[89]",column_lines[0]):
                raise ValueError("precise invalidation requires an enabled scalar cache in the column branch")
    frame = status.get("frame", "8x8")  # legacy logs were bounded 8x8 only
    if frame not in ("8x8", "16x8", "16x16", "64x48") or (expected_frame is not None and frame != expected_frame):
        raise ValueError("unsupported or unexpected numerical frame in run status")
    frame_w, frame_h = map(int, frame.split("x"))
    fused_final=check_final_fusion(log,frame_w,frame_h,1)
    write_slots=check_tensor_write_mlp(log,1)
    if check_dw_pixel_pipeline(log,frame_w,frame_h,1):print("C1_SOC_DW_PIXEL_PIPELINE_PASS full_group_conservation=1")
    batch_selection=check_pixel_write_batch(log,frame_w,frame_h,1)
    if batch_selection is not None:print(f"C1_SOC_PIXEL_WRITE_BATCH_PASS words={batch_selection[0]} timeout={batch_selection[1]} raster_ends_exact=1")
    if write_slots is not None:print(f"C1_SOC_TENSOR_WRITE_MLP_PASS actual_capacity={write_slots} AW_B_conserved=1")
    if check_requant_overlap(log,frame_w,frame_h,1):
        print("C1_SOC_MAC_REQUANT_OVERLAP_PASS transactions_conserved=1 early_starts=1")
    if check_pointwise_reduction(log,frame_w,frame_h,1):
        print("C1_SOC_POINTWISE_REDUCTION_PASS exact_early_beats=1")
    if check_source_writes(log,frame_w,frame_h,1):
        print("C1_SOC_SOURCE_PIPELINE_PASS inputs_writes_responses=1 bounded_batches=1")
    if check_pixel_column_prefetch(log,frame_w,frame_h,1):
        print("C1_SOC_PIXEL_COLUMN_PREFETCH_PASS jobs=1 conserved_first_columns=1 early_response=1")
    if check_column_row_map(log,1):
        print("C1_SOC_COLUMN_ROW_MAP_PASS independent_history=1 accepted_read_conservation=1")
    if check_column_response_bypass(log,1):
        print("C1_SOC_COLUMN_RESPONSE_BYPASS_PASS jobs=1 every_response=1")
    check_rgb_reduction(log,frame_w,frame_h,1)
    if check_pointwise_columns(log,frame_w,frame_h,1,require_pointwise_columns):
        print("C1_SOC_POINTWISE_COLUMNS_PASS jobs=1 exact_read_budget=1")
    dw_modes = [s for s in log.splitlines() if s.startswith("C1_NUM_DW_STREAM")]
    dw_records = [s for s in log.splitlines() if s.startswith("C1_PERF_DW_STREAM")]
    if require_dw_stream or dw_modes or dw_records:
        mode = re.fullmatch(r"C1_NUM_DW_STREAM enabled=([01])",dw_modes[0]) if len(dw_modes)==1 else None
        if mode is None or (require_dw_stream and mode[1]!="1"):
            raise ValueError("missing/invalid/duplicate DW group stream mode")
        record = re.fullmatch(r"C1_PERF_DW_STREAM job=(\d+) beats=(\d+) adjacent_feeds=(\d+)",dw_records[0]) if len(dw_records)==1 else None
        jobs = [s for s in log.splitlines() if s.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",s)]
        if record is None or len(jobs)!=1 or not re.search(rf"\bjob={record[1]}\b",jobs[0]):
            raise ValueError("missing/invalid/duplicate DW group stream progress")
        expected_warm = sum(s["dw_warm_beats"] for s in workload(frame_w,frame_h)["stages"]) if mode[1]=="1" else 0
        if int(record[2])!=expected_warm or (expected_warm and not 0<int(record[3])<expected_warm) or (not expected_warm and int(record[3])!=0):
            raise ValueError("DW stream handshakes do not match warm pixel/group workload")
        if mode[1]=="1":
            options = [s for s in log.splitlines() if s.startswith("C1_NUM_ENGINE_OPTIONS")]
            if len(options)!=1 or not re.fullmatch(r"C1_NUM_ENGINE_OPTIONS dw_cache=1 mac_overlap=[01]",options[0]):
                raise ValueError("DW stream requires the actual weight cache")
        print(f"C1_SOC_DW_STREAM_PASS enabled={mode[1]} warm_beats={record[2]} adjacent_feeds={record[3]}")
    if virtual_upsample or require_stage_perf or any(s.startswith(("C1_NUM_STAGE_PERF", "C1_PERF_STAGE")) for s in log.splitlines()):
        check_stage_performance(log, frame_w, frame_h, virtual_upsample=virtual_upsample)
    schema = status.get("numerical_trace_schema")
    if schema is not None and schema != 2:
        raise ValueError("unsupported numerical trace schema")
    store_lines = [s for s in log.splitlines() if s.startswith("C1_NUM_DDR_STORE")]
    if schema == 2 or store_lines:
        if store_lines != ["C1_NUM_DDR_STORE address_keyed collision_pair=02800100:02000500 byte_strobes=1"]:
            raise ValueError("missing/invalid/duplicate address-keyed DDR self-test evidence")
    shape_lines = [s for s in log.splitlines() if s.startswith("C1_NUM_SHAPE")]
    declared_results = None
    if schema == 2 or frame != "8x8" or shape_lines:
        shape = re.fullmatch(r"C1_NUM_SHAPE width=(\d+) height=(\d+) C8_results=(\d+)", shape_lines[0]) if len(shape_lines) == 1 else None
        if shape is None or tuple(map(int, shape.groups()[:2])) != (frame_w, frame_h):
            raise ValueError("missing/invalid/duplicate shape or shape/status mismatch")
        declared_results = int(shape[3])
    if frame != "8x8" and (schema != 2 or any(s.startswith((
            "C1_NUM_SOURCE ", "C1_NUM_RESIZE ", "C1_NUM_PREVIEW_", "C1_NUM_TWO_",
            "C1_NUM_SOURCE_TONE", "C1_NUM_FIRST_DISPLAY", "C1_SOC_INFLIGHT_"))
            for s in log.splitlines())):
        raise ValueError("extended numerical frame requires schema 2 and normal single-frame geometry")
    trained_lines = [s for s in log.splitlines() if s.startswith("C1_R1_PORTABLE_SOC_TRAINED_ARTIFACT_")]
    if len(trained_lines) != 1 or not trained_lines[0].startswith(
            "C1_R1_PORTABLE_SOC_TRAINED_ARTIFACT_" + frame.upper() + "_PASS "):
        raise ValueError("missing/duplicate or wrong-size trained SoC PASS marker")
    image = np.zeros((frame_h, frame_w, 3), dtype=np.uint8)
    delay_lines = [s for s in log.splitlines() if s.startswith("C1_NUM_BFM_DELAY")]
    latency_lines = [s for s in log.splitlines() if s.startswith("C1_PERF_BFM_LATENCY")]
    if expected_bfm_extra is not None or delay_lines or latency_lines:
        delay = re.fullmatch(r"C1_NUM_BFM_DELAY first_extra=(\d+) beat_extra=(\d+) write_extra=(\d+)", delay_lines[0]) if len(delay_lines) == 1 else None
        latency = re.fullmatch(r"C1_PERF_BFM_LATENCY first_events=(\d+) first_min=(\d+) first_max=(\d+) beat_events=(\d+) beat_min=(\d+) beat_max=(\d+)", latency_lines[0]) if len(latency_lines) == 1 else None
        if delay is None or latency is None:
            raise ValueError("missing/invalid/duplicate BFM latency configuration or observations")
        extras = tuple(map(int, delay.groups()))
        first_n, first_min, first_max, beat_n, beat_min, beat_max = map(int, latency.groups())
        if (any(v > 255 for v in extras) or
                (expected_bfm_extra is not None and extras != tuple(expected_bfm_extra)) or
                first_n <= 0 or beat_n <= 0 or
                not 2 + extras[0] <= first_min <= first_max or
                not 2 + extras[1] <= beat_min <= beat_max):
            raise ValueError("BFM latency mismatch, unexercised read phase or premature RVALID")
        # Injected cancellation may hold R beyond the configured minimum;
        # no upper bound is imposed. B delay is configured but not measured
        # by this read-presentation monitor.
        print(f"C1_SOC_BFM_DELAY_TRACE_PASS first_extra={extras[0]} beat_extra={extras[1]} write_extra={extras[2]} first_range={first_min}:{first_max} beat_range={beat_min}:{beat_max}")
    write_drains = [s for s in log.splitlines() if s.startswith("C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS")]
    write_restarts = [s for s in log.splitlines() if s.startswith("C1_SOC_INFLIGHT_WRITE_ABORT_PASS")]
    if require_write_abort or write_restarts:
        drain = re.fullmatch(r"C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS pending=(\d+) held_cycles=64 aw=(\d+) b=(\d+) no_restart=1", write_drains[0]) if len(write_drains) == 1 else None
        restart = re.fullmatch(r"C1_SOC_INFLIGHT_WRITE_ABORT_PASS pending=(\d+) held_cycles=64 captures=3 done=1 aw=(\d+) b=(\d+) reset=0", write_restarts[0]) if len(write_restarts) == 1 else None
        if (drain is None or restart is None or int(drain[1]) < 2 or
                drain[1] != restart[1] or drain[2] != drain[3] or restart[2] != restart[3] or
                int(drain[2]) < int(drain[1]) or int(restart[2]) <= int(drain[2]) or
                log.index(write_drains[0]) >= log.index(write_restarts[0])):
            raise ValueError("missing/invalid/duplicate or out-of-order write abort recovery evidence")
        require_video = True
        print(f"C1_SOC_WRITE_ABORT_TRACE_PASS pending={drain[1]} held_cycles=64 reset=0")
    read_drains = [s for s in log.splitlines() if s.startswith("C1_SOC_INFLIGHT_READ_ABORT_DRAIN_PASS")]
    read_restarts = [s for s in log.splitlines() if s.startswith("C1_SOC_INFLIGHT_READ_ABORT_PASS")]
    pw_partial_read_mode="C1_NUM_POINTWISE_REDUCTION_ABORT " in log
    read_targets = [s for s in log.splitlines() if s.startswith("C1_NUM_READ_ABORT_TARGET")]
    scalar_cache_drains = [s for s in log.splitlines() if s.startswith("C1_SOC_SCALAR_READ_ABORT_CACHE_PASS")]
    scalar_read_mode = require_scalar_read_abort or bool(read_targets or scalar_cache_drains)
    if scalar_read_mode:
        cache_options = [s for s in log.splitlines() if s.startswith("C1_NUM_SCALAR_READ_CACHE")]
        if (read_targets != ["C1_NUM_READ_ABORT_TARGET scalar"] or
                cache_options != ["C1_NUM_SCALAR_READ_CACHE enabled=1"] or
                scalar_cache_drains != ["C1_SOC_SCALAR_READ_ABORT_CACHE_PASS before=1 after=0 valid=0 pending=0"]):
            raise ValueError("missing/invalid/duplicate scalar read-cache abort target or drain evidence")
    if require_read_abort or scalar_read_mode or read_drains or read_restarts:
        drain = re.fullmatch(r"C1_SOC_INFLIGHT_READ_ABORT_DRAIN_PASS pending_beats=(\d+) held_cycles=64 owner=(\d+) no_restart=1", read_drains[0]) if len(read_drains) == 1 else None
        restart = re.fullmatch(r"C1_SOC_INFLIGHT_READ_ABORT_PASS pending_beats=(\d+) held_cycles=64 captures=3 done=1 owner=(\d+) reset=0", read_restarts[0]) if len(read_restarts) == 1 else None
        options = [s for s in log.splitlines() if s.startswith("C1_NUM_COLUMN_OPTION")]
        option = re.fullmatch(r"C1_NUM_COLUMN_OPTION enabled=([01]) clients=(\d+)", options[0]) if len(options) == 1 else None
        if options and (option is None or int(option[2]) not in
                        ((8, 9) if option[1] == "1" else (7, 8))):
            raise ValueError("invalid column option in read abort trace")
        owner = int(option[2])-1 if option and option[1] == "1" else 6
        if scalar_read_mode or pw_partial_read_mode:
            if option is None or option[1] != "1":
                raise ValueError("scalar read-cache cancellation requires the column tensor branch")
            owner = 6
        if (drain is None or restart is None or
                (int(drain[1]) != 1 if scalar_read_mode or pw_partial_read_mode else int(drain[1]) < 2) or
                drain[1] != restart[1] or int(drain[2]) != owner or int(restart[2]) != owner or
                log.index(read_drains[0]) >= log.index(read_restarts[0])):
            raise ValueError("missing/invalid/duplicate or out-of-order read abort recovery evidence")
        if scalar_read_mode and not (log.index(read_targets[0]) < log.index(read_drains[0]) <
                log.index(scalar_cache_drains[0]) < log.index(read_restarts[0])):
            raise ValueError("out-of-order scalar read-cache abort/drain/restart evidence")
        require_video = True
        print(f"C1_SOC_READ_ABORT_TRACE_PASS owner={owner} held_cycles=64 reset=0")
        if scalar_read_mode:
            print("C1_SOC_SCALAR_READ_ABORT_TRACE_PASS late_refill_blocked=1 pending=0 reset=0")
    explicit = [s for s in log.splitlines() if s.startswith("C1_SOC_EXPLICIT_RECOVERY_PASS")]
    apb = [s for s in log.splitlines() if s.startswith("C1_SOC_EXPLICIT_RECOVERY_APB_PASS")]
    if require_apb_recovery or apb:
        accepted = [s for s in log.splitlines() if s.startswith("C1_SOC_EXPLICIT_RECOVERY_APB_ACCEPT_PASS")]
        apb_drains = [s for s in log.splitlines() if s.startswith("C1_SOC_EXPLICIT_RECOVERY_DRAIN_PASS")]
        if (accepted != ["C1_SOC_EXPLICIT_RECOVERY_APB_ACCEPT_PASS diagnostic=46 busy=1 duplicate_rejected=1"] or
                apb != ["C1_SOC_EXPLICIT_RECOVERY_APB_PASS hardware_request=0 completion_read=1 completion_cleared=1"] or
                len(apb_drains) != 1 or not (log.index(accepted[0]) < log.index(apb_drains[0]) < log.index(apb[0]))):
            raise ValueError("missing/invalid/duplicate APB recovery evidence")
        require_explicit_recovery = True
        print("C1_SOC_APB_RECOVERY_TRACE_PASS hardware_request=0 diagnostic=46 completion_cleared=1")
    late = [s for s in log.splitlines() if s.startswith("C1_SOC_EXPLICIT_RECOVERY_LATE_ACK_PASS")]
    if require_late_source_ack or late:
        drains_late = [s for s in log.splitlines() if s.startswith("C1_SOC_EXPLICIT_RECOVERY_DRAIN_PASS")]
        if (late != ["C1_SOC_EXPLICIT_RECOVERY_LATE_ACK_PASS cycles=32 bus_drained=1 ownership_held=1"] or
                len(drains_late) != 1 or log.index(late[0]) >= log.index(drains_late[0])):
            raise ValueError("missing/invalid/duplicate late source ACK evidence")
        require_explicit_recovery = True
        print("C1_SOC_LATE_SOURCE_ACK_TRACE_PASS cycles=32 ownership_held=1")
    if require_explicit_recovery or explicit:
        drains = [s for s in log.splitlines() if s.startswith("C1_SOC_EXPLICIT_RECOVERY_DRAIN_PASS")]
        match = re.fullmatch(r"C1_SOC_EXPLICIT_RECOVERY_DRAIN_PASS pending=(\d+) held_cycles=64 source_stopped=1", drains[0]) if len(drains) == 1 else None
        if (explicit != ["C1_SOC_EXPLICIT_RECOVERY_PASS flushes=1 captures=3 errors=1 done=1 reset=0"] or
                match is None or int(match[1]) < 2 or log.index(drains[0]) >= log.index(explicit[0])):
            raise ValueError("missing/invalid/duplicate explicit recovery evidence")
        require_idle_timeout_recovery = True
        print("C1_SOC_EXPLICIT_RECOVERY_TRACE_PASS flushes=1 source_stopped=1 reset=0")
    idle_recovery = [line for line in log.splitlines() if line.startswith("C1_SOC_RAW_IDLE_TIMEOUT_PASS")]
    if require_idle_timeout_recovery or idle_recovery:
        if idle_recovery != ["C1_SOC_RAW_IDLE_TIMEOUT_PASS threshold=4096 code=46 captures=3 errors=1 done=1 reset=0"]:
            raise ValueError("missing/invalid/duplicate RAW idle timeout evidence")
        require_raw_fault_recovery = True
        print("C1_SOC_IDLE_TIMEOUT_TRACE_PASS threshold=4096 code=46 reset=0")
    eof_recovery = [line for line in log.splitlines() if line.startswith("C1_SOC_RAW_MISSING_EOF_PASS")]
    if require_missing_eof_recovery or eof_recovery:
        waits = [line for line in log.splitlines() if line.startswith("C1_SOC_RAW_EOF_WAIT_PASS")]
        if (eof_recovery != ["C1_SOC_RAW_MISSING_EOF_PASS bus_hold=64 boundary_wait=64 captures=3 errors=1 done=1 reset=0"] or
                waits != ["C1_SOC_RAW_EOF_WAIT_PASS cycles=64 bus_drained=1 cleanup_held=1"] or
                log.index(waits[0]) >= log.index(eof_recovery[0])):
            raise ValueError("missing/invalid/duplicate EOF boundary recovery evidence")
        require_raw_fault_recovery = True
        print("C1_SOC_MISSING_EOF_TRACE_PASS bus_drained_wait=64 no_reset=1")
    raw_recovery = [line for line in log.splitlines() if line.startswith("C1_SOC_RAW_RASTER_FAULT_PASS")]
    if require_raw_fault_recovery or raw_recovery:
        if len(raw_recovery) != 1:
            raise ValueError("missing/duplicate RAW fault recovery evidence")
        match = re.fullmatch(r"C1_SOC_RAW_RASTER_FAULT_PASS pending=(\d+) held_cycles=64 captures=3 errors=1 done=1 reset=0", raw_recovery[0])
        drain = [line for line in log.splitlines() if line.startswith("C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS")]
        drain_match = re.fullmatch(r"C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS pending=(\d+) held_cycles=64 aw=(\d+) b=(\d+) no_restart=1", drain[0]) if len(drain) == 1 else None
        if (not match or int(match.group(1)) < 2 or not drain_match or
                drain_match.group(1) != match.group(1) or
                drain_match.group(2) != drain_match.group(3) or
                log.index(drain[0]) >= log.index(raw_recovery[0])):
            raise ValueError("RAW recovery missing ordered multi-writer drain evidence")
        require_video = True
        require_queued_write = True
        print("C1_SOC_RAW_RECOVERY_TRACE_PASS errors=1 held_cycles=64 reset=0")
    tones=[line for line in log.splitlines() if line.startswith("C1_NUM_SOURCE_TONE")]
    if tones not in ([], ["C1_NUM_SOURCE_TONE 32"]):
        raise ValueError("invalid/duplicate source tone")
    source_tone=32 if tones else 0
    if require_distinct_recovery and not tones:
        raise ValueError("missing distinct recovery frame tone")
    if tones and not any(line.startswith(("C1_SOC_PREVIEW_CANCEL_RECOVERY_PASS", "C1_SOC_PREVIEW_BRESP_RECOVERY_PASS")) for line in log.splitlines()):
        raise ValueError("distinct tone requires a completed preview recovery")
    display_sources = [line for line in log.splitlines() if line.startswith("C1_NUM_FIRST_DISPLAY")]
    if display_sources not in ([], ["C1_NUM_FIRST_DISPLAY preview"]):
        raise ValueError("invalid/duplicate first-display source")
    preview_display = bool(display_sources)
    if require_preview_display and not preview_display:
        raise ValueError("missing preview display selection")
    if preview_display:
        require_video = True
        require_preview = True
    cancel_recovery = [line for line in log.splitlines() if line.startswith("C1_SOC_PREVIEW_CANCEL_RECOVERY_PASS")]
    if require_preview_cancel_recovery or cancel_recovery:
        require_preview = True
        expected_cancel = "C1_SOC_PREVIEW_CANCEL_PASS clients=8 held_cycles=64 preview_aw=8 preview_w=16 preview_b=8 aborted=1 errors=0 done=0 swaps=0 start_rejected=1 drained=1 reset=0"
        cancel = [line for line in log.splitlines() if line.startswith("C1_SOC_PREVIEW_CANCEL_PASS")]
        if cancel_recovery != ["C1_SOC_PREVIEW_CANCEL_RECOVERY_PASS aborted=1 errors=0 done=1 captures=2 reset=0 pixels=64"] or cancel != [expected_cancel]:
            raise ValueError("missing/invalid/duplicate preview cancel recovery evidence")
        if log.index(cancel[0])>=log.index(cancel_recovery[0]):
            raise ValueError("preview cancellation must precede recovered completion")
        print("C1_SOC_PREVIEW_CANCEL_RECOVERY_TRACE_PASS aborted=1 errors=0 recompute=1 reset=0")
    recovery = [line for line in log.splitlines() if line.startswith("C1_SOC_PREVIEW_BRESP_RECOVERY_PASS")]
    if require_preview_recovery or recovery:
        require_preview = True
        if recovery != ["C1_SOC_PREVIEW_BRESP_RECOVERY_PASS errors=1 done=1 captures=2 injected=1 reset=0 pixels=64"]:
            raise ValueError("missing/invalid/duplicate preview recovery evidence")
        fault = [line for line in log.splitlines() if line.startswith("C1_SOC_PREVIEW_BRESP_ERROR_PASS")]
        if len(fault)!=1:
            raise ValueError("missing/duplicate preview fault-drain evidence")
        fault_match = re.fullmatch(r"C1_SOC_PREVIEW_BRESP_ERROR_PASS clients=8 errors=1 done=0 swaps=0 code=63 address=01000000 preview_aw=8 preview_w=16 preview_b=8 cnn_pixels=63 pending_cnn_at_fault=1 hold=(\d+) drained=1 no_software_abort=1", fault[0])
        if not fault_match or int(fault_match.group(1))<64 or log.index(fault[0])>=log.index(recovery[0]):
            raise ValueError("invalid preview fault-drain ordering/coverage")
        print("C1_SOC_PREVIEW_RECOVERY_TRACE_PASS errors=1 successful_recompute=1 reset=0")
    windows = [line for line in log.splitlines() if line.startswith("C1_NUM_REFILL_WINDOW")]
    window = 16
    if windows:
        if len(windows)!=1 or not re.fullmatch(r"C1_NUM_REFILL_WINDOW [1-9][0-9]*",windows[0]):
            raise ValueError("invalid/duplicate refill window")
        window=int(windows[0].split()[-1])
        if window>255:
            raise ValueError("refill window exceeds scheduler capacity")
    capacities = [line for line in log.splitlines() if line.startswith("C1_NUM_REFILL_CAPACITY")]
    if capacities or require_compact_refill or windows:
        if len(capacities) != 1:
            raise ValueError("missing/duplicate refill-capacity evidence")
        match = re.fullmatch(r"C1_NUM_REFILL_CAPACITY req_depth=(\d+) rsp_depth=(\d+) beat_mode=([01]) req_peak=(\d+) rsp_peak=(\d+) meta_peak=(\d+)", capacities[0])
        if not match:
            raise ValueError("malformed refill-capacity evidence")
        req_depth, rsp_depth, beat, req_peak, rsp_peak, meta_peak = map(int,match.groups())
        if not (2 <= req_depth <= 255 and rsp_depth >= (1 if beat else 2) and
                0 < req_peak <= min(req_depth,meta_peak) and
                0 < rsp_peak <= min(rsp_depth,meta_peak) and 0 < meta_peak <= window):
            raise ValueError("refill occupancy/capacity mismatch")
        if require_compact_refill and (req_depth,rsp_depth,beat,window) != (16,16,0,16):
            raise ValueError("compact refill configuration not exercised")
        print(f"C1_SOC_REFILL_CAPACITY_TRACE_PASS req={req_peak}/{req_depth} rsp={rsp_peak}/{rsp_depth} meta_peak={meta_peak} beat={beat}")
    write_modes = [line for line in log.splitlines() if line.startswith("C1_NUM_WRITE_MODE")]
    if write_modes not in ([], ["C1_NUM_WRITE_MODE serial"], ["C1_NUM_WRITE_MODE ahead"]):
        raise ValueError("invalid/duplicate write-mode marker")
    if cancel_recovery and len(write_modes)!=1:
        raise ValueError("cancel recovery requires explicit write-mode evidence")
    serial_write = write_modes == ["C1_NUM_WRITE_MODE serial"]
    concurrent = [line for line in log.splitlines() if line.startswith("C1_SOC_CONCURRENT_CAPTURE_PASS")]
    require_queued_write = require_queued_write or require_concurrent_capture or bool(concurrent)
    queued = [line for line in log.splitlines() if line.startswith("C1_SOC_QUEUED_WRITE_NUMERIC_PASS")]
    if queued or require_queued_write:
        if len(queued) != 1:
            raise ValueError("missing/duplicate queued-write retirement marker")
        match = re.fullmatch(r"C1_SOC_QUEUED_WRITE_NUMERIC_PASS aw=(\d+) w=(\d+) b=(\d+) max_outstanding=(\d+) w_ahead_beats=(\d+)", queued[0])
        if not match:
            raise ValueError("malformed queued-write retirement marker")
        aw, w, b, peak, ahead = map(int, match.groups())
        if not (aw > 0 and w >= aw and b == aw and 1 <= peak <= 4 and 0 <= ahead <= w):
            raise ValueError("queued-write retirement/capacity mismatch")
        if serial_write and ahead!=0:
            raise ValueError("serial write mode cannot have W-ahead beats")
        print(f"C1_SOC_QUEUED_WRITE_TRACE_PASS aw={aw} w={w} b={b} peak={peak} ahead={ahead}")
    if concurrent or require_concurrent_capture:
        if len(concurrent) != 1:
            raise ValueError("missing/duplicate concurrent capture marker")
        match = re.fullmatch(r"C1_SOC_CONCURRENT_CAPTURE_PASS captures=(\d+) capture_aw_during_compute=(\d+) peak=(\d+) ahead=(\d+) done=(\d+)", concurrent[0])
        if not match:
            raise ValueError("malformed concurrent capture marker")
        captures, overlap, concurrent_peak, concurrent_ahead, completed = map(int,match.groups())
        if not (captures == 2 and 0 < overlap <= aw and 2 <= concurrent_peak == peak and
                concurrent_ahead == ahead and (ahead == 0 if serial_write else ahead > 0) and completed == 1):
            raise ValueError("concurrent capture coverage/count mismatch")
        print(f"C1_SOC_CONCURRENT_CAPTURE_TRACE_PASS captures={captures} overlap_aw={overlap} peak={peak} ahead={ahead}")
    fixture_lines = [line for line in log.splitlines() if line.startswith("C1_NUM_FIXTURE")]
    # Older numerical logs predate the explicit header and use gray only.
    if not fixture_lines:
        if schema == 2:
            raise ValueError("new numerical trace requires an explicit fixture header")
        fixture = "gray"
    elif fixture_lines in (["C1_NUM_FIXTURE gray"], ["C1_NUM_FIXTURE color_rggb"]):
        fixture = fixture_lines[0].split()[1]
    else:
        raise ValueError("unknown or duplicate numerical fixture header")
    resize_lines = [line for line in log.splitlines() if line.startswith("C1_NUM_RESIZE ")]
    if resize_lines not in ([], ["C1_NUM_RESIZE reverse_fractional"]):
        raise ValueError("unknown or duplicate resize fixture header")
    source_lines = [line for line in log.splitlines() if line.startswith("C1_NUM_SOURCE ")]
    if source_lines not in ([], ["C1_NUM_SOURCE 12x10"]) or (source_lines and resize_lines):
        raise ValueError("unknown, duplicate or conflicting source geometry header")
    source_w, source_h = (12,10) if source_lines else (frame_w,frame_h)
    raw_image = camera_fixture_rgb(source_w, source_h, fixture, source_tone)
    resized_image = (explicit_phase_rgb(raw_image,8,8,-0x14000,0xc000,0x78000,-0x4000)
                     if resize_lines else raw_image)
    if source_lines:
        resized_image = explicit_phase_rgb(raw_image,8,8,0x18000,0x14000,0x4000,0x2000)
    for line in log.splitlines():
        if not line.startswith(("C1_NUM_IN ", "C1_NUM_OUT ", "C1_NUM_DDR ",
                                "C1_NUM_VIDEO_RAW ", "C1_NUM_VIDEO_STYLED ", "C1_NUM_PREVIEW_DDR ")):
            continue
        fields = line.split()
        ncoords = 4 if fields[0] == "C1_NUM_OUT" else 2
        digits = 16 if fields[0] in ("C1_NUM_IN", "C1_NUM_OUT") else 8
        if len(fields) != ncoords + 2 or not re.fullmatch(r"[0-9a-fA-F]{%d}" % digits, fields[-1]):
            raise ValueError(f"malformed or unknown-valued trace: {line}")
        coords = tuple(int(v) for v in fields[1:-1])
        word = int(fields[-1], 16)
        if fields[0] == "C1_NUM_IN":
            x, y = coords
            if not (0 <= x < frame_w and 0 <= y < frame_h) or word >> 24:
                raise ValueError(f"invalid source coordinate/padding: {line}")
            inputs.append((x, y))
            for channel in range(3):
                image[y, x, channel] = ((word >> (channel * 8)) & 255) ^ 128
            # Independent CFA interpolation also covers discontinuities at
            # RAW10 wrapping. Gamma is programmed as rgb10 >> 2.
            expected_rgb = resized_image[y,x]
            if not np.array_equal(image[y, x], expected_rgb):
                raise ValueError(f"RAW10/ISP/resize fixture mismatch at {(x, y)}")
        elif fields[0] == "C1_NUM_OUT":
            outputs.append((*coords, word))
        elif fields[0] == "C1_NUM_DDR":
            ddr.append((*coords, word))
        elif fields[0] == "C1_NUM_PREVIEW_DDR":
            preview.append((*coords, word))
        elif fields[0] == "C1_NUM_VIDEO_RAW":
            video_raw.append((*coords, word))
        else:
            video_styled.append((*coords, word))
    if inputs != [(x, y) for y in range(frame_h) for x in range(frame_w)]:
        raise ValueError(f"source must contain exactly one row-major {frame} frame")
    preview_markers = [line for line in log.splitlines() if line.startswith("C1_NUM_PREVIEW_CAPTURE_PASS")]
    preview_admits = [line for line in log.splitlines() if line.startswith("C1_NUM_PREVIEW_ADMIT")]
    if require_preview or preview or preview_markers or preview_admits:
        if len(preview_markers) != 1:
            raise ValueError("missing/duplicate preview capture marker")
        match = re.fullmatch(r"C1_NUM_PREVIEW_CAPTURE_PASS clients=8 pixels=64 aw=8 w=16 b=8 paired_base=([0-9a-fA-F]{8}) retired_before_done=1", preview_markers[0])
        if not match:
            raise ValueError("invalid preview capture retirement evidence")
        completed_base = int(match.group(1), 16)
        admitted_bases = []
        for line in preview_admits:
            admission = re.fullmatch(r"C1_NUM_PREVIEW_ADMIT base=([0-9a-fA-F]{8}) slot=([01])", line)
            if not admission:
                raise ValueError("invalid preview slot admission")
            base, slot = int(admission.group(1), 16), int(admission.group(2))
            # This checker targets the BFM's fixed two-slot 8x8 memory map.
            if base != 0x01000000 + slot * 0x100 or base in admitted_bases:
                raise ValueError("incorrect/duplicate preview slot binding")
            admitted_bases.append(base)
        # One completed frame; a second slot may already be admitted at stop.
        if not admitted_bases or completed_base != admitted_bases[0]:
            raise ValueError("preview completion does not identify the first admitted frame")
        expected_preview = [(x, y, (int(resized_image[y,x,0]) << 16) |
                             (int(resized_image[y,x,1]) << 8) | int(resized_image[y,x,2]))
                            for y in range(8) for x in range(8)]
        if preview != expected_preview:
            raise ValueError(f"preview XRGB DDR mismatch: pixels={len(preview)}")
        print("C1_SOC_PREVIEW_GOLDEN_PASS pixels=64 source=independent_raw_isp_resize paired_slot=1 retired=1")
    rgb, layers = integer_infer_rgb(image, artifact, collect=True)
    views=check_view_elision(log,frame_w,frame_h,1)
    expected = []
    for stage, name in enumerate(STAGE_NAMES):
        if (views and stage in (14,17)) or (final_fusion_mode(log) and stage==21):continue
        plane = layers["output.conv3x3" if stage == 21 else name]
        height, width, channels = plane.shape
        for y in range(height):
            for x in range(width):
                for group in range((channels + 7) // 8):
                    expected.append((stage, x, y, group,
                                     _center_group(plane, x, y, group, channels)))
    if declared_results is not None and declared_results != len(expected):
        raise ValueError("declared C8 result count does not match the integer golden graph")
    if len(outputs) != len(expected):
        raise ValueError(f"result count {len(outputs)} != {len(expected)}")
    for index, (actual, golden) in enumerate(zip(outputs, expected)):
        if actual != golden:
            raise ValueError(f"result {index}: actual={actual[:-1]}/{actual[-1]:016x} "
                             f"golden={golden[:-1]}/{golden[-1]:016x}")
    expected_ddr = [(x, y, (int(rgb[y,x,0]) << 16) | (int(rgb[y,x,1]) << 8) | int(rgb[y,x,2]))
                    for y in range(frame_h) for x in range(frame_w)]
    if ddr != expected_ddr:
        mismatch = next((i for i, pair in enumerate(zip(ddr, expected_ddr)) if pair[0] != pair[1]), None)
        raise ValueError(f"final XRGB DDR mismatch: pixels={len(ddr)}, first_difference={mismatch}")
    # Older traces lack the video extension. Once either stream is present,
    # require both complete images; partial video evidence must not pass.
    if require_video or video_raw or video_styled:
        first_image = resized_image if preview_display else raw_image
        first_h, first_w = first_image.shape[:2]
        expected_raw = [(x,y,(int(first_image[y,x,0])<<16)|(int(first_image[y,x,1])<<8)|int(first_image[y,x,2]))
                        for y in range(first_h) for x in range(first_w)]
        if video_raw != expected_raw or video_styled != expected_ddr:
            raw_difference = next(((i,a,b) for i,(a,b) in enumerate(zip(video_raw,expected_raw)) if a!=b),None)
            styled_difference = next(((i,a,b) for i,(a,b) in enumerate(zip(video_styled,expected_ddr)) if a!=b),None)
            raise ValueError(f"display pixel mismatch: raw={len(video_raw)} styled={len(video_styled)} "
                             f"raw_first={raw_difference} styled_first={styled_difference}")
        if preview_display:
            print("C1_SOC_PREVIEW_VIDEO_GOLDEN_PASS preview_pixels=64 styled_pixels=64")
        else:
            print(f"C1_SOC_VIDEO_GOLDEN_PASS raw_pixels={source_w*source_h} styled_pixels={frame_w*frame_h}")
    if views:print(f"C1_SOC_VIEW_ELISION_GOLDEN_PASS logical_stages=22 data_stages={20-int(fused_final)} views=2 full_network_reference=1")
    if fused_final:print("C1_SOC_FINAL_FUSION_GOLDEN_PASS logical_stages=22 identity_stage=21 held_eof_barrier=1 full_network_reference=1")
    if check_column_refill(log,frame_w,frame_h,1) is not None:
        histogram = int("C1_NUM_COLUMN_REFILL version=2 " in log)
        print(f"C1_SOC_COLUMN_REFILL_PASS descriptor_words=1 reserved_credit=1 burst_histogram={histogram}")
    assoc=check_scalar_assoc(log,frame_w,frame_h,1)
    if assoc is not None:
        print(f"C1_SOC_SCALAR_ASSOC_PASS entries={assoc} residual_budget=1 actual_axi=1")
    print(f"C1_SOC_NUMERICAL_GOLDEN_PASS frame={frame} fixture={fixture} resize={'downsample_12x10' if source_lines else ('reverse_fractional' if resize_lines else 'unit')} inputs={frame_w*frame_h} stages=22 C8_results={len(expected)} DDR_pixels={frame_w*frame_h}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--expect-frame", choices=("8x8", "16x8", "16x16", "64x48"), help="Require this frame size independently of the trace")
    parser.add_argument("--require-stage-perf", action="store_true", help="Require every stage's real MAC handshakes and reconciliation with job counters")
    parser.add_argument("--require-stage0-profile", action="store_true")
    parser.add_argument("--require-precise-write-invalidation", action="store_true", help="Require actual line-matching write invalidation in the scalar read-cache path")
    parser.add_argument("--require-virtual-upsample", action="store_true", help="Require actual virtual tensors plus all 22 numerical stages and zero stage14/17 scalar writes")
    parser.add_argument("--require-virtual-upsample-abort", action="store_true", help="Require real stage18 small-tensor refill cancellation, drain and full numerical restart")
    parser.add_argument("--require-dw-stream", action="store_true", help="Require actual cached DW group streaming and descriptor-derived warm beat counts")
    parser.add_argument("--require-column-write-overlap", action="store_true", help="Require actual independent column/write progress and bounded write credits")
    parser.add_argument("--require-pointwise-columns", action="store_true")
    parser.add_argument("--require-column-response-bypass", action="store_true")
    parser.add_argument("--require-column-row-map", action="store_true")
    parser.add_argument("--require-final-fusion", action="store_true")
    parser.add_argument("--require-pixel-column-prefetch", action="store_true")
    parser.add_argument("--require-all-pixel-groups", action="store_true")
    parser.add_argument("--require-dot-pixel-pipeline", action="store_true")
    parser.add_argument("--require-all-dot-groups", action="store_true")
    parser.add_argument("--require-packed-rgb", action="store_true")
    parser.add_argument("--require-view-elision", action="store_true")
    parser.add_argument("--require-all-dot-abort", action="store_true")
    parser.add_argument("--require-dot-pixel-abort", action="store_true")
    parser.add_argument("--expect-tensor-write-outstanding",type=int,choices=(1,2,4))
    parser.add_argument("--expect-pixel-write-batch",type=int,nargs=2,metavar=("WORDS","TIMEOUT"))
    parser.add_argument("--require-dw-pixel-pipeline",action="store_true")
    parser.add_argument("--require-dw-frame",action="store_true")
    parser.add_argument("--expect-column-refill",type=int,nargs=2,metavar=("WINDOW","HANDOFF"))
    parser.add_argument("--expect-scalar-cache-entries",type=int,choices=(1,2))
    parser.add_argument("--require-scalar-assoc-abort",action="store_true")
    parser.add_argument("--require-dw-pixel-abort",action="store_true")
    parser.add_argument("--require-tensor-mlp-abort",action="store_true")
    parser.add_argument("--require-pixel-prefetch-abort", action="store_true")
    parser.add_argument("--require-source-pipeline", action="store_true")
    parser.add_argument("--require-pointwise-reduction", action="store_true")
    parser.add_argument("--require-requant-overlap", action="store_true")
    parser.add_argument("--require-pointwise-reduction-abort", action="store_true")
    parser.add_argument("--require-source-write-abort", action="store_true")
    parser.add_argument("--expect-bfm-extra", type=int, nargs=3, metavar=("FIRST", "BEAT", "WRITE"),
                        help="Require exact BFM extra-cycle configuration and measured read presentation evidence")
    parser.add_argument("--require-read-abort", action="store_true", help="Require real refill hold, drain, no-reset restart and full video golden")
    parser.add_argument("--require-scalar-read-abort", action="store_true", help="Require the slot6 cacheable miss, late-fill suppression, drain and no-reset recovery")
    parser.add_argument("--require-write-abort", action="store_true", help="Require held write responses, full drain and no-reset numerical recovery")
    parser.add_argument("--require-video", action="store_true", help="Reject absent or incomplete display pixel traces")
    parser.add_argument("--require-raw-fault-recovery", action="store_true", help="Require real RAW fault, ordered write drain, no-reset recovery, video and DDR golden")
    parser.add_argument("--require-missing-eof-recovery", action="store_true", help="Require post-drain EOF boundary wait and full numerical recovery")
    parser.add_argument("--require-idle-timeout-recovery", action="store_true", help="Require hardware source timeout and complete numerical recovery")
    parser.add_argument("--require-explicit-recovery", action="store_true", help="Require permanent-stop explicit FIFO recovery and complete numerical recovery")
    parser.add_argument("--require-late-source-ack", action="store_true", help="Require ownership held after DDR drain until source acknowledgement")
    parser.add_argument("--require-apb-recovery", action="store_true", help="Require software-command recovery and numerical correctness")
    parser.add_argument("--require-preview", action="store_true", help="Require complete preview DDR and retirement traces")
    parser.add_argument("--require-preview-display", action="store_true", help="Require preview rather than camera raw on first display branch")
    parser.add_argument("--require-distinct-recovery", action="store_true", help="Require recovery camera frame RAW10 tone offset 32")
    parser.add_argument("--require-preview-recovery", action="store_true", help="Require fault drain followed by no-reset preview recovery and golden frame")
    parser.add_argument("--require-preview-cancel-recovery", action="store_true", help="Require canceled task drain followed by no-reset complete golden frame")
    parser.add_argument("--require-queued-write", action="store_true", help="Require queued-write retirement evidence")
    parser.add_argument("--require-concurrent-capture", action="store_true", help="Require real capture/CNN write overlap evidence")
    parser.add_argument("--require-compact-refill", action="store_true", help="Require actual 16/16 logical refill FIFO capacity evidence")
    parser.add_argument("--artifact", type=Path,
                        default=Path(__file__).resolve().parents[1] / "model/microstyle24_starry_functional")
    args = parser.parse_args()
    if args.expect_scalar_cache_entries is not None or args.require_scalar_assoc_abort:
        assoc_status=json.loads((args.run/"status.json").read_text(encoding="utf-8-sig"))
        assoc_w,assoc_h=map(int,assoc_status.get("frame","8x8").split("x"))
        assoc_log=(args.run/"xsim.stdout.log").read_text(encoding="utf-8-sig")
        check_scalar_assoc(assoc_log,assoc_w,assoc_h,1,args.expect_scalar_cache_entries)
        check_scalar_assoc_abort(assoc_log,args.require_scalar_assoc_abort)
    if args.expect_column_refill is not None:
        refill_status=json.loads((args.run / "status.json").read_text(encoding="utf-8-sig"))
        refill_w,refill_h=map(int,refill_status.get("frame","8x8").split("x"))
        check_column_refill((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),refill_w,refill_h,1,args.expect_column_refill)
    if args.require_dw_frame:
        frame_status=json.loads((args.run / "status.json").read_text(encoding="utf-8-sig"))
        frame_w,frame_h=map(int,frame_status.get("frame","8x8").split("x"))
        check_dw_frame((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),frame_w,frame_h,1,True)
    if args.require_view_elision:
        view_status=json.loads((args.run / "status.json").read_text(encoding="utf-8-sig"))
        view_w,view_h=map(int,view_status.get("frame","8x8").split("x"))
        check_view_elision((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),view_w,view_h,1,True)
    if args.require_packed_rgb:
        rgb_status=json.loads((args.run / "status.json").read_text(encoding="utf-8-sig"))
        rgb_w,rgb_h=map(int,rgb_status.get("frame","8x8").split("x"))
        check_rgb_reduction((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),rgb_w,rgb_h,1,True)
    if args.require_stage0_profile:
        check_stage0_profile((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),True)
    if args.require_all_dot_groups:
        all_dot_groups_enabled((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),True)
    if args.require_all_dot_abort:
        check_all_dot_abort((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),True)
    if args.require_dw_pixel_pipeline or args.require_dw_pixel_abort:
        dw_status=json.loads((args.run / "status.json").read_text(encoding="utf-8-sig"))
        dw_w,dw_h=map(int,dw_status.get("frame","8x8").split("x"))
        check_dw_pixel_pipeline((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),dw_w,dw_h,1,True,args.require_dw_pixel_abort)
    if args.expect_pixel_write_batch is not None:
        batch_status=json.loads((args.run / "status.json").read_text(encoding="utf-8-sig"))
        batch_w,batch_h=map(int,batch_status.get("frame","8x8").split("x"))
        check_pixel_write_batch((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),batch_w,batch_h,1,
                                tuple(args.expect_pixel_write_batch))
    if args.expect_tensor_write_outstanding is not None or args.require_tensor_mlp_abort:
        check_tensor_write_mlp((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),1,
                               args.expect_tensor_write_outstanding,args.require_tensor_mlp_abort)
    if args.require_dot_pixel_pipeline or args.require_dot_pixel_abort:
        pixel_status=json.loads((args.run / "status.json").read_text(encoding="utf-8-sig"))
        pixel_w,pixel_h=map(int,pixel_status.get("frame","8x8").split("x"))
        check_dot_pixel_pipeline((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),pixel_w,pixel_h,1,True,args.require_dot_pixel_abort)
    if args.require_requant_overlap:
        rq_status=json.loads((args.run / "status.json").read_text(encoding="utf-8-sig"))
        rq_w,rq_h=map(int,rq_status.get("frame","8x8").split("x"))
        check_requant_overlap((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),rq_w,rq_h,1,True)
    if args.require_pointwise_reduction or args.require_pointwise_reduction_abort:
        pw_status=json.loads((args.run / "status.json").read_text(encoding="utf-8-sig"))
        pw_w,pw_h=map(int,pw_status.get("frame","8x8").split("x"))
        check_pointwise_reduction((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),pw_w,pw_h,1,True,args.require_pointwise_reduction_abort)
    if args.require_source_pipeline or args.require_source_write_abort:
        source_status=json.loads((args.run / "status.json").read_text(encoding="utf-8-sig"))
        source_w,source_h=map(int,source_status.get("frame","8x8").split("x"))
        check_source_writes((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),source_w,source_h,1,True,args.require_source_write_abort)
    if args.require_all_pixel_groups:
        all_pixel_groups_enabled((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),True)
    if args.require_pixel_column_prefetch or args.require_pixel_prefetch_abort or args.require_all_pixel_groups:
        pf_frame=json.loads((args.run / "status.json").read_text(encoding="utf-8-sig")).get("frame","8x8")
        pf_w,pf_h=map(int,pf_frame.split("x"))
        check_pixel_column_prefetch((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),
            pf_w,pf_h,1,args.require_pixel_column_prefetch,args.require_pixel_prefetch_abort)
    if args.require_final_fusion:
        final_fusion_mode((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),True)
    if args.require_column_row_map:
        check_column_row_map((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),1,True)
    if args.require_column_response_bypass:
        check_column_response_bypass((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),1,True)
    check(args.run, args.artifact, require_pointwise_columns=args.require_pointwise_columns, require_column_write_overlap=args.require_column_write_overlap, require_dw_stream=args.require_dw_stream, require_virtual_upsample_abort=args.require_virtual_upsample_abort, require_virtual_upsample=args.require_virtual_upsample, require_precise_write_invalidation=args.require_precise_write_invalidation, require_stage_perf=args.require_stage_perf, expected_frame=args.expect_frame, require_scalar_read_abort=args.require_scalar_read_abort, expected_bfm_extra=args.expect_bfm_extra, require_write_abort=args.require_write_abort, require_read_abort=args.require_read_abort, require_video=args.require_video, require_queued_write=args.require_queued_write,
          require_concurrent_capture=args.require_concurrent_capture, require_compact_refill=args.require_compact_refill,
          require_preview=args.require_preview, require_preview_recovery=args.require_preview_recovery,
          require_preview_cancel_recovery=args.require_preview_cancel_recovery,
          require_preview_display=args.require_preview_display, require_distinct_recovery=args.require_distinct_recovery,
          require_raw_fault_recovery=args.require_raw_fault_recovery,
          require_missing_eof_recovery=args.require_missing_eof_recovery,
          require_idle_timeout_recovery=args.require_idle_timeout_recovery,
          require_explicit_recovery=args.require_explicit_recovery,
          require_late_source_ack=args.require_late_source_ack,
          require_apb_recovery=args.require_apb_recovery)
