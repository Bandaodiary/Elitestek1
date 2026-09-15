"""Validate early pointwise reduction using descriptor-derived work counts."""
import re
from microstyle_workload import workload

MODE = "C1_NUM_POINTWISE_REDUCTION"
PROGRESS = "C1_PERF_POINTWISE_REDUCTION"


def check_pointwise_reduction(log: str, width: int, height: int, jobs: int,
                             required: bool = False, require_abort: bool = False) -> bool:
    lines=log.splitlines()
    modes=[s for s in lines if s.startswith(MODE+" ")]
    records=[s for s in lines if s.startswith(PROGRESS)]
    aborts=[s for s in lines if s.startswith("C1_NUM_POINTWISE_REDUCTION_ABORT")]
    if not modes and not records and not aborts and not required and not require_abort: return False
    if modes not in ([MODE+" enabled=0"],[MODE+" enabled=1"]):
        raise ValueError("pointwise reduction mode missing/duplicate/invalid")
    enabled=modes==[MODE+" enabled=1"]
    if (required or require_abort) and not enabled: raise ValueError("pointwise reduction was required")
    stages=workload(width,height)["stages"]
    beats=sum(s["pointwise_stream_beats"] for s in stages) if enabled else 0
    early=sum(s["pointwise_early_beats"] for s in stages) if enabled else 0
    ids=[]
    for s in lines:
        if s.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",s):
            m=re.search(r"\bjob=(\d+)\b",s)
            if m is None: raise ValueError("pointwise progress job lacks id")
            ids.append(int(m[1]))
    if len(ids)!=jobs or len(set(ids))!=jobs or any(i<=0 for i in ids) or len(records)!=jobs:
        raise ValueError("pointwise progress lacks unique successful jobs")
    for job,line in zip(ids,records):
        row=re.fullmatch(PROGRESS+r" job=(\d+) beats=(\d+) early=(\d+)",line)
        if row is None or tuple(map(int,row.groups()))!=(job,beats,early):
            raise ValueError("pointwise early/total beats disagree with descriptors")
    if require_abort or aborts:
        if not enabled or (width,height,jobs)!=(8,8,1) or aborts!=[
            "C1_NUM_POINTWISE_REDUCTION_ABORT stage=19 group=1 output_group=0"]:
            raise ValueError("pointwise abort missed partial first-output-group reduction")
        for mode in ("C1_NUM_POINTWISE_COLUMN_READS enabled=0","C1_NUM_SCALAR_READ_CACHE enabled=0"):
            if mode not in lines: raise ValueError("pointwise abort must reach a real scalar AXI read")
        if len([s for s in lines if s.startswith("C1_SOC_INFLIGHT_READ_ABORT_DRAIN_PASS ")])!=1 or \
           len([s for s in lines if s.startswith("C1_SOC_INFLIGHT_READ_ABORT_PASS ")])!=1:
            raise ValueError("pointwise abort lacks real drain and restart")
    return enabled


def pointwise_reduction_mutations(log: str) -> dict[str,str]:
    lines=log.splitlines();mode=MODE+" enabled=1"
    if mode not in lines: return {}
    cases={}
    targets=[mode]+[s for s in lines if s.startswith(PROGRESS)]
    for index,target in enumerate(targets):
        cases[f"pw_reduction_missing_{index}"]=log.replace(target+"\n","",1)
        cases[f"pw_reduction_duplicate_{index}"]=log.replace(target,target+"\n"+target,1)
    cases["pw_reduction_all_removed"]="\n".join(s for s in lines if not s.startswith((MODE,PROGRESS)))+"\n"
    for value in (0,2):
        cases[f"pw_reduction_mode_{value}"]=log.replace(mode,MODE+f" enabled={value}",1)
    for index,target in enumerate(targets[1:]):
        for field in ("job","beats","early"):
            for delta in ("0","99999999"):
                cases[f"pw_reduction_bad_{index}_{field}_{delta}"]=log.replace(target,re.sub(rf"\b{field}=\d+",f"{field}={delta}",target),1)
    for target in (s for s in lines if s.startswith("C1_NUM_POINTWISE_REDUCTION_ABORT")):
        cases["pw_reduction_abort_missing"]=log.replace(target+"\n","",1)
        cases["pw_reduction_abort_duplicate"]=log.replace(target,target+"\n"+target,1)
        for field in ("stage","group","output_group"):
            cases[f"pw_reduction_abort_bad_{field}"]=log.replace(target,re.sub(rf"\b{field}=\d+",f"{field}=9",target),1)
    return cases
