"""Read-only checks of sized SoC fixtures and rejection of incompatible artifacts."""
import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import numpy as np

from prepare_portable_soc_trained_fixture import build_fixture
from check_portable_soc_numerical_trace import camera_fixture_rgb,check_stage0_profile
from microstyle_workload import workload
from check_source_write_pipeline_trace import check_source_writes, source_write_mutations
from check_pointwise_reduction_trace import check_pointwise_reduction, pointwise_reduction_mutations
from check_mac_requant_overlap_trace import check_requant_overlap, requant_overlap_mutations
from check_pixel_column_prefetch_trace import all_pixel_groups_enabled
from check_dot_pixel_pipeline_trace import check_dot_pixel_pipeline, dot_pixel_mutations, all_dot_groups_enabled,check_all_dot_abort
from check_tensor_write_mlp_trace import check_tensor_write_mlp,tensor_mlp_mutations
from check_pixel_write_batch_trace import batch_budget,check_pixel_write_batch,pixel_batch_mutations
from check_dw_pixel_pipeline_trace import dw_pixel_budget,check_dw_pixel_pipeline,dw_pixel_mutations
from check_rgb_reduction_trace import check_rgb_reduction,rgb_reduction_mutations
from check_view_elision_trace import check_view_elision,view_elision_mutations


