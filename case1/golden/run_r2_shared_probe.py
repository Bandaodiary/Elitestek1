"""C2 regression entry reconstructed after the C10 name collision.

The original C2 RTL/TBs and PW/RGB/MAC golden builders are unchanged.
C10 lives in run_r2_shared_system_probe.py. Quantization stress values here
are regenerated independently, not claimed byte-identical to the lost driver.
"""
from __future__ import annotations
import json, tempfile
from pathlib import Path
from run_r2_array_probe import ROOT, vectors as array_vectors, packed
from run_r2_pw_tile_probe import vectors as pw_vectors, affine_scalar
from run_r2_rgb_row_probe import vectors as rgb_vectors
from run_r2_shared_system_probe import run

SOURCES=['rtl/common/c1_ram_sdp_read_first.sv','rtl/cnn/c1_requant_bank8.sv',
    'rtl/r2/c1_r2_dot16_array.sv','rtl/r2/c1_r2_compute6.sv',
    'rtl/r2/c1_r2_window3x4_c8.sv','rtl/r2/c1_r2_pw16x8_feeder.sv',
    'rtl/r2/c1_r2_rgb3x3_feeder.sv','rtl/r2/c1_r2_shared_row_engine.sv']

def vectors(folder):
    queues=[[],[]]
    for mode,build in enumerate((pw_vectors,rgb_vectors)):
        part=folder/str(mode);part.mkdir();meta=build(part)
        cmd=[int(s,16) for s in (part/'input.mem').read_text().splitlines()]
        out=[int(s,16) for s in (part/'output.mem').read_text().splitlines()]
        ci=oi=0
        for j in meta['jobs']:
            translated=[]
            for v in cmd[ci:ci+j['loads']+1]:
                k=v>>(44 if mode==0 else 45);a=(v>>32)&(0xfff if mode==0 else 0x1fff)
                translated.append((k<<46)|(mode<<45)|(a<<32)|(v&0xffffffff))
            queues[mode].append((translated,[(mode<<70)|v for v in out[oi:oi+j['vectors']]],
                dict(mode=mode,size=j.get('pixels',j.get('width')),vectors=j['vectors'],
                     scalars=j['scalars'],loads=j['loads'],label=j['label'])))
            ci+=j['loads']+1;oi+=j['vectors']
        assert ci==len(cmd) and oi==len(out)
    jobs=[];commands=[];expected=[]
    for pair in zip(*queues):
        for c,o,j in pair:commands+=c;expected+=o;jobs.append(j)
    for q in queues:
        c,o,j=q[-1];commands.append(c[-1]);expected+=o
        jobs.append(dict(j,loads=0,label='cached_'+j['label']))
    (folder/'input.mem').write_text(''.join(f'{v:013x}\n' for v in commands),encoding='ascii')
    (folder/'output.mem').write_text(''.join(f'{v:018x}\n' for v in expected),encoding='ascii')
    return dict(commands=len(commands),vectors=len(expected),jobs=jobs)

def compute_vectors(folder):
    meta=array_vectors(6,folder)
    source=[int(s,16) for s in (folder/'input.mem').read_text().splitlines()]
    result=[int(s,16) for s in (folder/'output.mem').read_text().splitlines()]
    inp=[];out=[]
    def affine(tag):
        return ([(-131072,-3,0,1,65537,131071)[(tag+r)%6] for r in range(6)],
                [(0,1,7,17,46,47)[(tag+r)%6] for r in range(6)],[(tag+r)%2 for r in range(6)])
    for v in source:
        tag=(v>>1728)&65535;first=(v>>1751)&1
        mu,sh,re=affine(tag)
        if not first:mu=[17]*6;sh=[63]*6;re=[1]*6
        inp.append((v<<150)|(packed(mu,18)<<42)|(packed(sh,6)<<6)|packed(re,1))
    for v in result:
        tag=(v>>192)&65535;mask=v>>208;mu,sh,re=affine(tag);q=[]
        for r in range(6):
            acc=(v>>(32*r))&0xffffffff
            if acc>=0x80000000:acc-=0x100000000
            q.append(affine_scalar(acc,mu[r],sh[r],re[r]) if mask>>r&1 else 0)
        out.append((tag<<54)|(mask<<48)|packed(q,8))
    (folder/'input.mem').write_text(''.join(f'{v:x}\n' for v in inp),encoding='ascii')
    (folder/'output.mem').write_text(''.join(f'{v:018x}\n' for v in out),encoding='ascii')
    return dict(inputs=meta['inputs'],outputs=meta['outputs'],trained_scalars=meta['trained_scalars'],nonfirst_affine_poisoned=True)

def main():
    with tempfile.TemporaryDirectory(prefix='c1_r2_c2_restore_',dir=ROOT/'sim') as td:
        root=Path(td);m=vectors(root)
        print('C1_R2_SHARED_VECTORS '+json.dumps(m),flush=True)
        args=[f'+INPUTS={root.as_posix()}/input.mem',f'+OUTPUTS={root.as_posix()}/output.mem',f'+N={m["commands"]}',f'+M={m["vectors"]}']
        for s in (0,1):run(root,'tb_c1_r2_shared_row_engine',SOURCES,dict(STALLS=s),args,120,'C1_R2_SHARED_PASS ')
        f=root/'compute';f.mkdir();m=compute_vectors(f)
        print('C1_R2_COMPUTE_VECTORS '+json.dumps(m),flush=True)
        args=[f'+INPUTS={f.as_posix()}/input.mem',f'+OUTPUTS={f.as_posix()}/output.mem',f'+N={m["inputs"]}',f'+M={m["outputs"]}']
        for depth in (8,2):
            for s in (0,1):run(f,'tb_c1_r2_compute6',SOURCES,dict(STALLS=s,DEPTH=depth),args,120,'C1_R2_COMPUTE_PASS ')
    print('C1_R2_SHARED_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)

if __name__=='__main__':main()
