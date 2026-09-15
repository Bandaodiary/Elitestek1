"""Column backend credits/bursts and layer refill attribution; no fitted fps."""
import re

from microstyle_workload import build_layout

MODE = "C1_NUM_COLUMN_REFILL"
PROGRESS = "C1_PERF_COLUMN_REFILL"
BURSTS = "C1_PERF_COLUMN_BURSTS"
STAGE_MODE = "C1_NUM_COLUMN_STAGE"
STAGE_ROW = "C1_PERF_COLUMN_STAGE"


def refill_budget(width, height, virtual, pointwise):
    descriptors, _ = build_layout(width, height)
    budget = []
    for stage, d in enumerate(descriptors):
        use = d.opcode in (1, 3) or (pointwise and d.opcode == 2)
        divisor = 2 if virtual and stage in (15, 18) else 1
        rows = d.input_height // divisor if use else 0
        row_words = (d.input_width // divisor) * ((d.input_channels + 7) // 8) if use else 0
        budget.append((rows, rows * row_words))
    return budget


def check_column_stage(log, width, height, required=False):
    lines = log.splitlines()
    headers = [s for s in lines if s.startswith(STAGE_MODE)]
    records = [s for s in lines if s.startswith(STAGE_ROW)]
    if not headers and not records and not required:
        return False
    if headers != [STAGE_MODE + " version=1 includes_setup=1 stage_source=adapter"]:
        raise ValueError("missing/duplicate/invalid column stage header")
    virtual = "C1_NUM_VIRTUAL_UPSAMPLE enabled=1" in lines
    pointwise = "C1_NUM_POINTWISE_COLUMN_READS enabled=1" in lines
    budget = refill_budget(width, height, virtual, pointwise)
    targets = {}
    for line in lines:
        if line.startswith("C1_PERF_STAGE "):
            row = re.fullmatch(r"C1_PERF_STAGE job=(\d+) stage=(\d+) cycles=(\d+) dot_beats=\d+ dw_beats=\d+ mem_read=\d+ mem_write=\d+ columns=(\d+)", line)
            if row is None:
                raise ValueError("malformed column stage residency target")
            job, stage, cycles, columns = map(int, row.groups())
            if job <= 0 or not 0 <= stage < 22 or (job, stage) in targets:
                raise ValueError("invalid/duplicate column stage residency target")
            targets[job, stage] = cycles, columns
    ids = {job for job, _ in targets}
    if not ids or len(targets) != len(ids)*22 or len(records) != len(targets):
        raise ValueError("column stage profile lacks complete successful layer witnesses")
    seen = set()
    for line in records:
        row = re.fullmatch(STAGE_ROW + r" job=(\d+) stage=(\d+) idle=(\d+) lookup=(\d+) req=(\d+) data=(\d+) read=(\d+) capture=(\d+) response=(\d+) refill_commands=(\d+) refill_words=(\d+)", line)
        if row is None:
            raise ValueError("malformed column stage profile")
        job, stage, *values = map(int, row.groups())
        if (job, stage) not in targets or (job, stage) in seen:
            raise ValueError("column stage profile duplicated or changed ownership")
        seen.add((job, stage))
        cycles, columns = targets[job, stage]
        if (sum(values[:7]) != cycles or values[5] != columns or
                tuple(values[7:]) != budget[stage] or values[2] < values[7] or values[3] < values[8]):
            raise ValueError("column stage cycles/columns/descriptor refill budget disagree")
    return True


def check_column_refill(log, width, height, jobs, expected=None, require_mode=False):
    lines = log.splitlines()
    check_column_stage(log, width, height)
    headers = [s for s in lines if s.startswith(MODE)]
    records = [s for s in lines if s.startswith(PROGRESS)]
    hist = [s for s in lines if s.startswith(BURSTS)]
    if not headers and not records and not hist and expected is None and not require_mode:
        return None
    row = re.fullmatch(MODE + r" version=([12]) window=(\d+) req_depth=(\d+) rsp_depth=(\d+) beat_mode=([01]) handoff=([01])", headers[0]) if len(headers) == 1 else None
    if row is None:
        raise ValueError("missing/duplicate/invalid actual column refill mode")
    version, window, req_depth, rsp_depth, beat_mode, handoff = map(int, row.groups())
    if not 1 <= window <= 255 or not 2 <= req_depth <= 255 or rsp_depth < (1 if beat_mode else 2):
        raise ValueError("invalid column refill storage/credit configuration")
    if expected is not None and (window, handoff) != tuple(expected):
        raise ValueError("column refill configuration differs from independently required profile")
    if "C1_NUM_COLUMN_OPTION enabled=1 clients=8" not in lines:
        raise ValueError("column refill profile refers to an inactive backend")
    budget = refill_budget(width, height, "C1_NUM_VIRTUAL_UPSAMPLE enabled=1" in lines,
                           "C1_NUM_POINTWISE_COLUMN_READS enabled=1" in lines)
    commands, words = map(sum, zip(*budget))
    max_row_words = max(words_in_rowset//rows for rows, words_in_rowset in budget if rows)
    ids = []
    for line in lines:
        if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b", line):
            row = re.search(r"\bjob=(\d+)\b", line)
            if row is None or int(row[1]) <= 0:
                raise ValueError("column refill job lacks positive owner id")
            ids.append(int(row[1]))
    if len(ids) != jobs or len(set(ids)) != jobs or len(records) != jobs:
        raise ValueError("column refill requires one summary per unique successful job")
    bins = {}
    for line in hist:
        row = re.fullmatch(BURSTS + r" job=(\d+) beats=(\d+) count=(\d+)", line)
        if row is None:
            raise ValueError("malformed column burst histogram")
        job, beats, count = map(int, row.groups())
        if job not in ids or not 1 <= beats <= 16 or count <= 0 or (job, beats) in bins:
            raise ValueError("invalid/duplicate column burst bin or owner")
        bins[job, beats] = count
    if version == 1 and hist:
        raise ValueError("v1 exploration trace unexpectedly has v2 burst bins")
    for job, line in zip(ids, records):
        row = re.fullmatch(PROGRESS + r" job=(\d+) requests=(\d+) responses=(\d+) handoffs=(\d+) adjacent=(\d+) req_peak=(\d+) rsp_peak=(\d+) meta_peak=(\d+) credit_peak=(\d+) ar=(\d+) beats=(\d+)", line)
        if row is None:
            raise ValueError("malformed column refill progress")
        owner, req, rsp, transfers, adjacent, req_peak, rsp_peak, meta_peak, credit_peak, ar, beats = map(int, row.groups())
        if (owner, req, rsp) != (job, words, words):
            raise ValueError("column requests/responses differ from complete physical input tensor budget")
        if not (0 < req_peak <= min(req_depth, meta_peak) and 0 < rsp_peak <= min(rsp_depth, meta_peak) and
                0 < meta_peak <= credit_peak <= min(window, max_row_words, meta_peak+1)):
            raise ValueError("column accepted/pending credit or FIFO peak exceeds capacity")
        if not 0 <= adjacent <= transfers <= words-commands or (not handoff and (transfers or adjacent)) or (handoff and (transfers == 0 or adjacent == 0)):
            raise ValueError("column continuous handoff missing or exceeds real requests")
        if not (commands <= ar <= beats <= words and (words+1)//2 <= beats <= 16*ar):
            raise ValueError("column physical AR/R count violates word/burst bounds")
        if version == 2 and (sum(n for (j, _), n in bins.items() if j == job) != ar or
                sum(b*n for (j, b), n in bins.items() if j == job) != beats):
            raise ValueError("column real R beats/AR count disagree with independent burst histogram")
    return window, handoff


def column_refill_mutations(log):
    cases = {}
    targets = [s for s in log.splitlines() if s.startswith((MODE, PROGRESS, BURSTS, STAGE_MODE))]
    for i, row in enumerate(targets):
        for kind, replacement in (("missing", ""), ("duplicate", row+"\n"+row)):
            cases[f"column_refill_{kind}_{i}"] = log.replace(row+"\n", replacement+"\n", 1)
    cases["column_refill_all_removed"] = "\n".join(s for s in log.splitlines() if not s.startswith((MODE, PROGRESS, BURSTS)))+"\n"
    for i, row in enumerate(s for s in targets if s.startswith(PROGRESS)):
        for field in ("job", "requests", "responses", "ar", "beats"):
            # V1 has only count bounds, not an independent ARLEN histogram.
            # A one-beat/one-burst change may be a different valid transaction
            # shape; do not claim it is provably invalid without a witness.
            increment = 99999999 if MODE+" version=1 " in log and field in ("ar","beats") else 1
            cases[f"column_refill_bad_{i}_{field}"] = log.replace(row, re.sub(rf"\b{field}=(\d+)", lambda m: f"{field}={int(m[1])+increment}", row), 1)
        for field in ("req_peak", "rsp_peak", "meta_peak", "credit_peak", "handoffs", "adjacent"):
            cases[f"column_refill_bound_{i}_{field}"] = log.replace(row, re.sub(rf"\b{field}=\d+", field+"=99999999", row), 1)
    return cases
