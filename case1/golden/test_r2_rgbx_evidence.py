"""Verifier tests only: synthetic intervals are NOT hardware performance data."""
import unittest
from check_r2_rgbx_system_evidence import throughput,require_throughput

class ThroughputTests(unittest.TestCase):
    def evaluate(self,intervals,native=True):
        return throughput({'completion_intervals':intervals},native)

    def test_single_full_load_sample(self):
        r=self.evaluate([9600000,9900000])
        self.assertEqual(r['full_load_interval_samples'],1)
        require_throughput(r,1)
        with self.assertRaisesRegex(ValueError,'insufficient'):require_throughput(r,4)

    def test_all_four_samples_at_deadline(self):
        r=self.evaluate([8000000,10000000,10000000,10000000,10000000])
        self.assertEqual(r['worst_full_load_interval_fps_at_150mhz'],15)
        require_throughput(r,4)

    def test_fast_last_frame_cannot_hide_earlier_miss(self):
        r=self.evaluate([9000000,10000001,9500000,9500000,9000000])
        self.assertGreater(r['last_interval_fps_at_150mhz'],15)
        self.assertLess(r['worst_full_load_interval_fps_at_150mhz'],15)
        with self.assertRaisesRegex(ValueError,'at least one'):require_throughput(r,4)

    def test_fast_average_cannot_hide_middle_miss(self):
        r=self.evaluate([8000000,8000000,12000000,8000000,8000000])
        with self.assertRaises(ValueError):require_throughput(r,4)

    def test_only_partly_loaded_interval_excluded(self):
        r=self.evaluate([20000000,9900000,9950000,9800000,9700000])
        self.assertEqual(len(r['full_load_completion_intervals']),4)
        require_throughput(r,4)

    def test_small_shape_never_a_native_fps_claim(self):
        r=self.evaluate([15000,16000,17000,18000,19000],False)
        self.assertIsNone(r['meets_15fps'])
        self.assertIsNone(r['last_interval_fps_at_150mhz'])
        with self.assertRaises(ValueError):require_throughput(r,1)

    def test_absent_native_full_load_sample_rejected(self):
        with self.assertRaises(ValueError):self.evaluate([9900000])

    def test_nonpositive_interval_rejected(self):
        for intervals in ([],[1,0],[1,-1]):
            with self.subTest(intervals=intervals),self.assertRaises(ValueError):self.evaluate(intervals)

if __name__=='__main__':unittest.main()
