"""Small, read-only contract tests; no new-profile RTL success is implied."""
import copy
import json
from pathlib import Path
import sys
import unittest

import psutil
process=psutil.Process()
process.cpu_affinity([max(process.cpu_affinity())])
process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)

from check_r2_trained_pipeline import predecessor_contract
from check_r2_trained_host_evidence import check_text
from r2_camera_cadence_contract import ROOT,TOP,PREFIX,assess,profile,render_testbench


class CameraCadenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.real=(ROOT/'logs/r2_trained_host_runs/c36_b_trained_host_20260915b/native_xsim.result.log').read_text(encoding='utf-8-sig')
        cls.config=dict(blocks=2,expansion=24,preproject=True)

    def test_real_legacy_keeps_cnn_intervals_but_not_30_capture(self):
        result=check_text(self.real,self.config,6)
        camera=assess(self.real)
        self.assertEqual(max(result['completion_intervals']),6396012)
        self.assertFalse(camera['capture_30fps_met_for_observed_intervals'])
        self.assertAlmostEqual(camera['min_observed_capture_fps_at_nominal_core'],29.25704655966)

    def test_real_legacy_cannot_be_relabelled_camera30(self):
        with self.assertRaises(ValueError):
            assess(self.real,'camera30')
        with self.assertRaises((ValueError,AssertionError)):
            check_text(self.real,self.config,6,camera_profile='camera30')

    def test_disagreeing_rgb2_period_rejected(self):
        damaged=self.real.replace('source_period_camera_cycles=1196052','source_period_camera_cycles=1196053')
        self.assertNotEqual(damaged,self.real)
        with self.assertRaises((ValueError,AssertionError)):
            check_text(damaged,self.config,6)

    def test_slow_completion_cannot_be_hidden_by_fast_source(self):
        cfg=profile('camera30');period=cfg['source_period_camera_cycles']
        lines=[PREFIX+f'CAMERA frames=3 source_sof_cycles={period}',
               PREFIX+f'RGB2 frame_divisor=1 source_period_camera_cycles={period}',
               PREFIX+f"PASS native_timing=1 captures=3 camera_period={cfg['camera_period_summary']}"]
        for i in range(3):
            core=round(i*period*14286/6666)
            lines.append(PREFIX+f'SOURCE_SOF tag={i} camera_cycle={i*period} core_cycle={core}')
            # An intentionally delayed middle completion; not real evidence.
            lines.append(PREFIX+f'CAPTURE tag={i} words=76800 cycle={core+1000+(100000 if i==1 else 0)}')
        result=assess('\n'.join(lines),'camera30')
        self.assertGreater(result['eligible_fps_at_nominal_core'],30)
        self.assertFalse(result['capture_30fps_met_for_observed_intervals'])

    def test_camera_variant_preserves_all_other_testbench_lines(self):
        original=(ROOT/'sim'/f'{TOP}.sv').read_text(encoding='utf-8-sig')
        changed,metadata=render_testbench(original,'camera30')
        differences=[(a,b) for a,b in zip(original.splitlines(),changed.splitlines()) if a!=b]
        self.assertEqual(len(original.splitlines()),len(changed.splitlines()))
        self.assertEqual(len(differences),2)
        self.assertFalse(metadata['production_RTL_changed'])
        self.assertFalse(metadata['RTL_compiled'])
        self.assertEqual(metadata['frame_divisor'],1)

    def test_predecessor_phase_and_identity(self):
        for skip in (False,True):
            phase='small' if skip else 'native'
            prior=dict(run_id='prior',worker_pid=12345,worker_start='synthetic-start',skip_native=skip,
                       state='complete',exit_code=0,simulator_directory_present=False,worker_in_windows_job=False)
            status=dict(after_run='prior',predecessor=dict(run='prior',worker_pid=12345,worker_start='synthetic-start',
                        strict_native_preflight_required=not skip,strict_preflight_phase=phase),
                        completed_steps=[dict(name='predecessor_'+phase+'_preflight',exit_code=0,in_windows_job=False,
                                              free_memory_kib_at_phase_admission=8388608)])
            self.assertEqual(predecessor_contract(status,prior),phase)
            if not skip:
                old=copy.deepcopy(status);del old['predecessor']['strict_preflight_phase']
                self.assertEqual(predecessor_contract(old,prior),'native')
            for key,value in (('state','running'),('exit_code',1),('skip_native',not skip),
                              ('worker_pid',12346),('worker_start','different'),('simulator_directory_present',True)):
                with self.subTest(skip=skip,key=key):
                    damaged=dict(prior);damaged[key]=value
                    with self.assertRaises(ValueError):
                        predecessor_contract(status,damaged)
            missing=copy.deepcopy(status);missing['completed_steps']=[]
            with self.assertRaises(ValueError):
                predecessor_contract(missing,prior)


if __name__=='__main__':
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(CameraCadenceTests)
    outcome=unittest.TextTestRunner(verbosity=2).run(suite)
    if not outcome.wasSuccessful():
        sys.exit(1)
    print('C36_CAMERA_PIPELINE_UNIT_PASS '+json.dumps(dict(tests=outcome.testsRun,
        legacy_real_CNN_evidence_preserved=True,legacy_not_30fps=True,
        predecessor_mutations_rejected=14,new_profile_RTL_run=False),separators=(',',':')))
