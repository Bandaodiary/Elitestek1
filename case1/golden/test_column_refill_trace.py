"""Independent column credit/count contracts; no EDA or fitted cycle fixture."""
from collections import Counter
from pathlib import Path
import re
import sys
import unittest

from check_column_refill_trace import (
    MODE, PROGRESS, BURSTS, STAGE_MODE, STAGE_ROW, refill_budget,
    check_column_refill, check_column_stage, column_refill_mutations,
)


def fixture(window=32, handoff=1, jobs=1, virtual=True, pointwise=True):
    budget = refill_budget(8, 8, virtual, pointwise)
    commands, words = map(sum, zip(*budget))
    peak = min(window, max(n // rows for rows, n in budget if rows))
    bins = Counter()
    for rows, n in budget:
        if rows:
            # Small synthetic rows fit a single AXI burst, including odd C8.
            bins[(n // rows + 1) // 2] += rows
    ar, beats = sum(bins.values()), sum(b*n for b, n in bins.items())
    lines = [f"{MODE} version=2 window={window} req_depth=32 rsp_depth=128 beat_mode=0 handoff={handoff}",
             "C1_NUM_COLUMN_OPTION enabled=1 clients=8",
             STAGE_MODE + " version=1 includes_setup=1 stage_source=adapter"]
    if virtual:
        lines.append("C1_NUM_VIRTUAL_UPSAMPLE enabled=1")
    if pointwise:
        lines.append("C1_NUM_POINTWISE_COLUMN_READS enabled=1")
    for job in range(1, jobs+1):
        lines.append(f"C1_PERF_JOB job={job} elapsed=12345 error=0")
        lines.append(f"{PROGRESS} job={job} requests={words} responses={words} handoffs={10*handoff} adjacent={9*handoff} req_peak=1 rsp_peak=2 meta_peak={peak} credit_peak={peak} ar={ar} beats={beats}")
        for length, count in sorted(bins.items()):
            lines.append(f"{BURSTS} job={job} beats={length} count={count}")
        for stage, (rows, n) in enumerate(budget):
            columns = n
            cycles = 4 + rows + 2*n + columns
            lines.append(f"C1_PERF_STAGE job={job} stage={stage} cycles={cycles} dot_beats=0 dw_beats=0 mem_read=0 mem_write=0 columns={columns}")
            lines.append(f"{STAGE_ROW} job={job} stage={stage} idle=3 lookup=1 req={rows} data={2*n} read=0 capture={columns} response=0 refill_commands={rows} refill_words={n}")
    return "\n".join(lines) + "\n"


def stage_mutations(log):
    cases = {}
    for i, row in enumerate(s for s in log.splitlines() if s.startswith((STAGE_MODE, STAGE_ROW))):
        cases[f"missing_{i}"] = log.replace(row+"\n", "", 1)
        cases[f"duplicate_{i}"] = log.replace(row, row+"\n"+row, 1)
        if row.startswith(STAGE_ROW):
            for field in ("job", "stage", "idle", "lookup", "req", "data", "read", "capture", "response", "refill_commands", "refill_words"):
                bad = re.sub(rf"\b{field}=(\d+)", lambda m: f"{field}={int(m[1])+1}", row)
                cases[f"field_{i}_{field}"] = log.replace(row, bad, 1)
    return cases


class ColumnRefillTest(unittest.TestCase):
    def test_profiles_and_historical(self):
        self.assertIsNone(check_column_refill("historical log", 8, 8, 1))
        for handoff in (0, 1):
            for window in (16, 32):
                for jobs in (1, 2):
                    with self.subTest(window=window, handoff=handoff, jobs=jobs):
                        self.assertEqual(check_column_refill(fixture(window,handoff,jobs),8,8,jobs), (window,handoff))
        with self.assertRaises(ValueError):
            check_column_refill("historical log", 8, 8, 1, (32,1))

    def test_descriptor_budgets(self):
        # These totals are independently observed full physical C8 workloads.
        self.assertEqual(sum(w for _,w in refill_budget(64,48,True,True)),26880)
        self.assertEqual(sum(w for _,w in refill_budget(8,8,True,True)),560)
        for virtual in (False,True):
            for pointwise in (False,True):
                self.assertTrue(check_column_stage(fixture(virtual=virtual,pointwise=pointwise),8,8,True))

    def test_trace_mutations(self):
        log=fixture()
        for name, changed in column_refill_mutations(log).items():
            with self.subTest(name=name), self.assertRaises(ValueError):
                check_column_stage(changed,8,8,True)
                check_column_refill(changed,8,8,1,(32,1))

    def test_all_stage_fields(self):
        log=fixture()
        for name, changed in stage_mutations(log).items():
            with self.subTest(name=name), self.assertRaises(ValueError):
                check_column_stage(changed,8,8,True)

    def test_independent_required_mode(self):
        for changed in (fixture(16,1),fixture(32,0)):
            with self.assertRaises(ValueError):
                check_column_refill(changed,8,8,1,(32,1))

    def test_wrong_owner_and_malformed_fields(self):
        log=fixture(jobs=2)
        for before,after in (("job=2","job=1"),("job=2","job=0"),
                             ("version=2","version=3"),("window=32","window=0"),
                             ("req_depth=32","req_depth=1"),("rsp_depth=128","rsp_depth=1"),
                             ("beat_mode=0","beat_mode=2"),("clients=8","clients=7"),
                             ("handoffs=10","handoffs=0"),("adjacent=9","adjacent=11"),
                             ("credit_peak=16","credit_peak=17")):
            with self.subTest(before=before), self.assertRaises(ValueError):
                check_column_refill(log.replace(before,after),8,8,2,(32,1))

    def test_v1_explicit_compatibility(self):
        log=fixture().replace("version=2", "version=1")
        with self.assertRaises(ValueError):
            check_column_refill(log,8,8,1)
        log="\n".join(s for s in log.splitlines() if not s.startswith(BURSTS))
        self.assertEqual(check_column_refill(log,8,8,1), (32,1))

    def test_equal_sum_cannot_hide_wrong_capture_or_budget(self):
        log=fixture()
        row=next(s for s in log.splitlines() if s.startswith(STAGE_ROW))
        capture=int(re.search(r"capture=(\d+)",row)[1])
        changed=row.replace("idle=3","idle=2").replace(f"capture={capture}",f"capture={capture+1}")
        with self.assertRaises(ValueError):
            check_column_stage(log.replace(row,changed),8,8,True)
        # Reassign a refill word to its adjacent layer, preserving global sum.
        with self.assertRaises(ValueError):
            check_column_stage(log.replace("refill_words=64","refill_words=63",1),8,8,True)

    def test_v1_mutations_only_claim_provable_failures(self):
        log="\n".join(s for s in fixture().replace("version=2","version=1").splitlines()
                      if not s.startswith(BURSTS))+"\n"
        check_column_refill(log,8,8,1,(32,1))
        for name,changed in column_refill_mutations(log).items():
            with self.subTest(name=name), self.assertRaises(ValueError):
                check_column_stage(changed,8,8,True)
                check_column_refill(changed,8,8,1,(32,1))


def audit_trace(path):
    log=path.read_text(encoding="utf-8-sig")
    # This inexpensive audit only handles the recorded 64x48 profile.
    baseline=check_column_refill(log,64,48,1,require_mode=True)
    check_column_stage(log,64,48,True)
    cases={**stage_mutations(log),**column_refill_mutations(log)}
    for name,changed in cases.items():
        if changed==log:
            raise AssertionError(f"ineffective mutation: {name}")
        try:
            check_column_stage(changed,64,48,True)
            check_column_refill(changed,64,48,1,baseline)
        except ValueError:
            continue
        raise AssertionError(f"invalid column contract accepted: {name}")
    print(f"C1_COLUMN_REFILL_TRACE_AUDIT_PASS stage_records=22 mutations={len(cases)}")


if __name__=="__main__":
    if len(sys.argv)==3 and sys.argv[1]=="--trace":
        audit_trace(Path(sys.argv[2]))
    else:
        unittest.main()
