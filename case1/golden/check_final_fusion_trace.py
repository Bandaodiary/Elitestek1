"""Contract for forwarding real final-convolution pixels before identity commit."""
import re

MODE="C1_NUM_FINAL_FUSION"
PROGRESS="C1_PERF_FINAL_FUSION"
COMMIT="C1_FINAL_FUSION_COMMIT"
EOF="C1_FINAL_FUSION_EOF"
STOP="C1_FINAL_FUSION_STOP"
BEGIN="C1_FINAL_FUSION_BEGIN"
COMPUTE="C1_PERF_FINAL_COMPUTE"


def final_fusion_mode(log: str, required: bool=False, *, require_mode: bool=False) -> bool:
    modes=[s for s in log.splitlines() if s.startswith(MODE)]
    if not modes and not required and not require_mode:
        if any(s.startswith((PROGRESS,COMPUTE,"C1_FINAL_FUSION_")) for s in log.splitlines()):
            raise ValueError("fusion events without mode")
        return False
    if modes not in ([MODE+" enabled=0"],[MODE+" enabled=1"]):
        raise ValueError("final fusion mode missing/duplicate/invalid")
    enabled=modes==[MODE+" enabled=1"]
    if required and not enabled:raise ValueError("final fusion was required")
    return enabled


def check_final_compute(log: str, width: int, height: int, jobs: int) -> dict[int,int]:
    """Independent final-convolution starts, not a fabricated writer count."""
    enabled=final_fusion_mode(log)
    lines=log.splitlines(); records=[s for s in lines if s.startswith(COMPUTE)]
    if not enabled:
        if records:raise ValueError("disabled fusion has compute witness")
        return {}
    ids=[]
    for line in lines:
        if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",line):
            match=re.search(r"\bjob=(\d+)\b",line)
            if match is None:raise ValueError("fusion compute job lacks identity")
            ids.append(int(match[1]))
    if len(ids)!=jobs or ids!=sorted(set(ids)) or len(records)!=jobs:
        raise ValueError("fusion compute lacks unique successful jobs")
    early={}; pixels=width*height
    for job,line in zip(ids,records):
        row=re.fullmatch(COMPUTE+r" job=(\d+) generation=(\d+) starts=(\d+) outputs=(\d+) inputs_ahead=(\d+) starts_ahead=(\d+)",line)
        if row is None:raise ValueError("malformed fusion compute witness")
        ident,gen,starts,outputs,inputs_ahead,starts_ahead=map(int,row.groups())
        if ident!=job or gen>255 or (starts,outputs)!=(pixels,pixels):
            raise ValueError("fusion compute lost starts/retirements")
        if not 0<=starts_ahead<=inputs_ahead<pixels:
            raise ValueError("fusion compute ahead count exceeds predecessor budget")
        early[job]=starts_ahead
    return early


