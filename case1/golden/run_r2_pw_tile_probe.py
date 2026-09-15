"""R2-B real banked feature RAM + 96 MAC + six affine lanes; disposable Icarus.

Native-width stage19 QAT data and independently calculated randomized INT8
cases. The host loader is deliberately not included in compute throughput.
"""
from __future__ import annotations
import json, random, subprocess, tempfile
from pathlib import Path
import numpy as np
from run_r2_array_probe import ROOT, packed, wrap
from generate_microstyle_engine_bitexact_vectors import _image, _stage_sources, STAGE_NAMES, integer_infer_rgb
from microstyle_quant import _read_layer_arrays


def affine_scalar(acc, mult, shift, relu):
    value=int(acc)*int(mult)
    rounded=(abs(value)+(1<<(shift-1)))>>shift if shift else abs(value)
    if value<0: rounded=-rounded
    result=min(127,max(-128,rounded))
    return max(0,result) if relu else result


def vectors(directory):
    commands=[]; expected=[]; jobs=[]
    def emit(kind,address,data): commands.append((kind<<44)|(address<<32)|(int(data)&0xffffffff))
    def job(label,source,weight,bias,mult,shift,relu,target=None):
        pixels=len(source); assert source.shape==(pixels,16) and weight.shape==(8,16)
        # Deliberately shuffled load order exercises the byte/word/pixel banks.
        loads=[(0,p*4+w,packed(source[p,w*4:w*4+4],8)) for p in range(pixels) for w in range(4)]
        loads += [(1,c*4+w,packed(weight[c,w*4:w*4+4],8)) for c in range(8) for w in range(4)]
        loads += [(2,c,bias[c]) for c in range(8)]
        loads += [(3,c,(int(relu[c])<<24)|(int(shift[c])<<18)|(int(mult[c])&0x3ffff)) for c in range(8)]
        random.Random(73+len(jobs)).shuffle(loads)
        for args in loads: emit(*args)
        emit(4,0,pixels)
        values=[]
        for p in range(pixels):
            for c in range(8):
                acc=wrap(int(bias[c])+sum(int(source[p,k])*int(weight[c,k]) for k in range(16)))
                value=affine_scalar(acc,int(mult[c]),int(shift[c]),bool(relu[c]))
                if target is not None and value!=int(target[p,c]): raise AssertionError((label,p,c,value,target[p,c]))
                values.append(value)
        for base in range(0,len(values),6):
            chunk=values[base:base+6];mask=(1<<len(chunk))-1
            expected.append((base<<54)|(mask<<48)|packed(chunk,8))
        jobs.append(dict(label=label,pixels=pixels,scalars=len(values),vectors=(len(values)+5)//6,loads=len(loads)))

    artifact=ROOT/'model/microstyle24_starry_functional'
    manifest=json.loads((artifact/'manifest.json').read_text(encoding='utf-8'))
    assert manifest['trained'] is True
    row=next(row for row in manifest['quantized_layers'] if row['name']==STAGE_NAMES[19])
    weight,bias,mult,shift=_read_layer_arrays((artifact/manifest['parameter_file']).read_bytes(),row)
    assert weight.shape==(8,16,1,1)
    image=_image(640,4);_,layers=integer_infer_rgb(image,artifact,collect=True)
    source,_=_stage_sources(image,layers,19)
    for y in range(4): job(f'qat_stage19_row{y}',source[y],weight[:,:,0,0],bias,mult,shift,[row['activation']]*8,layers[row['name']][y])
    rng=np.random.default_rng(20260913)
    for trial,pixels in enumerate((1,2,3,7,31,639,641,1024)):
        src=rng.integers(-128,128,(pixels,16),dtype=np.int16)
        wt=rng.integers(-128,128,(8,16),dtype=np.int16)
        bi=[-2**31,2**31-1,-1,0,1,-65537,65537,1234567]
        mu=[-131072,131071,-1,1,0,65537,3,-7]
        sh=[0,1,2,15,17,31,46,47]
        rl=[(c+trial)%2 for c in range(8)]
        job(f'random_{trial}',src,wt,bi,mu,sh,rl)
    # Exactly half-way +/-1/2 and +/-3/2; both signs, saturation, and ReLU.
    job('ties_away',np.zeros((3,16),dtype=np.int16),np.zeros((8,16),dtype=np.int16),
        [1,-1,3,-3,255,-257,-3,3],[1]*8,[1]*8,[0,0,0,0,0,0,1,1])
    (directory/'input.mem').write_text(''.join(f'{x:012x}\n' for x in commands),encoding='ascii')
    (directory/'output.mem').write_text(''.join(f'{x:017x}\n' for x in expected),encoding='ascii')
    return dict(commands=len(commands),vectors=len(expected),jobs=jobs)


def main():
    with tempfile.TemporaryDirectory(prefix='c1_r2_pw_',dir=ROOT/'sim') as temporary:
        directory=Path(temporary); meta=vectors(directory)
        print('C1_R2_PW_VECTORS '+json.dumps(meta),flush=True)
        for stalls in (0,1):
            executable=directory/f'pw_{stalls}.vvp'
            sources=['rtl/common/c1_ram_sdp_read_first.sv','rtl/r2/c1_r2_dot16_array.sv',
                     'rtl/cnn/c1_requant_bank8.sv','rtl/r2/c1_r2_pw16x8_tile.sv','sim/tb_c1_r2_pw16x8_tile.sv']
            commands=[['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_c1_r2_pw16x8_tile',
                      f'-Ptb_c1_r2_pw16x8_tile.STALLS={stalls}','-o',str(executable),*[str(ROOT/p) for p in sources]],
                     ['D:/iverilog/bin/vvp.exe',str(executable),f'+INPUTS={directory.as_posix()}/input.mem',
                      f'+OUTPUTS={directory.as_posix()}/output.mem',f'+N={meta["commands"]}',f'+M={meta["vectors"]}']]
            for command in commands:
                result=subprocess.run(command,capture_output=True,text=True,timeout=120)
                if result.returncode: raise RuntimeError('\n'.join((result.stdout+result.stderr).splitlines()[-20:]))
            lines=result.stdout.splitlines()
            if sum(line.startswith('C1_R2_PW_PASS ') for line in lines)!=1 or any('FATAL' in line or 'ERROR' in line for line in lines):
                raise RuntimeError(result.stdout[-4000:])
            for line in lines:
                if line.startswith('C1_R2_PW_'): print(line,flush=True)
    print('C1_R2_PW_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__': main()
