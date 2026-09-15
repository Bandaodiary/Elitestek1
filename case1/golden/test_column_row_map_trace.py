import unittest
from check_column_row_map_trace import check_column_row_map, row_map_mutations


def fixture(enabled=1, jobs=(1,)):
    rows = [f"C1_NUM_COLUMN_ROW_MAP enabled={enabled}", "C1_NUM_COLUMN_OPTION enabled=1 clients=9"]
    for job in jobs:
        rows += [f"C1_PERF_START job={job} cycle=1",
                 f"C1_PERF_COLUMN_ROW_MAP job={job} accepted=10 eligible=8 reused={8*enabled} normal={10-8*enabled} ram_reads=10",
                 f"C1_PERF_COLUMNS job={job} accepted=10 retired=10",
                 f"C1_PERF_JOB job={job} error=0"]
    return "\n".join(rows) + "\n"


class RowMapTraceTest(unittest.TestCase):
    def test_valid_modes_and_multiple_jobs(self):
        for mode in (0, 1):
            for jobs in ((1,), (1, 2), (2,)):
                self.assertEqual(check_column_row_map(fixture(mode, jobs), len(jobs)), bool(mode))

    def test_mutations(self):
        for mode in (0, 1):
            for jobs in ((1,), (1, 2)):
                for name, changed in row_map_mutations(fixture(mode, jobs)).items():
                    with self.subTest(mode=mode, jobs=jobs, mutation=name):
                        with self.assertRaises(ValueError):
                            check_column_row_map(changed, len(jobs), bool(mode), require_mode=True)

    def test_historical_and_disabled_branch(self):
        self.assertFalse(check_column_row_map("", 1))
        self.assertFalse(check_column_row_map("C1_NUM_COLUMN_ROW_MAP enabled=0\nC1_NUM_COLUMN_OPTION enabled=0 clients=7\n", 1))
        for required in (False, True):
            with self.assertRaises(ValueError):
                check_column_row_map("", 1, required, require_mode=True)

    def test_missing_branch_and_retirement(self):
        log = fixture()
        for before, after in (("enabled=1 clients=9", "enabled=0 clients=9"),
                              ("retired=10", "retired=9"), ("job=1 error=0", "job=1 error=1")):
            with self.assertRaises(ValueError):
                check_column_row_map(log.replace(before, after), 1)

    def test_disabled_branch_requires_zero_real_activity(self):
        log=("C1_NUM_COLUMN_ROW_MAP enabled=0\nC1_NUM_COLUMN_OPTION enabled=0 clients=7\n"
             "C1_PERF_START job=1 cycle=1\n"
             "C1_PERF_COLUMN_ROW_MAP job=1 accepted=0 eligible=0 reused=0 normal=0 ram_reads=0\n"
             "C1_PERF_COLUMNS job=1 accepted=0 retired=0\nC1_PERF_JOB job=1 error=0\n")
        self.assertFalse(check_column_row_map(log,1))
        for name,changed in row_map_mutations(log).items():
            with self.subTest(name=name):
                with self.assertRaises(ValueError):check_column_row_map(changed,1,require_mode=True)


if __name__ == "__main__":
    unittest.main()
