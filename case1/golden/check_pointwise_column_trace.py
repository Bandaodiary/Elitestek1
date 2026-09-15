"""Descriptor-derived checks for reusing the column endpoint for 1x1 inputs."""
import re
from microstyle_workload import workload
from check_view_elision_trace import check_view_elision
from check_final_fusion_trace import final_fusion_mode

MODE = "C1_NUM_POINTWISE_COLUMN_READS"
PROGRESS = "C1_PERF_POINTWISE_COLUMNS"


def check_pointwise_columns(log: str, width: int, height: int, jobs: int,
                            required: bool = False) -> bool:
    lines = log.splitlines()
    modes = [s for s in lines if s.startswith(MODE)]
    records = [s for s in lines if s.startswith(PROGRESS)]
    if not modes and not records and not required:
        return False
    if modes not in ([MODE+" enabled=0"], [MODE+" enabled=1"]):
        raise ValueError("missing/duplicate/invalid pointwise column mode")
    enabled = modes == [MODE+" enabled=1"]
    if required and not enabled:
        raise ValueError("pointwise column mode was required")
    columns = [s for s in lines if s.startswith("C1_NUM_COLUMN_OPTION")]
    column_enabled = len(columns)==1 and re.fullmatch(r"C1_NUM_COLUMN_OPTION enabled=1 clients=[89]",columns[0]) is not None
    if enabled and not column_enabled:
        raise ValueError("pointwise column mode requires actual column endpoint")
    success = [dict(re.findall(r"([a-z_]+)=(\d+)",s)) for s in lines
               if s.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",s)]
    ids = [s.get("job") for s in success]
    if len(success)!=jobs or len(set(ids))!=jobs or any(i is None or int(i)<=0 for i in ids) or len(records)!=jobs:
        raise ValueError("pointwise column progress lacks unique successful jobs")
    views=check_view_elision(log,width,height,jobs)
    stages = workload(width,height,virtual_upsample=views,elide_views=views,fuse_final=final_fusion_mode(log))["stages"]
    pw = sum(s["pointwise_reads"] for s in stages) if enabled else 0
    scalar = sum(s["scalar_reads_with_columns"] for s in stages)-pw
    for job, line in zip(success,records):
        row = re.fullmatch(PROGRESS+r" job=(\d+) reads=(\d+)",line)
        if row is None or row[1]!=job["job"] or int(row[2])!=pw:
            raise ValueError("pointwise column reads disagree with descriptor workload")
        if column_enabled and job.get("mem_read")!=str(scalar):
            raise ValueError("pointwise/scalar read budgets did not transfer exactly")
        # Single-frame traces contain per-stage evidence; two-frame logs may
        # omit it. When present, audit each 1x1 stage, not merely the total.
        rows = [s for s in lines if s.startswith(f"C1_PERF_STAGE job={job['job']} ")]
        if rows:
            if len(rows)!=22:
                raise ValueError("pointwise stage performance is incomplete")
            for line,target in zip(rows,stages):
                values=dict(re.findall(r"([a-z_]+)=(\d+)",line))
                if values.get("stage")!=str(target["stage"]):
                    raise ValueError("pointwise stage order mismatch")
                if enabled and target["opcode"]==2 and (
                    values.get("mem_read")!="0" or values.get("columns")!=str(target["pointwise_reads"])):
                    raise ValueError("a 1x1 stage bypassed the required column input path")
    return enabled


def pointwise_mutations(log: str) -> dict[str,str]:
    lines=log.splitlines()
    mode=MODE+" enabled=1"
    if mode not in lines:
        return {}
    variants={}
    for index,target in enumerate([mode]+[s for s in lines if s.startswith(PROGRESS)]):
        variants[f"pointwise_missing_{index}"]=log.replace(target+"\n","",1)
        variants[f"pointwise_duplicate_{index}"]=log.replace(target,target+"\n"+target,1)
    for value in (0,2):
        variants[f"pointwise_mode_{value}"]=log.replace(mode,MODE+f" enabled={value}",1)
    variants["pointwise_all_removed"]="\n".join(s for s in lines if not s.startswith((MODE,PROGRESS)))
    for index,target in enumerate(s for s in lines if s.startswith(PROGRESS)):
        for field,value in (("job",0),("reads",0),("reads",999999)):
            variants[f"pointwise_{index}_{field}_{value}"]=log.replace(target,re.sub(rf"\b{field}=\d+",f"{field}={value}",target),1)
    column=next(s for s in lines if s.startswith("C1_NUM_COLUMN_OPTION"))
    variants["pointwise_no_columns"]=log.replace(column,column.replace("enabled=1","enabled=0"),1)
    for index,target in enumerate(s for s in lines if s.startswith("C1_PERF_JOB ") and "error=0" in s):
        variants[f"pointwise_wrong_scalar_{index}"]=log.replace(target,re.sub(r"\bmem_read=\d+","mem_read=1",target),1)
    return variants
