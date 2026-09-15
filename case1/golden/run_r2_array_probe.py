"""Disposable Icarus R2 MAC probe; real QAT layer data + randomized s32 wraps.

Only small text summaries survive. This checks the arithmetic stream, NOT the
tile loader, quantizer RTL, SoC, native frame throughput or board memory.
"""
from __future__ import annotations
import argparse,json,random,subprocess,sys,tempfile
from pathlib import Path
import numpy as np
from generate_microstyle_engine_bitexact_vectors import _image,_stage_sources,STAGE_NAMES,integer_infer_rgb
from microstyle_quant import _read_layer_arrays

ROOT=Path(__file__).resolve().parents[1]

def packed(values,bits):
    n=0
    for i,v in enumerate(values):n|=(int(v)&((1<<bits)-1))<<(i*bits)
    return n

def wrap(v):return (int(v)+(1<<31))%(1<<32)-(1<<31)

def vectors(rows,directory):
    ip=directory/'input.mem';op=directory/'output.mem'
    count=0;outputs=0;tag=0;trained_scalars=0;stage_summary=[]
    rng=random.Random(20260913)
    with ip.open('w',encoding='ascii') as inf,op.open('w',encoding='ascii') as outf:
        def emit(aa,bb,bias,mask,expected):
            nonlocal count,outputs,tag
            length=len(aa[0]);assert all(len(x)==length for x in aa+bb)
            for off in range(0,length,16):
                av=[(aa[r][k] if k<length else 0) for r in range(rows) for k in range(off,off+16)]
                bv=[(bb[r][k] if k<length else 0) for r in range(rows) for k in range(off,off+16)]
                record=int(off==0)
                for value,bits in ((int(off+16>=length),1),(mask,rows),(tag,16),(packed(bias,32),rows*32),
                                   (packed(av,8),rows*128),(packed(bv,8),rows*128)):
                    record=(record<<bits)|value
                inf.write(f'{record:x}\n');count+=1
            record=(mask<<(16+rows*32))|(tag<<(rows*32))|packed([expected[r] if mask>>r&1 else 0 for r in range(rows)],32)
            outf.write(f'{record:x}\n');outputs+=1;tag+=1
            if tag>65535:raise ValueError('tag overflow')

        for trial in range(180):
            length=(1,9,16,17,27,48,72,108,271)[trial%9]
            aa=[[rng.randrange(-128,128) for _ in range(length)] for _ in range(rows)]
            bb=[[rng.randrange(-128,128) for _ in range(length)] for _ in range(rows)]
            if trial%11==0:aa=[[(-128 if k%2 else 127) for k in range(length)] for _ in range(rows)]
            bias=[rng.choice((-(1<<31),(1<<31)-1,rng.randrange(-100000,100000))) for _ in range(rows)]
            mask=rng.randrange(1<<rows) if trial%3 else (1<<rows)-1
            expected=[wrap(bias[r]+sum(a*b for a,b in zip(aa[r],bb[r]))) for r in range(rows)]
            emit(aa,bb,bias,mask,expected)

        artifact=ROOT/'model/microstyle24_starry_functional'
        manifest=json.loads((artifact/'manifest.json').read_text(encoding='utf-8'))
        if manifest.get('trained') is not True:raise ValueError('trained artifact required')
        arena=(artifact/manifest['parameter_file']).read_bytes()
        quant={r['name']:r for r in manifest['quantized_layers']}
        image=_image(640,4)
        _,layers=integer_infer_rgb(image,artifact,collect=True)
        for stage in (18,19,20):
            name=STAGE_NAMES[stage];source,_=_stage_sources(image,layers,stage)
            row=quant[name];weight,bias,mult,shift=_read_layer_arrays(arena,row)
            target=layers[name];h,w,cout=target.shape
            cin=source.shape[2];kh,kw=weight.shape[2:];dw=int(row['groups'])==cin
            reduction=(1 if dw else cin)*kh*kw
            before=count;before_out=outputs
            for base in range(0,h*w*cout,rows):
                aa=[];bb=[];biases=[];expected=[];mask=0
                for r in range(rows):
                    n=base+r
                    if n>=h*w*cout:
                        aa.append([0]*reduction);bb.append([0]*reduction);biases.append(0);expected.append(0);continue
                    y,x,c=n//(w*cout),(n//cout)%w,n%cout
                    acts=[];weights=[]
                    # Independent OIHW walk, not the RTL's 16-term packing.
                    for ic in range(1 if dw else cin):
                        for ky in range(kh):
                            for kx in range(kw):
                                sy=min(max(y+ky-kh//2,0),source.shape[0]-1)
                                sx=min(max(x+kx-kw//2,0),source.shape[1]-1)
                                acts.append(int(source[sy,sx,c if dw else ic]))
                                weights.append(int(weight[c,ic,ky,kx]))
                    acc=int(bias[c])+sum(a*b for a,b in zip(acts,weights))
                    if not -(1<<31)<=acc<(1<<31):raise ValueError('trained s32 overflow')
                    product=acc*int(mult[c]);sh=int(shift[c])
                    q=((abs(product)+(1<<(sh-1)))>>sh) if sh else abs(product)
                    if product<0:q=-q
                    q=max(-128,min(127,q))
                    if int(row['activation'])==1:q=max(0,q)
                    if q!=int(target[y,x,c]):raise ValueError(f'independent full-network layer mismatch {name} {y,x,c}')
                    aa.append(acts);bb.append(weights);biases.append(int(bias[c]));expected.append(acc);mask|=1<<r
                    trained_scalars+=1
                emit(aa,bb,biases,mask,expected)
            stage_summary.append(dict(stage=stage,width=w,height=h,outputs=h*w*cout,reduction=reduction,input_beats=count-before,result_vectors=outputs-before_out))
    return dict(inputs=count,outputs=outputs,trained_scalars=trained_scalars,stages=stage_summary)

def run(rows,stalls,directory,meta):
    executable=directory/f'r{rows}_{stalls}.vvp'
    compile_cmd=['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_c1_r2_dot16_array',f'-Ptb_c1_r2_dot16_array.ROWS={rows}',f'-Ptb_c1_r2_dot16_array.STALLS={stalls}',
                 '-o',str(executable),str(ROOT/'rtl/r2/c1_r2_dot16_array.sv'),str(ROOT/'sim/tb_c1_r2_dot16_array.sv')]
    for cmd in (compile_cmd,['D:/iverilog/bin/vvp.exe',str(executable),f'+INPUTS={directory.as_posix()}/input.mem',f'+OUTPUTS={directory.as_posix()}/output.mem',f'+N={meta["inputs"]}',f'+M={meta["outputs"]}']):
        result=subprocess.run(cmd,capture_output=True,text=True,timeout=120)
        if result.returncode:
            raise RuntimeError('R2 command failed:\n'+'\n'.join((result.stdout+result.stderr).splitlines()[-16:]))
    lines=[line for line in result.stdout.splitlines() if line.startswith('C1_R2_ARRAY_PASS ')]
    if len(lines)!=1 or 'ERROR' in result.stdout or 'FATAL' in result.stdout:raise ValueError('missing/invalid R2 completion')
    print(lines[0],flush=True)

def host_probe(rows,directory):
    executable=directory/f'host_r{rows}.vvp'
    commands=[['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_c1_r2_array_host_probe',f'-Ptb_c1_r2_array_host_probe.ROWS={rows}',
               '-o',str(executable),str(ROOT/'rtl/r2/c1_r2_dot16_array.sv'),str(ROOT/'rtl/r2/c1_r2_array_host_probe.sv'),str(ROOT/'sim/tb_c1_r2_array_host_probe.sv')],
              ['D:/iverilog/bin/vvp.exe',str(executable)]]
    for cmd in commands:
        result=subprocess.run(cmd,capture_output=True,text=True,timeout=30)
        if result.returncode:raise RuntimeError('host probe failed:\n'+result.stdout[-3000:]+result.stderr[-1000:])
    if result.stdout.count('C1_R2_ARRAY_HOST_PASS ')!=1:raise ValueError('host proof absent')
    print(result.stdout.strip(),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--rows',type=int,nargs='+',default=[6,8],choices=[4,6,8]);a=p.parse_args()
    for rows in a.rows:
        with tempfile.TemporaryDirectory(prefix='c1_r2_array_',dir=ROOT/'sim') as td:
            d=Path(td);host_probe(rows,d);meta=vectors(rows,d)
            print('C1_R2_TRAINED_STRIP_VECTORS '+json.dumps(dict(rows=rows,**meta),separators=(',',':')),flush=True)
            for stalls in (0,1):run(rows,stalls,d,meta)
        print(f'C1_R2_TEMP_CLEAN_PASS rows={rows}',flush=True)
