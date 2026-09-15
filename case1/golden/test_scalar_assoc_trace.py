"""Count, ownership and residual cache contracts without an EDA dependency."""
from pathlib import Path
import re
import sys
import unittest
from check_scalar_assoc_trace import (
    MODE,ENTRIES,PROGRESS,STAGE,ABORT,residual_budget,check_scalar_assoc,
    check_scalar_assoc_abort,scalar_assoc_mutations,
)


def fixture(entries=2,precise=1,enabled=1,jobs=1,width=8,height=8,extra=0):
    budget=residual_budget(width,height,bool(entries==2 and precise and enabled),
                           bool(entries==2 and enabled and not precise))
    reads=sum(n for n,_ in budget.values())+extra
    hits=sum(n for _,n in budget.values())
    ar=reads-hits
    lines=[f"{MODE} version=1 enabled={enabled} entries={entries} precise={precise}",
           f"{ENTRIES} entries={entries}",f"C1_NUM_SCALAR_READ_CACHE enabled={enabled}",
           f"C1_NUM_PRECISE_WRITE_INVALIDATION enabled={precise}",
           "C1_NUM_COLUMN_OPTION enabled=1 clients=8"]
    for job in range(1,jobs+1):
        lines += [f"C1_PERF_JOB job={job} error=0 mem_read={reads}",
                  f"C1_PERF_TENSOR_AXI_READ job={job} ar={ar} beats={ar}",
                  f"{PROGRESS} job={job} reads={reads} responses={reads} hits={hits} ar={ar} beats={ar}"]
        for stage in range(22):
            n,h=budget.get(stage,(extra if stage==0 else 0,0))
            lines += [f"C1_PERF_STAGE job={job} stage={stage} mem_read={n}",
                      f"{STAGE} job={job} stage={stage} reads={n} hits={h} ar={n-h} beats={n-h}"]
    return "\n".join(lines)+"\n"


