"""Bounded positive/negative residency checks without a generated simulation."""
import unittest
from pathlib import Path
import sys

from check_stage_fsm_trace import HEADER, check_stage_fsm


def fixture():
    lines = [HEADER]
    for stage in range(22):
        lines.append(f"C1_PERF_STAGE job=1 stage={stage} cycles=5 dot_beats=0 dw_beats=0 mem_read=0 mem_write=0 columns=0")
        for side, state in (("engine", 8), ("adapter", 11)):
            lines.append(f"C1_PERF_STAGE_FSM job=1 stage={stage} side={side} state={state} cycles=5")
    lines.append("C1_PERF_ADAPTER job=1 state=11 cycles=110 input_wait=0 result_stall=0")
    return "\n".join(lines) + "\n"


class StageFsmTest(unittest.TestCase):
    def test_valid_and_historical(self):
        self.assertEqual(len(check_stage_fsm(fixture(), True)), 44)
        self.assertEqual(check_stage_fsm("old trace"), {})
        with self.assertRaises(ValueError):
            check_stage_fsm("old trace", True)

    def test_header_and_missing_records(self):
        log = fixture()
        for replacement in ("", HEADER + "\n" + HEADER, HEADER.replace("version=1", "version=2")):
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                check_stage_fsm(log.replace(HEADER, replacement))
        with self.assertRaises(ValueError):
            check_stage_fsm(HEADER)

    def test_every_missing_and_duplicate_bin(self):
        log = fixture()
        for row in log.splitlines():
            if not row.startswith("C1_PERF_STAGE_FSM "):
                continue
            for replacement in ("", row + "\n" + row):
                with self.subTest(row=row, replacement=replacement), self.assertRaises(ValueError):
                    check_stage_fsm(log.replace(row, replacement))

    def test_bad_fields_and_global_histogram(self):
        log = fixture()
        row = "C1_PERF_STAGE_FSM job=1 stage=0 side=engine state=8 cycles=5"
        for field, value in (("job=1", "job=2"), ("stage=0", "stage=22"),
                             ("side=engine", "side=core"), ("state=8", "state=20"),
                             ("cycles=5", "cycles=0"), ("cycles=5", "cycles=6")):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                check_stage_fsm(log.replace(row, row.replace(field, value)))
        with self.assertRaises(ValueError):
            check_stage_fsm(log.replace("cycles=110", "cycles=111"))
        # Same per-stage sum, different state: global independent bins reject it.
        with self.assertRaises(ValueError):
            check_stage_fsm(log.replace("side=adapter state=11", "side=adapter state=12", 1))

    def test_missing_stage_witness(self):
        log = fixture()
        row = next(s for s in log.splitlines() if s.startswith("C1_PERF_STAGE "))
        for replacement in ("", row + "\n" + row):
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                check_stage_fsm(log.replace(row, replacement))


def audit_trace(path: Path):
    log = path.read_text(encoding="utf-8-sig")
    check_stage_fsm(log, True)
    count = 0
    # Run the cheap, independent residency checker for every real bin; do
    # not run the full image golden hundreds of extra times for a histogram.
    targets = [s for s in log.splitlines() if s.startswith(("C1_NUM_STAGE_FSM", "C1_PERF_STAGE_FSM"))]
    for row in targets:
        for changed in (log.replace(row + "\n", "", 1), log.replace(row, row + "\n" + row, 1)):
            if changed == log:
                raise AssertionError("layer FSM mutation did not change its input")
            try:
                check_stage_fsm(changed, True)
            except ValueError:
                count += 1
            else:
                raise AssertionError("layer FSM checker accepted a missing/duplicate real bin")
    print(f"C1_STAGE_FSM_TRACE_AUDIT_PASS records={len(targets)-1} mutations={count}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--trace":
        audit_trace(Path(sys.argv[2]))
    else:
        unittest.main()
