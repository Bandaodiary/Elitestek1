"""Real DW start/EOF/continuation witnesses for the default-off frame scheduler."""
import re

from microstyle_workload import workload

MODE = "C1_NUM_DW_FRAME_STREAM"
PROGRESS = "C1_PERF_DW_FRAME"


def check_dw_frame(log: str, width: int, height: int, jobs: int,
                   required: bool = False, require_mode: bool = False) -> bool:
    lines = log.splitlines()
    modes = [s for s in lines if s.startswith(MODE)]
    records = [s for s in lines if s.startswith(PROGRESS)]
    if not modes and not records and not required and not require_mode:
        return False
    if modes not in ([MODE + " enabled=0"], [MODE + " enabled=1"]):
        raise ValueError("missing/duplicate/malformed DW frame mode")
    enabled = modes == [MODE + " enabled=1"]
    if required and not enabled:
        raise ValueError("DW frame stream was required")
    if not enabled:
        if records:
            raise ValueError("disabled DW frame stream reported activity")
        return False
    for prefix in ("C1_NUM_DW_PIXEL_PIPELINE", "C1_NUM_DW_STREAM"):
        if [s for s in lines if s.startswith(prefix)] != [prefix + " enabled=1"]:
            raise ValueError("DW frame prerequisite missing")
    stages = [s for s in workload(width, height)["stages"] if s["opcode"] == 3]
    cold = sum(s["input_groups"] for s in stages)
    warm = sum(s["output_width"] * s["output_height"] > 1 for s in stages)
    continues = sum(max(s["output_width"] * s["output_height"] - 2, 0) for s in stages)
    ids = []
    for line in lines:
        if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b", line):
            row = re.search(r"\bjob=(\d+)\b", line)
            if row is None or int(row[1]) <= 0:
                raise ValueError("DW frame successful job lacks a positive id")
            ids.append(int(row[1]))
    if len(ids) != jobs or len(set(ids)) != jobs or len(records) != jobs:
        raise ValueError("DW frame requires unique successful jobs and one summary each")
    for job, line in zip(ids, records):
        row = re.fullmatch(PROGRESS + r" job=(\d+) cold_starts=(\d+) warm_starts=(\d+) continues=(\d+) input_eofs=(\d+) output_eofs=(\d+) held_continues=(\d+)", line)
        if row is None:
            raise ValueError("malformed DW frame progress")
        owner, got_cold, got_warm, got_continues, in_eof, out_eof, held = map(int, row.groups())
        if (owner, got_cold, got_warm, got_continues, in_eof, out_eof) != (job, cold, warm, continues, cold + warm, cold + warm):
            raise ValueError("DW start/continuation/real EOF counts disagree with descriptor work")
        if not 0 <= held <= continues:
            raise ValueError("DW held continuation exceeds actual continuations")
    return True


def dw_frame_mutations(log: str) -> dict[str, str]:
    targets = [s for s in log.splitlines() if s.startswith((MODE, PROGRESS))]
    cases = {}
    for index, row in enumerate(targets):
        cases[f"dw_frame_missing_{index}"] = log.replace(row + "\n", "", 1)
        cases[f"dw_frame_duplicate_{index}"] = log.replace(row, row + "\n" + row, 1)
        for field in re.findall(r"([a-z_]+)=\d+", row):
            cases[f"dw_frame_wrong_{index}_{field}"] = log.replace(row, re.sub(rf"\b{field}=(\d+)", lambda m: f"{field}={int(m[1])+1}", row), 1)
    cases["dw_frame_all_removed"] = "\n".join(s for s in log.splitlines() if not s.startswith((MODE, PROGRESS))) + "\n"
    # held is a bounded observation, not an exact expected count.
    for index, row in enumerate(s for s in targets if s.startswith(PROGRESS)):
        cases[f"dw_frame_wrong_{index}_held_overflow"] = log.replace(row, re.sub(r"held_continues=\d+", "held_continues=999999999", row), 1)
    return {key: value for key, value in cases.items() if not key.endswith("_held_continues")}
