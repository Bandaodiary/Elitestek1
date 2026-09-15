"""All model PW shapes using synchronous shared weight banks, plus C3 cases.

No externally prepared MAC operands. Input Cin24 padding is deliberately
poisoned; RTL must zero its upper K16 half. No waves or retained executables.
"""
from __future__ import annotations
import json, random, subprocess, tempfile
from pathlib import Path
import numpy as np
from run_r2_cnn_row_probe import vectors as row_vectors, command
from run_r2_array_probe import ROOT, packed, wrap
from run_r2_pw_tile_probe import affine_scalar
from generate_microstyle_engine_bitexact_vectors import _image, _stage_sources, STAGE_NAMES, integer_infer_rgb
from microstyle_quant import _read_layer_arrays

SOURCES = ['rtl/common/c1_ram_sdp_read_first.sv','rtl/cnn/c1_requant_bank8.sv',
           'rtl/r2/c1_r2_dot16_array.sv','rtl/r2/c1_r2_compute6.sv','rtl/r2/c1_r2_group_window_store.sv',
           'rtl/r2/c1_r2_weight_store8.sv','rtl/r2/c1_r2_pw_banked_feeder.sv',
           'rtl/r2/c1_r2_spatial_banked_feeder.sv','rtl/r2/c1_r2_cnn_tile_engine.sv']


