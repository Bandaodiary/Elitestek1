from pathlib import Path
import unittest
from check_final_fusion_trace import check_final_fusion,final_fusion_mutations
from microstyle_workload import workload
from prepare_portable_soc_trained_fixture import build_fixture


def fixture(enabled=1,jobs=1,cancel_prefix=None):
    rows=[f"C1_NUM_FINAL_FUSION enabled={enabled}"]
    start=1
    if cancel_prefix is not None:
        start=2
    for job in range(1,jobs+start):
        canceled=cancel_prefix is not None and job==1
        prefix=cancel_prefix if canceled else 3
        rows += [f"C1_PERF_START job={job} cycle=1"]
        if enabled:
            rows += [f"C1_FINAL_FUSION_BEGIN job={job} generation={job} width=2 height=2"]
            if prefix>=1:
                rows += [f"C1_FINAL_FUSION_COMMIT job={job} generation={job} stage=21 inputs=4 outputs=3 held_eof=1"]
            if prefix>=2:
                rows += [f"C1_FINAL_FUSION_EOF job={job} generation={job} inputs=4 outputs=4"]
        terminal="C1_FINAL_FUSION_STOP" if canceled else "C1_PERF_FINAL_FUSION"
        ins=4 if enabled else 0;outs=(4 if prefix>=2 else 3) if enabled else 0
        if enabled and not canceled:
            rows += [f"C1_PERF_FINAL_COMPUTE job={job} generation={job} starts=4 outputs=4 inputs_ahead=2 starts_ahead=1"]
        rows += [f"{terminal} job={job} generation={job} inputs={ins} outputs={outs} commits={int(enabled and prefix>=1)} eofs={int(enabled and prefix>=2)}",
                 f"C1_PERF_ABORT job={job} cycle=10" if canceled else f"C1_PERF_JOB job={job} error=0"]
    return "\n".join(rows)+"\n"


class FinalFusionTest(unittest.TestCase):
    def test_valid_modes_and_recovery_prefixes(self):
        for mode in (0,1):
            for jobs in (1,2):
                for prefix in (None,0,1,2):
                    self.assertEqual(check_final_fusion(fixture(mode,jobs,prefix),2,2,jobs),bool(mode))

    def test_negative_mutations(self):
        for mode in (0,1):
            for prefix in (None,0,1,2):
                for name,changed in final_fusion_mutations(fixture(mode,1,prefix)).items():
                    with self.subTest(mode=mode,prefix=prefix,name=name):
                        with self.assertRaises(ValueError):check_final_fusion(changed,2,2,1,bool(mode),require_mode=True)

    def test_original_fixture_and_arithmetic_unchanged(self):
        artifact=Path(__file__).resolve().parents[1]/"model/microstyle24_starry_functional"
        for w,h in ((8,8),(64,48),(640,480)):
            for views in (False,True):
                # Native geometry is a workload audit, not a supported sized
                # simulation fixture. Do not relax the generator's bound.
                if w<=64:
                    old=build_fixture(artifact,w,h,elide_views=views)
                    new=build_fixture(artifact,w,h,elide_views=views,fuse_final=True)
                    self.assertEqual(old[:2],new[:2])
                    self.assertEqual(old[2]["C8_results"]-new[2]["C8_results"],w*h)
                a=workload(w,h,virtual_upsample=views,elide_views=views,pack_rgb_reduction=True)
                b=workload(w,h,virtual_upsample=views,elide_views=views,pack_rgb_reduction=True,fuse_final=True)
                self.assertEqual(a["useful_macs"],b["useful_macs"])
                self.assertEqual(a["minimum_cycles"]-b["minimum_cycles"],w*h)
                self.assertEqual(b["stages"][20]["scalar_writes"],0)
                self.assertEqual(b["stages"][21]["C8_results"],0)
                self.assertEqual(b["stages"][21]["scalar_reads_with_columns"],0)
        self.assertEqual(workload(640,480,virtual_upsample=True,elide_views=True,pack_rgb_reduction=True,fuse_final=True)["minimum_cycles"],8928000)

    def test_compute_early_is_independent_from_writer(self):
        from check_mac_requant_overlap_trace import check_requant_overlap
        log=fixture().replace("width=2 height=2","width=8 height=8")
        for before,after in (("inputs=4","inputs=64"),("outputs=3","outputs=63"),
                             ("outputs=4","outputs=64"),("starts=4","starts=64")):
            log=log.replace(before,after)
        stages=workload(8,8)["stages"]
        starts=sum(s["dot_transactions"] for s in stages)
        early=sum(s["dot_requant_restarts"] for s in stages)+1
        log += ("C1_NUM_MAC_REQUANT_OVERLAP enabled=1\nC1_NUM_DOT_PIXEL_PIPELINE enabled=0\n"
                "C1_NUM_POINTWISE_COLUMN_READS enabled=0\n"
                "C1_PERF_DOT_PIXEL_PIPELINE job=1 starts=0 outputs=0 inputs_ahead=0 starts_ahead=0 writes=0 responses=0 peak=0\n"
                f"C1_PERF_MAC_REQUANT_OVERLAP job=1 starts={starts} outputs={starts} early={early} peak=2\n")
        self.assertTrue(check_final_fusion(log,8,8,1))
        self.assertTrue(check_requant_overlap(log,8,8,1))
        bad=log.replace("inputs_ahead=2 starts_ahead=1","inputs_ahead=2 starts_ahead=0")
        # The changed count is locally legal, but violates independent global
        # arithmetic conservation. Never turn that exact equality into >=.
        self.assertTrue(check_final_fusion(bad,8,8,1))
        with self.assertRaises(ValueError):check_requant_overlap(bad,8,8,1)

    def test_real_result_chronology(self):
        log=fixture()
        commit=next(s for s in log.splitlines() if s.startswith("C1_FINAL_FUSION_COMMIT"))
        data="\n".join(f"C1_NUM_OUT 20 {i} 0 0 0" for i in range(4))+"\n"
        good=log.replace(commit,data+commit)
        self.assertTrue(check_final_fusion(good,2,2,1))
        for bad in (log.replace(commit,commit+"\n"+data),good.replace("C1_NUM_OUT 20 3", "C1_NUM_OUT 21 3"),
                    good.replace("C1_NUM_OUT 20 3 0 0 0\n", "")):
            with self.assertRaises(ValueError):check_final_fusion(bad,2,2,1)


if __name__=="__main__":unittest.main()
