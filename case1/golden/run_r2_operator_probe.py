"""C5: real stride2 encoder gather and raw-input virtual nearest2x DW.

Retains all C4 jobs; new references directly convolve OIHW or explicitly
expand tiny host-reference stripes, never loading expanded input into RTL.
"""
from __future__ import annotations
import json,random,subprocess,tempfile
from pathlib import Path
import numpy as np
from run_r2_cnn_tile_probe import vectors as tile_vectors
from run_r2_cnn_row_probe import spatial_address
from run_r2_array_probe import ROOT,packed,wrap
from run_r2_pw_tile_probe import affine_scalar
from generate_microstyle_engine_bitexact_vectors import _image,_stage_sources,STAGE_NAMES,integer_infer_rgb
from microstyle_quant import _read_layer_arrays

SOURCES=['rtl/common/c1_ram_sdp_read_first.sv','rtl/cnn/c1_requant_bank8.sv',
         'rtl/r2/c1_r2_dot16_array.sv','rtl/r2/c1_r2_compute6.sv','rtl/r2/c1_r2_weight_store8.sv',
         'rtl/r2/c1_r2_pw_banked_feeder.sv','rtl/r2/c1_r2_mapped_window_store.sv',
         'rtl/r2/c1_r2_encoder_feeder.sv','rtl/r2/c1_r2_spatial_operator_feeder.sv','rtl/r2/c1_r2_cnn_operator_engine.sv']


def command(mode,kind,address,value):
    return (kind<<49)|(mode<<46)|(address<<32)|(int(value)&0xffffffff)


