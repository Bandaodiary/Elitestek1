"""Audit pixel-compute/result-write decoupling against the descriptor graph."""
import re
from microstyle_workload import workload
from check_final_fusion_trace import final_fusion_mode

MODE="C1_NUM_DOT_PIXEL_PIPELINE"
PROGRESS="C1_PERF_DOT_PIXEL_PIPELINE"
ABORT="C1_NUM_DOT_PIXEL_ABORT"
ALL_GROUPS="C1_NUM_ALL_DOT_GROUPS"
ALL_ABORT="C1_NUM_ALL_DOT_PIXEL_ABORT"


def all_dot_groups_enabled(log: str, required: bool=False) -> bool:
    check_all_dot_abort(log)
    lines=log.splitlines()
    records=[s for s in lines if s.startswith(ALL_GROUPS)]
    if not records and not required:return False
    if records not in ([ALL_GROUPS+" enabled=0"],[ALL_GROUPS+" enabled=1"]):
        raise ValueError("all dot groups mode missing/duplicate/invalid")
    enabled=records==[ALL_GROUPS+" enabled=1"]
    if required and not enabled:raise ValueError("all dot groups was required")
    if enabled and [s for s in lines if s.startswith(MODE)]!=[MODE+" enabled=1"]:
        raise ValueError("all dot groups lacks actual dot pixel pipeline")
    return enabled


def check_raster_write_abort(log: str, mode_prefix: str, abort_prefix: str,
                             stage: int, required: bool=False) -> bool:
    lines=log.splitlines()
    records=[s for s in lines if s.startswith(abort_prefix)]
    if not records and not required:return False
    row=re.fullmatch(abort_prefix+rf" stage={stage} pending=(\d+)",records[0]) if len(records)==1 else None
    if row is None or not 2<=int(row[1])<=15:
        raise ValueError("pixel abort lacks unique selected-stage sink write debt")
    if [s for s in lines if s.startswith(mode_prefix)]!=[mode_prefix+" enabled=1"]:
        raise ValueError("pixel abort requires actual pixel pipeline mode")
    drains=[s for s in lines if s.startswith("C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS")]
    restarts=[s for s in lines if s.startswith("C1_SOC_INFLIGHT_WRITE_ABORT_PASS")]
    drain=re.fullmatch(r"C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS pending=(\d+) held_cycles=64 aw=(\d+) b=(\d+) no_restart=1",drains[0]) if len(drains)==1 else None
    restart=re.fullmatch(r"C1_SOC_INFLIGHT_WRITE_ABORT_PASS pending=(\d+) held_cycles=64 captures=3 done=1 aw=(\d+) b=(\d+) reset=0",restarts[0]) if len(restarts)==1 else None
    if (drain is None or restart is None or int(drain[1])<2 or
        drain[1]!=restart[1] or drain[2]!=drain[3] or restart[2]!=restart[3] or
        int(drain[2])<int(drain[1]) or int(restart[2])<=int(drain[2]) or
        not log.index(records[0])<log.index(drains[0])<log.index(restarts[0])):
        raise ValueError("pixel abort missing ordered real B drain and no-reset recovery")
    return True


def check_dot_pixel_abort(log: str, required: bool=False) -> bool:
    return check_raster_write_abort(log,MODE,ABORT,20,required)


def check_all_dot_abort(log: str, required: bool=False) -> bool:
    return check_raster_write_abort(log,ALL_GROUPS,ALL_ABORT,0,required)


