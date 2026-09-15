"""Validate simulation-only layer/FSM residency, not an estimated MAC budget."""
from __future__ import annotations

from collections import defaultdict
import re


HEADER = "C1_NUM_STAGE_FSM version=1 includes_setup=1 stage_source=adapter"
ROW = re.compile(r"C1_PERF_STAGE_FSM job=(\d+) stage=(\d+) side=(engine|adapter) state=(\d+) cycles=(\d+)")


def check_stage_fsm(log: str, required: bool = False) -> dict:
    lines = log.splitlines()
    headers = [s for s in lines if s.startswith("C1_NUM_STAGE_FSM")]
    records = [s for s in lines if s.startswith("C1_PERF_STAGE_FSM")]
    if not headers and not records and not required:
        return {}  # Historical traces predate this witness.
    if headers != [HEADER] or not records:
        raise ValueError("missing/duplicate/malformed layer FSM profile/header")
    targets = {}
    for line in lines:
        if not line.startswith("C1_PERF_STAGE "):
            continue
        row = re.fullmatch(r"C1_PERF_STAGE job=(\d+) stage=(\d+) cycles=(\d+) dot_beats=\d+ dw_beats=\d+ mem_read=\d+ mem_write=\d+ columns=\d+", line)
        if row is None:
            raise ValueError("malformed layer residency witness")
        job, stage, cycles = map(int, row.groups())
        if not 0 <= stage < 22 or cycles <= 0 or (job, stage) in targets:
            raise ValueError("invalid/duplicate layer residency witness")
        targets[job, stage] = cycles
    jobs = {job for job, _ in targets}
    if not jobs or any({stage for owner, stage in targets if owner == job} != set(range(22)) for job in jobs):
        raise ValueError("layer FSM profile needs all 22 stage witnesses per successful job")
    counts = defaultdict(dict)
    for line in records:
        row = ROW.fullmatch(line)
        if row is None:
            raise ValueError("malformed layer FSM record")
        job, stage, side, state, cycles = int(row[1]), int(row[2]), row[3], int(row[4]), int(row[5])
        key = (job, stage, side)
        if ((job, stage) not in targets or cycles <= 0 or
                not 0 <= state < (20 if side == "engine" else 32) or state in counts[key]):
            raise ValueError("layer FSM record has unknown job/stage/state, duplicate bin or invalid count")
        counts[key][state] = cycles
    for (job, stage), cycles in targets.items():
        for side in ("engine", "adapter"):
            if sum(counts[job, stage, side].values()) != cycles:
                raise ValueError("layer FSM residency does not cover each cycle exactly once per side")
    # A second, independently accumulated adapter histogram checks the sum
    # across stages. Ignore failed-job global bins, which have no stage rows.
    globals_ = {}
    for line in lines:
        if not line.startswith("C1_PERF_ADAPTER "):
            continue
        row = re.fullmatch(r"C1_PERF_ADAPTER job=(\d+) state=(\d+) cycles=(\d+) input_wait=\d+ result_stall=\d+", line)
        if row is None:
            raise ValueError("malformed global adapter histogram")
        job, state, cycles = map(int, row.groups())
        if job not in jobs:
            continue
        if (job, state) in globals_ or not 0 <= state < 32 or cycles <= 0:
            raise ValueError("invalid/duplicate global adapter histogram bin")
        globals_[job, state] = cycles
    for job in jobs:
        for state in range(32):
            if sum(counts[job, stage, "adapter"].get(state, 0) for stage in range(22)) != globals_.get((job, state), 0):
                raise ValueError("layer adapter FSM bins disagree with independent job histogram")
    return dict(counts)
