"""Audit the teacher against reviewed upstream code and public photo previews.

This does NOT train/validate a student, use held-out test images, or run RTL.
"""
import argparse
import ast
import json
import os
from pathlib import Path
import types

from PIL import Image, ImageDraw
import psutil
import torch
from torch.nn import functional as F

from r2_style_teacher import load_teacher,teacher_rgb,teacher_state
from train_r2_style_student import load_rgb,image_from_tensor


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.output.exists():
        raise ValueError('new teacher probe output required')
    process=psutil.Process()
    process.cpu_affinity(process.cpu_affinity()[-1:])
    if os.name=='nt':
        process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
    if psutil.virtual_memory().available<8*2**30:
        raise RuntimeError('less than 8 GiB free before teacher test')
    torch.set_num_threads(1)
    case=Path(__file__).resolve().parents[1]
    root=case/'assets/teachers/c36_pytorch_mosaic_20260915b'
    # This exact upstream reference was read in full before adding this test.
    # Only import torch plus class declarations are allowed at top level.
    source=(root/'transformer_net.py.reference').read_text(encoding='utf-8')
    syntax=ast.parse(source)
    assert all(isinstance(n,ast.ClassDef) or
               (isinstance(n,ast.Import) and len(n.names)==1 and n.names[0].name=='torch') for n in syntax.body)
    upstream=types.ModuleType('reviewed_pytorch_style_teacher')
    exec(compile(syntax,str(root/'transformer_net.py.reference'),'exec'),upstream.__dict__)
    reference=upstream.TransformerNet().eval()
    reference.load_state_dict(teacher_state(root),strict=True)
    model=load_teacher(root)
    differences=[]
    torch.manual_seed(20260915)
    with torch.no_grad():
        for height,width in ((32,48),(64,80)):
            x=torch.rand(1,3,height,width)
            expected=reference(x*255)
            actual=model(x*255)
            torch.testing.assert_close(actual,expected,atol=0,rtol=0)
            torch.testing.assert_close(teacher_rgb(model,x),expected.clamp(0,255)/255,atol=0,rtol=0)
            differences.append(float((actual-expected).abs().max()))
    assert all(not p.requires_grad for p in model.parameters())
    args.output.mkdir(parents=True)
    with torch.no_grad():
        for filename in ('astronaut.png','coffee.png','rocket.jpg'):
            x=F.interpolate(load_rgb(case/'assets/images'/filename)[None],size=(240,320),mode='bilinear',align_corners=False,antialias=True)
            y=teacher_rgb(model,x)
            assert y.shape==x.shape and torch.isfinite(y).all()
            canvas=Image.new('RGB',(640,264),'white')
            draw=ImageDraw.Draw(canvas)
            draw.text((4,4),'INPUT 320x240',fill='black')
            draw.text((324,4),'OFFICIAL MOSAIC TEACHER (NOT FPGA)',fill='black')
            canvas.paste(image_from_tensor(x[0]),(0,24))
            canvas.paste(image_from_tensor(y[0]),(320,24))
            canvas.save(args.output/(Path(filename).stem+'_teacher.png'))
    report=dict(state='complete',upstream_exact_max_errors=differences,actual_pretrained_parameters=sum(p.numel() for p in model.parameters()),
                frozen=True,public_preview_images=3,preview_shape=[240,320],student_trained=False,RTL_simulated=False)
    (args.output/'result.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print('C36_STYLE_TEACHER_PROBE_PASS '+json.dumps(report,separators=(',',':')))


if __name__=='__main__':
    main()
