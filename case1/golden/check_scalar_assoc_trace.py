"""Scalar cache hit/miss conservation against real AXI and residual workload."""
import re
from microstyle_workload import build_layout

MODE="C1_NUM_SCALAR_ASSOC"
ENTRIES="C1_NUM_SCALAR_CACHE_ENTRIES"
PROGRESS="C1_PERF_SCALAR_ASSOC"
STAGE="C1_PERF_SCALAR_ASSOC_STAGE"
ABORT="C1_NUM_SCALAR_ASSOC_ABORT stage=5 entries=2 surviving_valid=1 hits=2 reads=5 pending=1"


def rows(log,prefix):
    return [s for s in log.splitlines() if s.startswith(prefix+" ")]


def residual_budget(width,height,two_precise,two_coarse=False):
    layout,_=build_layout(width,height)
    result={}
    for stage in (5,9,13):
        d=layout[stage]
        pixels=d.input_width*d.input_height
        groups=(d.input_channels+7)//8
        words=pixels*groups
        # The engine collects ALL groups of one pixel before writing its
        # output groups. A coarse write fence therefore loses inter-pixel,
        # but not intra-pixel reuse. Current residual descriptors use 3 groups.
        hits=2*(words//2) if two_precise else (2*pixels*(groups//2) if two_coarse else 0)
        result[stage]=(2*words,hits)
    return result


def check_scalar_assoc(log,width,height,jobs,expected_entries=None,required=False):
    headers=rows(log,MODE)
    records=rows(log,PROGRESS)
    stage_records=rows(log,STAGE)
    if not headers and not records and not stage_records and expected_entries is None and not required:
        return None
    match=re.fullmatch(MODE+r" version=1 enabled=([01]) entries=([12]) precise=([01])",headers[0]) if len(headers)==1 else None
    if match is None:
        raise ValueError("missing/duplicate/invalid scalar associative cache mode")
    enabled,entries,precise=map(int,match.groups())
    check_scalar_assoc_abort(log)
    if entries==2 and not enabled or precise and not enabled:
        raise ValueError("scalar associative mode prerequisites are absent")
    if expected_entries is not None and entries!=expected_entries:
        raise ValueError("scalar cache capacity differs from independently required profile")
    if (rows(log,ENTRIES)!=[f"{ENTRIES} entries={entries}"] or
            rows(log,"C1_NUM_SCALAR_READ_CACHE")!=[f"C1_NUM_SCALAR_READ_CACHE enabled={enabled}"] or
            rows(log,"C1_NUM_PRECISE_WRITE_INVALIDATION")!=[f"C1_NUM_PRECISE_WRITE_INVALIDATION enabled={precise}"]):
        raise ValueError("scalar cache leaf mode disagrees with requested root configuration")
    if not re.search(r"^C1_NUM_COLUMN_OPTION enabled=1 clients=[89]$",log,re.M):
        raise ValueError("scalar cache profile refers to an inactive column branch")
    targets={}
    for line in rows(log,"C1_PERF_JOB"):
        fields=dict(re.findall(r"(\w+)=(\d+)",line))
        if fields.get("error")!="0":
            continue
        if not {"job","mem_read"}<=fields.keys():
            raise ValueError("scalar cache job lacks independent logical read total")
        job=int(fields["job"])
        if job<=0 or job in targets:
            raise ValueError("scalar cache successful job owner is invalid or duplicated")
        targets[job]=int(fields["mem_read"])
    if len(targets)!=jobs or len(records)!=jobs:
        raise ValueError("scalar cache requires one summary per successful job")
    axi={}
    for line in rows(log,"C1_PERF_TENSOR_AXI_READ"):
        match=re.fullmatch(r"C1_PERF_TENSOR_AXI_READ job=(\d+) ar=(\d+) beats=(\d+)",line)
        if match is None:
            raise ValueError("invalid independent tensor AXI read summary")
        job,ar,beats=map(int,match.groups())
        if job in axi or job not in targets:
            raise ValueError("tensor AXI summary changed ownership")
        axi[job]=(ar,beats)
    if set(axi)!=set(targets):
        raise ValueError("missing independent scalar AXI witness")
    budget=residual_budget(width,height,bool(enabled and entries==2 and precise),
                           bool(enabled and entries==2 and not precise))
    residual_reads=sum(pair[0] for pair in budget.values())
    residual_hits=sum(pair[1] for pair in budget.values())
    total={}
    for job,line in zip(targets,records):
        match=re.fullmatch(PROGRESS+r" job=(\d+) reads=(\d+) responses=(\d+) hits=(\d+) ar=(\d+) beats=(\d+)",line)
        if match is None:
            raise ValueError("malformed scalar associative cache progress")
        owner,reads,responses,hits,ar,beats=map(int,match.groups())
        if (owner,reads,responses)!=(job,targets[job],targets[job]) or hits>reads or reads!=hits+ar or ar!=beats or axi[job]!=(ar,beats):
            raise ValueError("scalar logical reads/responses/hits/physical AR/R disagree")
        if not enabled and hits or reads<residual_reads:
            raise ValueError("inactive cache hit or incomplete residual workload")
        # With views/final fusion/pointwise columns, every remaining scalar
        # read belongs to the three residual stages. No fitted cycle constant.
        if reads==residual_reads and hits!=residual_hits:
            raise ValueError("scalar residual-only hit budget is not implemented")
        total[job]=(reads,hits,ar,beats)
    stage_targets={}
    for line in rows(log,"C1_PERF_STAGE"):
        fields=dict(re.findall(r"(\w+)=(\d+)",line))
        if not {"job","stage","mem_read"}<=fields.keys():
            raise ValueError("missing scalar stage target fields")
        key=(int(fields["job"]),int(fields["stage"]))
        if key[0] not in targets or not 0<=key[1]<22 or key in stage_targets:
            raise ValueError("scalar stage target owner is invalid or duplicated")
        stage_targets[key]=int(fields["mem_read"])
    if stage_targets or stage_records:
        if len(stage_targets)!=jobs*22 or len(stage_records)!=jobs*22:
            raise ValueError("missing complete scalar per-stage witnesses")
        seen=set();sums={j:[0]*4 for j in targets}
        for line in stage_records:
            match=re.fullmatch(STAGE+r" job=(\d+) stage=(\d+) reads=(\d+) hits=(\d+) ar=(\d+) beats=(\d+)",line)
            if match is None:
                raise ValueError("malformed scalar cache stage record")
            job,stage,reads,hits,ar,beats=map(int,match.groups())
            key=(job,stage)
            if key not in stage_targets or key in seen:
                raise ValueError("scalar cache stage record changed ownership")
            seen.add(key)
            if reads!=stage_targets[key] or hits>reads or reads!=hits+ar or ar!=beats:
                raise ValueError("scalar stage count conservation failed")
            if stage in budget and (reads,hits)!=budget[stage]:
                raise ValueError("scalar stage differs from descriptor-derived residual hit budget")
            sums[job]=[a+b for a,b in zip(sums[job],(reads,hits,ar,beats))]
        if any(tuple(sums[j])!=total[j] for j in targets):
            raise ValueError("scalar stage sums disagree with independent job totals")
    return entries


def check_scalar_assoc_abort(log,required=False):
    markers=rows(log,"C1_NUM_SCALAR_ASSOC_ABORT")
    if not markers and not required:
        return False
    if markers!=[ABORT] or rows(log,MODE)!=[MODE+" version=1 enabled=1 entries=2 precise=1"]:
        raise ValueError("missing/invalid warm associative replacement-read cancellation")
    drained="C1_SOC_SCALAR_READ_ABORT_CACHE_PASS before=1 after=0 valid=0 pending=0"
    completions=rows(log,"C1_SOC_INFLIGHT_READ_ABORT_PASS")
    if len(completions)!=1 or rows(log,"C1_SOC_SCALAR_READ_ABORT_CACHE_PASS")!=[drained]:
        raise ValueError("warm associative abort lacks complete late-fill/owner drain")
    if not log.index(ABORT)<log.index(drained)<log.index(completions[0]):
        raise ValueError("warm associative abort/drain/recovery order changed")
    return True


def scalar_assoc_mutations(log):
    cases={}
    targets=rows(log,MODE)+rows(log,ENTRIES)+rows(log,PROGRESS)
    for n,row in enumerate(targets):
        cases[f"scalar_assoc_missing_{n}"]=log.replace(row+"\n","",1)
        cases[f"scalar_assoc_duplicate_{n}"]=log.replace(row,row+"\n"+row,1)
        for field,value in re.findall(r"(\w+)=(\d+)",row):
            cases[f"scalar_assoc_bad_{n}_{field}"]=log.replace(row,re.sub(rf"\b{field}=\d+",f"{field}={int(value)+1}",row),1)
    cases["scalar_assoc_all_removed"]="\n".join(s for s in log.splitlines() if not s.startswith((MODE,ENTRIES,PROGRESS)))+"\n"
    if rows(log,STAGE):
        row=rows(log,STAGE)[0]
        cases["scalar_assoc_stage_missing"]=log.replace(row+"\n","",1)
        cases["scalar_assoc_stage_duplicate"]=log.replace(row,row+"\n"+row,1)
    if ABORT in log:
        cases["scalar_assoc_abort_missing"]=log.replace(ABORT+"\n","",1)
        cases["scalar_assoc_abort_duplicate"]=log.replace(ABORT,ABORT+"\n"+ABORT,1)
        for field,value in re.findall(r"(\w+)=(\d+)",ABORT):
            cases[f"scalar_assoc_abort_bad_{field}"]=log.replace(ABORT,re.sub(rf"\b{field}=\d+",f"{field}={int(value)+1}",ABORT),1)
    return cases
