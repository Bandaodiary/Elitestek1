"""Check real row-map reuse against independent request/response history."""
import re

MODE = "C1_NUM_COLUMN_ROW_MAP"
PROGRESS = "C1_PERF_COLUMN_ROW_MAP"


def check_column_row_map(log: str, jobs: int, required: bool = False, *,
                         require_mode: bool = False) -> bool:
    lines = log.splitlines()
    modes = [s for s in lines if s.startswith(MODE)]
    progress = [s for s in lines if s.startswith(PROGRESS)]
    if not modes and not progress and not required and not require_mode:
        return False  # Historical traces predate this optional architecture.
    if modes not in ([MODE + " enabled=0"], [MODE + " enabled=1"]):
        raise ValueError("row-map mode missing, duplicate or invalid")
    enabled = modes == [MODE + " enabled=1"]
    if required and not enabled:
        raise ValueError("row-map reuse was required")
    columns = [s for s in lines if s.startswith("C1_NUM_COLUMN_OPTION")]
    if len(columns) != 1 or not re.fullmatch(r"C1_NUM_COLUMN_OPTION enabled=[01] clients=\d+", columns[0]):
        raise ValueError("row-map lacks a unique column branch identity")
    column_enabled = "enabled=1 " in columns[0]
    if not column_enabled:
        if enabled:
            raise ValueError("row-map activity without a column branch")
        # Header-only legacy structural traces have no per-job counters.
        # Current scalar-system traces emit explicit zero progress; audit it
        # instead of mistaking the existence of a record for actual activity.
        if not progress and not any(s.startswith("C1_PERF_START ") for s in lines):
            return False
    starts, ends, successful = {}, {}, []
    for pos, line in enumerate(lines):
        if line.startswith("C1_PERF_START "):
            m = re.search(r"\bjob=(\d+)\b", line)
            if m is None or int(m[1]) in starts:
                raise ValueError("row-map job start missing identity or duplicated")
            starts[int(m[1])] = pos
        if line.startswith(("C1_PERF_JOB ", "C1_PERF_ABORT ")):
            m = re.search(r"\bjob=(\d+)\b", line)
            if m is None or int(m[1]) in ends:
                raise ValueError("row-map job termination invalid")
            ends[int(m[1])] = pos
            if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b", line):
                successful.append(int(m[1]))
    if len(successful) != jobs or successful != sorted(set(successful)) or len(progress) != jobs:
        raise ValueError("row-map progress must cover every successful job once")
    for job, line in zip(successful, progress):
        m = re.fullmatch(PROGRESS + r" job=(\d+) accepted=(\d+) eligible=(\d+) reused=(\d+) normal=(\d+) ram_reads=(\d+)", line)
        if m is None:
            raise ValueError("invalid row-map progress schema")
        identity, accepted, eligible, reused, normal, ram_reads = map(int, m.groups())
        totals = [s for s in lines if s.startswith(f"C1_PERF_COLUMNS job={job} ")]
        total = re.fullmatch(r"C1_PERF_COLUMNS job=\d+ accepted=(\d+) retired=(\d+)", totals[0]) if len(totals) == 1 else None
        if (identity != job or job not in starts or not starts[job] < lines.index(line) < ends[job] or
                total is None or int(total[1]) != accepted or total[1] != total[2]):
            raise ValueError("row-map ownership, eligibility, RAM reads or lifetime mismatch")
        if column_enabled:
            if (accepted <= 0 or not 0 <= eligible < accepted or reused != (eligible if enabled else 0) or
                    reused + normal != accepted or ram_reads != accepted or (enabled and eligible == 0)):
                raise ValueError("row-map eligibility/RAM conservation mismatch")
        elif any((accepted, eligible, reused, normal, ram_reads)):
            raise ValueError("disabled column branch has nonzero row-map activity")
    return enabled


def row_map_mutations(log: str) -> dict[str, str]:
    lines = log.splitlines()
    modes = [s for s in lines if s.startswith(MODE)]
    if not modes:
        return {}
    cases = {
        "row_map_all_removed": "\n".join(s for s in lines if not s.startswith((MODE, PROGRESS))) + "\n",
        "row_map_mode_flipped": log.replace(modes[0], MODE + " enabled=" + str(1-int(modes[0][-1])), 1),
    }
    for index, line in enumerate(modes + [s for s in lines if s.startswith(PROGRESS)]):
        cases[f"row_map_missing_{index}"] = log.replace(line + "\n", "", 1)
        cases[f"row_map_duplicate_{index}"] = log.replace(line, line + "\n" + line, 1)
        cases[f"row_map_schema_{index}"] = log.replace(line, line + " unrecognized=1", 1)
        if line.startswith(PROGRESS):
            fields = dict(re.findall(r"(\w+)=(\d+)", line))
            for field in ("job", "accepted", "eligible", "reused", "normal", "ram_reads"):
                # Eligible is independently correlated only in enabled mode.
                if field == "eligible" and modes[0].endswith("=0") and "C1_NUM_COLUMN_OPTION enabled=1 " in log:
                    continue
                for value in (int(fields[field]) + 1, 99999999):
                    cases[f"row_map_{index}_{field}_{value}"] = log.replace(
                        line, re.sub(rf"\b{field}=\d+", f"{field}={value}", line), 1)
            cases[f"row_map_late_{index}"] = log.replace(line + "\n", "", 1) + line + "\n"
    return cases