class ScalarAssocTest(unittest.TestCase):
    def test_modes_and_history(self):
        self.assertIsNone(check_scalar_assoc("historical log",8,8,1))
        with self.assertRaises(ValueError):
            check_scalar_assoc("historical log",8,8,1,2)
        for entries in (1,2):
            for precise in (0,1):
                for jobs in (1,2):
                    self.assertEqual(check_scalar_assoc(fixture(entries,precise,jobs=jobs),8,8,jobs,entries),entries)
        self.assertEqual(check_scalar_assoc(fixture(1,0,0),8,8,1),1)

    def test_residual_totals_and_odd_last_half(self):
        self.assertEqual(residual_budget(64,48,True),{5:(1152,576),9:(1152,576),13:(1152,576)})
        self.assertEqual(residual_budget(4,4,True),{5:(6,2),9:(6,2),13:(6,2)})
        self.assertEqual(residual_budget(8,8,False,True),{5:(24,8),9:(24,8),13:(24,8)})
        self.assertEqual(check_scalar_assoc(fixture(width=4,height=4),4,4,1),2)
        self.assertEqual(check_scalar_assoc(fixture(extra=10),8,8,1),2)

    def test_every_generated_mutation(self):
        for entries in (1,2):
            log=fixture(entries=entries)
            for name,changed in scalar_assoc_mutations(log).items():
                with self.subTest(name=name,entries=entries),self.assertRaises(ValueError):
                    check_scalar_assoc(changed,8,8,1,entries)

    def test_per_stage_fields_and_independent_axi(self):
        log=fixture()
        for row in log.splitlines():
            if not row.startswith((STAGE+" ","C1_PERF_TENSOR_AXI_READ ","C1_PERF_STAGE ")):
                continue
            variants=["",row+"\n"+row]
            for field,value in re.findall(r"(\w+)=(\d+)",row):
                variants.append(re.sub(rf"\b{field}=\d+",f"{field}={int(value)+1}",row))
            for changed in variants:
                with self.subTest(row=row,changed=changed),self.assertRaises(ValueError):
                    check_scalar_assoc(log.replace(row,changed,1),8,8,1,2)

    def test_strict_configuration_and_job_identity(self):
        log=fixture(jobs=2)
        for old,new in (("job=2","job=1"),("job=2","job=0"),
                        ("clients=8","clients=7"),("entries=2","entries=3"),
                        ("enabled=1","enabled=0"),("precise=1","precise=0")):
            with self.subTest(old=old),self.assertRaises(ValueError):
                check_scalar_assoc(log.replace(old,new,1),8,8,2,2)
        with self.assertRaises(ValueError):
            check_scalar_assoc(fixture(entries=1),8,8,1,2)

    def test_twoframe_without_layer_traces(self):
        log="\n".join(s for s in fixture(jobs=2).splitlines() if not s.startswith((STAGE,"C1_PERF_STAGE")))
        self.assertEqual(check_scalar_assoc(log,8,8,2,2),2)
        # Existing layer targets prevent deleting just the new layer witnesses.
        partial="\n".join(s for s in fixture(jobs=2).splitlines() if not s.startswith(STAGE))
        with self.assertRaises(ValueError):
            check_scalar_assoc(partial,8,8,2,2)

    def test_equal_global_sum_cannot_hide_wrong_layer(self):
        log=fixture()
        for stage,delta in ((5,1),(9,-1)):
            row=next(s for s in log.splitlines() if s.startswith(f"{STAGE} job=1 stage={stage} "))
            altered=row.replace("hits=12",f"hits={12+delta}").replace("ar=12",f"ar={12-delta}").replace("beats=12",f"beats={12-delta}")
            log=log.replace(row,altered,1)
        with self.assertRaises(ValueError):
            check_scalar_assoc(log,8,8,1,2)

    def test_warm_abort_requirements(self):
        drained="C1_SOC_SCALAR_READ_ABORT_CACHE_PASS before=1 after=0 valid=0 pending=0"
        complete="C1_SOC_INFLIGHT_READ_ABORT_PASS pending_beats=1 owner=6 reset=0"
        log=fixture()+ABORT+"\n"+drained+"\n"+complete+"\n"
        self.assertTrue(check_scalar_assoc_abort(log,True))
        self.assertFalse(check_scalar_assoc_abort(fixture()))
        for row in (ABORT,drained,complete):
            with self.assertRaises(ValueError):
                check_scalar_assoc_abort(log.replace(row,""),True)
        with self.assertRaises(ValueError):
            check_scalar_assoc_abort(log.replace(ABORT+"\n","")+ABORT+"\n",True)
        for name,changed in scalar_assoc_mutations(log).items():
            with self.subTest(name=name),self.assertRaises(ValueError):
                check_scalar_assoc(changed,8,8,1,2)
                check_scalar_assoc_abort(changed,True)


def audit_trace(path):
    log=path.read_text(encoding="utf-8-sig")
    entries=check_scalar_assoc(log,64,48,1,required=True)
    mutations=scalar_assoc_mutations(log)
    for n,row in enumerate(s for s in log.splitlines() if s.startswith(STAGE+" ")):
        for kind,changed in (("missing",""),("duplicate",row+"\n"+row)):
            mutations[f"stage_{n}_{kind}"]=log.replace(row,changed,1)
        for field,value in re.findall(r"(\w+)=(\d+)",row):
            mutations[f"stage_{n}_{field}"]=log.replace(row,re.sub(rf"\b{field}=\d+",f"{field}={int(value)+1}",row),1)
    for name,changed in mutations.items():
        if changed==log:
            raise AssertionError(f"ineffective scalar mutation {name}")
        try:
            check_scalar_assoc(changed,64,48,1,entries)
        except ValueError:
            continue
        raise AssertionError(f"scalar contract accepted {name}")
    print(f"C1_SCALAR_ASSOC_TRACE_AUDIT_PASS entries={entries} stage_records=22 mutations={len(mutations)}")


if __name__=="__main__":
    if len(sys.argv)==3 and sys.argv[1]=="--trace":
        audit_trace(Path(sys.argv[2]))
    else:
        unittest.main()
