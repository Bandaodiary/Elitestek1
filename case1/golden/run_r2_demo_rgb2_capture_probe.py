"""C30 unstoppable RGB -> ROI/CDC -> real Resize/Capture AXI; not CNN/board FPS."""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path
import numpy as np
from run_r2_resize_probe import ROOT,SOURCES
from generate_r1_resize_line_sampler_vectors import source_image
from r1_isp import resize_bilinear_q16_u8,resize_axis_q16
from run_r2_official_debayer_contract import VENDOR,SOURCES as VENDOR_SOURCES

EXTRA=['rtl/r2/c1_r2_rgb2_raster_source.sv','rtl/r2/c1_r2_async_pixel_fifo_guarded.sv','rtl/r2/c1_r2_camera_pair_ingress.sv',
       'rtl/r2/c1_r2_resize_capture_rgbx32.sv','rtl/r2/c1_r2_video_capture_rgbx32.sv',
       'rtl/r2/c1_r2_video_bram_fifo.sv','rtl/r2/c1_r2_axi_row_write.sv']


def vectors(folder,sw,sh,rx,ry,rw,rh,ow,oh,vendor=False):
    src=source_image(sw,sh,42)
    if vendor:src[:]=[160,96,32]
    resized=resize_bilinear_q16_u8(src[ry:ry+rh,rx:rx+rw],ow,oh)
    packed=src.astype(np.uint32).reshape(-1,3)
    packed=(packed[:,0]<<16)|(packed[:,1]<<8)|packed[:,2]
    (folder/'source.mem').write_text(''.join(f'{int(v):06x}\n' for v in packed),encoding='ascii')
    rgbx=np.zeros((oh,ow,4),dtype=np.uint8);rgbx[:,:,:3]=resized
    data=rgbx.tobytes()
    (folder/'expected.mem').write_text(''.join(f'{int.from_bytes(data[i:i+16],"little"):032x}\n' for i in range(0,len(data),16)),encoding='ascii')
    xs,xp=resize_axis_q16(rw,ow);ys,yp=resize_axis_q16(rh,oh)
    return dict(XS=xs,YS=ys,XP=xp,YP=yp)


def main():
    p=argparse.ArgumentParser();p.add_argument('--native',action='store_true');p.add_argument('--stalls',default='0,1')
    p.add_argument('--fifo',type=int);p.add_argument('--vectors-only',type=Path);p.add_argument('--expect-overflow',action='store_true')
    p.add_argument('--odd-roi',action='store_true')
    p.add_argument('--vendor',action='store_true')
    p.add_argument('--temporary-parent',type=Path)
    p.add_argument('--overlap-resize',action='store_true')
    a=p.parse_args();top='tb_c1_r2_demo_rgb2_capture'
    geometry=(1920,1080,240,0,1440,1080,640,480) if a.native else (20,20,2,2,16,16,8,8)
    if a.odd_roi:
        if a.native:p.error('odd ROI case is the independent small boundary profile')
        geometry=(20,20,3,2,15,15,8,8)
    if a.vendor:
        if a.native or a.odd_roi:p.error('vendor direct RTL fixture uses the fixed interior ROI')
        geometry=(20,20,4,4,12,12,8,8)
    opts=dict(zip(('SW','SH','RX','RY','RW','RH','OW','OH'),geometry))
    opts.update(VENDOR_SOURCE=int(a.vendor))
    opts.update(FD=a.fifo or (512 if a.native else 64),FAULTS=0 if a.native or a.vendor else 1)
    if a.expect_overflow:
        if not a.native or not a.fifo:p.error('expected overflow requires explicit native source and FIFO capacity')
        opts.update(EXPECT_OVERFLOW=1)
    if a.native:opts.update(CORE_HALF=3.333,CAM_HALF=7.143,HBLANK=106,VBLANK=42)
    if a.vectors_only:
        a.vectors_only.mkdir(parents=True,exist_ok=True)
        if (a.vectors_only/'source.mem').exists():raise FileExistsError('private vectors exist')
        meta=dict(parameters=opts,plusargs=vectors(a.vectors_only,*geometry,a.vendor),source_backpressure=False,overlap_resize=a.overlap_resize,actual_vendor_rtl=a.vendor,pixels_per_word=2,
                  native_shape=a.native,cnn_included=False)
        (a.vectors_only/'metadata.json').write_text(json.dumps(meta),encoding='utf-8')
        print('C1_R2_DEMO_RGB2_VECTORS '+json.dumps(meta),flush=True);return
    if not set(a.stalls.split(','))<={'0','1'}:p.error('stalls must be 0 or 1')
    temp_parent=(a.temporary_parent or ROOT/'sim').resolve()
    if not temp_parent.is_dir() or not temp_parent.is_relative_to((ROOT/'sim').resolve()):
        p.error('temporary parent must be an existing directory within case1/sim')
    swaps={'rtl/video/c1_r1_resize_system.sv':'rtl/r2/c1_r2_resize_overlap_system.sv',
           'rtl/r2/c1_r2_resize_pipeline.sv':'rtl/r2/c1_r2_resize_overlap_pipeline.sv',
           'rtl/r2/c1_r2_resize_capture_rgbx32.sv':'rtl/r2/c1_r2_resize_overlap_capture.sv'} if a.overlap_resize else {}
    with tempfile.TemporaryDirectory(prefix='c1_r2_demo_rgb2_capture_',dir=temp_parent) as td:
        folder=Path(td);plus=vectors(folder,*geometry,a.vendor)
        print('C1_R2_DEMO_RGB2_VECTORS '+json.dumps(dict(parameters=opts,plusargs=plus,source_backpressure=False,overlap_resize=a.overlap_resize,actual_vendor_rtl=a.vendor,pixels_per_word=2,native_shape=a.native,cnn_included=False)),flush=True)
        for stalls in map(int,a.stalls.split(',')):
            exe=folder/'test.vvp'
            c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,
                *(['-DC30_RESIZE_OVERLAP'] if a.overlap_resize else []),
                *[f'-P{top}.{k}={v}' for k,v in dict(**opts,STALLS=stalls).items()],'-o',str(exe),
                *[str(ROOT/swaps.get(s,s)) for s in SOURCES+EXTRA+['sim/c1_r2_axi_memory_bfm.sv',f'sim/{top}.sv']],*[str(VENDOR/s) for s in VENDOR_SOURCES if a.vendor]],capture_output=True,text=True,timeout=90)
            if c.returncode:raise RuntimeError(c.stderr[-3500:])
            r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={folder.as_posix()}',
                *[f'+{k}={v}' for k,v in plus.items()]],capture_output=True,text=True,timeout=1800)
            for line in r.stdout.splitlines():
                if line.startswith(('C1_','C30_')):print(line,flush=True)
            if r.returncode or r.stdout.count('C1_R2_DEMO_RGB2_CAPTURE_PASS ')!=1:raise RuntimeError((r.stdout+r.stderr)[-3500:])
    print('C1_R2_DEMO_RGB2_CAPTURE_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()
