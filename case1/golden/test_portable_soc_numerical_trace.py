"""Check that trace validation fails closed; mutate logs in memory only."""
import contextlib
import io
import json
from pathlib import Path
import sys
import re
from unittest.mock import patch

from check_portable_soc_numerical_trace import check,check_stage0_profile
from check_column_write_overlap_trace import overlap_mutations
from check_pointwise_column_trace import pointwise_mutations
from check_column_response_bypass_trace import check_column_response_bypass, response_bypass_mutations
from check_column_row_map_trace import check_column_row_map, row_map_mutations
from check_final_fusion_trace import check_final_fusion,final_fusion_mutations
from check_pixel_column_prefetch_trace import check_pixel_column_prefetch, pixel_prefetch_mutations, all_pixel_groups_enabled
from check_source_write_pipeline_trace import check_source_writes, source_write_mutations
from check_pointwise_reduction_trace import check_pointwise_reduction, pointwise_reduction_mutations
from check_mac_requant_overlap_trace import check_requant_overlap, requant_overlap_mutations
from check_tensor_write_mlp_trace import check_tensor_write_mlp,tensor_mlp_mutations
from check_pixel_write_batch_trace import check_pixel_write_batch,pixel_batch_mutations
from check_dw_pixel_pipeline_trace import check_dw_pixel_pipeline,dw_pixel_mutations
from check_dw_frame_trace import check_dw_frame,dw_frame_mutations
from check_stage_fsm_trace import check_stage_fsm
from check_column_refill_trace import check_column_refill,check_column_stage,column_refill_mutations
from check_scalar_assoc_trace import check_scalar_assoc,check_scalar_assoc_abort,scalar_assoc_mutations
from check_dot_pixel_pipeline_trace import check_dot_pixel_pipeline, dot_pixel_mutations, all_dot_groups_enabled,check_all_dot_abort
from check_rgb_reduction_trace import check_rgb_reduction,rgb_reduction_mutations
from check_view_elision_trace import check_view_elision,view_elision_mutations


