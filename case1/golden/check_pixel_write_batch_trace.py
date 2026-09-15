"""Check actual raster batch hints, not assumed AXI burst packing efficiency."""
import re
from microstyle_workload import workload
from check_dot_pixel_pipeline_trace import check_dot_pixel_pipeline,all_dot_groups_enabled
from check_dw_pixel_pipeline_trace import check_dw_pixel_pipeline
from check_final_fusion_trace import final_fusion_mode

MODE="C1_NUM_PIXEL_WRITE_BATCH"
PROGRESS="C1_PERF_PIXEL_WRITE_BATCH"


def batch_budget(width: int, height: int, words: int, pointwise: bool, all_groups: bool=False, fuse_final: bool=False) -> tuple[int,int]:
    if words not in (1,2,4,8):raise ValueError("unsupported pixel write batch")
    selected=[s for s in workload(width,height)["stages"]
              if not(fuse_final and s["stage"]==20) and (s["opcode"]==1 or (s["opcode"]==2 and pointwise)) and
              (all_groups or s["C8_results"]==s["output_width"]*s["output_height"])]
    return (sum(s["C8_results"] for s in selected),
            sum(((s["C8_results"]//s["output_height"]+words-1)//words)*s["output_height"] for s in selected))


def check_pixel_write_batch(log: str, width: int, height: int, jobs: int,
                            required: tuple[int,int]|None=None) -> tuple[int,int]|None:
    lines=log.splitlines()
    modes=[s for s in lines if s.startswith(MODE)]
    records=[s for s in lines if s.startswith(PROGRESS)]
    if not modes and not records and required is None:return None
    mode=re.fullmatch(MODE+r" words=(1|2|4|8) build_timeout=(\d+)",modes[0]) if len(modes)==1 else None
    if mode is None:raise ValueError("pixel batching mode missing/duplicate/invalid")
    words,timeout=map(int,mode.groups())
    if not 1<=timeout<=255 or (required is not None and (words,timeout)!=tuple(required)):
        raise ValueError("pixel batching actual selection differs from requested configuration")
    enabled=bool(check_dot_pixel_pipeline(log,width,height,jobs))
    dw_enabled=check_dw_pixel_pipeline(log,width,height,jobs)
    if words>1 and not enabled and not dw_enabled:raise ValueError("pixel batching lacks an actual pixel pipeline")
    if words>1 or timeout!=8:
        packing=[s for s in lines if s.startswith("C1_NUM_TENSOR_WRITE_OPTIONS")]
        p=re.fullmatch(r"C1_NUM_TENSOR_WRITE_OPTIONS packed=1 pipeline=[01] end=([01])",packing[0]) if len(packing)==1 else None
        columns=[s for s in lines if s.startswith("C1_NUM_COLUMN_OPTION")]
        if (p is None or (words>1 and p[1]!="1") or len(columns)!=1 or
            not re.fullmatch(r"C1_NUM_COLUMN_OPTION enabled=1 clients=\d+",columns[0])):
            raise ValueError("pixel batching/build timeout lacks packed column/end prerequisites")
    pointwise="C1_NUM_POINTWISE_COLUMN_READS enabled=1" in lines
    count,ends=batch_budget(width,height,words,pointwise,all_dot_groups_enabled(log),final_fusion_mode(log)) if enabled else (0,0)
    # Dot checker already validates unique successful-job identities, exact
    # requests/responses and compute counts. Match that ordered witness.
    dots=[s for s in lines if s.startswith("C1_PERF_DOT_PIXEL_PIPELINE ")]
    if len(records)!=jobs or len(dots)!=jobs:raise ValueError("pixel batching missing successful job records")
    for dot,line in zip(dots,records):
        row=re.fullmatch(PROGRESS+r" job=(\d+) writes=(\d+) ends=(\d+)",line)
        ident=re.search(r" job=(\d+) ",dot)
        if row is None or ident is None or tuple(map(int,row.groups()))!=(int(ident[1]),count,ends):
            raise ValueError("pixel batching raster/end budget or ordered job mismatch")
    return words,timeout


def pixel_batch_mutations(log: str) -> dict[str,str]:
    lines=log.splitlines();modes=[s for s in lines if s.startswith(MODE)]
    if len(modes)!=1:return {}
    cases={};targets=modes+[s for s in lines if s.startswith(PROGRESS)]
    for i,target in enumerate(targets):
        cases[f"pixel_batch_missing_{i}"]=log.replace(target+"\n","",1)
        cases[f"pixel_batch_duplicate_{i}"]=log.replace(target,target+"\n"+target,1)
    cases["pixel_batch_all_removed"]="\n".join(s for s in lines if not s.startswith((MODE,PROGRESS)))+"\n"
    for field,values in (("words",(0,1,2,3,4,8,16)),("build_timeout",(0,8,32,64,256))):
        for value in values:
            changed=re.sub(rf"\b{field}=\d+",f"{field}={value}",modes[0])
            if changed!=modes[0]:cases[f"pixel_batch_{field}_{value}"]=log.replace(modes[0],changed,1)
    for i,target in enumerate(targets[1:]):
        for field in ("job","writes","ends"):
            changed=re.sub(rf"\b{field}=(\d+)",lambda m:f"{field}={int(m[1])+1}",target)
            cases[f"pixel_batch_{i}_{field}"]=log.replace(target,changed,1)
    return cases
