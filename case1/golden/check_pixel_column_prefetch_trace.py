"""Check first-column lookahead ownership against the independent layer graph."""
import re
from microstyle_workload import workload
from check_column_write_overlap_trace import check_column_write_overlap

MODE = "C1_NUM_PIXEL_COLUMN_PREFETCH"
PROGRESS = "C1_PERF_PIXEL_COLUMN_PREFETCH"
ABORT = "C1_NUM_PIXEL_PREFETCH_ABORT"
ALL_MODE = "C1_NUM_ALL_PIXEL_GROUPS"


def all_pixel_groups_enabled(log: str, required: bool = False) -> bool:
    modes=[s for s in log.splitlines() if s.startswith(ALL_MODE)]
    if not modes and not required:return False
    if modes not in ([ALL_MODE+" enabled=0"],[ALL_MODE+" enabled=1"]):
        raise ValueError("all-group prefetch mode missing/duplicate/invalid")
    enabled=modes==[ALL_MODE+" enabled=1"]
    if required and not enabled:raise ValueError("all-group prefetch was required")
    if enabled and [s for s in log.splitlines() if s.startswith(MODE)]!=[MODE+" enabled=1"]:
        raise ValueError("all-group prefetch requires next-pixel prefetch")
    return enabled


def check_pixel_column_prefetch(log: str, width: int, height: int, jobs: int,
                                required: bool = False, require_abort: bool = False) -> bool:
    lines = log.splitlines()
    all_groups = all_pixel_groups_enabled(log)
    modes = [s for s in lines if s.startswith(MODE)]
    records = [s for s in lines if s.startswith(PROGRESS)]
    aborts = [s for s in lines if s.startswith(ABORT)]
    if not modes and not records and not aborts and not required and not require_abort:
        return False
    if modes not in ([MODE+" enabled=0"], [MODE+" enabled=1"]):
        raise ValueError("missing/duplicate/invalid next-pixel column prefetch mode")
    enabled = modes == [MODE+" enabled=1"]
    if (required or require_abort) and not enabled:
        raise ValueError("next-pixel column prefetch was required")
    if enabled:
        check_column_write_overlap(log,jobs,True)
    pointwise = [s for s in lines if s.startswith("C1_NUM_POINTWISE_COLUMN_READS")]
    if pointwise not in (["C1_NUM_POINTWISE_COLUMN_READS enabled=0"],["C1_NUM_POINTWISE_COLUMN_READS enabled=1"]):
        raise ValueError("prefetch budget needs the actual 1x1 column option")
    pw = pointwise == ["C1_NUM_POINTWISE_COLUMN_READS enabled=1"]
    expected = sum(s["next_pixel_columns"]*(s["input_groups"] if all_groups else 1) for s in workload(width,height)["stages"]
                   if s["opcode"] in (1,3) or (pw and s["opcode"]==2)) if enabled else 0
    ids = []
    for line in lines:
        if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",line):
            job = re.search(r"\bjob=(\d+)\b",line)
            if job is None: raise ValueError("prefetch successful job lacks id")
            ids.append(int(job[1]))
    if len(ids)!=jobs or len(set(ids))!=jobs or any(i<=0 for i in ids) or len(records)!=jobs:
        raise ValueError("prefetch progress lacks unique successful jobs")
    for job,line in zip(ids,records):
        row = re.fullmatch(PROGRESS+r" job=(\d+) requests=(\d+) responses=(\d+) uses=(\d+) early=(\d+)",line)
        if row is None or int(row[1])!=job or any(int(row[i])!=expected for i in (2,3,4)):
            raise ValueError("prefetch request/response/use conservation disagrees with first-column budget")
        if (enabled and not 0<int(row[5])<=expected) or (not enabled and row[5]!="0"):
            raise ValueError("prefetch lacks real early responses or has spurious progress")
    if require_abort or aborts:
        # 8x8 virtual stage18 caches a physical 4x4 image. The first next-row
        # refill belongs to logical (0,2), not to the current pixel (7,1).
        if not enabled or (width,height)!=(8,8) or aborts!=[ABORT+" stage=18 x=0 y=2"] or \
           [s for s in lines if s.startswith("C1_NUM_VIRTUAL_UPSAMPLE_ABORT")]!=[
               "C1_NUM_VIRTUAL_UPSAMPLE_ABORT stage=18 width=4 height=4 input_bank=0 output_bank=1"]:
            raise ValueError("prefetch abort missed the real next-row ownership point")
    return enabled


def pixel_prefetch_mutations(log: str) -> dict[str,str]:
    lines = log.splitlines()
    mode = MODE+" enabled=1"
    if mode not in lines: return {}
    cases = {}
    all_modes=[s for s in lines if s.startswith(ALL_MODE)]
    if all_modes:
        target=all_modes[0]
        cases["pixel_all_duplicate"]=log.replace(target,target+"\n"+target,1)
        cases["pixel_all_invalid"]=log.replace(target,ALL_MODE+" enabled=2",1)
        if target==ALL_MODE+" enabled=1":
            cases["pixel_all_missing"]=log.replace(target+"\n","",1)
            cases["pixel_all_disabled"]=log.replace(target,ALL_MODE+" enabled=0",1)
    for index,target in enumerate([mode]+[s for s in lines if s.startswith((PROGRESS,ABORT))]):
        cases[f"pixel_prefetch_missing_{index}"] = log.replace(target+"\n","",1)
        cases[f"pixel_prefetch_duplicate_{index}"] = log.replace(target,target+"\n"+target,1)
    for value in (0,2):
        cases[f"pixel_prefetch_mode_{value}"] = log.replace(mode,MODE+f" enabled={value}",1)
    cases["pixel_prefetch_all_removed"] = "\n".join(s for s in lines if not s.startswith((MODE,PROGRESS,ABORT,ALL_MODE)))
    for index,target in enumerate(s for s in lines if s.startswith(PROGRESS)):
        for field in ("job","requests","responses","uses","early"):
            cases[f"pixel_prefetch_{index}_{field}_zero"] = log.replace(target,re.sub(rf"\b{field}=\d+",f"{field}=0",target),1)
        cases[f"pixel_prefetch_{index}_early_overflow"] = log.replace(target,re.sub(r"\bearly=\d+","early=9999999",target),1)
    if ABORT+" stage=18 x=0 y=2" in lines:
        target=ABORT+" stage=18 x=0 y=2"
        for field,value in (("stage",19),("x",7),("y",1)):
            cases[f"pixel_prefetch_abort_{field}"] = log.replace(target,re.sub(rf"\b{field}=\d+",f"{field}={value}",target),1)
    cases["pixel_prefetch_no_overlap"] = log.replace("C1_NUM_COLUMN_WRITE_OVERLAP enabled=1","C1_NUM_COLUMN_WRITE_OVERLAP enabled=0",1)
    return cases
