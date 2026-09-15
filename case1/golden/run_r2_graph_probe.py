"""True layer handoff: only RGB input and trained parameters initialize RAM.

The expected write stream is checker-only. Subsequent read responses always
come from actual RTL writes, with per-word producer ownership checked in TB.
No waves or retained executable/vector directories. P2C8 is a new internal
layout, not the existing R1/video memory ABI.
"""
from __future__ import annotations
import argparse,json,subprocess,tempfile
from pathlib import Path
import numpy as np
from run_r2_operator_probe import SOURCES,weight_address
from run_r2_array_probe import ROOT,packed
from generate_microstyle_engine_bitexact_vectors import _image,STAGE_NAMES,integer_infer_rgb
from microstyle_quant import _read_layer_arrays

GRAPH_SOURCES=SOURCES+['rtl/r2/c1_r2_tensor_row_loader.sv','rtl/r2/c1_r2_tensor_row_writer.sv','rtl/r2/c1_r2_microstyle_graph.sv']
SLOT=1<<23
DEST={0:1,1:2,2:1,3:3,4:1,5:3,6:1,7:2,8:1,9:2,10:1,11:3,12:1,13:3,15:1,16:2,18:1,19:2,20:4}


def p2c8(tensor):
    """HWC -> row/pixel-pair/group/parity/channel, zero padding."""
    h,w,c=tensor.shape;g=(c+7)//8
    padded=np.zeros((h,(w+1)//2*2,g*8),dtype=np.uint8)
    padded[:,:w,:c]=tensor.astype(np.uint8)
    return [packed(padded[y,x:x+2,group*8:group*8+8].reshape(-1),8)
            for y in range(h) for x in range(0,w,2) for group in range(g)]


def vectors(directory,width,height,artifact=None):
    artifact=artifact or ROOT/'model/microstyle24_starry_functional'
    manifest=json.loads((artifact/'manifest.json').read_text());arena=(artifact/manifest['parameter_file']).read_bytes()
    lookup={row['name']:row for row in manifest['quantized_layers']};initial=[];expected=[];frames=[]
    for stage in DEST:
        if stage in (5,9,13): continue
        row=lookup[STAGE_NAMES[stage]];weight,bias,mult,shift=_read_layer_arrays(arena,row)
        commands=[]
        def emit(kind,address,value):commands.append((kind<<46)|(address<<32)|(int(value)&0xffffffff))
        for c in range(len(bias)):
            if stage in (3,7,11,15,18):coefficients=list(weight[c,0].reshape(-1))
            else:coefficients=list(weight[c].transpose(1,2,0).reshape(-1))
            k=(len(coefficients)+15)//16;coefficients += [117]*(k*16-len(coefficients))
            for beat in range(k):
                for word in range(4): emit(1,weight_address(c,beat,word),packed(coefficients[beat*16+word*4:beat*16+word*4+4],8))
            emit(2,c,bias[c]);emit(3,c,(int(row['activation'])<<24)|(int(shift[c])<<18)|(int(mult[c])&0x3ffff))
        assert len(commands)%2==0 and len(commands)*8<=8192
        for j in range(0,len(commands),2):initial.append(((5*SLOT+stage*8192+j*8)<<128)|commands[j]|(commands[j+1]<<64))
    parameter_words=len(initial)
    for frame in range(2):
        rgb=_image(width,height)
        if frame:rgb=np.bitwise_xor(np.roll(rgb,1,axis=1),np.uint8(0x5b))
        result,layers=integer_infer_rgb(rgb,artifact,collect=True)
        inputs=p2c8(rgb);(directory/f'input{frame}.mem').write_text(''.join(f'{x:032x}\n' for x in inputs),encoding='ascii')
        frame_words=0;stage_shapes=[];scalar_count=0
        for stage,slot in DEST.items():
            # Stage21 is fused at writer, so stage20 stores uint8 final RGB.
            tensor=result if stage==20 else layers[STAGE_NAMES[stage]]
            words=p2c8(tensor);scalar_count+=int(tensor.size);frame_words+=len(words)
            stage_shapes.append(dict(stage=stage,shape=list(tensor.shape),words=len(words)))
            for j,word in enumerate(words):expected.append((stage<<160)|((slot*SLOT+j*16)<<128)|word)
        frames.append(dict(frame=frame,output_words=frame_words,scalars=scalar_count,stages=stage_shapes))
    (directory/'parameters.mem').write_text(''.join(f'{x:040x}\n' for x in initial),encoding='ascii')
    (directory/'expected.mem').write_text(''.join(f'{x:042x}\n' for x in expected),encoding='ascii')
    return dict(width=width,height=height,parameter_words=parameter_words,input_words=len(inputs),expected_words=len(expected),frames=frames)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--shapes',default='4x4,12x12,32x32,640x12');parser.add_argument('--stalls',default='0,1')
    parser.add_argument('--negative-only',action='store_true');parser.add_argument('--timeout-seconds',type=int,default=900);args=parser.parse_args()
    if args.timeout_seconds<1:parser.error('timeout must be positive')
    with tempfile.TemporaryDirectory(prefix='c1_r2_graph_',dir=ROOT/'sim') as tmp:
        directory=Path(tmp);top='tb_c1_r2_microstyle_graph'
        for shape in args.shapes.split(','):
            width,height=map(int,shape.split('x'));part=directory/shape;part.mkdir();meta=vectors(part,width,height)
            print('C1_R2_GRAPH_VECTORS '+json.dumps(meta),flush=True)
            for stalls in map(int,args.stalls.split(',')):
                exe=part/f'graph_{stalls}.vvp'
                compile_cmd=['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,f'-P{top}.STALLS={stalls}','-o',str(exe),
                             *[str(ROOT/s) for s in GRAPH_SOURCES],str(ROOT/f'sim/{top}.sv')]
                run_cmd=['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={part.as_posix()}',f'+W={width}',f'+H={height}',
                         f'+P={meta["parameter_words"]}',f'+I={meta["input_words"]}',f'+E={meta["expected_words"]}']
                if args.negative_only:
                    for fault,marker in ((1,'GRAPH_MISMATCH stage=1'),(2,'unwritten/wrong producer stage=1')):
                        compiled=subprocess.run(compile_cmd[:4]+[f'-P{top}.CORRUPT_HANDOFF={fault}']+compile_cmd[4:],capture_output=True,text=True,timeout=60)
                        if compiled.returncode:raise RuntimeError(compiled.stderr[-2000:])
                        failed=subprocess.run(run_cmd,capture_output=True,text=True,timeout=90)
                        if failed.returncode==0 or marker not in failed.stdout:raise RuntimeError('Handoff negative failed: '+failed.stdout[-2000:])
                        print(f'C1_R2_GRAPH_HANDOFF_NEGATIVE_PASS stalls={stalls} corruption={fault} detected_at_stage=1',flush=True)
                    continue
                for cmd in (compile_cmd,run_cmd):
                    completed=subprocess.run(cmd,capture_output=True,text=True,timeout=args.timeout_seconds)
                    if completed.returncode:raise RuntimeError('\n'.join((completed.stdout+completed.stderr).splitlines()[-25:]))
                lines=completed.stdout.splitlines()
                if sum(s.startswith('C1_R2_GRAPH_PASS ') for s in lines)!=1 or any('FATAL' in s or 'ERROR' in s for s in lines):raise RuntimeError(completed.stdout[-4000:])
                for line in lines:
                    if line.startswith('C1_R2_GRAPH_'):print(line,flush=True)
    print('C1_R2_GRAPH_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()