def main():
    run = Path(sys.argv[1])
    artifact = Path(__file__).resolve().parents[1] / "model/microstyle24_starry_functional"
    # Prove this input is valid before mutations; otherwise every negative
    # test could pass because of an unrelated missing prerequisite.
    check(run, artifact)
    original_read = Path.read_text
    original = (run / "xsim.stdout.log").read_text(encoding="utf-8-sig")
    status = json.loads((run / "status.json").read_text(encoding="utf-8-sig"))
    expected_frame = status.get("frame", "8x8")
    frame_w, frame_h = map(int, expected_frame.split("x"))
    require_fusion=check_final_fusion(original,frame_w,frame_h,1)
    require_scalar_read_abort = "C1_NUM_READ_ABORT_TARGET scalar" in original
    require_stage_perf = "C1_NUM_STAGE_PERF" in original
    require_stage0_profile=bool(check_stage0_profile(original))
    require_stage_fsm=bool(check_stage_fsm(original))
    require_dw_frame=check_dw_frame(original,frame_w,frame_h,1)
    column_refill=check_column_refill(original,frame_w,frame_h,1)
    column_stage=check_column_stage(original,frame_w,frame_h)
    scalar_assoc=check_scalar_assoc(original,frame_w,frame_h,1)
    scalar_assoc_abort=check_scalar_assoc_abort(original)
    require_precise_write_invalidation = "C1_NUM_PRECISE_WRITE_INVALIDATION enabled=1" in original
    require_virtual_upsample = "C1_NUM_VIRTUAL_UPSAMPLE enabled=1" in original
    require_virtual_upsample_abort = "C1_NUM_VIRTUAL_UPSAMPLE_ABORT " in original
    require_dw_stream = "C1_NUM_DW_STREAM enabled=1" in original
    require_column_write_overlap = "C1_NUM_COLUMN_WRITE_OVERLAP enabled=1" in original
    require_pointwise_columns = "C1_NUM_POINTWISE_COLUMN_READS enabled=1" in original
    require_response_bypass = check_column_response_bypass(original,1)
    require_row_map = check_column_row_map(original,1)
    row_map_present = "C1_NUM_COLUMN_ROW_MAP " in original
    require_pixel_prefetch=check_pixel_column_prefetch(original,frame_w,frame_h,1)
    require_all_groups=all_pixel_groups_enabled(original)
    require_source_pipeline=check_source_writes(original,frame_w,frame_h,1)
    require_pw_reduction=check_pointwise_reduction(original,frame_w,frame_h,1)
    require_rq_overlap=check_requant_overlap(original,frame_w,frame_h,1)
    write_slots=check_tensor_write_mlp(original,1)
    dw_pixels=check_dw_pixel_pipeline(original,frame_w,frame_h,1)
    dw_pixel_abort="C1_NUM_DW_PIXEL_ABORT " in original
    batch_selection=check_pixel_write_batch(original,frame_w,frame_h,1)
    require_mlp_abort="C1_NUM_TENSOR_MLP_ABORT " in original
    require_pixel_pipeline=bool(check_dot_pixel_pipeline(original,frame_w,frame_h,1))
    require_all_dot_groups=all_dot_groups_enabled(original)
    require_rgb=check_rgb_reduction(original,frame_w,frame_h,1)
    require_views=check_view_elision(original,frame_w,frame_h,1)
    require_all_dot_abort=check_all_dot_abort(original)
    require_dot_pixel_abort="C1_NUM_DOT_PIXEL_ABORT " in original
    require_pw_partial="C1_NUM_POINTWISE_REDUCTION_ABORT " in original
    require_source_abort="C1_NUM_SOURCE_WRITE_ABORT " in original
    require_pixel_abort="C1_NUM_PIXEL_PREFETCH_ABORT " in original
    require_video = "C1_NUM_VIDEO_RAW " in original or "C1_NUM_VIDEO_STYLED " in original
    require_queued_write = "C1_SOC_QUEUED_WRITE_NUMERIC_PASS" in original
    require_concurrent_capture = "C1_SOC_CONCURRENT_CAPTURE_PASS" in original
    require_compact_refill = "C1_NUM_REFILL_CAPACITY req_depth=16 rsp_depth=16 beat_mode=0 " in original
    require_preview = "C1_NUM_PREVIEW_" in original
    require_preview_display = "C1_NUM_FIRST_DISPLAY preview" in original
    require_distinct_recovery = "C1_NUM_SOURCE_TONE 32" in original
    require_preview_recovery = "C1_SOC_PREVIEW_BRESP_RECOVERY_PASS" in original
    require_preview_cancel_recovery = "C1_SOC_PREVIEW_CANCEL_RECOVERY_PASS" in original
    record = next(line for line in original.splitlines() if line.startswith("C1_NUM_OUT "))
    frame_record = next(line for line in original.splitlines() if line.startswith("C1_NUM_DDR "))
    variants = {
        "unknown": original.replace(record, record[:-1] + "x", 1),
        "wrong_value": original.replace(record, record[:-1] + ("1" if record[-1] != "1" else "0"), 1),
        "missing": original.replace(record + "\n", "", 1),
        "duplicate": original.replace(record, record + "\n" + record, 1),
        "ddr_wrong_value": original.replace(frame_record, frame_record[:-1] +
                                              ("1" if frame_record[-1] != "1" else "0"), 1),
        "ddr_missing": original.replace(frame_record + "\n", "", 1),
        "ddr_duplicate": original.replace(frame_record, frame_record + "\n" + frame_record, 1),
        "ddr_unknown": original.replace(frame_record, frame_record[:-1] + "x", 1),
    }
    if require_dw_stream:
        mode="C1_NUM_DW_STREAM enabled=1"
        for prefix in (mode,"C1_PERF_DW_STREAM "):
            line=next(s for s in original.splitlines() if s.startswith(prefix))
            variants[prefix+"_missing"]=original.replace(line+"\n","",1)
            variants[prefix+"_duplicate"]=original.replace(line,line+"\n"+line,1)
        variants["dw_stream_disabled"]=original.replace(mode,mode.replace("=1","=0"),1)
        variants["dw_stream_invalid"]=original.replace(mode,mode.replace("=1","=2"),1)
        record=next(s for s in original.splitlines() if s.startswith("C1_PERF_DW_STREAM "))
        for field in ("job","beats","adjacent_feeds"):
            variants["dw_stream_zero_"+field]=original.replace(record,re.sub(rf"\b{field}=\d+",field+"=0",record),1)
        variants["dw_stream_all_removed"]="\n".join(s for s in original.splitlines() if not s.startswith(("C1_NUM_DW_STREAM","C1_PERF_DW_STREAM")))
        options=next(s for s in original.splitlines() if s.startswith("C1_NUM_ENGINE_OPTIONS"))
        variants["dw_stream_cache_disabled"]=original.replace(options,options.replace("dw_cache=1","dw_cache=0"),1)
    if require_virtual_upsample_abort:
        point = next(s for s in original.splitlines() if s.startswith("C1_NUM_VIRTUAL_UPSAMPLE_ABORT "))
        variants["virtual_abort_point_missing"] = original.replace(point+"\n", "", 1)
        variants["virtual_abort_point_duplicate"] = original.replace(point, point+"\n"+point, 1)
        for field,value in (("stage",15),("width",8),("height",8),("input_bank",1),("output_bank",0)):
            variants["virtual_abort_point_wrong_"+field] = original.replace(point,re.sub(rf"\b{field}=\d+",f"{field}={value}",point),1)
    if require_virtual_upsample:
        mode = "C1_NUM_VIRTUAL_UPSAMPLE enabled=1"
        columns = next(s for s in original.splitlines() if s.startswith("C1_NUM_COLUMN_OPTION"))
        variants["virtual_mode_missing"] = original.replace(mode+"\n", "", 1)
        variants["virtual_mode_duplicate"] = original.replace(mode, mode+"\n"+mode, 1)
        variants["virtual_mode_disabled"] = original.replace(mode, mode.replace("=1", "=0"), 1)
        variants["virtual_mode_invalid"] = original.replace(mode, mode.replace("=1", "=2"), 1)
        variants["virtual_columns_missing"] = original.replace(columns+"\n", "", 1)
        variants["virtual_columns_disabled"] = original.replace(columns, columns.replace("enabled=1", "enabled=0"), 1)
        variants["virtual_all_mode_removed"] = "\n".join(s for s in original.splitlines() if not s.startswith(("C1_NUM_VIRTUAL_UPSAMPLE", "C1_NUM_COLUMN_OPTION")))
        for stage in (14,17):
            line = next(s for s in original.splitlines() if s.startswith("C1_PERF_STAGE ") and re.search(rf"\bstage={stage}\b", s))
            variants[f"virtual_stage{stage}_write"] = original.replace(line, line.replace("mem_write=0", "mem_write=1"), 1)
    if require_precise_write_invalidation:
        mode = "C1_NUM_PRECISE_WRITE_INVALIDATION enabled=1"
        cache = "C1_NUM_SCALAR_READ_CACHE enabled=1"
        columns = next(s for s in original.splitlines() if s.startswith("C1_NUM_COLUMN_OPTION"))
        variants["precise_mode_missing"] = original.replace(mode+"\n", "", 1)
        variants["precise_mode_duplicate"] = original.replace(mode, mode+"\n"+mode, 1)
        variants["precise_mode_disabled"] = original.replace(mode, mode.replace("=1", "=0"), 1)
        variants["precise_mode_invalid"] = original.replace(mode, mode.replace("=1", "=2"), 1)
        variants["precise_cache_missing"] = original.replace(cache+"\n", "", 1)
        variants["precise_cache_disabled"] = original.replace(cache, cache.replace("=1", "=0"), 1)
        variants["precise_column_disabled"] = original.replace(columns, columns.replace("enabled=1", "enabled=0"), 1)
        variants["precise_all_removed"] = "\n".join(s for s in original.splitlines() if not s.startswith(("C1_NUM_PRECISE_WRITE_INVALIDATION", "C1_NUM_SCALAR_READ_CACHE", "C1_NUM_COLUMN_OPTION")))
    if require_stage_perf:
        header = "C1_NUM_STAGE_PERF version=1 includes_setup=1"
        stage_lines = [s for s in original.splitlines() if s.startswith("C1_PERF_STAGE ")]
        first = stage_lines[0]
        dw_line = next(s for s in stage_lines if re.search(r"dw_beats=[1-9]", s))
        variants["stage_perf_missing_header"] = original.replace(header+"\n", "", 1)
        variants["stage_perf_duplicate_header"] = original.replace(header, header+"\n"+header, 1)
        variants["stage_perf_missing_row"] = original.replace(first+"\n", "", 1)
        variants["stage_perf_duplicate_row"] = original.replace(first, first+"\n"+first, 1)
        variants["stage_perf_all_removed"] = "\n".join(s for s in original.splitlines() if not s.startswith(("C1_NUM_STAGE_PERF", "C1_PERF_STAGE")))
        for key in ("job", "stage", "cycles", "dot_beats", "mem_read", "mem_write", "columns"):
            value = int(re.search(key+r"=(\d+)", first)[1])
            variants["stage_perf_wrong_"+key] = original.replace(first, re.sub(key+r"=\d+", key+"="+str(value+1), first), 1)
        variants["stage_perf_wrong_dw"] = original.replace(dw_line, re.sub(r"dw_beats=\d+", "dw_beats=0", dw_line), 1)
        variants["stage_perf_wrong_order"] = original.replace(stage_lines[0], "STAGE_SWAP", 1).replace(stage_lines[1], stage_lines[0], 1).replace("STAGE_SWAP", stage_lines[1], 1)
    profile_rows=[s for s in original.splitlines() if s.startswith("C1_PERF_STAGE0_FSM")]
    if profile_rows:
        variants["stage0_profile_all_removed"]="\n".join(s for s in original.splitlines() if not s.startswith("C1_PERF_STAGE0_FSM"))+"\n"
        for index,row in enumerate(profile_rows):
            variants[f"stage0_profile_missing_{index}"]=original.replace(row+"\n","",1)
            variants[f"stage0_profile_duplicate_{index}"]=original.replace(row,row+"\n"+row,1)
        for field in ("job","state","cycles"):
            row=profile_rows[0]
            changed=re.sub(rf"\b{field}=(\d+)",lambda m:f"{field}={int(m[1])+100000}",row)
            variants[f"stage0_profile_bad_{field}"]=original.replace(row,changed,1)
    shape_line = next((s for s in original.splitlines() if s.startswith("C1_NUM_SHAPE")), None)
    if shape_line:
        store = "C1_NUM_DDR_STORE address_keyed collision_pair=02800100:02000500 byte_strobes=1"
        variants["store_selftest_missing"] = original.replace(store+"\n", "", 1)
        variants["store_selftest_duplicate"] = original.replace(store, store+"\n"+store, 1)
        variants["store_selftest_wrong_pair"] = original.replace(store, store.replace("02800100", "02800110"), 1)
        variants["store_selftest_no_strobes"] = original.replace(store, store.replace("byte_strobes=1", "byte_strobes=0"), 1)
        trained = next(s for s in original.splitlines() if s.startswith("C1_R1_PORTABLE_SOC_TRAINED_ARTIFACT_"))
        fixture = next(s for s in original.splitlines() if s.startswith("C1_NUM_FIXTURE"))
        variants["shape_missing"] = original.replace(shape_line+"\n", "", 1)
        variants["shape_duplicate"] = original.replace(shape_line, shape_line+"\n"+shape_line, 1)
        for key in ("width", "height", "C8_results"):
            variants["shape_wrong_"+key] = original.replace(shape_line, re.sub(key+r"=\d+", key+"=0", shape_line), 1)
        variants["shape_malformed"] = original.replace(shape_line, shape_line+" extra=1", 1)
        variants["trained_pass_missing"] = original.replace(trained+"\n", "", 1)
        variants["trained_pass_duplicate"] = original.replace(trained, trained+"\n"+trained, 1)
        other_size = "8X8" if expected_frame == "16x8" else "16X8"
        variants["trained_pass_wrong_shape"] = original.replace(trained, trained.replace(expected_frame.upper(), other_size), 1)
        variants["fixture_header_missing"] = original.replace(fixture+"\n", "", 1)
        if expected_frame != "8x8":
            for tag in ("C1_NUM_IN", "C1_NUM_DDR", "C1_NUM_VIDEO_RAW", "C1_NUM_VIDEO_STYLED"):
                rows = [s for s in original.splitlines() if s.startswith(tag+" ")]
                if not rows:
                    continue
                last = rows[-1]
                assert last.split()[1:3] == [str(frame_w-1), str(frame_h-1)], "extended fixture must exercise the last pixel"
                variants[tag+"_last_pixel_missing"] = original.replace(last+"\n", "", 1)
                variants[tag+"_last_pixel_wrong"] = original.replace(last, last[:-1]+("1" if last[-1]!="1" else "0"), 1)
                variants[tag+"_crop_8x8"] = "\n".join(s for s in original.splitlines()
                    if not (s.startswith(tag+" ") and int(s.split()[1]) >= 8))
                if frame_h > 8:
                    variants[tag+"_crop_first_8_rows"] = "\n".join(s for s in original.splitlines()
                        if not (s.startswith(tag+" ") and int(s.split()[2]) >= 8))
            variants["C8_old_count_truncation"] = "\n".join(
                [s for s in original.splitlines() if not s.startswith("C1_NUM_OUT ")] +
                [s for s in original.splitlines() if s.startswith("C1_NUM_OUT ")][:836])
    require_read_abort = "C1_SOC_INFLIGHT_READ_ABORT_PASS" in original
    require_write_abort = "C1_SOC_INFLIGHT_WRITE_ABORT_PASS" in original
    if require_write_abort:
        drain = next(s for s in original.splitlines() if s.startswith("C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS"))
        restart = next(s for s in original.splitlines() if s.startswith("C1_SOC_INFLIGHT_WRITE_ABORT_PASS"))
        variants["write_abort_missing_drain"] = original.replace(drain+"\n", "", 1)
        variants["write_abort_missing_restart"] = original.replace(restart+"\n", "", 1)
        variants["write_abort_all_removed"] = original.replace(drain+"\n", "", 1).replace(restart+"\n", "", 1)
        variants["write_abort_duplicate"] = original.replace(restart, restart+"\n"+restart, 1)
        variants["write_abort_unretired_b"] = original.replace(drain, re.sub(r" b=\d+", " b=0", drain), 1)
        variants["write_abort_restart_unretired_b"] = original.replace(restart, re.sub(r" b=\d+", " b=0", restart), 1)
        variants["write_abort_no_debt"] = original.replace(drain, re.sub(r"pending=\d+", "pending=0", drain), 1)
        variants["write_abort_short_hold"] = original.replace(drain, drain.replace("held_cycles=64", "held_cycles=0"), 1)
        variants["write_abort_reset_used"] = original.replace(restart, restart.replace("reset=0", "reset=1"), 1)
        variants["write_abort_wrong_order"] = original.replace(drain, "WRITE_ABORT_SWAP", 1).replace(restart, drain, 1).replace("WRITE_ABORT_SWAP", restart, 1)
    if require_read_abort:
        drain = next(s for s in original.splitlines() if s.startswith("C1_SOC_INFLIGHT_READ_ABORT_DRAIN_PASS"))
        restart = next(s for s in original.splitlines() if s.startswith("C1_SOC_INFLIGHT_READ_ABORT_PASS"))
        variants["read_abort_drain_missing"] = original.replace(drain+"\n", "", 1)
        variants["read_abort_restart_missing"] = original.replace(restart+"\n", "", 1)
        variants["read_abort_all_removed"] = original.replace(drain+"\n", "", 1).replace(restart+"\n", "", 1)
        variants["read_abort_duplicate"] = original.replace(drain, drain+"\n"+drain, 1)
        variants["read_abort_restart_duplicate"] = original.replace(restart, restart+"\n"+restart, 1)
        variants["read_abort_wrong_owner"] = original.replace(drain, re.sub(r"owner=\d+", "owner=0", drain), 1)
        variants["read_abort_no_debt"] = original.replace(drain, re.sub(r"pending_beats=\d+", "pending_beats=0", drain), 1)
        variants["read_abort_debt_mismatch"] = original.replace(restart, re.sub(r"pending_beats=\d+", "pending_beats=999", restart), 1)
        variants["read_abort_short_hold"] = original.replace(drain, drain.replace("held_cycles=64", "held_cycles=0"), 1)
        variants["read_abort_reset_used"] = original.replace(restart, restart.replace("reset=0", "reset=1"), 1)
        variants["read_abort_wrong_order"] = original.replace(drain, "READ_ABORT_SWAP", 1).replace(restart, drain, 1).replace("READ_ABORT_SWAP", restart, 1)
        option = next((s for s in original.splitlines() if s.startswith("C1_NUM_COLUMN_OPTION")), None)
        if option:
            variants["read_abort_option_duplicate"] = original.replace(option, option+"\n"+option, 1)
            variants["read_abort_wrong_client_count"] = original.replace(option, re.sub(r"clients=\d+", "clients=0", option), 1)
    if require_scalar_read_abort:
        target = "C1_NUM_READ_ABORT_TARGET scalar"
        cache_drain = "C1_SOC_SCALAR_READ_ABORT_CACHE_PASS before=1 after=0 valid=0 pending=0"
        cache_option = "C1_NUM_SCALAR_READ_CACHE enabled=1"
        for name, line in (("target", target), ("drain", cache_drain), ("option", cache_option)):
            variants["scalar_abort_missing_"+name] = original.replace(line+"\n", "", 1)
            variants["scalar_abort_duplicate_"+name] = original.replace(line, line+"\n"+line, 1)
        for key, value in (("before", "0"), ("after", "1"), ("valid", "1"), ("pending", "1")):
            variants["scalar_abort_wrong_"+key] = original.replace(cache_drain, re.sub(key+r"=\d+", key+"="+value, cache_drain), 1)
        variants["scalar_abort_disabled_cache"] = original.replace(cache_option, "C1_NUM_SCALAR_READ_CACHE enabled=0", 1)
        variants["scalar_abort_wrong_target"] = original.replace(target, "C1_NUM_READ_ABORT_TARGET column", 1)
        variants["scalar_abort_wrong_count"] = re.sub(r"pending_beats=1\b", "pending_beats=2", original)
        variants["scalar_abort_late_proof"] = original.replace(cache_drain, "CACHE_DRAIN_SWAP", 1).replace(restart, cache_drain, 1).replace("CACHE_DRAIN_SWAP", restart, 1)
        variants["scalar_abort_all_removed"] = "\n".join(s for s in original.splitlines() if not s.startswith(("C1_NUM_READ_ABORT_TARGET", "C1_SOC_SCALAR_READ_ABORT_", "C1_SOC_INFLIGHT_READ_ABORT_")))
    if require_preview:
        preview_rows = [line for line in original.splitlines() if line.startswith("C1_NUM_PREVIEW_DDR ")]
        first, second = preview_rows[:2]
        marker = next(line for line in original.splitlines() if line.startswith("C1_NUM_PREVIEW_CAPTURE_PASS"))
        admission = next(line for line in original.splitlines() if line.startswith("C1_NUM_PREVIEW_ADMIT"))
        variants["preview_wrong_value"] = original.replace(first,first[:-1]+("1" if first[-1]!="1" else "0"),1)
        variants["preview_unknown"] = original.replace(first,first[:-1]+"x",1)
        variants["preview_missing_pixel"] = original.replace(first+"\n","",1)
        variants["preview_duplicate_pixel"] = original.replace(first,first+"\n"+first,1)
        variants["preview_wrong_coordinate"] = original.replace(first,first.replace(" 0 0 "," 8 0 "),1)
        variants["preview_reordered_pixels"] = original.replace(first+"\n"+second,second+"\n"+first,1)
        variants["preview_all_removed"] = "\n".join(line for line in original.splitlines() if not line.startswith("C1_NUM_PREVIEW_"))
        variants["preview_marker_missing"] = original.replace(marker+"\n","",1)
        variants["preview_marker_duplicate"] = original.replace(marker,marker+"\n"+marker,1)
        variants["preview_unretired_B"] = original.replace(marker,marker.replace(" b=8 "," b=7 "),1)
        variants["preview_wrong_client_count"] = original.replace(marker,marker.replace("clients=8","clients=7"),1)
        completed = int(re.search(r"paired_base=(\w+)",marker).group(1),16)
        variants["preview_pending_slot_as_completed"] = original.replace(marker,re.sub(r"paired_base=\w+",f"paired_base={completed ^ 0x100:08x}",marker),1)
        variants["preview_admit_missing"] = "\n".join(line for line in original.splitlines() if not line.startswith("C1_NUM_PREVIEW_ADMIT"))
        variants["preview_admit_duplicate"] = original.replace(admission,admission+"\n"+admission,1)
        variants["preview_wrong_slot_binding"] = original.replace(admission,admission[:-1]+("1" if admission[-1]=="0" else "0"),1)
        value = int(first.split()[-1],16)
        swapped = (value & 0xff00) | ((value & 255)<<16) | ((value>>16)&255)
        if swapped == value:
            raise AssertionError("preview fixture does not distinguish R/B")
        variants["preview_red_blue_swap"] = original.replace(first," ".join(first.split()[:-1]+[f"{swapped:08x}"]),1)
        styled_as_preview = [line.replace("C1_NUM_DDR ","C1_NUM_PREVIEW_DDR ",1)
                             for line in original.splitlines() if line.startswith("C1_NUM_DDR ")]
        if styled_as_preview == preview_rows:
            raise AssertionError("fixture does not distinguish preview from CNN output")
        changed = original
        for before, after in zip(preview_rows,styled_as_preview):
            changed=changed.replace(before,after,1)
        variants["preview_replaced_by_styled"] = changed
    if require_distinct_recovery:
        tone="C1_NUM_SOURCE_TONE 32"
        variants["distinct_tone_missing"]=original.replace(tone+"\n","",1)
        variants["distinct_tone_duplicate"]=original.replace(tone,tone+"\n"+tone,1)
        variants["distinct_tone_invalid"]=original.replace(tone,"C1_NUM_SOURCE_TONE 31",1)
        source=next(line for line in original.splitlines() if line.startswith("C1_NUM_IN "))
        word=int(source.split()[-1],16)
        stale_word=0
        for channel in range(3):
            value=((word>>(8*channel))&255)^128
            if value<8:
                raise AssertionError("distinct fixture underflow")
            stale_word|=((value-8)^128)<<(8*channel)
        variants["distinct_stale_cnn_input"]=original.replace(source," ".join(source.split()[:-1]+[f"{stale_word:016x}"]),1)
        for prefix,name in (("C1_NUM_PREVIEW_DDR ","distinct_stale_preview_ddr"),("C1_NUM_VIDEO_RAW ","distinct_stale_display")):
            pixel=next(line for line in original.splitlines() if line.startswith(prefix))
            value=int(pixel.split()[-1],16)
            if any(((value>>shift)&255)<8 for shift in (0,8,16)):
                raise AssertionError("distinct RGB fixture underflow")
            variants[name]=original.replace(pixel," ".join(pixel.split()[:-1]+[f"{value-0x080808:08x}"]),1)
    if require_preview_display:
        header="C1_NUM_FIRST_DISPLAY preview"
        variants["preview_display_header_missing"]=original.replace(header+"\n","",1)
        variants["preview_display_header_duplicate"]=original.replace(header,header+"\n"+header,1)
        variants["preview_display_header_unknown"]=original.replace(header,"C1_NUM_FIRST_DISPLAY invalid",1)
        raw_video=next(line for line in original.splitlines() if line.startswith("C1_NUM_VIDEO_RAW "))
        x,y=map(int,raw_video.split()[1:3])
        offsets=(96,40,0) if "C1_NUM_FIXTURE color_rggb" in original else (0,0,0)
        raw_channels=[(64+17*(x+1)+29*(y+1)+offset+(32 if require_distinct_recovery else 0))>>2 for offset in offsets]
        raw_word=(raw_channels[0]<<16)|(raw_channels[1]<<8)|raw_channels[2]
        if raw_word==int(raw_video.split()[-1],16):
            raise AssertionError("fixture must distinguish raw from preview display")
        variants["preview_display_raw_instead"]=original.replace(raw_video," ".join(raw_video.split()[:-1]+[f"{raw_word:08x}"]),1)
    if require_preview_cancel_recovery:
        recovery = next(line for line in original.splitlines() if line.startswith("C1_SOC_PREVIEW_CANCEL_RECOVERY_PASS"))
        cancel = next(line for line in original.splitlines() if line.startswith("C1_SOC_PREVIEW_CANCEL_PASS"))
        variants["cancel_recovery_missing"]=original.replace(recovery+"\n","",1)
        variants["cancel_recovery_duplicate"]=original.replace(recovery,recovery+"\n"+recovery,1)
        variants["cancel_recovery_reset"]=original.replace(recovery,recovery.replace("reset=0","reset=1"),1)
        variants["cancel_recovery_error"]=original.replace(recovery,recovery.replace("errors=0","errors=1"),1)
        variants["cancel_recovery_missing_drain"]=original.replace(cancel+"\n","",1)
        variants["cancel_recovery_early_start"]=original.replace(cancel,cancel.replace("start_rejected=1","start_rejected=0"),1)
        variants["cancel_recovery_no_hold"]=original.replace(cancel,cancel.replace("held_cycles=64","held_cycles=0"),1)
        variants["cancel_recovery_wrong_order"]=original.replace(cancel+"\n","",1)+"\n"+cancel
    if require_preview_recovery:
        recovery = next(line for line in original.splitlines() if line.startswith("C1_SOC_PREVIEW_BRESP_RECOVERY_PASS"))
        fault = next(line for line in original.splitlines() if line.startswith("C1_SOC_PREVIEW_BRESP_ERROR_PASS"))
        variants["preview_recovery_missing"]=original.replace(recovery+"\n","",1)
        variants["preview_recovery_duplicate"]=original.replace(recovery,recovery+"\n"+recovery,1)
        variants["preview_recovery_used_reset"]=original.replace(recovery,recovery.replace("reset=0","reset=1"),1)
        variants["preview_recovery_no_capture"]=original.replace(recovery,recovery.replace("captures=2","captures=1"),1)
        variants["preview_recovery_fault_missing"]=original.replace(fault+"\n","",1)
        variants["preview_recovery_no_hold"]=original.replace(fault,re.sub(r"hold=\d+","hold=0",fault),1)
        variants["preview_recovery_early_publication"]=original.replace(fault,fault.replace("swaps=0","swaps=1"),1)
        variants["preview_recovery_fault_after_success"]=original.replace(fault+"\n","",1)+"\n"+fault
    if "C1_NUM_FIXTURE color_rggb" in original:
        source_record = next(line for line in original.splitlines() if line.startswith("C1_NUM_IN "))
        source_word = int(source_record.split()[-1], 16)
        swapped = (source_word & ~0xff00ff) | ((source_word & 255) << 16) | ((source_word >> 16) & 255)
        if swapped == source_word:
            raise AssertionError("color fixture does not distinguish R/B")
        swapped_record = " ".join(source_record.split()[:-1] + [f"{swapped:016x}"])
        variants["source_red_blue_swap"] = original.replace(source_record, swapped_record, 1)
        variants["wrong_fixture"] = original.replace("C1_NUM_FIXTURE color_rggb", "C1_NUM_FIXTURE gray", 1)
        variants["unknown_fixture"] = original.replace("C1_NUM_FIXTURE color_rggb", "C1_NUM_FIXTURE invalid", 1)
        variants["duplicate_fixture"] = original.replace("C1_NUM_FIXTURE color_rggb",
            "C1_NUM_FIXTURE color_rggb\nC1_NUM_FIXTURE color_rggb", 1)
    if require_video:
        if "C1_NUM_SOURCE 12x10" in original:
            header = "C1_NUM_SOURCE 12x10"
            variants["source_geometry_missing"] = original.replace(header+"\n", "", 1)
            variants["source_geometry_unknown"] = original.replace(header,"C1_NUM_SOURCE 8x8",1)
            variants["source_geometry_duplicate"] = original.replace(header,header+"\n"+header,1)
            raw_tail = [line for line in original.splitlines() if line.startswith("C1_NUM_VIDEO_RAW ")][-1]
            variants["raw_source_tail_missing"] = original.replace(raw_tail+"\n","",1)
        if "C1_NUM_RESIZE reverse_fractional" in original:
            header = "C1_NUM_RESIZE reverse_fractional"
            variants["resize_missing"] = original.replace(header+"\n", "", 1)
            variants["resize_unknown"] = original.replace(header, "C1_NUM_RESIZE invalid", 1)
            variants["resize_duplicate"] = original.replace(header, header+"\n"+header, 1)
            # Raw scanout must remain the pre-resize source, not CNN input.
            in_line = next(line for line in original.splitlines() if line.startswith("C1_NUM_IN "))
            raw_line = next(line for line in original.splitlines() if line.startswith("C1_NUM_VIDEO_RAW "))
            v = int(in_line.split()[-1],16) ^ 0x808080
            raw_from_resized = ((v & 255)<<16) | (v & 0xff00) | ((v>>16)&255)
            if raw_from_resized == int(raw_line.split()[-1],16):
                raise AssertionError("fixture must distinguish original and resized images")
            variants["raw_replaced_by_resized"] = original.replace(raw_line,
                " ".join(raw_line.split()[:-1]+[f"{raw_from_resized:08x}"]),1)
        video_record = next(line for line in original.splitlines() if line.startswith("C1_NUM_VIDEO_STYLED "))
        variants["video_wrong_value"] = original.replace(video_record, video_record[:-1] +
                                             ("1" if video_record[-1] != "1" else "0"), 1)
        variants["video_missing"] = original.replace(video_record+"\n", "", 1)
        variants["video_all_removed"] = "\n".join(line for line in original.splitlines()
                                                  if not line.startswith("C1_NUM_VIDEO_"))
    expected_bfm_extra = None
    delay_line = next((s for s in original.splitlines() if s.startswith("C1_NUM_BFM_DELAY")), None)
    if delay_line:
        latency_line = next(s for s in original.splitlines() if s.startswith("C1_PERF_BFM_LATENCY"))
        expected_bfm_extra = tuple(map(int, re.findall(r"=(\d+)", delay_line)))
        variants["bfm_delay_missing"] = original.replace(delay_line+"\n", "", 1)
        variants["bfm_delay_duplicate"] = original.replace(delay_line, delay_line+"\n"+delay_line, 1)
        variants["bfm_delay_invalid"] = original.replace(delay_line, re.sub(r"write_extra=\d+", "write_extra=256", delay_line), 1)
        variants["bfm_delay_wrong_profile"] = original.replace(delay_line, re.sub(r"write_extra=\d+", f"write_extra={(expected_bfm_extra[2]+1)%256}", delay_line), 1)
        variants["bfm_latency_missing"] = original.replace(latency_line+"\n", "", 1)
        variants["bfm_latency_duplicate"] = original.replace(latency_line, latency_line+"\n"+latency_line, 1)
        variants["bfm_all_removed"] = original.replace(latency_line+"\n", "", 1).replace(delay_line+"\n", "", 1)
        for key in ("first_events", "beat_events", "first_min", "beat_min", "first_max", "beat_max"):
            variants["bfm_invalid_"+key] = original.replace(latency_line, re.sub(key+r"=\d+", key+"=0", latency_line), 1)
    if require_queued_write:
        q = next(line for line in original.splitlines() if line.startswith("C1_SOC_QUEUED_WRITE_NUMERIC_PASS"))
        variants["queued_missing"] = original.replace(q+"\n", "", 1)
        variants["queued_duplicate"] = original.replace(q,q+"\n"+q,1)
        variants["queued_wrong_retirement"] = original.replace(q,re.sub(r" b=\d+", " b=0",q),1)
        variants["queued_over_capacity"] = original.replace(q,re.sub(r"max_outstanding=\d+", "max_outstanding=5",q),1)
    if require_concurrent_capture:
        c = next(line for line in original.splitlines() if line.startswith("C1_SOC_CONCURRENT_CAPTURE_PASS"))
        variants["concurrent_missing"] = original.replace(c+"\n", "", 1)
        variants["concurrent_duplicate"] = original.replace(c,c+"\n"+c,1)
        variants["concurrent_one_capture"] = original.replace(c,re.sub(r"captures=\d+", "captures=1",c),1)
        variants["concurrent_no_overlap"] = original.replace(c,re.sub(r"capture_aw_during_compute=\d+", "capture_aw_during_compute=0",c),1)
        variants["concurrent_peak_mismatch"] = original.replace(c,re.sub(r"peak=\d+", "peak=1",c),1)
    mode = next((line for line in original.splitlines() if line.startswith("C1_NUM_WRITE_MODE")), None)
    if mode:
        variants["write_mode_duplicate"] = original.replace(mode,mode+"\n"+mode,1)
        variants["write_mode_invalid"] = original.replace(mode,"C1_NUM_WRITE_MODE unknown",1)
        if require_concurrent_capture:
            opposite = "ahead" if mode.endswith("serial") else "serial"
            variants["write_mode_counter_mismatch"] = original.replace(mode,"C1_NUM_WRITE_MODE "+opposite,1)
        if mode.endswith("serial"):
            variants["serial_mode_missing"] = original.replace(mode+"\n","",1)
            if require_queued_write:
                variants["serial_claims_w_ahead"] = re.sub(r"w_ahead_beats=\d+","w_ahead_beats=1",original)
    if require_compact_refill:
        cap = next(line for line in original.splitlines() if line.startswith("C1_NUM_REFILL_CAPACITY"))
        variants["capacity_missing"] = original.replace(cap+"\n","",1)
        variants["capacity_duplicate"] = original.replace(cap,cap+"\n"+cap,1)
        variants["capacity_peak_overflow"] = original.replace(cap,re.sub(r"req_peak=\d+","req_peak=17",cap),1)
        variants["capacity_wrong_depth"] = original.replace(cap,cap.replace("req_depth=16","req_depth=32"),1)
        variants["capacity_unexercised"] = original.replace(cap,re.sub(r"meta_peak=\d+","meta_peak=0",cap),1)
    window_line=next((line for line in original.splitlines() if line.startswith("C1_NUM_REFILL_WINDOW")),None)
    if window_line:
        if not require_compact_refill:
            cap=next(line for line in original.splitlines() if line.startswith("C1_NUM_REFILL_CAPACITY"))
            variants["window_capacity_missing"]=original.replace(cap+"\n","",1)
            variants["window_capacity_duplicate"]=original.replace(cap,cap+"\n"+cap,1)
            variants["window_peak_overflow"]=original.replace(cap,re.sub(r"meta_peak=\d+","meta_peak=256",cap),1)
        variants["window_duplicate"]=original.replace(window_line,window_line+"\n"+window_line,1)
        variants["window_zero"]=original.replace(window_line,"C1_NUM_REFILL_WINDOW 0",1)
        variants["window_over_capacity"]=original.replace(window_line,"C1_NUM_REFILL_WINDOW 256",1)
        peak=re.search(r"C1_NUM_REFILL_CAPACITY .* meta_peak=(\d+)",original)
        if peak and int(peak.group(1))>16:
            variants["wide_window_missing"]=original.replace(window_line+"\n","",1)
            variants["wide_window_counter_mismatch"]=original.replace(window_line,"C1_NUM_REFILL_WINDOW 16",1)
    variants.update(overlap_mutations(original))
    variants.update(pointwise_mutations(original))
    variants.update(response_bypass_mutations(original))
    variants.update(row_map_mutations(original))
    variants.update(final_fusion_mutations(original))
    variants.update(pixel_prefetch_mutations(original))
    variants.update(source_write_mutations(original))
    variants.update(pointwise_reduction_mutations(original))
    variants.update(requant_overlap_mutations(original))
    variants.update(tensor_mlp_mutations(original))
    variants.update(dot_pixel_mutations(original))
    variants.update(rgb_reduction_mutations(original))
    variants.update(view_elision_mutations(original))
    variants.update(pixel_batch_mutations(original))
    variants.update(dw_pixel_mutations(original))
    if column_refill is not None:
        variants.update(column_refill_mutations(original))
    if scalar_assoc is not None:
        variants.update(scalar_assoc_mutations(original))
    if "C1_NUM_DW_FRAME_STREAM " in original:
        variants.update(dw_frame_mutations(original))
    for name, changed in variants.items():
        def read(path, *args, **kwargs):
            return changed if path == run / "xsim.stdout.log" else original_read(path, *args, **kwargs)
        with patch.object(Path, "read_text", read), contextlib.redirect_stdout(io.StringIO()):
            try:
                check_column_response_bypass(changed,1,require_response_bypass)
                check_column_row_map(changed,1,require_row_map,require_mode=row_map_present)
                check_final_fusion(changed,frame_w,frame_h,1,require_fusion,require_mode="C1_NUM_FINAL_FUSION " in original)
                check_pixel_column_prefetch(changed,frame_w,frame_h,1,require_pixel_prefetch,require_pixel_abort)
                all_pixel_groups_enabled(changed,require_all_groups)
                check_source_writes(changed,frame_w,frame_h,1,require_source_pipeline,require_source_abort)
                check_pointwise_reduction(changed,frame_w,frame_h,1,require_pw_reduction,require_pw_partial)
                check_requant_overlap(changed,frame_w,frame_h,1,require_rq_overlap)
                check_tensor_write_mlp(changed,1,write_slots,require_mlp_abort)
                check_dw_pixel_pipeline(changed,frame_w,frame_h,1,dw_pixels,dw_pixel_abort)
                check_pixel_write_batch(changed,frame_w,frame_h,1,batch_selection)
                check_stage0_profile(changed,require_stage0_profile)
                check_stage_fsm(changed,require_stage_fsm)
                check_column_stage(changed,frame_w,frame_h,column_stage)
                check_column_refill(changed,frame_w,frame_h,1,column_refill)
                check_scalar_assoc(changed,frame_w,frame_h,1,scalar_assoc)
                check_scalar_assoc_abort(changed,scalar_assoc_abort)
                check_dw_frame(changed,frame_w,frame_h,1,require_dw_frame,
                               require_mode="C1_NUM_DW_FRAME_STREAM " in original)
                all_dot_groups_enabled(changed,require_all_dot_groups)
                check_view_elision(changed,frame_w,frame_h,1,require_views,require_mode="C1_NUM_VIEW_ELISION" in original)
                check_rgb_reduction(changed,frame_w,frame_h,1,require_rgb,
                                    require_mode="C1_NUM_RGB_REDUCTION" in original)
                check_all_dot_abort(changed,require_all_dot_abort)
                check_dot_pixel_pipeline(changed,frame_w,frame_h,1,require_pixel_pipeline,require_dot_pixel_abort)
                check(run, artifact, require_pointwise_columns=require_pointwise_columns, require_column_write_overlap=require_column_write_overlap, require_dw_stream=require_dw_stream,require_virtual_upsample_abort=require_virtual_upsample_abort,require_virtual_upsample=require_virtual_upsample,require_precise_write_invalidation=require_precise_write_invalidation,require_stage_perf=require_stage_perf,expected_frame=expected_frame,require_scalar_read_abort=require_scalar_read_abort,expected_bfm_extra=expected_bfm_extra,require_write_abort=require_write_abort,require_read_abort=require_read_abort,require_video=require_video,require_queued_write=require_queued_write,
                      require_concurrent_capture=require_concurrent_capture, require_compact_refill=require_compact_refill,
                      require_preview=require_preview, require_preview_recovery=require_preview_recovery,
                      require_preview_cancel_recovery=require_preview_cancel_recovery,
                      require_preview_display=require_preview_display, require_distinct_recovery=require_distinct_recovery)
            except ValueError:
                pass
            else:
                raise AssertionError(f"invalid trace accepted: {name}")
        print(f"C1_NUMERICAL_CHECKER_REJECTION_PASS case={name}")
    if shape_line:
        for name, changed_status in (
                ("status_wrong_frame", dict(status, frame="8x8" if expected_frame=="16x8" else "16x8")),
                ("status_invalid_frame", dict(status, frame="7x8")),
                ("status_invalid_schema", dict(status, numerical_trace_schema=9))):
            def read_status(path, *args, **kwargs):
                return json.dumps(changed_status) if path == run / "status.json" else original_read(path, *args, **kwargs)
            with patch.object(Path, "read_text", read_status), contextlib.redirect_stdout(io.StringIO()):
                try:
                    check(run, artifact, expected_frame=expected_frame, require_video=require_video)
                except ValueError:
                    pass
                else:
                    raise AssertionError(f"invalid status accepted: {name}")
            print(f"C1_NUMERICAL_CHECKER_REJECTION_PASS case={name}")


if __name__ == "__main__":
    main()
