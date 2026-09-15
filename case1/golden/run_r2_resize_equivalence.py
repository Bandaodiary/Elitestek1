"""C23 old/new cycle miter with independent full-resolution Resize pixels."""
from __future__ import annotations
import argparse
import subprocess
import tempfile
from pathlib import Path
import numpy as np
from run_r2_resize_probe import ROOT,SOURCES,OLD
from r1_isp import resize_axis_q16,resize_bilinear_q16_u8
from generate_r1_resize_line_sampler_vectors import source_image

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--shapes',default='1x7:4x3,2047x5:641x3,2048x5:640x4')
    p.add_argument('--stalls',default='0,1')
    p.add_argument('--negative-only',action='store_true')
    a=p.parse_args()
    top='tb_c1_r2_resize_equivalence'
    with tempfile.TemporaryDirectory(prefix='c1_r2_resize_miter_',dir=ROOT/'sim') as td:
        folder=Path(td);exe=folder/'test.vvp'
        r=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,'-o',str(exe),
                         *[str(ROOT/s) for s in SOURCES+OLD],str(ROOT/f'sim/{top}.sv')],capture_output=True,text=True,timeout=90)
        if r.returncode:raise RuntimeError(r.stderr[-2500:])
        for index,shape in enumerate(a.shapes.split(',')):
            left,right=shape.split(':');w,h=map(int,left.split('x'));ow,oh=map(int,right.split('x'))
            if not (1<=w<=2048 and 1<=h<=65535 and 1<=ow<=65535 and 1<=oh<=65535 and w*h<=2211840 and ow*oh<=307200):raise ValueError('unsupported test fixture size')
            source=source_image(w,h,index+20);expected=resize_bilinear_q16_u8(source,ow,oh)
            for name,array in [('source',source),('golden',expected)]:
                rgb=array.astype(np.uint32).reshape(-1,3)
                packed=(rgb[:,0]<<16)|(rgb[:,1]<<8)|rgb[:,2]
                np.savetxt(folder/(name+'.hex'),packed,fmt='%06x')
            xs,xp=resize_axis_q16(w,ow);ys,yp=resize_axis_q16(h,oh)
            for stall in map(int,a.stalls.split(',')):
                if stall not in (0,1):raise ValueError('stalls must be 0 or 1')
                args=dict(W=w,H=h,OW=ow,OH=oh,XS=xs,YS=ys,XP=xp,YP=yp,STALLS=stall,NEGATIVE=int(a.negative_only))
                r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe),*[f'+{k}={v}' for k,v in args.items()]],cwd=folder,capture_output=True,text=True,timeout=1200)
                if a.negative_only:
                    if not r.returncode or 'resize independent golden mismatch' not in r.stdout:raise RuntimeError('negative control failed: '+r.stdout[-2500:])
                    print(f'C1_R2_RESIZE_EQUIVALENCE_NEGATIVE_PASS shape={shape} stalls={stall}',flush=True)
                else:
                    if r.returncode or r.stdout.count('C1_R2_RESIZE_EQUIVALENCE_PASS ')!=1:raise RuntimeError((r.stdout+r.stderr)[-3500:])
                    for line in r.stdout.splitlines():
                        if line.startswith('C1_'):print(line,flush=True)
    print('C1_R2_RESIZE_EQUIVALENCE_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)

if __name__=='__main__':main()
