"""Independent source upload budget; no changes to model arithmetic."""
import re

MODE = "C1_NUM_SOURCE_PIPELINE"
PROGRESS = "C1_PERF_SOURCE_WRITES"


def check_source_writes(log: str, width: int, height: int, jobs: int,
                        required: bool = False, require_abort: bool = False) -> bool:
    lines = log.splitlines()
    modes = [s for s in lines if s.startswith(MODE)]
    records = [s for s in lines if s.startswith(PROGRESS)]
    aborts = [s for s in lines if s.startswith("C1_NUM_SOURCE_WRITE_ABORT")]
    if not modes and not records and not aborts and not required and not require_abort:
        return False  # Compatible with historical traces only.
    if modes not in ([MODE+" enabled=0"], [MODE+" enabled=1"]):
        raise ValueError("source pipeline mode missing/duplicate/invalid")
    enabled = modes == [MODE+" enabled=1"]
    if (required or require_abort) and not enabled:
        raise ValueError("source write pipeline was required")
    ids = []
    for line in lines:
        if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b", line):
            job = re.search(r"\bjob=(\d+)\b", line)
            if job is None: raise ValueError("successful source job lacks id")
            ids.append(int(job[1]))
    if len(ids)!=jobs or len(set(ids))!=jobs or any(i<=0 for i in ids) or len(records)!=jobs:
        raise ValueError("source write progress lacks unique successful jobs")
    pixels = width*height  # Resized NN geometry, not camera/source geometry.
    ends = ((width+7)//8)*height if enabled else pixels
    for job, line in zip(ids, records):
        row = re.fullmatch(PROGRESS+r" job=(\d+) inputs=(\d+) requests=(\d+) responses=(\d+) ends=(\d+) peak=(\d+) pending_cycles=(\d+)", line)
        if row is None or int(row[1])!=job or any(int(row[i])!=pixels for i in (2,3,4)) or int(row[5])!=ends:
            raise ValueError("source write input/request/response/batch budget mismatch")
        if not 1<=int(row[6])<=(15 if enabled else 1) or int(row[7])<pixels:
            raise ValueError("source write debt/latency bounds violated")
    if require_abort or aborts:
        row = re.fullmatch(r"C1_NUM_SOURCE_WRITE_ABORT pending=(\d+) accepted=(\d+) state=([234])",aborts[0]) if len(aborts)==1 else None
        if not enabled or row is None or not 1<=int(row[1])<=15 or not int(row[1])<=int(row[2])<=pixels or jobs!=1:
            raise ValueError("source abort lacked real upload write ownership")
        if len([s for s in lines if s.startswith("C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS ")])!=1 or \
           len([s for s in lines if s.startswith("C1_SOC_INFLIGHT_WRITE_ABORT_PASS ")])!=1:
            raise ValueError("source abort lacked physical drain and no-reset restart")
    return enabled


def source_write_mutations(log: str) -> dict[str,str]:
    lines = log.splitlines()
    mode = MODE+" enabled=1"
    if mode not in lines: return {}
    cases = {}
    targets = [mode]+[s for s in lines if s.startswith(PROGRESS)]
    for index, target in enumerate(targets):
        cases[f"source_missing_{index}"] = log.replace(target+"\n", "", 1)
        cases[f"source_duplicate_{index}"] = log.replace(target,target+"\n"+target,1)
    cases["source_all_removed"] = "\n".join(s for s in lines if not s.startswith((MODE,PROGRESS)))+"\n"
    for value in (0,2):
        cases[f"source_mode_{value}"] = log.replace(mode,MODE+f" enabled={value}",1)
    for index, target in enumerate(targets[1:]):
        for field in ("job", "inputs", "requests", "responses", "ends", "peak", "pending_cycles"):
            cases[f"source_zero_{index}_{field}"] = log.replace(target,re.sub(rf"\b{field}=\d+",f"{field}=0",target),1)
        cases[f"source_credit_overflow_{index}"] = log.replace(target,re.sub(r"\bpeak=\d+","peak=16",target),1)
    for target in (s for s in lines if s.startswith("C1_NUM_SOURCE_WRITE_ABORT")):
        cases["source_abort_missing"] = log.replace(target+"\n","",1)
        cases["source_abort_duplicate"] = log.replace(target,target+"\n"+target,1)
        for field,value in (("pending",0),("pending",16),("accepted",0),("state",5)):
            cases[f"source_abort_bad_{field}_{value}"] = log.replace(target,re.sub(rf"\b{field}=\d+",f"{field}={value}",target),1)
    return cases
