"""Audit dot transactions and reuse of existing requant pipeline slots."""
import re
from microstyle_workload import workload
from check_dot_pixel_pipeline_trace import check_dot_pixel_pipeline
from check_final_fusion_trace import check_final_compute,COMPUTE
MODE="C1_NUM_MAC_REQUANT_OVERLAP"
PROGRESS="C1_PERF_MAC_REQUANT_OVERLAP"


def check_requant_overlap(log: str, width: int, height: int, jobs: int, required: bool=False) -> bool:
    lines=log.splitlines()
    pixel_early=check_dot_pixel_pipeline(log,width,height,jobs)
    fused_early=check_final_compute(log,width,height,jobs)
    modes=[s for s in lines if s.startswith(MODE)]
    records=[s for s in lines if s.startswith(PROGRESS)]
    if not modes and not records and not required:return False
    if modes not in ([MODE+" enabled=0"],[MODE+" enabled=1"]):
        raise ValueError("MAC/requant overlap mode missing/duplicate/invalid")
    enabled=modes==[MODE+" enabled=1"]
    if required and not enabled:raise ValueError("MAC/requant overlap was required")
    stages=workload(width,height)["stages"]
    expected=sum(s["dot_transactions"] for s in stages)
    early=sum(s["dot_requant_restarts"] for s in stages) if enabled else 0
    ids=[]
    for line in lines:
        if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",line):
            row=re.search(r"\bjob=(\d+)\b",line)
            if row is None:raise ValueError("requant progress job has no id")
            ids.append(int(row[1]))
    if len(ids)!=jobs or len(set(ids))!=jobs or any(j<=0 for j in ids) or len(records)!=jobs:
        raise ValueError("requant overlap lacks unique successful job records")
    for job,line in zip(ids,records):
        row=re.fullmatch(PROGRESS+r" job=(\d+) starts=(\d+) outputs=(\d+) early=(\d+) peak=(\d+)",line)
        if row is None or tuple(map(int,row.groups()[:4]))!=(job,expected,expected,early+pixel_early.get(job,0)+fused_early.get(job,0)):
            raise ValueError("requant starts/retirements/early restarts disagree with descriptors")
        if not ((2<=int(row[5])<=6) if enabled else int(row[5])==1):
            raise ValueError("requant overlap absent or exceeded physical storage")
    return enabled


def requant_overlap_mutations(log: str) -> dict[str,str]:
    lines=log.splitlines();mode=MODE+" enabled=1"
    if mode not in lines:return {}
    cases={};targets=[mode]+[s for s in lines if s.startswith(PROGRESS)]
    for index,target in enumerate(targets):
        cases[f"rq_missing_{index}"]=log.replace(target+"\n","",1)
        cases[f"rq_duplicate_{index}"]=log.replace(target,target+"\n"+target,1)
    cases["rq_all_removed"]="\n".join(s for s in lines if not s.startswith((MODE,PROGRESS)))+"\n"
    for value in (0,2):cases[f"rq_bad_mode_{value}"]=log.replace(mode,MODE+f" enabled={value}",1)
    for index,target in enumerate(targets[1:]):
        for field in ("job","starts","outputs","early","peak"):
            cases[f"rq_zero_{index}_{field}"]=log.replace(target,re.sub(rf"\b{field}=\d+",f"{field}=0",target),1)
        for peak in (1,7):cases[f"rq_bad_peak_{index}_{peak}"]=log.replace(target,re.sub(r"\bpeak=\d+",f"peak={peak}",target),1)
    for index,target in enumerate(s for s in lines if s.startswith(COMPUTE)):
        match=re.search(r"\bstarts_ahead=(\d+)",target)
        if match:
            changed=int(match[1])-1 if int(match[1]) else 1
            cases[f"rq_fused_early_{index}"]=log.replace(target,re.sub(r"\bstarts_ahead=\d+",f"starts_ahead={changed}",target),1)
    return cases
