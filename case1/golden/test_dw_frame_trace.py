import unittest

from check_dw_frame_trace import MODE, PROGRESS, check_dw_frame, dw_frame_mutations


def fixture(warm=5, continues=82):
    return (f"{MODE} enabled=1\nC1_NUM_DW_PIXEL_PIPELINE enabled=1\nC1_NUM_DW_STREAM enabled=1\n"
            "C1_PERF_JOB job=1 error=0\n"
            f"{PROGRESS} job=1 cold_starts=23 warm_starts={warm} continues={continues} "
            f"input_eofs={23+warm} output_eofs={23+warm} held_continues=0\n")


class DwFrameTest(unittest.TestCase):
    def test_valid_and_legacy(self):
        self.assertTrue(check_dw_frame(fixture(), 8, 8, 1, True))
        self.assertTrue(check_dw_frame(fixture(5, 4406), 64, 48, 1, True))
        self.assertFalse(check_dw_frame("old trace", 8, 8, 1))
        self.assertFalse(check_dw_frame(MODE + " enabled=0", 8, 8, 1))

    def test_one_pixel_cold_layers(self):
        # Three low-resolution DW layers are only one pixel, so those layers
        # never enter a warm batch. No fabricated warm start/continuation.
        self.assertTrue(check_dw_frame(fixture(2, 16), 4, 4, 1, True))

    def test_mutations(self):
        for name, log in dw_frame_mutations(fixture()).items():
            with self.subTest(name=name), self.assertRaises(ValueError):
                check_dw_frame(log, 8, 8, 1, True, True)

    def test_prerequisites_and_disabled_activity(self):
        for prefix in (MODE, "C1_NUM_DW_PIXEL_PIPELINE", "C1_NUM_DW_STREAM"):
            with self.subTest(prefix=prefix), self.assertRaises(ValueError):
                check_dw_frame(fixture().replace(prefix + " enabled=1", prefix + " enabled=0"), 8, 8, 1)
        for replacement in ("", "job=0", "job=x"):
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                check_dw_frame(fixture().replace("C1_PERF_JOB job=1", "C1_PERF_JOB " + replacement), 8, 8, 1)


if __name__ == "__main__":
    unittest.main()