def check_dot_pixel_pipeline(log: str, width: int, height: int, jobs: int,
                             required: bool=False, require_abort: bool=False) -> dict[int,int]:
    check_dot_pixel_abort(log,require_abort)
    lines=log.splitlines()
    modes=[s for s in lines if s.startswith(MODE)]
    records=[s for s in lines if s.startswith(PROGRESS)]
    if not modes and not records and not required:return {}
    if modes not in ([MODE+" enabled=0"],[MODE+" enabled=1"]):
        raise ValueError("pixel pipeline mode missing/duplicate/invalid")
    enabled=modes==[MODE+" enabled=1"]
    if required and not enabled:raise ValueError("dot pixel pipeline was required")
    pw=[s for s in lines if s.startswith("C1_NUM_POINTWISE_COLUMN_READS")]
    if pw not in (["C1_NUM_POINTWISE_COLUMN_READS enabled=0"],["C1_NUM_POINTWISE_COLUMN_READS enabled=1"]):
        raise ValueError("pixel pipeline needs actual pointwise column mode")
    if enabled:
        for prefix in ("C1_NUM_MAC_REQUANT_OVERLAP","C1_NUM_COLUMN_WRITE_OVERLAP"):
            if [s for s in lines if s.startswith(prefix)]!=[prefix+" enabled=1"]:
                raise ValueError("pixel pipeline prerequisite mode absent")
    all_groups=all_dot_groups_enabled(log)
    fused=final_fusion_mode(log)
    selected=[s for s in workload(width,height)["stages"]
              if not(fused and s["stage"]==20) and
              (s["opcode"]==1 or (s["opcode"]==2 and pw[0].endswith("=1"))) and
              (all_groups or s["C8_results"]==s["next_pixel_columns"]+1)]
    count=sum(s["C8_results"] for s in selected) if enabled else 0
    possible_ahead=sum(s["next_pixel_columns"] for s in selected) if enabled else 0
    ids=[]
    for line in lines:
        if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",line):
            row=re.search(r"\bjob=(\d+)\b",line)
            if row is None:raise ValueError("pixel pipeline successful job lacks id")
            ids.append(int(row[1]))
    if len(ids)!=jobs or len(set(ids))!=jobs or any(i<=0 for i in ids) or len(records)!=jobs:
        raise ValueError("pixel pipeline lacks ordered unique successful jobs")
    early={}
    for job,line in zip(ids,records):
        row=re.fullmatch(PROGRESS+r" job=(\d+) starts=(\d+) outputs=(\d+) inputs_ahead=(\d+) starts_ahead=(\d+) writes=(\d+) responses=(\d+) peak=(\d+)",line)
        if row is None:raise ValueError("pixel pipeline progress malformed")
        ident,starts,outputs,inputs_ahead,starts_ahead,writes,responses,peak=map(int,row.groups())
        if ident!=job or (starts,outputs,writes,responses)!=(count,)*4:
            raise ValueError("pixel pipeline lost/reordered compute or real write completion")
        if not 0<=starts_ahead<=inputs_ahead<=possible_ahead:
            raise ValueError("pixel pipeline ahead count exceeds admitted predecessor budget")
        if not ((1<=peak<=15) if enabled and count else peak==0):
            raise ValueError("pixel pipeline exceeded bounded write reservations")
        if enabled:early[job]=starts_ahead
    return early


def dot_pixel_mutations(log: str) -> dict[str,str]:
    mode=MODE+" enabled=1"
    if mode not in log.splitlines():return {}
    cases={}
    all_mode=ALL_GROUPS+" enabled=1"
    if all_mode in log.splitlines():
        cases["all_dot_missing"]=log.replace(all_mode+"\n","",1)
        cases["all_dot_duplicate"]=log.replace(all_mode,all_mode+"\n"+all_mode,1)
        for value in (0,2):cases[f"all_dot_mode_{value}"]=log.replace(all_mode,ALL_GROUPS+f" enabled={value}",1)
    for target in (s for s in log.splitlines() if s.startswith(ALL_ABORT)):
        cases["all_dot_abort_missing"]=log.replace(target+"\n","",1)
        cases["all_dot_abort_duplicate"]=log.replace(target,target+"\n"+target,1)
        cases["all_dot_abort_wrong_stage"]=log.replace(target,target.replace("stage=0","stage=20"),1)
        cases["all_dot_abort_one_debt"]=log.replace(target,re.sub(r"pending=\d+","pending=1",target),1)
        cases["all_dot_abort_late"]=log.replace(target+"\n","",1)+target+"\n"
    targets=[mode]+[s for s in log.splitlines() if s.startswith(PROGRESS)]
    for i,target in enumerate(targets):
        cases[f"pixel_pipeline_missing_{i}"]=log.replace(target+"\n","",1)
        cases[f"pixel_pipeline_duplicate_{i}"]=log.replace(target,target+"\n"+target,1)
    cases["pixel_pipeline_all_removed"]="\n".join(s for s in log.splitlines() if not s.startswith((MODE,PROGRESS)))+"\n"
    for value in (0,2):cases[f"pixel_pipeline_mode_{value}"]=log.replace(mode,MODE+f" enabled={value}",1)
    for i,target in enumerate(targets[1:]):
        for field in ("job","starts","outputs","writes","responses","peak"):
            cases[f"pixel_pipeline_{i}_{field}"]=log.replace(target,re.sub(rf"\b{field}=\d+",field+"=0",target),1)
        for field in ("inputs_ahead","starts_ahead","peak"):
            cases[f"pixel_pipeline_{i}_{field}_overflow"]=log.replace(target,re.sub(rf"\b{field}=\d+",field+"=99999999",target),1)
    aborts=[s for s in log.splitlines() if s.startswith(ABORT)]
    if len(aborts)==1:
        target=aborts[0]
        cases["pixel_abort_missing"]=log.replace(target+"\n","",1)
        cases["pixel_abort_duplicate"]=log.replace(target,target+"\n"+target,1)
        cases["pixel_abort_wrong_stage"]=log.replace(target,target.replace("stage=20","stage=19"),1)
        for value in (0,1,16):
            cases[f"pixel_abort_pending_{value}"]=log.replace(target,re.sub(r"pending=\d+",f"pending={value}",target),1)
        cases["pixel_abort_late"]=log.replace(target+"\n","",1)+target+"\n"
    return cases