def feature_address(pixel, k, chunks, word):
    bank_word = (pixel//2)*chunks+k
    assert bank_word < 512
    return ((pixel%2) << 11) | (bank_word << 2) | word


def weight_address(channel, k, word):
    assert channel < 48 and k < 5
    return ((channel%8) << 8) | ((channel//8) << 5) | (k << 2) | word


def vectors(directory):
    old = directory/'c3'; old.mkdir(); meta = row_vectors(old)
    raw = [int(s,16) for s in (old/'input.mem').read_text().splitlines()]
    expected = [int(s,16) for s in (old/'output.mem').read_text().splitlines()]
    groups = []; ci=oi=0
    for job in meta['jobs']:
        mode = job['mode']; cout = 8 if mode == 0 else 3 if mode == 1 else job['channels'] if mode == 2 else 0
        translated = []
        for cmd in raw[ci:ci+job['loads']+1]:
            kind=cmd>>48; address=(cmd>>32)&0x3fff; value=cmd&0xffffffff
            if kind == 0 and mode in (0,3):
                pixel, word = divmod(address,4); address = feature_address(pixel,0,1,word)
            if kind == 1:
                if mode == 0: channel, word = divmod(address,4); address = weight_address(channel,0,word)
                elif mode == 1:
                    channel, part = divmod(address,20); k, word = divmod(part,4); address = weight_address(channel,k,word)
                else: channel, word = divmod(address,3); address = weight_address(channel,0,word)
            if kind == 4: value |= cout<<22
            translated.append(command(mode,kind,address,value))
        groups.append((translated,expected[oi:oi+job['vectors']],dict(job,outputs=cout)))
        ci+=job['loads']+1; oi+=job['vectors']
    assert ci==len(raw) and oi==len(expected)
    extra=[]
    def pw_job(label, source, weight, bias, mult, shift, relu, target=None):
        pixels, cin = source.shape; cout = len(weight); chunks=(cin+15)//16
        assert cin in (16,24,48) and cout in (8,16,24,48) and weight.shape==(cout,cin)
        padded_source=np.full((pixels,chunks*16),113,dtype=np.int16);padded_source[:,:cin]=source
        padded_weight=np.full((cout,chunks*16),-117,dtype=np.int16);padded_weight[:,:cin]=weight
        loads=[(0,feature_address(p,k,chunks,w),packed(padded_source[p,k*16+w*4:k*16+w*4+4],8))
               for p in range(pixels) for k in range(chunks) for w in range(4)]
        loads += [(1,weight_address(c,k,w),packed(padded_weight[c,k*16+w*4:k*16+w*4+4],8))
                  for c in range(cout) for k in range(chunks) for w in range(4)]
        loads += [(2,c,bias[c]) for c in range(cout)]
        loads += [(3,c,(int(relu[c])<<24)|(int(shift[c])<<18)|(int(mult[c])&0x3ffff)) for c in range(cout)]
        random.Random(1103+len(extra)).shuffle(loads)
        # Independent scalar dot over ACTUAL Cin (24, not padded 32).
        values=[]
        for p in range(pixels):
            for c in range(cout):
                acc=wrap(int(bias[c])+sum(int(source[p,k])*int(weight[c,k]) for k in range(cin)))
                value=affine_scalar(acc,int(mult[c]),int(shift[c]),bool(relu[c]))
                if target is not None and value!=int(target[p,c]): raise AssertionError((label,p,c,value,target[p,c]))
                values.append(value)
        outputs=[]
        for base in range(0,len(values),6):
            chunk=values[base:base+6]
            outputs.append((base<<54)|(((1<<len(chunk))-1)<<48)|packed(chunk,8))
        commands=[command(0,*load) for load in loads]+[command(0,4,0,pixels|(cin<<14)|(cout<<22))]
        extra.append((commands,outputs,dict(mode=0,size=pixels,channels=cin,outputs=cout,vectors=len(outputs),
                     scalars=len(values),loads=len(loads),label=label,trained=target is not None)))
    artifact=ROOT/'model/microstyle24_starry_functional'
    manifest=json.loads((artifact/'manifest.json').read_text());arena=(artifact/manifest['parameter_file']).read_bytes()
    lookup={r['name']:r for r in manifest['quantized_layers']}
    image=_image(640,4);_,layers=integer_infer_rgb(image,artifact,collect=True)
    for stage in (2,4,6,8,10,12,16):
        row=lookup[STAGE_NAMES[stage]];weight,bias,mult,shift=_read_layer_arrays(arena,row)
        source,_=_stage_sources(image,layers,stage)
        for y in range(len(source)):
            pw_job(f'qat_stage{stage}_row{y}',source[y],weight[:,:,0,0],bias,mult,shift,[row['activation']]*len(bias),layers[row['name']][y])
    rng=np.random.default_rng(20260914)
    shapes=[(cin,cout,p) for cin in (16,24,48) for cout in (8,16,24,48) for p in (1,3,7)]
    shapes += [(16,48,1024),(24,16,511),(24,48,512),(48,8,339),(48,24,340)]
    for trial,(cin,cout,pixels) in enumerate(shapes):
        source=rng.integers(-128,128,(pixels,cin),dtype=np.int16);weight=rng.integers(-128,128,(cout,cin),dtype=np.int16)
        bias=[[-2**31,2**31-1,-1,0,1,65537,-123456][c%7] for c in range(cout)]
        mult=[[-131072,131071,-1,0,1,65537,3][c%7] for c in range(cout)]
        shift=[[0,1,2,15,17,31,46,47][(c+trial)%8] for c in range(cout)]
        pw_job(f'random_c{cin}_o{cout}_p{pixels}',source,weight,bias,mult,shift,[(c+trial)%2 for c in range(cout)])
    # Put new PW jobs between old modes; shared parameter ownership must survive
    # different shapes and deliberately overlapping bank locations without reset.
    ordered=[]
    for i in range(max(len(groups),len(extra))):
        if i<len(groups): ordered.append(groups[i])
        if i<len(extra): ordered.append(extra[i])
    commands=[c for cs,_,_ in ordered for c in cs]; outputs=[v for _,vs,_ in ordered for v in vs]
    jobs=[j for _,_,j in ordered]
    (directory/'input.mem').write_text(''.join(f'{v:013x}\n' for v in commands),encoding='ascii')
    (directory/'output.mem').write_text(''.join(f'{v:018x}\n' for v in outputs),encoding='ascii')
    return dict(commands=len(commands),vectors=len(outputs),jobs=jobs,scalars=sum(j['scalars'] for j in jobs),
                trained_scalars=sum(j['scalars'] for j in jobs if j['trained']))


def main():
    with tempfile.TemporaryDirectory(prefix='c1_r2_tile_',dir=ROOT/'sim') as temporary:
        directory=Path(temporary);meta=vectors(directory)
        print('C1_R2_TILE_VECTORS '+json.dumps(meta),flush=True)
        top='tb_c1_r2_cnn_tile_engine'
        for stalls in (0,1):
            executable=directory/f'tile_{stalls}.vvp'
            commands=[['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,f'-P{top}.STALLS={stalls}',
                       '-o',str(executable),*[str(ROOT/s) for s in SOURCES],str(ROOT/f'sim/{top}.sv')],
                      ['D:/iverilog/bin/vvp.exe',str(executable),f'+INPUTS={directory.as_posix()}/input.mem',
                       f'+OUTPUTS={directory.as_posix()}/output.mem',f'+N={meta["commands"]}',f'+M={meta["vectors"]}',f'+J={len(meta["jobs"])}']]
            for cmd in commands:
                result=subprocess.run(cmd,capture_output=True,text=True,timeout=300)
                if result.returncode: raise RuntimeError('\n'.join((result.stdout+result.stderr).splitlines()[-25:]))
            lines=result.stdout.splitlines()
            if sum(s.startswith('C1_R2_TILE_PASS ') for s in lines)!=1 or any('ERROR' in s or 'FATAL' in s for s in lines): raise RuntimeError(result.stdout[-4000:])
            for line in lines:
                if line.startswith('C1_R2_TILE_'): print(line,flush=True)
    print('C1_R2_TILE_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__': main()
