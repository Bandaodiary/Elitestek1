"""Shared, fail-closed evidence checks for independent column/write progress."""
import re

MODE = "C1_NUM_COLUMN_WRITE_OVERLAP"
PROGRESS = "C1_PERF_COLUMN_WRITE_OVERLAP"


def check_column_write_overlap(log: str, jobs: int, required: bool = False) -> bool:
    lines = log.splitlines()
    modes = [s for s in lines if s.startswith(MODE)]
    records = [s for s in lines if s.startswith(PROGRESS)]
    if not modes and not records and not required:
        return False  # Compatibility with logs predating this option.
    if modes not in ([MODE + " enabled=0"], [MODE + " enabled=1"]):
        raise ValueError("missing/duplicate/invalid column-write overlap mode")
    enabled = modes == [MODE + " enabled=1"]
    if required and not enabled:
        raise ValueError("column-write overlap was required but not enabled")
    success = [s for s in lines if s.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b", s)]
    ids = []
    for line in success:
        job = re.search(r"\bjob=(\d+)\b", line)
        if job is None:
            raise ValueError("column-write overlap successful job lacks an identifier")
        ids.append(int(job[1]))
    if len(ids) != jobs or len(set(ids)) != jobs or any(i <= 0 for i in ids) or len(records) != jobs:
        raise ValueError("column-write overlap has incomplete/duplicate successful jobs")
    if enabled:
        columns = [s for s in lines if s.startswith("C1_NUM_COLUMN_OPTION")]
        writes = [s for s in lines if s.startswith("C1_NUM_TENSOR_WRITE_OPTIONS")]
        if len(columns) != 1 or not re.fullmatch(r"C1_NUM_COLUMN_OPTION enabled=1 clients=[89]", columns[0]):
            raise ValueError("column-write overlap needs the actual column branch")
        if len(writes) != 1 or not re.fullmatch(r"C1_NUM_TENSOR_WRITE_OPTIONS packed=[01] pipeline=1 end=[01]", writes[0]):
            raise ValueError("column-write overlap needs actual pipelined writes")
    for expected_job, line in zip(ids, records):
        row = re.fullmatch(PROGRESS + r" job=(\d+) columns=(\d+) peak_writes=(\d+)", line)
        if row is None or int(row[1]) != expected_job:
            raise ValueError("column-write overlap progress has wrong job/order/format")
        overlap, peak = int(row[2]), int(row[3])
        total = [s for s in lines if s.startswith(f"C1_PERF_COLUMNS job={expected_job} ")]
        count = re.fullmatch(r"C1_PERF_COLUMNS job=\d+ accepted=(\d+) retired=(\d+)", total[0]) if len(total) == 1 else None
        if count is None or count[1] != count[2]:
            raise ValueError("column-write overlap has no fully retired column budget")
        if enabled and (not 0 < overlap <= int(count[1]) or not 1 <= peak <= 15):
            raise ValueError("column-write overlap has no real progress or invalid credit peak")
        if not enabled and (overlap != 0 or not 0 <= peak <= 8):
            raise ValueError("disabled overlap unexpectedly crossed the pixel write fence")
    return enabled


def overlap_mutations(log: str) -> dict[str, str]:
    """Targeted negative evidence shared by single-frame and two-frame gates."""
    lines = log.splitlines()
    mode = MODE + " enabled=1"
    if mode not in lines:
        return {}
    variants = {}
    targets = [mode] + [s for s in lines if s.startswith(PROGRESS)]
    for index, target in enumerate(targets):
        variants[f"overlap_missing_{index}"] = log.replace(target + "\n", "", 1)
        variants[f"overlap_duplicate_{index}"] = log.replace(target, target + "\n" + target, 1)
    for value in (0, 2):
        variants[f"overlap_mode_{value}"] = log.replace(mode, MODE + f" enabled={value}", 1)
    variants["overlap_all_removed"] = "\n".join(s for s in lines if not s.startswith((MODE, PROGRESS)))
    for index, target in enumerate(targets[1:]):
        for field, value in (("job", 0), ("columns", 0), ("columns", 99999999), ("peak_writes", 0), ("peak_writes", 16)):
            variants[f"overlap_{index}_{field}_{value}"] = log.replace(target, re.sub(rf"\b{field}=\d+", f"{field}={value}", target), 1)
    columns = next(s for s in lines if s.startswith("C1_NUM_COLUMN_OPTION"))
    writes = next(s for s in lines if s.startswith("C1_NUM_TENSOR_WRITE_OPTIONS"))
    variants["overlap_no_columns"] = log.replace(columns, columns.replace("enabled=1", "enabled=0"), 1)
    variants["overlap_no_write_pipeline"] = log.replace(writes, writes.replace("pipeline=1", "pipeline=0"), 1)
    return variants
