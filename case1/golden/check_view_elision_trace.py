"""Audit metadata-only nearest-neighbour views, never fabricate C8 results.

This contract gate supplements (does not replace) the full integer-network
golden comparison of all non-elided results and the final DDR/video image.
"""
import re
from microstyle_workload import workload

MODE="C1_NUM_VIEW_ELISION"
EVENT="C1_VIEW_COMMIT"
PROGRESS="C1_PERF_VIEW_ELISION"
CONTEXT="C1_VIEW_CONTEXT"
STOP="C1_VIEW_STOP"


def check_view_elision(log: str, width: int, height: int, jobs: int,
                       required: bool=False, *, require_mode: bool=False) -> bool:
    lines=log.splitlines()
    modes=[s for s in lines if s.startswith(MODE)]
    events=[s for s in lines if s.startswith(EVENT)]
    records=[s for s in lines if s.startswith(PROGRESS)]
    contexts=[s for s in lines if s.startswith(CONTEXT)]
    stops=[s for s in lines if s.startswith(STOP)]
    if any(s.startswith("C1_VIEW_") and not s.startswith((EVENT,CONTEXT,STOP)) for s in lines):
        raise ValueError("unknown view trace record")
    if not modes and not events and not records and not contexts and not stops and not required and not require_mode:
        return False
    if modes not in ([MODE+" enabled=0"],[MODE+" enabled=1"]):
        raise ValueError("view elision mode missing/duplicate/invalid")
    enabled=modes==[MODE+" enabled=1"]
    if required and not enabled:raise ValueError("view elision was required")
    if enabled and ([s for s in lines if s.startswith("C1_NUM_VIRTUAL_UPSAMPLE enabled=")] !=
                    ["C1_NUM_VIRTUAL_UPSAMPLE enabled=1"] or
                    not any(re.fullmatch(r"C1_NUM_COLUMN_OPTION enabled=1 clients=[89]",s) for s in lines)):
        raise ValueError("view elision lacks virtual tensor/column ownership")
    starts={}
    ends={}
    success=[]
    for pos,line in enumerate(lines):
        if line.startswith("C1_PERF_START "):
            row=re.search(r"\bjob=(\d+)\b",line)
            if row is None or int(row[1]) in starts:raise ValueError("view job start invalid/duplicate")
            starts[int(row[1])]=pos
        if line.startswith(("C1_PERF_JOB ","C1_PERF_ABORT ")):
            row=re.search(r"\bjob=(\d+)\b",line)
            if row is None or int(row[1]) in ends:raise ValueError("view job termination invalid/duplicate")
            ends[int(row[1])]=pos
            if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",line):success.append(int(row[1]))
    if len(success)!=jobs or success!=sorted(set(success)) or len(records)!=jobs:
        raise ValueError("view progress lacks ordered successful jobs")
    targets={s["stage"]:s for s in workload(width,height,virtual_upsample=True)["stages"] if s["stage"] in (14,17)}
    captured={}
    for context in contexts:
        row=re.fullmatch(CONTEXT+r" job=(\d+) generation=(\d+)",context)
        if row is None or not enabled:raise ValueError("invalid/unexpected view context")
        job,gen=map(int,row.groups())
        if job in captured or gen>255 or job not in starts or job not in ends or not starts[job]<lines.index(context)<ends[job]:
            raise ValueError("view context identity/lifetime mismatch")
        captured[job]=(gen,lines.index(context))
    grouped={}
    for event in events:
        row=re.fullmatch(EVENT+r" job=(\d+) stage=(\d+) generation=(\d+) input_bank=(\d+) output_bank=(\d+) width=(\d+) height=(\d+) groups=(\d+) debt=(\d+)",event)
        if row is None or not enabled:raise ValueError("invalid/unexpected view commit")
        job,stage,gen,bank,outbank,w,h,groups,debt=map(int,row.groups())
        t=targets.get(stage)
        if (t is None or gen>255 or bank!=0 or outbank!=3 or debt!=0 or
            (w,h,groups)!=(t["output_width"]//2,t["output_height"]//2,t["input_groups"]) or
            job not in captured or gen!=captured[job][0] or
            not captured[job][1]<lines.index(event)<ends[job]):
            raise ValueError("view identity/geometry/ownership/lifetime mismatch")
        grouped.setdefault(job,[]).append((stage,gen,event))
    for job,rows in grouped.items():
        if [s for s,_,_ in rows] != [14,17][:len(rows)] or len({g for _,g,_ in rows})!=1:
            raise ValueError("view commits must be a unique ordered prefix, also on cancellation")
    stopped={}
    for stop in stops:
        row=re.fullmatch(STOP+r" job=(\d+) generation=(\d+) views=(\d+)",stop)
        if row is None:raise ValueError("invalid view stop accounting")
        job,gen,count=map(int,row.groups())
        if (job in stopped or job in success or gen>255 or count>2 or job not in starts or job not in ends or
            not starts[job]<lines.index(stop)<ends[job] or len(grouped.get(job,[]))!=count or
            (job in captured and gen!=captured[job][0])):
            raise ValueError("view stop generation/count/lifetime mismatch")
        stopped[job]=count
    if set(stopped)!=set(ends)-set(success):raise ValueError("missing aborted/failed view accounting")
    for job,record in zip(success,records):
        row=re.fullmatch(PROGRESS+r" job=(\d+) generation=(\d+) views=(\d+)",record)
        if (row is None or int(row[1])!=job or int(row[2])>255 or int(row[3])!=(2 if enabled else 0) or
            job not in starts or job not in ends or not starts[job]<lines.index(record)<ends[job]):
            raise ValueError("view completion progress invalid")
        committed=grouped.get(job,[])
        if (len(committed)!=(2 if enabled else 0) or any(g!=int(row[2]) for _,g,_ in committed) or
            (enabled and (job not in captured or captured[job][0]!=int(row[2])))):
            raise ValueError("view completion count/generation mismatch")
        if not enabled:continue
        for stage,_,event in committed:
            perf=[s for s in lines if s.startswith(f"C1_PERF_STAGE job={job} stage={stage} ")]
            if perf:
                fields=dict(re.findall(r"([a-z_]+)=(\d+)",perf[0]))
                if len(perf)!=1 or any(fields.get(k)!="0" for k in ("dot_beats","dw_beats","mem_read","mem_write","columns")):
                    raise ValueError("elided stage still transferred tensor data")
            # When numerical traces exist, place each commit strictly between
            # its predecessor's last result and its successor's first result.
            pattern=(rf"C1_NUM_OUT (\d+) " if jobs==1 else
                     rf"C1_NUM_TWO_OUT {success.index(job)} (\d+) ")
            data=[(p,int(m[1])) for p,s in enumerate(lines) if (m:=re.match(pattern,s))]
            if data:
                before=[p for p,k in data if k==stage-1]
                after=[p for p,k in data if k==stage+1]
                if any(k==stage for _,k in data) or not before or not after or not max(before)<lines.index(event)<min(after):
                    raise ValueError("view commit/result chronology mismatch")
    return enabled


def view_elision_mutations(log: str) -> dict[str,str]:
    modes=[s for s in log.splitlines() if s.startswith(MODE)]
    records=[s for s in log.splitlines() if s.startswith(PROGRESS)]
    events=[s for s in log.splitlines() if s.startswith(EVENT)]
    if not modes or not records:return {}
    variants={"view_mode_removed":log.replace(modes[0]+"\n","",1),
              "view_mode_duplicate":log.replace(modes[0],modes[0]+"\n"+modes[0],1),
              "view_mode_flipped":log.replace(modes[0],MODE+" enabled="+str(1-int(modes[0][-1])),1),
              "view_progress_removed":log.replace(records[0]+"\n","",1),
              "view_progress_duplicate":log.replace(records[0],records[0]+"\n"+records[0],1),
              "view_all_removed":"\n".join(s for s in log.splitlines() if not s.startswith((MODE,PROGRESS,EVENT,CONTEXT,STOP)))+"\n"}
    for target,fields in ((records[0],("job","generation","views") if modes[0].endswith("=1") else ("job","views")), *((e,("job","stage","generation","input_bank","output_bank","width","height","groups","debt")) for e in events)):
        for field in fields:
            old=re.search(rf"\b{field}=(\d+)",target)
            bad=target.replace(old[0],f"{field}={int(old[1])+1}",1)
            variants[f"view_{len(variants)}_{field}"]=log.replace(target,bad,1)
    for i,event in enumerate(events):
        variants[f"view_event_{i}_removed"]=log.replace(event+"\n","",1)
        variants[f"view_event_{i}_duplicate"]=log.replace(event,event+"\n"+event,1)
        variants[f"view_event_{i}_late"]=log.replace(event+"\n","",1)+"\n"+event+"\n"
    for i,context in enumerate(s for s in log.splitlines() if s.startswith(CONTEXT)):
        variants[f"view_context_{i}_removed"]=log.replace(context+"\n","",1)
        variants[f"view_context_{i}_duplicate"]=log.replace(context,context+"\n"+context,1)
        variants[f"view_context_{i}_generation"]=log.replace(context,re.sub(r"generation=\d+","generation=999",context),1)
    for i,stop in enumerate(s for s in log.splitlines() if s.startswith(STOP)):
        variants[f"view_stop_{i}_removed"]=log.replace(stop+"\n","",1)
        variants[f"view_stop_{i}_duplicate"]=log.replace(stop,stop+"\n"+stop,1)
        variants[f"view_stop_{i}_count"]=log.replace(stop,re.sub(r"views=\d+","views=3",stop),1)
    return variants
