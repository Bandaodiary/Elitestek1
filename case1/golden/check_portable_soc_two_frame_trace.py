"""Independent bounded two-job CNN, physical-DDR and optional video checker."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

import numpy as np
from generate_microstyle_engine_bitexact_vectors import STAGE_NAMES, _center_group, integer_infer_rgb
from generate_r1_resize_line_sampler_vectors import explicit_phase_rgb
from microstyle_workload import workload
from check_column_write_overlap_trace import check_column_write_overlap, overlap_mutations
from check_pointwise_column_trace import check_pointwise_columns, pointwise_mutations
from check_column_response_bypass_trace import check_column_response_bypass, response_bypass_mutations
from check_column_row_map_trace import check_column_row_map, row_map_mutations
from check_pixel_column_prefetch_trace import check_pixel_column_prefetch, pixel_prefetch_mutations, all_pixel_groups_enabled
from check_source_write_pipeline_trace import check_source_writes, source_write_mutations
from check_pointwise_reduction_trace import check_pointwise_reduction, pointwise_reduction_mutations
from check_mac_requant_overlap_trace import check_requant_overlap, requant_overlap_mutations
from check_tensor_write_mlp_trace import check_tensor_write_mlp,tensor_mlp_mutations
from check_pixel_write_batch_trace import check_pixel_write_batch,pixel_batch_mutations
from check_dw_pixel_pipeline_trace import check_dw_pixel_pipeline,dw_pixel_mutations
from check_dw_frame_trace import check_dw_frame,dw_frame_mutations
from check_column_refill_trace import check_column_refill,column_refill_mutations
from check_scalar_assoc_trace import check_scalar_assoc,check_scalar_assoc_abort,scalar_assoc_mutations
from check_dot_pixel_pipeline_trace import check_dot_pixel_pipeline, dot_pixel_mutations, all_dot_groups_enabled
from check_rgb_reduction_trace import check_rgb_reduction,rgb_reduction_mutations
from check_view_elision_trace import check_view_elision,view_elision_mutations
from check_final_fusion_trace import final_fusion_mode,check_final_fusion,final_fusion_mutations

PASS = "C1_NUM_TWO_PASS frames=2 inputs=128 outputs=1672 ddr=128 swaps=2"
VIDEO_PASS = "C1_NUM_TWO_VIDEO_PASS frames=2 raw=128 styled=128 compositor_aligned=1"
PREVIEW_MODE = "C1_NUM_TWO_PREVIEW_MODE source=12x10 slots=01000000,01000100 stride=32"
COLOR_MODE = "C1_NUM_TWO_FIXTURE color_rggb"


def color_mode(log: str, required: bool = False) -> bool:
    headers = [line for line in log.splitlines() if line.startswith("C1_NUM_TWO_FIXTURE")]
    if headers not in ([], [COLOR_MODE]) or (required and not headers):
        raise ValueError("missing/duplicate/invalid two-frame color fixture")
    return bool(headers)


def preview_mode(log: str, required: bool = False) -> bool:
    headers = [line for line in log.splitlines() if line.startswith("C1_NUM_TWO_PREVIEW_MODE")]
    if headers not in ([], [PREVIEW_MODE]) or (required and not headers):
        raise ValueError("missing/duplicate/invalid two-frame preview configuration")
    return bool(headers)


def virtual_upsample_mode(log: str, required: bool = False) -> bool:
    check_rgb_reduction(log,8,8,2)
    pointwise=check_pointwise_columns(log,8,8,2)
    headers = [s for s in log.splitlines() if s.startswith("C1_NUM_VIRTUAL_UPSAMPLE")]
    if headers not in ([], ["C1_NUM_VIRTUAL_UPSAMPLE enabled=0"], ["C1_NUM_VIRTUAL_UPSAMPLE enabled=1"]):
        raise ValueError("invalid/duplicate two-frame virtual upsample mode")
    enabled = headers == ["C1_NUM_VIRTUAL_UPSAMPLE enabled=1"]
    if required and not enabled:
        raise ValueError("two-frame virtual upsample mode is required")
    if enabled:
        columns = [s for s in log.splitlines() if s.startswith("C1_NUM_COLUMN_OPTION")]
        if len(columns)!=1 or not re.fullmatch(r"C1_NUM_COLUMN_OPTION enabled=1 clients=[89]",columns[0]):
            raise ValueError("virtual tensors require the column branch")
        views=check_view_elision(log,8,8,2)
        jobs = [dict(re.findall(r"([a-z_]+)=(\d+)",s)) for s in log.splitlines() if s.startswith("C1_PERF_JOB ")]
        stages=workload(8,8,virtual_upsample=True,elide_views=views,fuse_final=final_fusion_mode(log))["stages"]
        scalar_reads=sum(s["scalar_reads_with_columns"]-(s["pointwise_reads"] if pointwise else 0)
                         for s in stages)
        # workload stage0 already includes ingress-to-tensor writes.
        scalar_writes=sum(s["scalar_writes"] for s in stages)
        if len(jobs)!=2 or [j.get("job") for j in jobs] != ["1","2"] or any(
                j.get("error")!="0" or j.get("mem_write")!=str(scalar_writes) or j.get("mem_read")!=str(scalar_reads) for j in jobs):
            raise ValueError("two-frame virtual tensor read/write budget mismatch")
    return enabled


def dw_stream_mode(log: str, required: bool = False) -> bool:
    modes=[s for s in log.splitlines() if s.startswith("C1_NUM_DW_STREAM")]
    records=[s for s in log.splitlines() if s.startswith("C1_PERF_DW_STREAM")]
    if not modes and not records and not required:
        return False
    if modes not in (["C1_NUM_DW_STREAM enabled=0"],["C1_NUM_DW_STREAM enabled=1"]):
        raise ValueError("missing/duplicate/invalid two-frame DW stream mode")
    enabled=modes==["C1_NUM_DW_STREAM enabled=1"]
    if required and not enabled:raise ValueError("two-frame DW streaming required")
    if len(records)!=2:raise ValueError("two-frame DW stream progress must contain two jobs")
    expected=sum(s["dw_warm_beats"] for s in workload(8,8)["stages"]) if enabled else 0
    for job,line in enumerate(records,1):
        row=re.fullmatch(r"C1_PERF_DW_STREAM job=(\d+) beats=(\d+) adjacent_feeds=(\d+)",line)
        if row is None or int(row[1])!=job or int(row[2])!=expected or (
                not 0<int(row[3])<expected if expected else int(row[3])!=0):
            raise ValueError("two-frame DW stream workload mismatch")
    if enabled:
        options=[s for s in log.splitlines() if s.startswith("C1_NUM_ENGINE_OPTIONS")]
        if len(options)!=1 or not re.fullmatch(r"C1_NUM_ENGINE_OPTIONS dw_cache=1 mac_overlap=[01]",options[0]):
            raise ValueError("two-frame DW streaming requires weight cache")
    return enabled


def reference(artifact: Path, frame: int, preview: bool = False, color: bool = False, *, elide_views: bool=False, fuse_final: bool=False) -> dict[str, list[tuple[int, ...]]]:
    # Linear RAW10 planes, valid 3x3 crop, identity ISP/Gamma.
    # Preview mode adds explicit-phase 12x10 -> 8x8 Resize; otherwise unit Resize.
    # Tone is 0/32; all sensor samples remain below 1024 (no clipping).
    width, height = (12, 10) if preview else (8, 8)
    image = np.empty((height, width, 3), dtype=np.uint8)
    for y in range(height):
        for x in range(width):
            offsets = (96, 40, 0) if color else (0, 0, 0)
            image[y, x, :] = [(64 + 17*(x+1) + 29*(y+1) + frame*32 + offset) >> 2
                              for offset in offsets]
    if preview:
        image = explicit_phase_rgb(image, 8, 8, 0x18000, 0x14000, 0x4000, 0x2000)
    rgb, layers = integer_infer_rgb(image, artifact, collect=True)
    inputs = [(x, y, sum((int(image[y, x, c]) ^ 128) << (8*c) for c in range(3)))
              for y in range(8) for x in range(8)]
    outputs = []
    for stage, name in enumerate(STAGE_NAMES):
        if (elide_views and stage in (14,17)) or (fuse_final and stage==21):continue
        plane = layers["output.conv3x3" if stage == 21 else name]
        h, w, channels = plane.shape
        for y in range(h):
            for x in range(w):
                for group in range((channels+7)//8):
                    outputs.append((stage, x, y, group, _center_group(plane, x, y, group, channels)))
    ddr = [(x, y, (int(rgb[y, x, 0]) << 16) | (int(rgb[y, x, 1]) << 8) | int(rgb[y, x, 2]))
           for y in range(8) for x in range(8)]
    if len(outputs) != (660 if elide_views else 836)-(64 if fuse_final else 0):
        raise ValueError("artifact is not the supported 22-stage 8x8 topology")
    raw = [(x, y, sum(int(image[y, x, c]) << (8*(2-c)) for c in range(3)))
           for y in range(8) for x in range(8)]
    return {"IN": inputs, "OUT": outputs, "DDR": ddr, "PREVIEW": raw, "VIDEO_RAW": raw, "VIDEO_STYLED": ddr}


def check_text(log: str, expected: list[dict], require_video: bool = False, require_preview: bool = False) -> None:
    views=check_view_elision(log,8,8,2)
    physical_results=(660 if views else 836)-(64 if final_fusion_mode(log) else 0)
    check_final_fusion(log,8,8,2)
    if any(len(frame["OUT"])!=physical_results for frame in expected):
        raise ValueError("reference result count disagrees with view execution mode")
    pass_marker=f"C1_NUM_TWO_PASS frames=2 inputs=128 outputs={physical_results*2} ddr=128 swaps=2"
    check_requant_overlap(log,8,8,2)
    check_tensor_write_mlp(log,2)
    check_pixel_write_batch(log,8,8,2)
    check_dw_pixel_pipeline(log,8,8,2)
    check_column_refill(log,8,8,2)
    check_scalar_assoc(log,8,8,2)
    check_pointwise_reduction(log,8,8,2)
    check_source_writes(log,8,8,2)
    check_pixel_column_prefetch(log,8,8,2)
    check_column_response_bypass(log,2)
    check_column_row_map(log,2)
    virtual_upsample_mode(log)
    dw_stream_mode(log)
    check_column_write_overlap(log, 2)
    preview = preview_mode(log, require_preview)
    color_mode(log)
    require_video = require_video or preview
    retired = [False, False]
    active = None
    completed = 0
    passed = False
    counts = {}
    video_counts = [{"RAW": 0, "STYLED": 0} for _ in range(2)]
    video_seen = False
    video_passed = False
    for line in log.splitlines():
        if not line.startswith("C1_NUM_TWO_"):
            continue
        if passed:
            raise ValueError("trace after terminal marker")
        if line in (PREVIEW_MODE, COLOR_MODE):
            if active is not None or completed:
                raise ValueError("late configuration header")
            continue
        if line == pass_marker:
            if completed != 2 or active is not None:
                raise ValueError("premature terminal marker")
            if (require_video or video_seen) and not video_passed:
                raise ValueError("missing complete two-frame video evidence")
            passed = True
            continue
        if line == VIDEO_PASS:
            if video_passed or video_counts != [{"RAW": 64, "STYLED": 64}]*2:
                raise ValueError("incomplete/duplicate video marker")
            video_passed = True
            video_seen = True
            continue
        fields = line.split()
        if fields[0] == "C1_NUM_TWO_PREVIEW_RETIRED":
            if not preview or active is None or retired[active] or counts.get("PREVIEW") != 64 or line != f"C1_NUM_TWO_PREVIEW_RETIRED {active} 8 16 8":
                raise ValueError("invalid preview retirement accounting")
            retired[active] = True
        elif fields[0] in ("C1_NUM_TWO_VIDEO_RAW", "C1_NUM_TWO_VIDEO_STYLED"):
            video_seen = True
            match = re.fullmatch(r"C1_NUM_TWO_VIDEO_(RAW|STYLED) ([01]) (\d+) (\d+) ([0-9a-fA-F]{8})", line)
            if not match or video_passed:
                raise ValueError("malformed/late video record")
            kind, frame, x, y, word = match.groups()
            frame = int(frame)
            if frame >= completed:
                raise ValueError("video frame precedes its successful completion")
            idx = video_counts[frame][kind]
            actual = (int(x), int(y), int(word, 16))
            if idx >= 64 or actual != expected[frame][f"VIDEO_{kind}"][idx]:
                raise ValueError(f"frame {frame} video {kind} pixel {idx} differs from independent golden")
            video_counts[frame][kind] += 1
        elif fields[0] == "C1_NUM_TWO_BEGIN":
            if active is not None or completed >= 2 or line != f"C1_NUM_TWO_BEGIN {completed} {completed} {completed}":
                raise ValueError("incorrect frame admission or input/output slot pairing")
            active = completed
            counts = {"IN": 0, "OUT": 0, "DDR": 0}
            if preview:
                counts["PREVIEW"] = 0
        elif fields[0] == "C1_NUM_TWO_END":
            wanted_counts = {"IN": 64, "OUT": physical_results, "DDR": 64}
            if preview:
                wanted_counts["PREVIEW"] = 64
            if active is None or line != f"C1_NUM_TWO_END {active}" or counts != wanted_counts or (preview and not retired[active]):
                raise ValueError("incomplete/duplicate frame completion")
            completed += 1
            active = None
        else:
            kind = fields[0].removeprefix("C1_NUM_TWO_")
            if active is None or kind not in counts:
                raise ValueError("unknown/out-of-frame trace")
            ncoords, digits = (4, 16) if kind == "OUT" else (2, 16 if kind == "IN" else 8)
            if len(fields) != ncoords+3 or fields[1] != str(active) or not re.fullmatch(rf"[0-9a-fA-F]{{{digits}}}", fields[-1]):
                raise ValueError("malformed/unknown-valued frame record")
            actual = tuple(int(v) for v in fields[2:-1]) + (int(fields[-1], 16),)
            idx = counts[kind]
            wanted = expected[active][kind]
            if idx >= len(wanted) or actual != wanted[idx]:
                raise ValueError(f"frame {active} {kind} record {idx} differs from independent golden")
            if kind in ("DDR", "PREVIEW") and (counts["IN"] != 64 or counts["OUT"] != physical_results):
                raise ValueError("DDR completion snapshot precedes compute retirement")
            counts[kind] += 1
    if not passed:
        raise ValueError("missing terminal marker/two completed frames")


def negative_tests(log: str, expected: list[dict], require_video: bool = False, require_preview: bool = False) -> int:
    lines = log.splitlines()
    cases = []
    for prefix in ("C1_NUM_TWO_BEGIN 1", "C1_NUM_TWO_IN 1", "C1_NUM_TWO_OUT 1", "C1_NUM_TWO_DDR 1", "C1_NUM_TWO_END 1", "C1_NUM_TWO_PASS "):
        idx = next(i for i, line in enumerate(lines) if line.startswith(prefix))
        cases.append(lines[:idx] + lines[idx+1:])
        cases.append(lines[:idx] + [lines[idx]] + lines[idx:])
    for kind in ("IN", "OUT", "DDR"):
        idx = next(i for i, line in enumerate(lines) if line.startswith(f"C1_NUM_TWO_{kind} 1 "))
        fields = lines[idx].split()
        wrong = fields[:-1] + [f"{int(fields[-1],16)^1:0{len(fields[-1])}x}"]
        cases.append(lines[:idx] + [" ".join(wrong)] + lines[idx+1:])
        wrong[-1] = "x" * len(fields[-1])
        cases.append(lines[:idx] + [" ".join(wrong)] + lines[idx+1:])
    # Stale first-frame input is valid numeric data, but the wrong image.
    i0 = next(i for i, line in enumerate(lines) if line.startswith("C1_NUM_TWO_IN 0 "))
    i1 = next(i for i, line in enumerate(lines) if line.startswith("C1_NUM_TWO_IN 1 "))
    cases.append(lines[:i1] + [lines[i0].replace("IN 0 ", "IN 1 ", 1)] + lines[i1+1:])
    if VIDEO_PASS in lines:
        for prefix in ("C1_NUM_TWO_VIDEO_RAW 0", "C1_NUM_TWO_VIDEO_RAW 1",
                       "C1_NUM_TWO_VIDEO_STYLED 0", "C1_NUM_TWO_VIDEO_STYLED 1", VIDEO_PASS):
            idx = next(i for i, line in enumerate(lines) if line.startswith(prefix))
            cases.append(lines[:idx] + lines[idx+1:])
            cases.append(lines[:idx] + [lines[idx]] + lines[idx:])
        idx = next(i for i, line in enumerate(lines) if line.startswith("C1_NUM_TWO_VIDEO_RAW 1 "))
        fields = lines[idx].split()
        stale = expected[0]["VIDEO_RAW"][0][-1]
        cases.append(lines[:idx] + [" ".join(fields[:-1] + [f"{stale:08x}"])] + lines[idx+1:])
        cases.append(lines[:idx] + [" ".join(fields[:-1] + ["xxxxxxxx"])] + lines[idx+1:])
        if require_video:
            cases.append([line for line in lines if not line.startswith("C1_NUM_TWO_VIDEO_")])
    if PREVIEW_MODE in lines:
        for prefix in (PREVIEW_MODE, "C1_NUM_TWO_PREVIEW 0", "C1_NUM_TWO_PREVIEW 1",
                       "C1_NUM_TWO_PREVIEW_RETIRED 0", "C1_NUM_TWO_PREVIEW_RETIRED 1"):
            idx = next(i for i, line in enumerate(lines) if line.startswith(prefix))
            cases.append(lines[:idx]+lines[idx+1:])
            cases.append(lines[:idx]+[lines[idx]]+lines[idx:])
        idx = next(i for i, line in enumerate(lines) if line.startswith("C1_NUM_TWO_PREVIEW 1 "))
        fields = lines[idx].split()
        stale = expected[0]["PREVIEW"][0][-1]
        cases.append(lines[:idx]+[" ".join(fields[:-1]+[f"{stale:08x}"])]+lines[idx+1:])
        if require_preview:
            cases.append([line for line in lines if not line.startswith("C1_NUM_TWO_PREVIEW")])
    if COLOR_MODE in lines:
        idx = lines.index(COLOR_MODE)
        cases.append(lines[:idx] + lines[idx+1:])
        cases.append(lines[:idx] + [lines[idx]] + lines[idx:])
        cases.append(lines[:idx] + ["C1_NUM_TWO_FIXTURE unknown"] + lines[idx+1:])
        # Swap R/B while preserving coordinates, padding and record count.
        for kind in ("IN", "PREVIEW", "VIDEO_RAW"):
            if kind == "PREVIEW" and PREVIEW_MODE not in lines:
                continue
            for frame in range(2):
                idx = next(i for i, line in enumerate(lines) if line.startswith(f"C1_NUM_TWO_{kind} {frame} "))
                fields = lines[idx].split()
                word = int(fields[-1], 16)
                swapped = (word & ~0xff00ff) | ((word & 255) << 16) | ((word >> 16) & 255)
                assert word != swapped, "color fixture must distinguish R from B"
                cases.append(lines[:idx] + [" ".join(fields[:-1]+[f"{swapped:0{len(fields[-1])}x}"])] + lines[idx+1:])
    virtual = virtual_upsample_mode(log)
    if virtual:
        mode = "C1_NUM_VIRTUAL_UPSAMPLE enabled=1"
        for prefix in (mode,"C1_NUM_COLUMN_OPTION","C1_PERF_JOB job=1 ","C1_PERF_JOB job=2 "):
            idx = next(i for i,line in enumerate(lines) if line.startswith(prefix))
            cases.append(lines[:idx]+lines[idx+1:])
            cases.append(lines[:idx]+[lines[idx]]+lines[idx:])
        idx = lines.index(mode)
        cases.append(lines[:idx]+[mode.replace("=1","=0")]+lines[idx+1:])
        cases.append(lines[:idx]+[mode.replace("=1","=2")]+lines[idx+1:])
        for job in (1,2):
            idx = next(i for i,line in enumerate(lines) if line.startswith(f"C1_PERF_JOB job={job} "))
            wrong_writes=int(re.search(r"\bmem_write=(\d+)",lines[idx])[1])+1
            cases.append(lines[:idx]+[re.sub(r"\bmem_write=\d+",f"mem_write={wrong_writes}",lines[idx])]+lines[idx+1:])
    dw_stream=dw_stream_mode(log)
    if dw_stream:
        mode="C1_NUM_DW_STREAM enabled=1"
        for prefix in (mode,"C1_PERF_DW_STREAM job=1 ","C1_PERF_DW_STREAM job=2 "):
            idx=next(i for i,line in enumerate(lines) if line.startswith(prefix))
            cases.append(lines[:idx]+lines[idx+1:]);cases.append(lines[:idx]+[lines[idx]]+lines[idx:])
        idx=lines.index(mode)
        cases.append(lines[:idx]+[mode.replace("=1","=0")]+lines[idx+1:])
        cases.append(lines[:idx]+[mode.replace("=1","=2")]+lines[idx+1:])
        for job in (1,2):
            idx=next(i for i,line in enumerate(lines) if line.startswith(f"C1_PERF_DW_STREAM job={job} "))
            for field in ("beats","adjacent_feeds"):
                cases.append(lines[:idx]+[re.sub(rf"\b{field}=\d+",field+"=0",lines[idx])]+lines[idx+1:])
    overlap=check_column_write_overlap(log, 2)
    cases.extend(s.splitlines() for s in overlap_mutations(log).values())
    pointwise=check_pointwise_columns(log,8,8,2)
    cases.extend(s.splitlines() for s in pointwise_mutations(log).values())
    response_bypass=check_column_response_bypass(log,2)
    row_map=check_column_row_map(log,2)
    fusion=check_final_fusion(log,8,8,2)
    cases.extend(s.splitlines() for s in final_fusion_mutations(log).values())
    cases.extend(s.splitlines() for s in row_map_mutations(log).values())
    cases.extend(s.splitlines() for s in response_bypass_mutations(log).values())
    pixel_prefetch=check_pixel_column_prefetch(log,8,8,2)
    all_groups=all_pixel_groups_enabled(log)
    source_pipeline=check_source_writes(log,8,8,2)
    pw_reduction=check_pointwise_reduction(log,8,8,2)
    requant_overlap=check_requant_overlap(log,8,8,2)
    write_slots=check_tensor_write_mlp(log,2)
    dw_pixels=check_dw_pixel_pipeline(log,8,8,2)
    dw_frame=check_dw_frame(log,8,8,2)
    column_refill=check_column_refill(log,8,8,2)
    scalar_assoc=check_scalar_assoc(log,8,8,2)
    if scalar_assoc is not None:
        cases.extend(s.splitlines() for s in scalar_assoc_mutations(log).values())
    if column_refill is not None:
        cases.extend(s.splitlines() for s in column_refill_mutations(log).values())
    if "C1_NUM_DW_FRAME_STREAM " in log:
        cases.extend(s.splitlines() for s in dw_frame_mutations(log).values())
    cases.extend(s.splitlines() for s in dw_pixel_mutations(log).values())
    batch_selection=check_pixel_write_batch(log,8,8,2)
    cases.extend(s.splitlines() for s in pixel_batch_mutations(log).values())
    pixel_pipeline=bool(check_dot_pixel_pipeline(log,8,8,2))
    all_dot_groups=all_dot_groups_enabled(log)
    packed_rgb=check_rgb_reduction(log,8,8,2)
    views=check_view_elision(log,8,8,2)
    cases.extend(s.splitlines() for s in view_elision_mutations(log).values())
    cases.extend(s.splitlines() for s in rgb_reduction_mutations(log).values())
    cases.extend(s.splitlines() for s in dot_pixel_mutations(log).values())
    cases.extend(s.splitlines() for s in requant_overlap_mutations(log).values())
    cases.extend(s.splitlines() for s in tensor_mlp_mutations(log).values())
    cases.extend(s.splitlines() for s in pointwise_reduction_mutations(log).values())
    cases.extend(s.splitlines() for s in source_write_mutations(log).values())
    cases.extend(s.splitlines() for s in pixel_prefetch_mutations(log).values())
    for index, mutated in enumerate(cases):
        try:
            check_column_response_bypass("\n".join(mutated),2,response_bypass)
            check_column_row_map("\n".join(mutated),2,row_map,require_mode="C1_NUM_COLUMN_ROW_MAP " in log)
            check_final_fusion("\n".join(mutated),8,8,2,fusion,require_mode="C1_NUM_FINAL_FUSION " in log)
            check_pixel_column_prefetch("\n".join(mutated),8,8,2,pixel_prefetch)
            all_pixel_groups_enabled("\n".join(mutated),all_groups)
            check_source_writes("\n".join(mutated),8,8,2,source_pipeline)
            check_pointwise_reduction("\n".join(mutated),8,8,2,pw_reduction)
            check_requant_overlap("\n".join(mutated),8,8,2,requant_overlap)
            check_tensor_write_mlp("\n".join(mutated),2,write_slots)
            check_dw_pixel_pipeline("\n".join(mutated),8,8,2,dw_pixels)
            check_column_refill("\n".join(mutated),8,8,2,column_refill)
            check_scalar_assoc("\n".join(mutated),8,8,2,scalar_assoc)
            check_dw_frame("\n".join(mutated),8,8,2,dw_frame,
                           require_mode="C1_NUM_DW_FRAME_STREAM " in log)
            check_pixel_write_batch("\n".join(mutated),8,8,2,batch_selection)
            all_dot_groups_enabled("\n".join(mutated),all_dot_groups)
            check_view_elision("\n".join(mutated),8,8,2,views,require_mode="C1_NUM_VIEW_ELISION" in log)
            check_rgb_reduction("\n".join(mutated),8,8,2,packed_rgb,
                                require_mode="C1_NUM_RGB_REDUCTION" in log)
            check_dot_pixel_pipeline("\n".join(mutated),8,8,2,pixel_pipeline)
            virtual_upsample_mode("\n".join(mutated), required=virtual)
            dw_stream_mode("\n".join(mutated), required=dw_stream)
            check_column_write_overlap("\n".join(mutated), 2, required=overlap)
            check_pointwise_columns("\n".join(mutated),8,8,2,required=pointwise)
            if COLOR_MODE in lines:
                color_mode("\n".join(mutated), required=True)
            check_text("\n".join(mutated), expected, require_video, require_preview)
        except ValueError:
            continue
        raise AssertionError(f"negative case {index} unexpectedly accepted")
    return len(cases)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--artifact", type=Path, default=Path(__file__).resolve().parents[1] / "model/microstyle24_starry_functional")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--require-video", action="store_true")
    parser.add_argument("--require-preview", action="store_true")
    parser.add_argument("--require-color", action="store_true")
    parser.add_argument("--require-virtual-upsample", action="store_true")
    parser.add_argument("--require-dw-stream", action="store_true")
    parser.add_argument("--require-column-write-overlap", action="store_true")
    parser.add_argument("--require-pointwise-columns", action="store_true")
    parser.add_argument("--require-column-response-bypass", action="store_true")
    parser.add_argument("--require-column-row-map", action="store_true")
    parser.add_argument("--require-final-fusion", action="store_true")
    parser.add_argument("--require-pixel-column-prefetch", action="store_true")
    parser.add_argument("--require-all-pixel-groups", action="store_true")
    parser.add_argument("--require-source-pipeline", action="store_true")
    parser.add_argument("--require-pointwise-reduction", action="store_true")
    parser.add_argument("--require-requant-overlap", action="store_true")
    parser.add_argument("--require-dot-pixel-pipeline", action="store_true")
    parser.add_argument("--require-all-dot-groups", action="store_true")
    parser.add_argument("--require-packed-rgb", action="store_true")
    parser.add_argument("--require-view-elision", action="store_true")
    parser.add_argument("--expect-tensor-write-outstanding",type=int,choices=(1,2,4))
    parser.add_argument("--expect-pixel-write-batch",type=int,nargs=2,metavar=("WORDS","TIMEOUT"))
    parser.add_argument("--require-dw-pixel-pipeline",action="store_true")
    parser.add_argument("--require-dw-frame",action="store_true")
    parser.add_argument("--expect-column-refill",type=int,nargs=2,metavar=("WINDOW","HANDOFF"))
    parser.add_argument("--expect-scalar-cache-entries",type=int,choices=(1,2))
    args = parser.parse_args()
    if args.require_packed_rgb:
        check_rgb_reduction((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),8,8,2,True)
    if args.require_all_dot_groups:
        all_dot_groups_enabled((args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig"),True)
    status = json.loads((args.run / "status.json").read_text(encoding="utf-8-sig"))
    if status.get("state") != "complete" or status.get("exit_code") != 0:
        raise ValueError("simulation is not successfully complete")
    log = (args.run / "xsim.stdout.log").read_text(encoding="utf-8-sig")
    check_dw_frame(log,8,8,2,args.require_dw_frame)
    check_column_refill(log,8,8,2,args.expect_column_refill)
    check_scalar_assoc(log,8,8,2,args.expect_scalar_cache_entries)
    check_tensor_write_mlp(log,2,args.expect_tensor_write_outstanding)
    check_pixel_write_batch(log,8,8,2,args.expect_pixel_write_batch)
    check_dw_pixel_pipeline(log,8,8,2,args.require_dw_pixel_pipeline)
    check_pixel_column_prefetch(log,8,8,2,args.require_pixel_column_prefetch)
    all_pixel_groups_enabled(log,args.require_all_pixel_groups)
    check_source_writes(log,8,8,2,args.require_source_pipeline)
    check_pointwise_reduction(log,8,8,2,args.require_pointwise_reduction)
    check_requant_overlap(log,8,8,2,args.require_requant_overlap)
    check_dot_pixel_pipeline(log,8,8,2,args.require_dot_pixel_pipeline)
    check_column_response_bypass(log,2,args.require_column_response_bypass)
    check_column_row_map(log,2,args.require_column_row_map)
    check_final_fusion(log,8,8,2,args.require_final_fusion)
    virtual_upsample_mode(log, args.require_virtual_upsample)
    dw_stream_mode(log, args.require_dw_stream)
    check_column_write_overlap(log, 2, args.require_column_write_overlap)
    check_pointwise_columns(log,8,8,2,args.require_pointwise_columns)
    preview = preview_mode(log, args.require_preview)
    color = color_mode(log, args.require_color)
    views=check_view_elision(log,8,8,2,args.require_view_elision)
    expected = [reference(args.artifact, frame, preview, color,elide_views=views,fuse_final=final_fusion_mode(log)) for frame in range(2)]
    check_text(log, expected, args.require_video, args.require_preview)
    print(f"C1_TWO_FRAME_GOLDEN_PASS frames=2 inputs=128 C8_results={sum(len(frame['OUT']) for frame in expected)} DDR_pixels=128 independent_source=1")
    if views:print(f"C1_TWO_FRAME_VIEW_GOLDEN_PASS logical_stages=22 data_stages={20-int(final_fusion_mode(log))} views_per_job=2 full_network_reference=1")
    if final_fusion_mode(log):print("C1_TWO_FRAME_FINAL_FUSION_GOLDEN_PASS logical_stages=22 identity_stage=21 held_eof_barrier=1")
    if VIDEO_PASS in log.splitlines():
        print("C1_TWO_FRAME_VIDEO_GOLDEN_PASS frames=2 raw_pixels=128 styled_pixels=128")
    if preview:
        print("C1_TWO_FRAME_PREVIEW_GOLDEN_PASS frames=2 preview_pixels=128 retired_aw_w_b=8_16_8_each")
    if color:
        print("C1_TWO_FRAME_COLOR_GOLDEN_PASS frames=2 independent_RGGB_planes=1")
    if args.self_test:
        print(f"C1_TWO_FRAME_NEGATIVE_PASS cases={negative_tests(log, expected, args.require_video, args.require_preview)}")


if __name__ == "__main__":
    main()
