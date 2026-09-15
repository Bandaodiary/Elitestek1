"""Check real RGB reduction handshakes against the unchanged descriptor ABI."""
import re
from microstyle_workload import workload

MODE = "C1_NUM_RGB_REDUCTION"
PROGRESS = "C1_PERF_RGB_REDUCTION"


def check_rgb_reduction(log: str, width: int, height: int, jobs: int,
                        required: bool = False, *, require_mode: bool = False) -> bool:
    lines = log.splitlines()
    modes = [s for s in lines if s.startswith(MODE)]
    records = [s for s in lines if s.startswith(PROGRESS)]
    if not modes and not records and not required and not require_mode:
        return False  # Pre-option historical logs retain the nine-beat budget.
    if modes not in ([MODE+" enabled=0"], [MODE+" enabled=1"]):
        raise ValueError("RGB reduction missing/duplicate/invalid mode")
    enabled = modes == [MODE+" enabled=1"]
    if required and not enabled:
        raise ValueError("packed RGB reduction was required")
    targets = [s for s in workload(width,height,pack_rgb_reduction=enabled)["stages"] if s["rgb_conv"]]
    beats = sum(s["dot_beats"] for s in targets)
    tails = sum(s["C8_results"] for s in targets)
    good_jobs = [re.search(r"\bjob=(\d+)\b",s) for s in lines
                 if s.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",s)]
    if len(records) != jobs or len(good_jobs) != jobs or any(j is None for j in good_jobs):
        raise ValueError("RGB reduction missing successful job/count witnesses")
    ids = [int(j[1]) for j in good_jobs]
    if ids != sorted(set(ids)):
        raise ValueError("RGB reduction job ids must be unique and ordered")
    for record, job in zip(records,ids):
        row = re.fullmatch(PROGRESS+r" job=(\d+) beats=(\d+) tails=(\d+)",record)
        if row is None or tuple(map(int,row.groups())) != (job,beats,tails):
            raise ValueError("RGB reduction handshakes disagree with descriptor budget")
    return enabled


def rgb_reduction_mutations(log: str) -> dict[str,str]:
    modes = [s for s in log.splitlines() if s.startswith(MODE)]
    rows = [s for s in log.splitlines() if s.startswith(PROGRESS)]
    if not modes or not rows:
        return {}
    variants = {"rgb_no_mode": log.replace(modes[0]+"\n","",1),
                "rgb_duplicate_mode": log.replace(modes[0],modes[0]+"\n"+modes[0],1),
                "rgb_invalid_mode": log.replace(modes[0],MODE+" enabled=2",1),
                "rgb_flip_mode": log.replace(modes[0],MODE+" enabled="+str(1-int(modes[0][-1])),1),
                "rgb_missing_progress": log.replace(rows[0]+"\n","",1),
                "rgb_duplicate_progress": log.replace(rows[0],rows[0]+"\n"+rows[0],1)}
    for field in ("job","beats","tails"):
        match = re.search(rf"\b{field}=(\d+)",rows[0])
        bad = rows[0].replace(match[0],f"{field}={int(match[1])+1}",1)
        variants["rgb_wrong_"+field] = log.replace(rows[0],bad,1)
    variants["rgb_all_removed"] = "\n".join(s for s in log.splitlines() if not s.startswith((MODE,PROGRESS)))+"\n"
    return variants