class TrainedFixtureTest(unittest.TestCase):
    artifact = Path(__file__).resolve().parents[1] / "model/microstyle24_starry_functional"

    def test_view_workload_and_unchanged_artifact(self):
        for w,h in ((8,8),(64,48),(640,480)):
            old=workload(w,h,virtual_upsample=True,pack_rgb_reduction=True)
            new=workload(w,h,virtual_upsample=True,pack_rgb_reduction=True,elide_views=True)
            removed=sum(s["C8_results"] for s in old["stages"] if s["stage"] in (14,17))
            self.assertEqual(old["minimum_cycles"]-new["minimum_cycles"],removed)
            self.assertEqual(old["useful_macs"],new["useful_macs"])
            for a,b in zip(old["stages"],new["stages"]):
                if a["stage"] not in (14,17):self.assertEqual(a,b)
                else:
                    self.assertEqual(b["logical_C8_results"],a["C8_results"])
                    for key in ("C8_results","dot_beats","dw_beats","scalar_writes","scalar_reads_with_columns","linear_beats"):
                        self.assertEqual(b[key],0)
            if w<640:
                desc,arena,logical=build_fixture(self.artifact,w,h)
                desc2,arena2,physical=build_fixture(self.artifact,w,h,elide_views=True)
                self.assertEqual(desc,desc2)
                self.assertEqual(arena,arena2)
                self.assertEqual(logical["C8_results"]-physical["C8_results"],removed)
                self.assertEqual(physical["logical_C8_results"],logical["C8_results"])
        self.assertEqual(workload(640,480,virtual_upsample=True,pack_rgb_reduction=True,elide_views=True)["minimum_cycles"],9235200)
        with self.assertRaises(ValueError):workload(8,8,elide_views=True)

    def test_view_trace_lifetime_and_mutations(self):
        for enabled in (False,True):
            for jobs in (1,2):
                for stopped in (False,True):
                    log=f"C1_NUM_VIEW_ELISION enabled={int(enabled)}\nC1_NUM_VIRTUAL_UPSAMPLE enabled=1\nC1_NUM_COLUMN_OPTION enabled=1 clients=8\n"
                    for job in range(1,jobs+int(stopped)+1):
                        stop=stopped and job==1
                        log+=f"C1_PERF_START job={job} cycle=10\n"
                        if enabled:
                            log+=f"C1_VIEW_CONTEXT job={job} generation={job}\n"
                            stages=workload(8,8)["stages"]
                            for stage in ((14,) if stop else (14,17)):
                                t=stages[stage]
                                log+=f"C1_VIEW_COMMIT job={job} stage={stage} generation={job} input_bank=0 output_bank=3 width={t['output_width']//2} height={t['output_height']//2} groups={t['input_groups']} debt=0\n"
                        if stop:
                            log+=f"C1_VIEW_STOP job={job} generation={job} views={int(enabled)}\nC1_PERF_ABORT job={job} cycle=20\n"
                        else:
                            log+=f"C1_PERF_VIEW_ELISION job={job} generation={job} views={2*int(enabled)}\nC1_PERF_JOB job={job} error=0\n"
                    self.assertEqual(check_view_elision(log,8,8,jobs),enabled)
                    for name,bad in view_elision_mutations(log).items():
                        with self.subTest(name=name,enabled=enabled,jobs=jobs,stopped=stopped):
                            with self.assertRaises(ValueError):check_view_elision(bad,8,8,jobs,enabled,require_mode=True)
        self.assertFalse(check_view_elision("historical trace",8,8,1))
        with self.assertRaises(ValueError):check_view_elision("historical trace",8,8,1,True)

    def test_rgb_reduction_workload(self):
        for w,h in ((8,8),(64,48),(640,480)):
            for virtual in (False,True):
                old=workload(w,h,virtual_upsample=virtual)
                new=workload(w,h,virtual_upsample=virtual,pack_rgb_reduction=True)
                self.assertEqual(old["useful_macs"],new["useful_macs"])
                savings=(w//2)*(h//2)*2*5  # 3->12, two C8 output groups.
                self.assertEqual(old["minimum_cycles"]-new["minimum_cycles"],savings)
                for a,b in zip(old["stages"],new["stages"]):
                    if a["stage"]:
                        self.assertEqual(a,b)
                    else:
                        self.assertEqual(a["dot_beats"]*4,b["dot_beats"]*9)
                        for key in ("C8_results","scalar_writes","scalar_reads_with_columns","useful_macs"):
                            self.assertEqual(a[key],b[key])
        self.assertEqual(workload(640,480,pack_rgb_reduction=True)["minimum_cycles"],10080000)

    def test_rgb_reduction_trace(self):
        for packed in (0,1):
            for jobs in (1,2):
                for w,h in ((8,8),(64,48)):
                    tails=(w//2)*(h//2)*2
                    log=f"C1_NUM_RGB_REDUCTION enabled={packed}\n"
                    for job in range(2,2+jobs):
                        log+=f"C1_PERF_RGB_REDUCTION job={job} beats={tails*(4 if packed else 9)} tails={tails}\n"
                        log+=f"C1_PERF_JOB job={job} error=0\n"
                    self.assertEqual(check_rgb_reduction(log,w,h,jobs),bool(packed))
                    for name,bad in rgb_reduction_mutations(log).items():
                        with self.subTest(name=name,packed=packed,jobs=jobs,w=w):
                            with self.assertRaises(ValueError):
                                check_rgb_reduction(bad,w,h,jobs,bool(packed),require_mode=True)
        self.assertFalse(check_rgb_reduction("historical",8,8,1))
        with self.assertRaises(ValueError):check_rgb_reduction("historical",8,8,1,True)

    def test_all_dot_group_contract(self):
        for w,h,pw,count,ends in ((8,8,False,108,14),(8,8,True,312,44),
                                  (64,48,False,5184,648),(64,48,True,14976,1872),
                                  (640,480,True,1497600,187200)):
            self.assertEqual(batch_budget(w,h,8,pw,True),(count,ends))
            log=("C1_NUM_ALL_DOT_GROUPS enabled=1\nC1_NUM_DOT_PIXEL_PIPELINE enabled=1\n"
                 "C1_NUM_MAC_REQUANT_OVERLAP enabled=1\nC1_NUM_COLUMN_WRITE_OVERLAP enabled=1\n"
                 f"C1_NUM_POINTWISE_COLUMN_READS enabled={int(pw)}\n"
                 "C1_NUM_PIXEL_WRITE_BATCH words=8 build_timeout=64\n"
                 "C1_NUM_COLUMN_OPTION enabled=1 clients=8\nC1_NUM_TENSOR_WRITE_OPTIONS packed=1 pipeline=1 end=1\n"
                 f"C1_PERF_DOT_PIXEL_PIPELINE job=2 starts={count} outputs={count} inputs_ahead=3 starts_ahead=2 writes={count} responses={count} peak=6\n"
                 f"C1_PERF_PIXEL_WRITE_BATCH job=2 writes={count} ends={ends}\nC1_PERF_JOB job=2 error=0\n")
            self.assertTrue(all_dot_groups_enabled(log,True))
            self.assertEqual(check_dot_pixel_pipeline(log,w,h,1,True),{2:2})
            self.assertEqual(check_pixel_write_batch(log,w,h,1,(8,64)),(8,64))
            for name,bad in dot_pixel_mutations(log).items():
                with self.subTest(w=w,pw=pw,mutation=name),self.assertRaises(ValueError):
                    all_dot_groups_enabled(bad,True)
                    check_dot_pixel_pipeline(bad,w,h,1,True)
            two=log+"\n".join(s.replace("job=2","job=4") for s in log.splitlines() if s.startswith("C1_PERF_"))+"\n"
            self.assertEqual(check_dot_pixel_pipeline(two,w,h,2,True),{2:2,4:2})
            self.assertEqual(check_pixel_write_batch(two,w,h,2,(8,64)),(8,64))
        self.assertFalse(all_dot_groups_enabled("historical trace"))
        self.assertFalse(all_dot_groups_enabled("C1_NUM_ALL_DOT_GROUPS enabled=0\n"))
        with self.assertRaises(ValueError):all_dot_groups_enabled("historical trace",True)

    def test_all_dot_abort_contract(self):
        log=("C1_NUM_ALL_DOT_GROUPS enabled=1\nC1_NUM_DOT_PIXEL_PIPELINE enabled=1\n"
             "C1_NUM_ALL_DOT_PIXEL_ABORT stage=0 pending=15\n"
             "C1_NUM_TENSOR_WRITE_MLP outstanding=4\nC1_NUM_COLUMN_OPTION enabled=1 clients=8\n"
             "C1_NUM_TENSOR_WRITE_OPTIONS packed=1 pipeline=1 end=1\n"
             "C1_NUM_TENSOR_MLP_ABORT client=6 pending=2 capture_idle=1\n"
             "C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS pending=2 held_cycles=64 aw=12 b=12 no_restart=1\n"
             "C1_PERF_TENSOR_WRITE_MLP job=2 aw=32 b=32 peak=3\n"
             "C1_PERF_TENSOR_AXI_WRITE job=2 aw=32 beats=40 b=32 full_beats=20\n"
             "C1_PERF_JOB job=2 error=0\n"
             "C1_SOC_INFLIGHT_WRITE_ABORT_PASS pending=2 held_cycles=64 captures=3 done=1 aw=44 b=44 reset=0\n")
        self.assertTrue(check_all_dot_abort(log,True))
        self.assertTrue(all_dot_groups_enabled(log,True))
        self.assertEqual(check_tensor_write_mlp(log,1,4,True),4)
        for name,bad in dot_pixel_mutations(log).items():
            with self.subTest(mutation=name),self.assertRaises(ValueError):
                check_all_dot_abort(bad,True)
                all_dot_groups_enabled(bad,True)
        with self.assertRaises(ValueError):
            check_tensor_write_mlp(log+"C1_NUM_DOT_PIXEL_ABORT stage=20 pending=15\n",1,4,True)

    def test_stage0_profile_contract(self):
        rows=("C1_PERF_STAGE0_FSM job=1 side=engine state=8 cycles=100\n"
              "C1_PERF_STAGE0_FSM job=1 side=adapter state=2 cycles=40\n"
              "C1_PERF_STAGE0_FSM job=1 side=adapter state=3 cycles=60\n")
        stage="C1_PERF_STAGE job=1 stage=0 cycles=100 dot_beats=0 dw_beats=0 mem_read=0 mem_write=0 columns=0\n"
        log=rows+stage
        self.assertEqual(check_stage0_profile(log,True)["adapter"],{2:40,3:60})
        for bad in (stage,log+rows,log.replace("cycles=40","cycles=41"),log.replace("state=8","state=32"),
                    log.replace("side=engine","side=invalid"),log.replace("side=engine state=8 cycles=100","side=engine state=8 cycles=0"),
                    rows.replace("job=1","job=2")+stage):
            with self.subTest(bad=bad),self.assertRaises(ValueError):check_stage0_profile(bad,True)
        self.assertEqual(check_stage0_profile("historical trace"),{})

    def test_dw_pixel_pipeline_contract(self):
        for w,h,count,warm,maximum in ((8,8,248,87,82),(64,48,11904,4411,4406),
                                       (640,480,1190400,441595,441590)):
            for batch in (1,2,4,8):
                actual,ends,warm_actual,max_actual=dw_pixel_budget(w,h,batch)
                self.assertEqual((actual,warm_actual,max_actual),(count,warm,maximum))
                log=("C1_NUM_DW_PIXEL_PIPELINE enabled=1\nC1_NUM_DW_STREAM enabled=1\n"
                     "C1_NUM_COLUMN_WRITE_OVERLAP enabled=1\nC1_NUM_ENGINE_OPTIONS dw_cache=1 mac_overlap=0\n"
                     f"C1_NUM_PIXEL_WRITE_BATCH words={batch} build_timeout=64\n"
                     f"C1_PERF_DW_PIXEL_PIPELINE job=2 inputs={count} feeds={count} outputs={count} writes={count} responses={count} ends={ends} warm={warm} ahead=2 peak=12\n"
                     "C1_PERF_JOB job=2 error=0\n")
                self.assertTrue(check_dw_pixel_pipeline(log,w,h,1,True))
                for name,bad in dw_pixel_mutations(log).items():
                    with self.subTest(w=w,batch=batch,mutation=name),self.assertRaises(ValueError):
                        check_dw_pixel_pipeline(bad,w,h,1,True)
                two=log+"\n".join(s.replace("job=2","job=4") for s in log.splitlines() if s.startswith("C1_PERF_"))+"\n"
                self.assertTrue(check_dw_pixel_pipeline(two,w,h,2,True))
                with self.assertRaises(ValueError):check_dw_pixel_pipeline(two.replace("job=4","job=2"),w,h,2,True)
                with self.assertRaises(ValueError):check_dw_pixel_pipeline(log.replace("dw_cache=1","dw_cache=0"),w,h,1,True)
        self.assertFalse(check_dw_pixel_pipeline("historical trace",8,8,1))
        with self.assertRaises(ValueError):check_dw_pixel_pipeline("historical trace",8,8,1,True)

    def test_dw_pixel_disabled_contract(self):
        record=("C1_PERF_DW_PIXEL_PIPELINE job=1 inputs=0 feeds=0 outputs=0 writes=0 "
                "responses=0 ends=0 warm=0 ahead=0 peak=0\n")
        log=("C1_NUM_DW_PIXEL_PIPELINE enabled=0\n"
             "C1_NUM_PIXEL_WRITE_BATCH words=1 build_timeout=8\n"+record+
             "C1_PERF_JOB job=1 error=0\n")
        self.assertFalse(check_dw_pixel_pipeline(log,8,8,1))
        with self.assertRaises(ValueError):check_dw_pixel_pipeline(log,8,8,1,True)
        for field in ("inputs","feeds","outputs","writes","responses","ends","warm","ahead","peak"):
            with self.subTest(field=field),self.assertRaises(ValueError):
                check_dw_pixel_pipeline(log.replace(f"{field}=0",f"{field}=1"),8,8,1)
        with self.assertRaises(ValueError):check_dw_pixel_pipeline(log.replace(record,""),8,8,1)

    def test_dw_only_write_batch_contract(self):
        # Batch budget remains split: DOT progress is zero; DW groups, not
        # pixels, account for all nonzero sink writes/end hints in this mode.
        for words in (1,2,4,8):
            count,ends,warm,_=dw_pixel_budget(8,8,words)
            log=(f"C1_NUM_PIXEL_WRITE_BATCH words={words} build_timeout=64\n"
                 "C1_NUM_DOT_PIXEL_PIPELINE enabled=0\nC1_NUM_POINTWISE_COLUMN_READS enabled=0\n"
                 "C1_NUM_DW_PIXEL_PIPELINE enabled=1\nC1_NUM_DW_STREAM enabled=1\n"
                 "C1_NUM_COLUMN_WRITE_OVERLAP enabled=1\nC1_NUM_ENGINE_OPTIONS dw_cache=1 mac_overlap=0\n"
                 "C1_NUM_COLUMN_OPTION enabled=1 clients=8\nC1_NUM_TENSOR_WRITE_OPTIONS packed=1 pipeline=1 end=1\n"
                 "C1_PERF_DOT_PIXEL_PIPELINE job=1 starts=0 outputs=0 inputs_ahead=0 starts_ahead=0 writes=0 responses=0 peak=0\n"
                 "C1_PERF_PIXEL_WRITE_BATCH job=1 writes=0 ends=0\n"
                 f"C1_PERF_DW_PIXEL_PIPELINE job=1 inputs={count} feeds={count} outputs={count} writes={count} responses={count} ends={ends} warm={warm} ahead=0 peak=8\n"
                 "C1_PERF_JOB job=1 error=0\n")
            self.assertEqual(check_pixel_write_batch(log,8,8,1,(words,64)),(words,64))
            for name,bad in dw_pixel_mutations(log).items():
                with self.subTest(words=words,mutation=name),self.assertRaises(ValueError):
                    check_dw_pixel_pipeline(bad,8,8,1,True)
            with self.assertRaises(ValueError):
                check_pixel_write_batch(log.replace(f"ends={ends} warm=",f"ends={ends+1} warm="),8,8,1,(words,64))

    def test_dw_pixel_abort_contract(self):
        log=("C1_NUM_DW_PIXEL_PIPELINE enabled=1\nC1_NUM_DW_STREAM enabled=1\n"
             "C1_NUM_COLUMN_WRITE_OVERLAP enabled=1\nC1_NUM_ENGINE_OPTIONS dw_cache=1 mac_overlap=0\n"
             "C1_NUM_PIXEL_WRITE_BATCH words=8 build_timeout=64\nC1_NUM_DW_PIXEL_ABORT stage=18 pending=15\n"
             "C1_NUM_TENSOR_WRITE_MLP outstanding=4\nC1_NUM_COLUMN_OPTION enabled=1 clients=8\n"
             "C1_NUM_TENSOR_WRITE_OPTIONS packed=1 pipeline=1 end=1\n"
             "C1_NUM_TENSOR_MLP_ABORT client=6 pending=2 capture_idle=1\n"
             "C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS pending=2 held_cycles=64 aw=12 b=12 no_restart=1\n"
             "C1_PERF_DW_PIXEL_PIPELINE job=2 inputs=248 feeds=248 outputs=248 writes=248 responses=248 ends=36 warm=87 ahead=2 peak=12\n"
             "C1_PERF_TENSOR_WRITE_MLP job=2 aw=32 b=32 peak=3\n"
             "C1_PERF_TENSOR_AXI_WRITE job=2 aw=32 beats=40 b=32 full_beats=20\nC1_PERF_JOB job=2 error=0\n"
             "C1_SOC_INFLIGHT_WRITE_ABORT_PASS pending=2 held_cycles=64 captures=3 done=1 aw=44 b=44 reset=0\n")
        self.assertTrue(check_dw_pixel_pipeline(log,8,8,1,True,True))
        self.assertEqual(check_tensor_write_mlp(log,1,4,True),4)
        for name,bad in dw_pixel_mutations(log).items():
            with self.subTest(mutation=name),self.assertRaises(ValueError):check_dw_pixel_pipeline(bad,8,8,1,True,True)
        with self.assertRaises(ValueError):check_tensor_write_mlp(log+"C1_NUM_DOT_PIXEL_ABORT stage=20 pending=3\n",1,4,True)

    def test_pixel_write_batch_contract(self):
        for w,h in ((8,8),(64,48),(640,480)):
            for pw in (0,1):
                for words in (1,2,4,8):
                    count,ends=batch_budget(w,h,words,bool(pw))
                    self.assertEqual(count,w*h*(pw+1))
                    self.assertEqual(ends,((w+words-1)//words)*h*(pw+1))
                    log=(f"C1_NUM_PIXEL_WRITE_BATCH words={words} build_timeout=64\n"
                         "C1_NUM_DOT_PIXEL_PIPELINE enabled=1\nC1_NUM_MAC_REQUANT_OVERLAP enabled=1\n"
                         "C1_NUM_COLUMN_WRITE_OVERLAP enabled=1\n"
                         f"C1_NUM_POINTWISE_COLUMN_READS enabled={pw}\n"
                         "C1_NUM_COLUMN_OPTION enabled=1 clients=8\n"
                         "C1_NUM_TENSOR_WRITE_OPTIONS packed=1 pipeline=1 end=1\n"
                         f"C1_PERF_DOT_PIXEL_PIPELINE job=2 starts={count} outputs={count} inputs_ahead=3 starts_ahead=2 writes={count} responses={count} peak=3\n"
                         f"C1_PERF_PIXEL_WRITE_BATCH job=2 writes={count} ends={ends}\nC1_PERF_JOB job=2 error=0\n")
                    self.assertEqual(check_pixel_write_batch(log,w,h,1,(words,64)),(words,64))
                    for name,bad in pixel_batch_mutations(log).items():
                        with self.subTest(w=w,pw=pw,words=words,mutation=name),self.assertRaises(ValueError):
                            check_pixel_write_batch(bad,w,h,1,(words,64))
                    two=log+"\n".join(s.replace("job=2","job=4") for s in log.splitlines() if s.startswith("C1_PERF_"))+"\n"
                    self.assertEqual(check_pixel_write_batch(two,w,h,2,(words,64)),(words,64))
                    with self.assertRaises(ValueError):check_pixel_write_batch(two.replace("job=4","job=2"),w,h,2,(words,64))
                    with self.assertRaises(ValueError):check_pixel_write_batch(log.replace("packed=1","packed=0"),w,h,1)
                    if words>1:
                        with self.assertRaises(ValueError):check_pixel_write_batch(log.replace("end=1","end=0"),w,h,1)
        self.assertIsNone(check_pixel_write_batch("historical trace",8,8,1))
        with self.assertRaises(ValueError):check_pixel_write_batch("historical trace",8,8,1,(1,8))

    def test_pixel_write_batch_disabled(self):
        log=("C1_NUM_PIXEL_WRITE_BATCH words=1 build_timeout=8\n"
             "C1_NUM_DOT_PIXEL_PIPELINE enabled=0\nC1_NUM_POINTWISE_COLUMN_READS enabled=0\n"
             "C1_PERF_DOT_PIXEL_PIPELINE job=1 starts=0 outputs=0 inputs_ahead=0 starts_ahead=0 writes=0 responses=0 peak=0\n"
             "C1_PERF_PIXEL_WRITE_BATCH job=1 writes=0 ends=0\nC1_PERF_JOB job=1 error=0\n")
        self.assertEqual(check_pixel_write_batch(log,8,8,1,(1,8)),(1,8))
        for name,bad in pixel_batch_mutations(log).items():
            with self.subTest(mutation=name),self.assertRaises(ValueError):check_pixel_write_batch(bad,8,8,1,(1,8))

    def test_tensor_write_mlp_contract(self):
        for slots in (1,2,4):
            log=(f"C1_NUM_TENSOR_WRITE_MLP outstanding={slots}\n"
                 "C1_NUM_COLUMN_OPTION enabled=1 clients=8\nC1_NUM_TENSOR_WRITE_OPTIONS packed=1 pipeline=1 end=1\n"
                 f"C1_PERF_TENSOR_WRITE_MLP job=2 aw=16 b=16 peak={slots}\n"
                 "C1_PERF_TENSOR_AXI_WRITE job=2 aw=16 beats=24 b=16 full_beats=8\nC1_PERF_JOB job=2 error=0\n")
            self.assertEqual(check_tensor_write_mlp(log,1,slots),slots)
            for name,bad in tensor_mlp_mutations(log).items():
                with self.subTest(slots=slots,mutation=name),self.assertRaises(ValueError):check_tensor_write_mlp(bad,1,slots)
            two=log+"".join(s.replace("job=2","job=3") for s in log.splitlines(keepends=True) if s.startswith("C1_PERF"))
            self.assertEqual(check_tensor_write_mlp(two,2,slots),slots)
            with self.assertRaises(ValueError):check_tensor_write_mlp(two.replace("job=3","job=2"),2,slots)
            with self.assertRaises(ValueError):check_tensor_write_mlp(log.replace("beats=24","beats=65"),1,slots)
            if slots>1:
                abort=("C1_NUM_DOT_PIXEL_PIPELINE enabled=1\nC1_NUM_DOT_PIXEL_ABORT stage=20 pending=8\n"
                       "C1_NUM_TENSOR_MLP_ABORT client=6 pending=2 capture_idle=1\n"
                       "C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS pending=2 held_cycles=64 aw=12 b=12 no_restart=1\n")
                recovered=abort+log+"C1_SOC_INFLIGHT_WRITE_ABORT_PASS pending=2 held_cycles=64 captures=3 done=1 aw=28 b=28 reset=0\n"
                self.assertEqual(check_tensor_write_mlp(recovered,1,slots,True),slots)
                for name,bad in tensor_mlp_mutations(recovered).items():
                    with self.subTest(slots=slots,mutation=name),self.assertRaises(ValueError):check_tensor_write_mlp(bad,1,slots,True)
        self.assertIsNone(check_tensor_write_mlp("historical trace",1))
        with self.assertRaises(ValueError):check_tensor_write_mlp("historical trace",1,2)

    def test_8x8_matches_existing_inputs(self):
        descriptors, arena, summary = build_fixture(self.artifact, 8, 8)
        old = self.artifact.parents[1] / "vectors/microstyle_engine_bitexact_8x8"
        self.assertEqual(descriptors, (old / "descriptors.mem").read_text())
        self.assertEqual(arena, (old / "parameter_arena.mem").read_text())
        self.assertEqual(summary["C8_results"], 836)

    def test_16x8_dimensions_and_same_weights(self):
        small, small_arena, _ = build_fixture(self.artifact, 8, 8)
        wide, wide_arena, summary = build_fixture(self.artifact, 16, 8)
        self.assertEqual(small_arena, wide_arena)
        self.assertEqual(summary["parameter_arena_bytes"], 16896)
        self.assertEqual(summary["C8_results"], 1672)
        self.assertEqual(len(wide.splitlines()), 22)
        for before, after in zip(small.splitlines(), wide.splitlines()):
            a, b = bytearray.fromhex(before)[::-1], bytearray.fromhex(after)[::-1]
            # ABI bytes 4:6 / 8:10 are input/output widths; no other bytes change.
            for offset in (4, 8):
                self.assertEqual(int.from_bytes(b[offset:offset+2], "little"),
                                 2 * int.from_bytes(a[offset:offset+2], "little"))
                b[offset:offset+2] = a[offset:offset+2]
            self.assertEqual(a, b)

    def test_bad_shapes(self):
        for width, height in ((0, 8), (12, 8), (16, 7), (64, 47), (640, 480)):
            with self.subTest(shape=(width, height)), self.assertRaises(ValueError):
                build_fixture(self.artifact, width, height)

    def test_spatial_shape_scaling(self):
        small, small_arena, _ = build_fixture(self.artifact, 8, 8)
        for width, height, results in ((16, 16, 3344), (64, 48, 40128)):
            wide, arena, summary = build_fixture(self.artifact, width, height)
            self.assertEqual(arena, small_arena)
            self.assertEqual(summary["C8_results"], results)
            for before, after in zip(small.splitlines(), wide.splitlines()):
                a, b = bytearray.fromhex(before)[::-1], bytearray.fromhex(after)[::-1]
                for offset, scale in ((4, width//8), (6, height//8), (8, width//8), (10, height//8)):
                    self.assertEqual(int.from_bytes(b[offset:offset+2], "little"),
                                     scale * int.from_bytes(a[offset:offset+2], "little"))
                    b[offset:offset+2] = a[offset:offset+2]
                self.assertEqual(a, b)

    def test_small_camera_fixture_compatibility(self):
        for width, height, tone in ((8, 8, 0), (12, 10, 32), (16, 8, 0), (16, 16, 0)):
            for mode in ("gray", "color_rggb"):
                y, x = np.indices((height, width))
                base = 64+17*(x+1)+29*(y+1)+tone
                offsets = (96, 40, 0) if mode == "color_rggb" else (0, 0, 0)
                expected = np.stack([(base+offset)>>2 for offset in offsets], axis=-1).astype(np.uint8)
                np.testing.assert_array_equal(camera_fixture_rgb(width, height, mode, tone), expected)

    def test_wrapped_camera_fixture_against_scalar_interpolation(self):
        for mode in ("gray", "color_rggb"):
            def sample(x, y):
                offset = (96 if x%2==0 and y%2==0 else 0 if x%2==1 and y%2==1 else 40) if mode=="color_rggb" else 0
                return (64+17*x+29*y+offset)&1023
            expected = np.empty((48, 64, 3), dtype=np.uint8)
            for y in range(1, 49):
                for x in range(1, 65):
                    c = sample(x, y)
                    h = (sample(x-1,y)+sample(x+1,y)+1)//2
                    v = (sample(x,y-1)+sample(x,y+1)+1)//2
                    cross = (sample(x-1,y)+sample(x+1,y)+sample(x,y-1)+sample(x,y+1)+2)//4
                    diag = sum(sample(x+dx,y+dy) for dx,dy in ((-1,-1),(-1,1),(1,-1),(1,1)))
                    diag = (diag+2)//4
                    rgb = (c,cross,diag) if x%2==0 and y%2==0 else (diag,cross,c) if x%2==1 and y%2==1 else (h,c,v) if y%2==0 else (v,c,h)
                    expected[y-1,x-1] = [channel>>2 for channel in rgb]
            actual = camera_fixture_rgb(64, 48, mode)
            np.testing.assert_array_equal(actual, expected)
            # Ensure this case really exercises wrap discontinuities: applying
            # modulo to the old centre-plane approximation must differ.
            yy, xx = np.indices((48, 64))
            naive = ((64+17*(xx+1)+29*(yy+1)+(96 if mode=="color_rggb" else 0))&1023)>>2
            self.assertGreater(np.count_nonzero(actual[:,:,0] != naive), 0)

    def test_incompatible_manifest(self):
        manifest = json.loads((self.artifact / "manifest.json").read_text())
        bad = []
        for key, value in (("trained", False), ("trained", "true"),
                           ("model", "other"), ("descriptor_count", 21),
                           ("parameter_arena_bytes", 0)):
            variant = copy.deepcopy(manifest)
            variant[key] = value
            bad.append(variant)
        for key in ("weight_offset", "bias_offset", "multiplier_offset", "shift_offset"):
            variant = copy.deepcopy(manifest)
            variant["parameter_layout"][0][key] += 16
            bad.append(variant)
        variant = copy.deepcopy(manifest)
        variant["layers"][0]["input_channels"] = 8
        bad.append(variant)
        for variant in bad:
            with self.subTest(variant=bad.index(variant)), patch.object(Path, "read_text", return_value=json.dumps(variant)):
                with self.assertRaises(ValueError):
                    build_fixture(self.artifact, 16, 8)

    def test_short_arena(self):
        with patch.object(Path, "read_bytes", return_value=b"\x01" * 16880):
            with self.assertRaises(ValueError):
                build_fixture(self.artifact, 16, 8)

    def test_virtual_upsample_work(self):
        for width, height in ((4,4),(12,8),(20,12),(64,48),(640,480)):
            before = workload(width,height)
            after = workload(width,height,virtual_upsample=True)
            self.assertEqual(before["minimum_cycles"],after["minimum_cycles"])
            self.assertEqual(before["useful_macs"],after["useful_macs"])
            saved = 0
            for old,new in zip(before["stages"],after["stages"]):
                for key in ("dot_beats","dw_beats","linear_beats","C8_results"):
                    self.assertEqual(old[key],new[key])
                self.assertEqual(new["scalar_writes"],0 if new["stage"] in (14,17) else old["scalar_writes"])
                self.assertEqual(old["scalar_writes"]-new["scalar_writes"],new["elided_writes"])
                saved += new["elided_writes"]
            self.assertEqual(saved,width*height*11//4)

    def test_dw_stream_warm_work(self):
        for width,height,total in ((8,8,225),(64,48,11881),(640,480,1190377)):
            model=workload(width,height)
            self.assertEqual(sum(s["dw_warm_beats"] for s in model["stages"]),total)
            self.assertEqual(sum(s["dw_beats"]-s["dw_warm_beats"] for s in model["stages"]),23)
            self.assertEqual(sum(s["dw_warm_beats"] for s in workload(width,height,virtual_upsample=True)["stages"]),total)

    def test_native_scheduling_floor(self):
        model = workload(640, 480)
        self.assertEqual(sum(s["dot_beats"] for s in model["stages"]), 8332800)
        self.assertEqual(sum(s["dw_beats"] for s in model["stages"]), 1190400)
        self.assertEqual(sum(s["linear_beats"] for s in model["stages"]), 1324800)
        self.assertEqual(model["useful_macs"], 428236800)
        self.assertEqual(model["minimum_cycles"], 10848000)
        self.assertEqual(model["minimum_cycles"]*15, 162720000)
        for width, height in ((8, 8), (16, 8), (16, 16), (64, 48)):
            scaled = workload(width, height)
            for small, full in zip(scaled["stages"], model["stages"]):
                for key in ("dot_beats", "dw_beats", "linear_beats", "C8_results", "scalar_writes", "useful_macs"):
                    self.assertEqual(small[key]*640*480, full[key]*width*height)

    def test_pointwise_read_budget_and_cache_capacity(self):
        for w,h,scalar,pw in ((8,8,596,284),(64,48,28608,13632),(640,480,2860800,1363200)):
            stages=workload(w,h)["stages"]
            self.assertEqual(sum(s["scalar_reads_with_columns"] for s in stages),scalar)
            self.assertEqual(sum(s["pointwise_reads"] for s in stages),pw)
            selected=[s for s in stages if s["opcode"]==2]
            self.assertEqual([s["stage"] for s in selected],[2,4,6,8,10,12,16,19])
            self.assertLessEqual(max(s["input_row_words"] for s in selected),1280)
            self.assertLessEqual(max(s["input_groups"] for s in selected),8)
        self.assertEqual(max(s["input_row_words"] for s in selected),1280)

    def test_requant_overlap_contract(self):
        for w,h,count,early in ((8,8,312,124),(64,48,14976,5952),(640,480,1497600,595200)):
            stages=workload(w,h)["stages"]
            self.assertEqual(sum(s["dot_transactions"] for s in stages),count)
            self.assertEqual(sum(s["dot_requant_restarts"] for s in stages),early)
            log=("C1_NUM_MAC_REQUANT_OVERLAP enabled=1\n"
                 f"C1_PERF_MAC_REQUANT_OVERLAP job=1 starts={count} outputs={count} early={early} peak=2\n"
                 "C1_PERF_JOB job=1 error=0\n")
            self.assertTrue(check_requant_overlap(log,w,h,1,True))
            for name,bad in requant_overlap_mutations(log).items():
                with self.subTest(w=w,case=name),self.assertRaises(ValueError):check_requant_overlap(bad,w,h,1,True)
            disabled=log.replace("enabled=1","enabled=0").replace(f"early={early}","early=0").replace("peak=2","peak=1")
            self.assertFalse(check_requant_overlap(disabled,w,h,1))
            with self.assertRaises(ValueError):check_requant_overlap(disabled,w,h,1,True)
            with self.assertRaises(ValueError):check_requant_overlap(disabled.replace("peak=1","peak=2"),w,h,1)
            self.assertFalse(check_requant_overlap("historical trace without counters\n",w,h,1))
            with self.assertRaises(ValueError):check_requant_overlap("historical trace without counters\n",w,h,1,True)
            # A failed job does not own successful-job counters; subsequent
            # recovery still has to provide a unique, ordered result record.
            recovered=log.replace("job=1","job=3")
            recovered="C1_PERF_JOB job=2 error=1\n"+recovered
            self.assertTrue(check_requant_overlap(recovered,w,h,1,True))
            two=log+log.replace("job=1","job=3").replace("C1_NUM_MAC_REQUANT_OVERLAP enabled=1\n","")
            self.assertTrue(check_requant_overlap(two,w,h,2,True))
            with self.assertRaises(ValueError):check_requant_overlap(two.replace("job=3","job=1"),w,h,2,True)

    def test_pointwise_reduction_contract(self):
        for w,h,beats,early in ((8,8,284,180),(64,48,13632,8640),(640,480,1363200,864000)):
            stages=workload(w,h)["stages"]
            self.assertEqual(sum(s["pointwise_stream_beats"] for s in stages),beats)
            self.assertEqual(sum(s["pointwise_early_beats"] for s in stages),early)
            log=("C1_NUM_POINTWISE_REDUCTION enabled=1\n"
                 f"C1_PERF_POINTWISE_REDUCTION job=2 beats={beats} early={early}\nC1_PERF_JOB job=2 error=0\n")
            self.assertTrue(check_pointwise_reduction(log,w,h,1,True))
            for name,bad in pointwise_reduction_mutations(log).items():
                with self.subTest(w=w,case=name), self.assertRaises(ValueError):
                    check_pointwise_reduction(bad,w,h,1,True)

    def test_source_write_pipeline_contract(self):
        for w,h in ((8,8),(12,8),(64,48),(640,480)):
            pixels=w*h
            for enabled in (0,1):
                ends=((w+7)//8)*h if enabled else pixels
                log=(f"C1_NUM_SOURCE_PIPELINE enabled={enabled}\n"
                     f"C1_PERF_SOURCE_WRITES job=2 inputs={pixels} requests={pixels} responses={pixels} ends={ends} peak=1 pending_cycles={pixels}\n"
                     "C1_PERF_JOB job=2 error=0\n")
                self.assertEqual(check_source_writes(log,w,h,1),bool(enabled))
                if enabled:
                    for name,changed in source_write_mutations(log).items():
                        with self.subTest(w=w,h=h,mutation=name), self.assertRaises(ValueError):
                            check_source_writes(changed,w,h,1,True)
        self.assertFalse(check_source_writes("historical trace",8,8,1))
        with self.assertRaises(ValueError): check_source_writes("historical trace",8,8,1,True)

    def test_next_pixel_first_column_budget(self):
        for w,h,windowed,with_pointwise in ((8,8,168,264),(64,48,8440,13424),
                                           (640,480,844792,1343984)):
            stages=workload(w,h)["stages"]
            self.assertEqual(sum(s["next_pixel_columns"] for s in stages if s["opcode"] in (1,3)),windowed)
            self.assertEqual(sum(s["next_pixel_columns"] for s in stages),with_pointwise)
            self.assertEqual(sum(s["next_pixel_columns"] for s in workload(w,h,virtual_upsample=True)["stages"]),with_pointwise)

    def test_dot_pixel_pipeline_contract(self):
        for w,h in ((8,8),(64,48),(640,480)):
            for pw in (0,1):
                count=w*h*(pw+1)
                log=("C1_NUM_DOT_PIXEL_PIPELINE enabled=1\nC1_NUM_MAC_REQUANT_OVERLAP enabled=1\n"
                     "C1_NUM_COLUMN_WRITE_OVERLAP enabled=1\n"
                     f"C1_NUM_POINTWISE_COLUMN_READS enabled={pw}\n"
                     f"C1_PERF_DOT_PIXEL_PIPELINE job=2 starts={count} outputs={count} inputs_ahead=3 starts_ahead=2 writes={count} responses={count} peak=3\n"
                     "C1_PERF_JOB job=2 error=0\n")
                self.assertEqual(check_dot_pixel_pipeline(log,w,h,1,True),{2:2})
                for name,bad in dot_pixel_mutations(log).items():
                    with self.subTest(w=w,pw=pw,mutation=name),self.assertRaises(ValueError):check_dot_pixel_pipeline(bad,w,h,1,True)
        self.assertEqual(check_dot_pixel_pipeline("historical trace",8,8,1),{})
        with self.assertRaises(ValueError):check_dot_pixel_pipeline("historical trace",8,8,1,True)

    def test_dot_pixel_abort_contract(self):
        log=("C1_NUM_DOT_PIXEL_PIPELINE enabled=1\nC1_NUM_MAC_REQUANT_OVERLAP enabled=1\n"
             "C1_NUM_COLUMN_WRITE_OVERLAP enabled=1\nC1_NUM_POINTWISE_COLUMN_READS enabled=1\n"
             "C1_NUM_DOT_PIXEL_ABORT stage=20 pending=3\n"
             "C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS pending=2 held_cycles=64 aw=12 b=12 no_restart=1\n"
             "C1_PERF_DOT_PIXEL_PIPELINE job=2 starts=128 outputs=128 inputs_ahead=3 starts_ahead=2 writes=128 responses=128 peak=3\n"
             "C1_PERF_JOB job=2 error=0\n"
             "C1_SOC_INFLIGHT_WRITE_ABORT_PASS pending=2 held_cycles=64 captures=3 done=1 aw=212 b=212 reset=0\n")
        self.assertEqual(check_dot_pixel_pipeline(log,8,8,1,True,True),{2:2})
        for name,bad in dot_pixel_mutations(log).items():
            with self.subTest(case=name),self.assertRaises(ValueError):check_dot_pixel_pipeline(bad,8,8,1,True,True)
        for bad in (log.replace("held_cycles=64","held_cycles=63"),log.replace("b=212","b=211"),
                    log.replace("reset=0","reset=1"),log.replace("starts_ahead=2","starts_ahead=4")):
            with self.subTest(log=bad),self.assertRaises(ValueError):check_dot_pixel_pipeline(bad,8,8,1,True,True)

    def test_all_pixel_groups_contract(self):
        for w,h,windowed,with_pointwise in ((8,8,309,561),(64,48,16101,29701),(640,480,1612773,2975941)):
            stages=workload(w,h)["stages"]
            self.assertEqual(sum(s["next_pixel_columns"]*s["input_groups"] for s in stages if s["opcode"] in (1,3)),windowed)
            self.assertEqual(sum(s["next_pixel_columns"]*s["input_groups"] for s in stages),with_pointwise)
        mode="C1_NUM_ALL_PIXEL_GROUPS enabled=1\n"
        log="C1_NUM_PIXEL_COLUMN_PREFETCH enabled=1\n"+mode
        self.assertTrue(all_pixel_groups_enabled(log,True))
        for bad in ("",log+mode,log.replace(mode,"C1_NUM_ALL_PIXEL_GROUPS enabled=2\n"),
                    log.replace(mode,"C1_NUM_ALL_PIXEL_GROUPS enabled=0\n"),mode):
            with self.subTest(log=bad),self.assertRaises(ValueError):all_pixel_groups_enabled(bad,True)
        self.assertFalse(all_pixel_groups_enabled("historical log"))
        self.assertFalse(all_pixel_groups_enabled("C1_NUM_ALL_PIXEL_GROUPS enabled=0\n"))


if __name__ == "__main__":
    unittest.main()
