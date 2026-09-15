"""Real synchronous 3x4 C8 gather + five-beat RGB3 reduction + quantization.

Source images/intermediates remain ordinary HWC. Only weights are reordered
OIHW -> O(HW)I for the new hardware schedule. No pre-expanded windows loaded.
"""
from __future__ import annotations
import json,random,subprocess,tempfile
from pathlib import Path
import numpy as np
from run_r2_array_probe import ROOT,packed,wrap
from run_r2_pw_tile_probe import affine_scalar
from generate_microstyle_engine_bitexact_vectors import _image,_stage_sources,STAGE_NAMES,integer_infer_rgb
from microstyle_quant import _read_layer_arrays


def vectors(directory):
    commands=[];expected=[];jobs=[]
    def emit(kind,addr,value):commands.append((kind<<45)|(addr<<32)|(int(value)&0xffffffff))
    def job(label,source,weight,bias,mult,shift,relu,top,bottom,target=None):
        width=source.shape[1];assert source.shape==(3,width,8) and weight.shape==(3,8,3,3)
        loads=[(0,(r*1024+x)*2+w,packed(source[r,x,w*4:w*4+4],8)) for r in range(3) for x in range(width) for w in range(2)]
        for c in range(3):
            coefficient=[int(weight[c,ic,ky,kx]) for ky in range(3) for kx in range(3) for ic in range(8)]
            # Nonzero padding must be ignored by hardware, not by lucky zeros.
            coefficient += [(-117+7*k+c) for k in range(8)]
            loads += [(1,c*20+w,packed(coefficient[w*4:w*4+4],8)) for w in range(20)]
            loads += [(2,c,bias[c]),(3,c,(int(relu[c])<<24)|(int(shift[c])<<18)|(int(mult[c])&0x3ffff))]
        random.Random(20260913+len(jobs)).shuffle(loads)
        for args in loads:emit(*args)
        emit(4,0,width|(int(top)<<11)|(int(bottom)<<12))
        values=[]
        for x in range(width):
            for c in range(3):
                acc=int(bias[c])
                # Independent OIHW loop, unlike RTL's two spatial taps/beat.
                for ic in range(8):
                    for ky in range(3):
                        physical_row=1 if (ky==0 and top) or (ky==2 and bottom) else ky
                        for kx in range(3):
                            sx=min(width-1,max(0,x+kx-1))
                            acc+=int(source[physical_row,sx,ic])*int(weight[c,ic,ky,kx])
                value=affine_scalar(wrap(acc),int(mult[c]),int(shift[c]),bool(relu[c]))
                if target is not None and value!=int(target[x,c]):raise AssertionError((label,x,c,value,target[x,c]))
                values.append(value)
        for x in range(0,width,2):
            chunk=values[x*3:x*3+6];mask=(1<<len(chunk))-1
            expected.append((x<<54)|(mask<<48)|packed(chunk,8))
        jobs.append(dict(label=label,width=width,top=bool(top),bottom=bool(bottom),scalars=width*3,
                         vectors=(width+1)//2,mac_beats=((width+1)//2)*5,loads=len(loads)))
    artifact=ROOT/'model/microstyle24_starry_functional'
    manifest=json.loads((artifact/'manifest.json').read_text(encoding='utf-8'));assert manifest['trained'] is True
    row=next(r for r in manifest['quantized_layers'] if r['name']==STAGE_NAMES[20])
    weights,bias,mult,shift=_read_layer_arrays((artifact/manifest['parameter_file']).read_bytes(),row)
    image=_image(640,4);_,layers=integer_infer_rgb(image,artifact,collect=True)
    source,_=_stage_sources(image,layers,20)
    for y in range(4):
        stripe=np.stack([source[max(0,y-1)],source[y],source[min(3,y+1)]])
        # Unused out-of-frame row deliberately differs: boundary replication
        # must be performed by RTL, not precomputed in the host input.
        if y==0:stripe[0]=113
        if y==3:stripe[2]=-109
        job(f'qat_stage20_row{y}',stripe,weights,bias,mult,shift,[row['activation']]*3,y==0,y==3,layers[row['name']][y])
    rng=np.random.default_rng(20260913)
    for trial,width in enumerate((1,2,3,7,31,639,641,1024)):
        src=rng.integers(-128,128,(3,width,8),dtype=np.int16)
        wt=rng.integers(-128,128,(3,8,3,3),dtype=np.int16)
        bi=([-2**31,2**31-1,-123456] if trial%2 else [1,-1,777])
        mu=([-131072,131071,-3] if trial%2 else [0,1,65537])
        sh=[(0,1,15,31)[trial%4],(2,17,46,47)[trial%4],(1,7,31,47)[trial%4]]
        job(f'random_{trial}',src,wt,bi,mu,sh,[(trial+c)%2 for c in range(3)],bool(trial&1),bool(trial&2))
    job('ties_away',np.zeros((3,3,8),dtype=np.int16),np.zeros((3,8,3,3),dtype=np.int16),
        [1,-1,-3],[1,1,1],[1,1,1],[0,0,0],True,True)
    (directory/'input.mem').write_text(''.join(f'{v:013x}\n' for v in commands),encoding='ascii')
    (directory/'output.mem').write_text(''.join(f'{v:016x}\n' for v in expected),encoding='ascii')
    return dict(commands=len(commands),vectors=len(expected),jobs=jobs)


def main():
    with tempfile.TemporaryDirectory(prefix='c1_r2_rgb_',dir=ROOT/'sim') as temporary:
        directory=Path(temporary);meta=vectors(directory)
        print('C1_R2_RGB_VECTORS '+json.dumps(meta),flush=True)
        for stalls in (0,1):
            executable=directory/f'rgb_{stalls}.vvp'
            sources=['rtl/common/c1_ram_sdp_read_first.sv','rtl/r2/c1_r2_dot16_array.sv','rtl/cnn/c1_requant_bank8.sv',
                     'rtl/r2/c1_r2_window3x4_c8.sv','rtl/r2/c1_r2_rgb3x3_row.sv','sim/tb_c1_r2_rgb3x3_row.sv']
            commands=[['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_c1_r2_rgb3x3_row',
                       f'-Ptb_c1_r2_rgb3x3_row.STALLS={stalls}','-o',str(executable),*[str(ROOT/s) for s in sources]],
                      ['D:/iverilog/bin/vvp.exe',str(executable),f'+INPUTS={directory.as_posix()}/input.mem',
                       f'+OUTPUTS={directory.as_posix()}/output.mem',f'+N={meta["commands"]}',f'+M={meta["vectors"]}']]
            for command in commands:
                result=subprocess.run(command,capture_output=True,text=True,timeout=150)
                if result.returncode:raise RuntimeError('\n'.join((result.stdout+result.stderr).splitlines()[-24:]))
            lines=result.stdout.splitlines()
            if sum(s.startswith('C1_R2_RGB_PASS ') for s in lines)!=1 or any('FATAL' in s or 'ERROR' in s for s in lines):
                raise RuntimeError(result.stdout[-4000:])
            for line in lines:
                if line.startswith('C1_R2_RGB_'):print(line,flush=True)
    print('C1_R2_RGB_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()
