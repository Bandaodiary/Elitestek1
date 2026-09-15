"""Audit DW next-pixel preparation and multi-group real-write retirement."""
import re
from microstyle_workload import workload
from check_dot_pixel_pipeline_trace import check_raster_write_abort
from check_dw_frame_trace import check_dw_frame

MODE="C1_NUM_DW_PIXEL_PIPELINE"
PROGRESS="C1_PERF_DW_PIXEL_PIPELINE"
ABORT="C1_NUM_DW_PIXEL_ABORT"


def dw_pixel_budget(width: int,height: int,batch: int) -> tuple[int,int,int,int]:
    if batch not in (1,2,4,8):raise ValueError("DW pixel unsupported word batch")
    stages=[s for s in workload(width,height)["stages"] if s["opcode"]==3]
    return (sum(s["C8_results"] for s in stages),
            sum(((s["output_width"]*s["input_groups"]+batch-1)//batch)*s["output_height"] for s in stages),
            sum(s["output_width"]*s["output_height"]-1 for s in stages),
            sum(max(0,s["output_width"]*s["output_height"]-2) for s in stages))


def check_dw_pixel_abort(log: str,required: bool=False) -> bool:
    return check_raster_write_abort(log,MODE,ABORT,18,required)


def check_dw_pixel_pipeline(log: str,width: int,height: int,jobs: int,
                            required: bool=False,require_abort: bool=False) -> bool:
    check_dw_frame(log,width,height,jobs)
    check_dw_pixel_abort(log,require_abort)
    lines=log.splitlines()
    modes=[s for s in lines if s.startswith(MODE)]
    records=[s for s in lines if s.startswith(PROGRESS)]
    if not modes and not records and not required:return False
    if modes not in ([MODE+" enabled=0"],[MODE+" enabled=1"]):
        raise ValueError("DW pixel mode missing/duplicate/invalid")
    enabled=modes==[MODE+" enabled=1"]
    if required and not enabled:raise ValueError("DW pixel pipeline was required")
    if enabled:
        for prefix in ("C1_NUM_DW_STREAM","C1_NUM_COLUMN_WRITE_OVERLAP"):
            if [s for s in lines if s.startswith(prefix)]!=[prefix+" enabled=1"]:
                raise ValueError("DW pixel prerequisite absent")
        options=[s for s in lines if s.startswith("C1_NUM_ENGINE_OPTIONS")]
        if len(options)!=1 or not re.fullmatch(r"C1_NUM_ENGINE_OPTIONS dw_cache=1 mac_overlap=[01]",options[0]):
            raise ValueError("DW pixel requires actual cached weight tiles")
    selections=[s for s in lines if s.startswith("C1_NUM_PIXEL_WRITE_BATCH")]
    batch=re.fullmatch(r"C1_NUM_PIXEL_WRITE_BATCH words=(1|2|4|8) build_timeout=(\d+)",selections[0]) if len(selections)==1 else None
    if batch is None or not 1<=int(batch[2])<=255:raise ValueError("DW pixel requires actual batch/finite timeout selection")
    count,ends,warm,max_ahead=dw_pixel_budget(width,height,int(batch[1])) if enabled else (0,0,0,0)
    ids=[]
    for line in lines:
        if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",line):
            row=re.search(r"\bjob=(\d+)\b",line)
            if row is None:raise ValueError("DW pixel job missing id")
            ids.append(int(row[1]))
    if len(ids)!=jobs or len(set(ids))!=jobs or any(i<=0 for i in ids) or len(records)!=jobs:
        raise ValueError("DW pixel lacks unique ordered successful jobs")
    for job,line in zip(ids,records):
        row=re.fullmatch(PROGRESS+r" job=(\d+) inputs=(\d+) feeds=(\d+) outputs=(\d+) writes=(\d+) responses=(\d+) ends=(\d+) warm=(\d+) ahead=(\d+) peak=(\d+)",line)
        if row is None:raise ValueError("DW pixel progress malformed")
        ident,inputs,feeds,outputs,writes,responses,end_count,warm_count,ahead,peak=map(int,row.groups())
        if ident!=job or (inputs,feeds,outputs,writes,responses)!=(count,)*5 or (end_count,warm_count)!=(ends,warm):
            raise ValueError("DW pixel lost/reordered input, arithmetic, raster groups or real write responses")
        if not 0<=ahead<=max_ahead or not ((1<=peak<=15) if enabled else peak==0):
            raise ValueError("DW pixel preparation/credit budget exceeded")
    return enabled


def dw_pixel_mutations(log: str) -> dict[str,str]:
    mode=MODE+" enabled=1"
    if mode not in log.splitlines():return {}
    cases={};targets=[mode]+[s for s in log.splitlines() if s.startswith((PROGRESS,ABORT))]
    for i,target in enumerate(targets):
        cases[f"dw_pixel_missing_{i}"]=log.replace(target+"\n","",1)
        cases[f"dw_pixel_duplicate_{i}"]=log.replace(target,target+"\n"+target,1)
    cases["dw_pixel_all_removed"]="\n".join(s for s in log.splitlines() if not s.startswith((MODE,PROGRESS,ABORT)))+"\n"
    for value in (0,2):cases[f"dw_pixel_mode_{value}"]=log.replace(mode,MODE+f" enabled={value}",1)
    for i,target in enumerate(s for s in log.splitlines() if s.startswith(PROGRESS)):
        for field in ("job","inputs","feeds","outputs","writes","responses","ends","warm"):
            changed=re.sub(rf"\b{field}=(\d+)",lambda m:f"{field}={int(m[1])+1}",target)
            cases[f"dw_pixel_{i}_{field}"]=log.replace(target,changed,1)
        for field in ("ahead","peak"):
            cases[f"dw_pixel_{i}_{field}_overflow"]=log.replace(target,re.sub(rf"\b{field}=\d+",field+"=99999999",target),1)
    for target in (s for s in log.splitlines() if s.startswith(ABORT)):
        cases["dw_pixel_abort_wrong_stage"]=log.replace(target,target.replace("stage=18","stage=20"),1)
        cases["dw_pixel_abort_one_debt"]=log.replace(target,re.sub(r"pending=\d+","pending=1",target),1)
        cases["dw_pixel_abort_late"]=log.replace(target+"\n","",1)+target+"\n"
    return cases