def weight_address(channel,k,word):
    assert channel<48 and k<8
    return ((channel%8)<<8)|((channel//8)<<5)|(k<<2)|word


def vectors(directory):
    old=directory/'c4';old.mkdir();meta=tile_vectors(old)
    raw=[int(s,16) for s in (old/'input.mem').read_text().splitlines()]
    raw_out=[int(s,16) for s in (old/'output.mem').read_text().splitlines()]
    groups=[];ci=oi=0
    for job in meta['jobs']:
        cs=[command(job['mode'],c>>48,(c>>32)&0x3fff,c&0xffffffff) for c in raw[ci:ci+job['loads']+1]]
        groups.append((cs,raw_out[oi:oi+job['vectors']],dict(job,virtual_up2=False,phase=0,output_width=job['size'])))
        ci+=job['loads']+1;oi+=job['vectors']
    assert ci==len(raw) and oi==len(raw_out)
    extra=[]
    def spatial_job(mode,label,source,weight,bias,mult,shift,relu,top,bottom,phase=0,target=None):
        width=source.shape[1];cin=source.shape[2];virtual=mode==2;cout=len(bias);n_groups=(cin+7)//8
        out_width=width*2 if virtual else (width+1)//2
        assert source.shape==(3,width,cin) and (virtual or (cin,cout) in ((3,12),(12,24)))
        padded=np.full((3,width,n_groups*8),-113,dtype=np.int16);padded[:,:,:cin]=source
        loads=[(0,spatial_address(r,x,g,n_groups,w),packed(padded[r,x,g*8+w*4:g*8+w*4+4],8))
               for r in range(3) for x in range(width) for g in range(n_groups) for w in range(2)]
        for c in range(cout):
            if virtual: coefficients=[int(weight[c,0,ky,kx]) for ky in range(3) for kx in range(3)]
            else: coefficients=[int(weight[c,ic,ky,kx]) for ky in range(3) for kx in range(3) for ic in range(cin)]
            chunks=(len(coefficients)+15)//16
            coefficients += [117]*(chunks*16-len(coefficients))
            loads += [(1,weight_address(c,k,w),packed(coefficients[k*16+w*4:k*16+w*4+4],8)) for k in range(chunks) for w in range(4)]
            loads += [(2,c,bias[c]),(3,c,(int(relu[c])<<24)|(int(shift[c])<<18)|(int(mult[c])&0x3ffff))]
        random.Random(2203+len(extra)).shuffle(loads)
        reference=source.copy()
        if top: reference[0]=reference[1]
        if bottom: reference[2]=reference[1]
        # Only the independent REFERENCE expands; actual feature loads above
        # contain width raw pixels, not 2*width replicated pixels.
        if virtual: reference=np.repeat(np.repeat(reference,2,axis=0),2,axis=1)
        values=[]
        for x in range(out_width):
            for c in range(cout):
                acc=int(bias[c])
                for ky in range(3):
                    sy=(2+phase+ky-1) if virtual else ky
                    for kx in range(3):
                        sx=min(reference.shape[1]-1,max(0,(x if virtual else x*2)+kx-1))
                        if virtual: acc+=int(reference[sy,sx,c])*int(weight[c,0,ky,kx])
                        else:
                            for ic in range(cin): acc+=int(reference[sy,sx,ic])*int(weight[c,ic,ky,kx])
                value=affine_scalar(wrap(acc),int(mult[c]),int(shift[c]),bool(relu[c]))
                if target is not None and value!=int(target[x,c]): raise AssertionError((label,x,c,value,target[x,c]))
                values.append(value)
        outputs=[]
        if virtual:
            for x in range(0,out_width,2):
                for g in range(n_groups):
                    for batch in range(3):
                        chunk=[];mask=0
                        for lane in range(6):
                            local=batch*6+lane;valid=local<16
                            chunk.append(values[(x+local//8)*cout+g*8+local%8] if valid else 0)
                            if valid: mask|=1<<lane
                        tag=(x<<5)|(g<<2)|batch
                        outputs.append((mode<<70)|(tag<<54)|(mask<<48)|packed(chunk,8))
        else:
            for base in range(0,len(values),6): outputs.append((mode<<70)|(base<<54)|(63<<48)|packed(values[base:base+6],8))
        cs=[command(mode,*load) for load in loads]
        cs.append(command(mode,4,0,width|(cin<<14)|(int(top)<<20)|(int(bottom)<<21)|(cout<<22)|(int(virtual)<<28)|(phase<<29)))
        extra.append((cs,outputs,dict(mode=mode,size=width,channels=cin,outputs=cout,output_width=out_width,
                     virtual_up2=virtual,phase=phase,vectors=len(outputs),scalars=len(values),loads=len(loads),label=label,trained=target is not None)))

    artifact=ROOT/'model/microstyle24_starry_functional'
    manifest=json.loads((artifact/'manifest.json').read_text());arena=(artifact/manifest['parameter_file']).read_bytes()
    lookup={r['name']:r for r in manifest['quantized_layers']}
    image=_image(640,12);_,layers=integer_infer_rgb(image,artifact,collect=True)
    for stage in (0,1):
        row=lookup[STAGE_NAMES[stage]];weight,bias,mult,shift=_read_layer_arrays(arena,row)
        source,_=_stage_sources(image,layers,stage);target=layers[row['name']]
        for y in range(len(target)):
            center=y*2;stripe=np.stack([source[max(0,center-1)],source[center],source[min(len(source)-1,center+1)]])
            top=center==0;bottom=center==len(source)-1
            if top: stripe[0]=111
            if bottom: stripe[2]=-109
            spatial_job(4+stage,f'qat_stage{stage}_row{y}',stripe,weight,bias,mult,shift,[row['activation']]*len(bias),top,bottom,target=target[y])
    for stage,raw_stage in ((15,13),(18,16)):
        row=lookup[STAGE_NAMES[stage]];weight,bias,mult,shift=_read_layer_arrays(arena,row)
        source=layers[STAGE_NAMES[raw_stage]];target=layers[row['name']]
        for y in range(len(target)):
            center=y//2;stripe=np.stack([source[max(0,center-1)],source[center],source[min(len(source)-1,center+1)]])
            top=center==0;bottom=center==len(source)-1
            if top: stripe[0]=107
            if bottom: stripe[2]=-103
            spatial_job(2,f'qat_virtual_stage{stage}_row{y}',stripe,weight,bias,mult,shift,[row['activation']]*len(bias),top,bottom,y%2,target[y])
    rng=np.random.default_rng(20260915)
    def random_params(cout,trial):
        return ([[-2**31,2**31-1,1,-1,777][c%5] for c in range(cout)],
                [[-131072,131071,-3,0,1,65537][c%6] for c in range(cout)],
                [[0,1,2,15,17,31,46,47][(c+trial)%8] for c in range(cout)],[(c+trial)%2 for c in range(cout)])
    for mode,cin,cout in ((4,3,12),(5,12,24)):
        for trial,width in enumerate((1,2,3,7,31,639 if mode==4 else 319,1024)):
            source=rng.integers(-128,128,(3,width,cin),dtype=np.int16)
            weight=rng.integers(-128,128,(cout,cin,3,3),dtype=np.int16)
            spatial_job(mode,f'random_encoder_c{cin}_w{width}',source,weight,*random_params(cout,trial),bool(trial&1),bool(trial&2))
        spatial_job(mode,f'encoder_ties_c{cin}',np.zeros((3,3,cin),dtype=np.int16),np.zeros((cout,cin,3,3),dtype=np.int16),
                    ([1,-1,3,-3,255,-257]*4)[:cout],[1]*cout,[1]*cout,[0]*cout,True,True)
    for cin,max_width in ((16,512),(24,512),(48,340)):
        for trial,width in enumerate((1,3,7,max_width-1,max_width)):
            source=rng.integers(-128,128,(3,width,cin),dtype=np.int16)
            weight=rng.integers(-128,128,(cin,1,3,3),dtype=np.int16)
            for phase in (0,1):
                spatial_job(2,f'random_virtual_c{cin}_w{width}_p{phase}',source,weight,*random_params(cin,trial),bool(trial&1),bool(trial&2),phase)
    ordered=[]
    for i in range(max(len(groups),len(extra))):
        if i<len(groups): ordered.append(groups[i])
        if i<len(extra): ordered.append(extra[i])
    commands=[c for cs,_,_ in ordered for c in cs];outputs=[v for _,vs,_ in ordered for v in vs];jobs=[j for _,_,j in ordered]
    (directory/'input.mem').write_text(''.join(f'{v:014x}\n' for v in commands),encoding='ascii')
    (directory/'output.mem').write_text(''.join(f'{v:019x}\n' for v in outputs),encoding='ascii')
    return dict(commands=len(commands),vectors=len(outputs),jobs=jobs,scalars=sum(j['scalars'] for j in jobs),
                trained_scalars=sum(j['scalars'] for j in jobs if j['trained']))


def main():
    with tempfile.TemporaryDirectory(prefix='c1_r2_operator_',dir=ROOT/'sim') as temporary:
        directory=Path(temporary);meta=vectors(directory)
        print('C1_R2_OPERATOR_VECTORS '+json.dumps(meta),flush=True)
        top='tb_c1_r2_cnn_operator_engine'
        for stalls in (0,1):
            executable=directory/f'operator_{stalls}.vvp'
            commands=[['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,f'-P{top}.STALLS={stalls}',
                       '-o',str(executable),*[str(ROOT/s) for s in SOURCES],str(ROOT/f'sim/{top}.sv')],
                      ['D:/iverilog/bin/vvp.exe',str(executable),f'+INPUTS={directory.as_posix()}/input.mem',
                       f'+OUTPUTS={directory.as_posix()}/output.mem',f'+N={meta["commands"]}',f'+M={meta["vectors"]}',f'+J={len(meta["jobs"])}']]
            for cmd in commands:
                result=subprocess.run(cmd,capture_output=True,text=True,timeout=360)
                if result.returncode: raise RuntimeError('\n'.join((result.stdout+result.stderr).splitlines()[-25:]))
            lines=result.stdout.splitlines()
            if sum(s.startswith('C1_R2_OPERATOR_PASS ') for s in lines)!=1 or any('ERROR' in s or 'FATAL' in s for s in lines): raise RuntimeError(result.stdout[-4000:])
            for line in lines:
                if line.startswith('C1_R2_OPERATOR_'): print(line,flush=True)
    print('C1_R2_OPERATOR_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__': main()
