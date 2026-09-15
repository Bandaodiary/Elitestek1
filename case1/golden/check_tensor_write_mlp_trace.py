"""Audit actual tensor-client AXI AW/B debt, separately from logical credits."""
import re
from check_dot_pixel_pipeline_trace import check_dot_pixel_abort,check_all_dot_abort
from check_dw_pixel_pipeline_trace import check_dw_pixel_abort

MODE="C1_NUM_TENSOR_WRITE_MLP"
PROGRESS="C1_PERF_TENSOR_WRITE_MLP"
ABORT="C1_NUM_TENSOR_MLP_ABORT"


def check_tensor_write_mlp(log: str, jobs: int, required_slots: int|None=None,
                           require_abort: bool=False) -> int|None:
    lines=log.splitlines()
    modes=[s for s in lines if s.startswith(MODE)]
    records=[s for s in lines if s.startswith(PROGRESS)]
    aborts=[s for s in lines if s.startswith(ABORT)]
    if not modes and not records and not aborts and required_slots is None and not require_abort:return None
    mode=re.fullmatch(MODE+r" outstanding=(1|2|4)",modes[0]) if len(modes)==1 else None
    if mode is None:raise ValueError("tensor MLP mode missing/duplicate/invalid")
    slots=int(mode[1])
    if required_slots is not None and slots!=required_slots:raise ValueError("tensor MLP actual capacity differs from required selection")
    if slots>1:
        columns=[s for s in lines if s.startswith("C1_NUM_COLUMN_OPTION")]
        packing=[s for s in lines if s.startswith("C1_NUM_TENSOR_WRITE_OPTIONS")]
        if len(columns)!=1 or not re.fullmatch(r"C1_NUM_COLUMN_OPTION enabled=1 clients=\d+",columns[0]):
            raise ValueError("tensor MLP lacks actual column branch")
        if len(packing)!=1 or not re.fullmatch(r"C1_NUM_TENSOR_WRITE_OPTIONS packed=1 pipeline=[01] end=[01]",packing[0]):
            raise ValueError("tensor MLP lacks actual packed-write branch")
    ids=[]
    for line in lines:
        if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",line):
            row=re.search(r"\bjob=(\d+)\b",line)
            if row is None:raise ValueError("tensor MLP job lacks id")
            ids.append(int(row[1]))
    if len(ids)!=jobs or len(set(ids))!=jobs or any(i<=0 for i in ids) or len(records)!=jobs:
        raise ValueError("tensor MLP successful job records missing/duplicate")
    for job,line in zip(ids,records):
        row=re.fullmatch(PROGRESS+r" job=(\d+) aw=(\d+) b=(\d+) peak=(\d+)",line)
        if row is None:raise ValueError("tensor MLP progress malformed")
        ident,aw,b,peak=map(int,row.groups())
        if ident!=job or aw!=b or aw<=0 or not 1<=peak<=min(aw,slots):
            raise ValueError("tensor MLP AW/B conservation or physical credit bound failed")
        physical=[s for s in lines if s.startswith(f"C1_PERF_TENSOR_AXI_WRITE job={job} ")]
        p=re.fullmatch(r"C1_PERF_TENSOR_AXI_WRITE job=\d+ aw=(\d+) beats=(\d+) b=(\d+) full_beats=(\d+)",physical[0]) if len(physical)==1 else None
        if p is None or int(p[1])!=aw or int(p[3])!=b or not aw<=int(p[2])<=4*aw or int(p[4])>int(p[2]):
            raise ValueError("tensor MLP does not reconcile with actual AXI write traffic")
    if require_abort or aborts:
        a=re.fullmatch(ABORT+r" client=6 pending=(\d+) capture_idle=1",aborts[0]) if len(aborts)==1 else None
        if slots==1 or a is None or not 2<=int(a[1])<=slots:
            raise ValueError("tensor MLP abort missing same-client physical debt")
        pixel_aborts=[s for s in lines if s.startswith(("C1_NUM_DOT_PIXEL_ABORT","C1_NUM_DW_PIXEL_ABORT","C1_NUM_ALL_DOT_PIXEL_ABORT"))]
        if len(pixel_aborts)!=1:raise ValueError("tensor MLP needs exactly one raster write-abort owner")
        if pixel_aborts[0].startswith("C1_NUM_DW_PIXEL_ABORT"):check_dw_pixel_abort(log,True)
        elif pixel_aborts[0].startswith("C1_NUM_ALL_DOT_PIXEL_ABORT"):check_all_dot_abort(log,True)
        else:check_dot_pixel_abort(log,True)
        drain=next(s for s in lines if s.startswith("C1_SOC_INFLIGHT_WRITE_ABORT_DRAIN_PASS"))
        drain_pending=re.search(r" pending=(\d+)",drain)
        if drain_pending is None or int(drain_pending[1])>int(a[1]):
            raise ValueError("tensor MLP abort did not own the global physical debt")
        dot=pixel_aborts[0]
        if not log.index(dot)<log.index(aborts[0])<log.index(drain):
            raise ValueError("tensor MLP abort witness out of lifecycle order")
    return slots


def tensor_mlp_mutations(log: str) -> dict[str,str]:
    lines=log.splitlines();modes=[s for s in lines if s.startswith(MODE)]
    if len(modes)!=1:return {}
    targets=modes+[s for s in lines if s.startswith((PROGRESS,ABORT))]
    cases={}
    for i,target in enumerate(targets):
        cases[f"write_mlp_missing_{i}"]=log.replace(target+"\n","",1)
        cases[f"write_mlp_duplicate_{i}"]=log.replace(target,target+"\n"+target,1)
    cases["write_mlp_all_removed"]="\n".join(s for s in lines if not s.startswith((MODE,PROGRESS,ABORT)))+"\n"
    for value in (0,3,8):cases[f"write_mlp_bad_mode_{value}"]=log.replace(modes[0],MODE+f" outstanding={value}",1)
    for value in (1,2,4):
        if modes[0]!=MODE+f" outstanding={value}":
            cases[f"write_mlp_wrong_selection_{value}"]=log.replace(modes[0],MODE+f" outstanding={value}",1)
    for i,target in enumerate(s for s in lines if s.startswith(PROGRESS)):
        for field in ("job","aw","b","peak"):
            cases[f"write_mlp_{i}_zero_{field}"]=log.replace(target,re.sub(rf"\b{field}=\d+",field+"=0",target),1)
        cases[f"write_mlp_{i}_peak_overflow"]=log.replace(target,re.sub(r"peak=\d+","peak=9",target),1)
    for target in (s for s in lines if s.startswith(ABORT)):
        for before,after in (("client=6","client=5"),("capture_idle=1","capture_idle=0")):
            cases[f"write_mlp_abort_{before}"]=log.replace(target,target.replace(before,after),1)
        cases["write_mlp_abort_one_debt"]=log.replace(target,re.sub(r"pending=\d+","pending=1",target),1)
        cases["write_mlp_abort_late"]=log.replace(target+"\n","",1)+target+"\n"
    return cases