def check_final_fusion(log: str, width: int, height: int, jobs: int,
                       required: bool=False, *, require_mode: bool=False) -> bool:
    enabled=final_fusion_mode(log,required,require_mode=require_mode)
    check_final_compute(log,width,height,jobs)
    lines=log.splitlines()
    if not any(s.startswith(MODE) for s in lines):return False
    if any(s.startswith("C1_FINAL_FUSION_") and not s.startswith((BEGIN,COMMIT,EOF,STOP)) for s in lines):
        raise ValueError("unknown final fusion event")
    starts={};ends={};good=[]
    for pos,line in enumerate(lines):
        if line.startswith("C1_PERF_START "):
            m=re.search(r"\bjob=(\d+)\b",line)
            if m is None or int(m[1]) in starts:raise ValueError("fusion duplicate/invalid job start")
            starts[int(m[1])]=pos
        if line.startswith(("C1_PERF_JOB ","C1_PERF_ABORT ")):
            m=re.search(r"\bjob=(\d+)\b",line)
            if m is None or int(m[1]) in ends:raise ValueError("fusion duplicate/invalid job end")
            ends[int(m[1])]=pos
            if line.startswith("C1_PERF_JOB ") and re.search(r"\berror=0\b",line):good.append(int(m[1]))
    if len(good)!=jobs or good!=sorted(set(good)):raise ValueError("fusion successful jobs missing/out of order")
    patterns={BEGIN:r" job=(\d+) generation=(\d+) width=(\d+) height=(\d+)",
              COMMIT:r" job=(\d+) generation=(\d+) stage=21 inputs=(\d+) outputs=(\d+) held_eof=1",
              EOF:r" job=(\d+) generation=(\d+) inputs=(\d+) outputs=(\d+)",
              PROGRESS:r" job=(\d+) generation=(\d+) inputs=(\d+) outputs=(\d+) commits=(\d+) eofs=(\d+)",
              STOP:r" job=(\d+) generation=(\d+) inputs=(\d+) outputs=(\d+) commits=(\d+) eofs=(\d+)",
              COMPUTE:r" job=(\d+) generation=(\d+) starts=(\d+) outputs=(\d+) inputs_ahead=(\d+) starts_ahead=(\d+)"}
    tables={prefix:{} for prefix in patterns}
    order={prefix:[] for prefix in patterns}
    for pos,line in enumerate(lines):
        for prefix,pattern in patterns.items():
            if not line.startswith(prefix):continue
            m=re.fullmatch(prefix+pattern,line)
            if m is None:raise ValueError("malformed final fusion event")
            job,gen,*values=map(int,m.groups())
            if (job in tables[prefix] or gen>255 or job not in starts or job not in ends or
                    not starts[job]<pos<ends[job]):raise ValueError("fusion event identity/lifetime mismatch")
            tables[prefix][job]=(gen,values,pos);order[prefix].append(job)
    if order[PROGRESS]!=good or set(tables[STOP])!=set(ends)-set(good):
        raise ValueError("fusion lacks complete success/stop accounting")
    pixels=width*height
    for job in ends:
        terminal=tables[PROGRESS if job in good else STOP].get(job)
        if terminal is None:raise ValueError("fusion job lacks progress")
        gen,(inputs,outputs,commits,eofs),pos=terminal
        context=tables[BEGIN].get(job);commit=tables[COMMIT].get(job);eof=tables[EOF].get(job)
        if not enabled:
            if any((inputs,outputs,commits,eofs)) or context or commit or eof:
                raise ValueError("disabled final fusion was active")
            continue
        if not (0<=outputs<=inputs<=pixels and 0<=eofs<=commits<=1 and outputs<=pixels-1+eofs):
            raise ValueError("fusion invalid pixel/commit/EOF conservation")
        if (context is None and any((inputs,outputs,commits,eofs))) or bool(commit)!=bool(commits) or bool(eof)!=bool(eofs):
            raise ValueError("fusion missing context/commit/EOF witness")
        if context and (context[0]!=gen or context[1]!=[width,height] or context[2]>=pos):
            raise ValueError("fusion context geometry/generation/order mismatch")
        if commit and (not context or commit[0]!=gen or commit[1]!=[pixels,pixels-1] or
                       not context[2]<commit[2]<pos or inputs!=pixels):
            raise ValueError("fusion commit lacks held final pixel or prior results")
        if eof and (not commit or eof[0]!=gen or eof[1]!=[pixels,pixels] or
                    not commit[2]<eof[2]<pos or outputs!=pixels):
            raise ValueError("fusion EOF escaped the completion barrier")
        if job in good:
            if (inputs,outputs,commits,eofs)!=(pixels,pixels,1,1):
                raise ValueError("fusion successful job is incomplete")
            compute=tables[COMPUTE][job]
            if compute[0]!=gen or not eof[2]<compute[2]<pos:
                raise ValueError("fusion compute witness outside committed generation")
            for stage in (20,21):
                perf=[s for s in lines if s.startswith(f"C1_PERF_STAGE job={job} stage={stage} ")]
                if perf:
                    fields=dict(re.findall(r"([a-z_]+)=(\d+)",perf[0]))
                    forbidden=("mem_write",) if stage==20 else ("dot_beats","dw_beats","mem_read","mem_write","columns")
                    if len(perf)!=1 or any(fields.get(k)!="0" for k in forbidden):
                        raise ValueError("fused final intermediate still transferred")
            # Full numerical oracle remains separate. Here check chronology and
            # that identity elision did not hide final-convolution results.
            pattern=(r"C1_NUM_OUT (\d+) " if jobs==1 else rf"C1_NUM_TWO_OUT {good.index(job)} (\d+) ")
            data=[(p,int(m[1])) for p,s in enumerate(lines) if (m:=re.match(pattern,s))]
            if data:
                source=[p for p,stage in data if stage==20]
                if len(source)!=pixels or any(stage==21 for _,stage in data) or not context[2]<min(source)<=max(source)<commit[2]:
                    raise ValueError("fusion omitted/reordered real stage20 results")
    return enabled


def final_fusion_mutations(log: str) -> dict[str,str]:
    lines=log.splitlines()
    selected=[s for s in lines if s.startswith((MODE,PROGRESS,BEGIN,COMMIT,EOF,STOP,COMPUTE))]
    if not any(s.startswith(MODE) for s in selected):return {}
    cases={"fusion_all_removed":"\n".join(s for s in lines if s not in selected)+"\n"}
    mode=next(s for s in selected if s.startswith(MODE))
    cases["fusion_mode_flipped"]=log.replace(mode,MODE+" enabled="+str(1-int(mode[-1])),1)
    for i,line in enumerate(selected):
        cases[f"fusion_missing_{i}"]=log.replace(line+"\n","",1)
        cases[f"fusion_duplicate_{i}"]=log.replace(line,line+"\n"+line,1)
        cases[f"fusion_schema_{i}"]=log.replace(line,line+" unknown=1",1)
        for field,value in re.findall(r"(\w+)=(\d+)",line):
            if field in ("inputs_ahead","starts_ahead"):
                # Legal scheduling counts are not fixed; reject overflow here.
                # Global requant conservation independently checks starts_ahead.
                cases[f"fusion_field_{i}_{field}"]=log.replace(line,re.sub(rf"\b{field}=\d+",f"{field}=99999999",line),1)
                continue
            # Disabled/canceled pre-fusion generations have no independent
            # context to cross-check; do not invent a failing expectation.
            if field=="generation" and not any(s.startswith(BEGIN) and
                re.search(r" job=(\d+)",s)[1]==re.search(r" job=(\d+)",line)[1] for s in selected):continue
            cases[f"fusion_field_{i}_{field}"]=log.replace(line,re.sub(rf"\b{field}=\d+",f"{field}={int(value)+1}",line),1)
        if not line.startswith(MODE):
            cases[f"fusion_late_{i}"]=log.replace(line+"\n","",1)+line+"\n"
    return cases
