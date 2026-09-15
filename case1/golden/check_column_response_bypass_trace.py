"""Audit real synchronous-RAM response forwarding, not only a build flag."""
import re

MODE = "C1_NUM_COLUMN_RESPONSE_BYPASS"
PROGRESS = "C1_PERF_COLUMN_RESPONSE_BYPASS"


def check_column_response_bypass(log: str, jobs: int, required: bool = False) -> bool:
    lines = log.splitlines()
    modes = [s for s in lines if s.startswith(MODE)]
    progress = [s for s in lines if s.startswith(PROGRESS)]
    if not modes and not progress and not required:
        return False
    if modes not in ([MODE+" enabled=0"], [MODE+" enabled=1"]):
        raise ValueError("missing/duplicate/invalid column response bypass mode")
    enabled = modes == [MODE+" enabled=1"]
    if required and not enabled:
        raise ValueError("column response bypass was required")
    if enabled:
        columns = [s for s in lines if s.startswith("C1_NUM_COLUMN_OPTION")]
        if len(columns)!=1 or not re.fullmatch(r"C1_NUM_COLUMN_OPTION enabled=1 clients=[89]",columns[0]):
            raise ValueError("column response bypass needs the real column branch")
    ids = []
    for line in lines:
        if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",line):
            job = re.search(r"\bjob=(\d+)\b",line)
            if job is None:
                raise ValueError("response bypass successful job lacks id")
            ids.append(int(job[1]))
    if len(ids)!=jobs or len(set(ids))!=jobs or any(i<=0 for i in ids) or len(progress)!=jobs:
        raise ValueError("response bypass progress must match unique successful jobs")
    for job,line in zip(ids,progress):
        count = re.fullmatch(PROGRESS+r" job=(\d+) responses=(\d+)",line)
        if count is None or int(count[1])!=job:
            raise ValueError("response bypass progress has wrong order/id/format")
        totals = [s for s in lines if s.startswith(f"C1_PERF_COLUMNS job={job} ")]
        total = re.fullmatch(r"C1_PERF_COLUMNS job=\d+ accepted=(\d+) retired=(\d+)",totals[0]) if len(totals)==1 else None
        if total is None or total[1]!=total[2]:
            raise ValueError("response bypass lacks exact column retirement evidence")
        # In this SoC the transaction owner accepts every backend response
        # immediately and holds it if necessary. Successful jobs have no
        # poisoned columns, so every real response must use capture bypass.
        if enabled and (int(count[2])<=0 or count[2]!=total[2]):
            raise ValueError("not every successful column used real response bypass")
        if not enabled and count[2]!="0":
            raise ValueError("disabled response bypass still forwarded RAM outputs")
    return enabled


def response_bypass_mutations(log: str) -> dict[str,str]:
    lines = log.splitlines()
    mode = MODE+" enabled=1"
    if mode not in lines:
        return {}
    cases = {}
    for index,target in enumerate([mode]+[s for s in lines if s.startswith(PROGRESS)]):
        cases[f"response_bypass_missing_{index}"] = log.replace(target+"\n","",1)
        cases[f"response_bypass_duplicate_{index}"] = log.replace(target,target+"\n"+target,1)
    for value in (0,2):
        cases[f"response_bypass_mode_{value}"] = log.replace(mode,MODE+f" enabled={value}",1)
    cases["response_bypass_all_removed"] = "\n".join(s for s in lines if not s.startswith((MODE,PROGRESS)))
    for index,target in enumerate(s for s in lines if s.startswith(PROGRESS)):
        for field,value in (("job",0),("responses",0),("responses",1),("responses",999999)):
            cases[f"response_bypass_{index}_{field}_{value}"] = log.replace(
                target,re.sub(rf"\b{field}=\d+",f"{field}={value}",target),1)
    column = next(s for s in lines if s.startswith("C1_NUM_COLUMN_OPTION"))
    cases["response_bypass_no_columns"] = log.replace(column,column.replace("enabled=1","enabled=0"),1)
    return cases
