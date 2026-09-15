"""Full-size INT8 phase/noise sensitivity on three public demo photographs.

Known integer translations let us align outputs exactly, without estimating
optical flow. This is a synthetic camera-jitter probe, not real-video, temporal
coherence, RTL, or frame-rate signoff. No held-out test image is opened here.
"""
import argparse
import json
import os
from pathlib import Path
import time

import numpy as np
import psutil
import torch

from compare_r2_style_models import load_new_qat
from evaluate_r2_style_distill import preview_tensor
from microstyle_quant import load_qat_checkpoint
from prepare_r2_style_data import save_json

POSES=((1,0),(2,0),(3,0),(4,0),(0,1),(1,1),(2,2),(4,4))


def shift_rgb(image,dx,dy):
    if image.ndim!=3 or not 0<=dx<image.shape[1] or not 0<=dy<image.shape[0]:
        raise ValueError('invalid image or translation')
    return np.pad(image,((dy,0),(dx,0),(0,0)),mode='edge')[:image.shape[0],:image.shape[1]].copy()


def aligned_arrays(reference,moved,dx,dy,margin):
    h,w=reference.shape[:2]
    if moved.shape!=reference.shape or margin<=max(dx,dy) or min(h,w)<=2*margin:
        raise ValueError('invalid aligned evaluation region')
    return (reference[margin:h-margin,margin:w-margin].astype(np.int16),
            moved[margin+dy:h-margin+dy,margin+dx:w-margin+dx].astype(np.int16))


def delta_metrics(left,right):
    difference=np.abs(left.astype(np.int16)-right.astype(np.int16))
    return dict(mae_u8=float(difference.mean()),p99_u8=float(np.quantile(difference,.99)),
                max_u8=int(difference.max()),fraction_gt_8=float((difference>8).mean()))


def alignment_unit():
    original=(np.arange(32*32*3,dtype=np.int32).reshape(32,32,3)%251).astype(np.uint8)
    for dx,dy in POSES:
        moved=shift_rgb(original,dx,dy)
        a,b=aligned_arrays(original,moved,dx,dy,8)
        np.testing.assert_array_equal(a,b)
        assert np.any(original[8:-8,8:-8]!=moved[8:-8,8:-8]), 'ineffective synthetic motion'
        assert delta_metrics(a,b)['max_u8']==0
    assert delta_metrics(np.array([0],np.uint8),np.array([255],np.uint8))['max_u8']==255


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--candidate-qat-run',type=Path)
    args=parser.parse_args()
    case=Path(__file__).resolve().parents[1]
    root=args.output.resolve()
    if root.exists() or not root.is_relative_to(case/'outputs'):
        raise ValueError('new case1/outputs stability directory required')
    process=psutil.Process()
    process.cpu_affinity(process.cpu_affinity()[-1:])
    if os.name=='nt':
        process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
    if psutil.virtual_memory().available<8*2**30:
        raise RuntimeError('less than 8 GiB free before stability probe')
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    alignment_unit()
    models=dict(old_QAT_reference=load_qat_checkpoint(case/'model/microstyle24_starry_functional/checkpoint_qat.pt'),
                starry_B_INT8=load_new_qat(case/'outputs/c36_qat_b_starry_equalized_20260915a'),
                mosaic_B_INT8=load_new_qat(case/'outputs/c36_qat_b_mosaic_equalized_20260915a'))
    if args.candidate_qat_run:
        models['candidate_B_INT8']=load_new_qat(args.candidate_qat_run)
    for model in models.values():
        model.eval()
    root.mkdir(parents=True)
    started=time.monotonic()
    rng=np.random.default_rng(20260915)
    frames=checks=0
    records=[]
    max_grid_error={name:0. for name in models}

    def infer(name,pixels):
        nonlocal frames
        source=torch.from_numpy(pixels.transpose(2,0,1).copy())[None].float()/255
        output=models[name](source)[0]*255
        if tuple(output.shape)!=(3,480,640) or not torch.isfinite(output).all():
            raise AssertionError('invalid native inference output')
        error=float((output-output.round()).abs().max())
        max_grid_error[name]=max(max_grid_error[name],error)
        if name!='old_QAT_reference' and error>1e-4:
            raise AssertionError('new INT8 model is not on its declared RGB code grid')
        frames+=1
        return output.round().clamp(0,255).byte().numpy().transpose(1,2,0).copy()

    with torch.no_grad():
        for filename in ('astronaut.png','coffee.png','rocket.jpg'):
            _,pixels=preview_tensor(case/'assets/images'/filename)
            noise=rng.integers(-1,2,size=pixels.shape,dtype=np.int16)
            noisy=np.clip(pixels.astype(np.int16)+noise,0,255).astype(np.uint8)
            input_noise=delta_metrics(pixels[64:-64,64:-64],noisy[64:-64,64:-64])
            for name in models:
                baseline=infer(name,pixels)
                np.testing.assert_array_equal(baseline,infer(name,pixels))
                checks+=1
                poses=[]
                for dx,dy in POSES:
                    moved=infer(name,shift_rgb(pixels,dx,dy))
                    a,b=aligned_arrays(baseline,moved,dx,dy,64)
                    metrics=delta_metrics(a,b)
                    same_grid=dx%4==0 and dy%4==0
                    if same_grid:
                        np.testing.assert_array_equal(a,b,err_msg='four-pixel equivariance control failed: '+name)
                        checks+=1
                    poses.append(dict(dx=dx,dy=dy,same_encoder_grid=same_grid,**metrics))
                changed=infer(name,noisy)
                output_noise=delta_metrics(baseline[64:-64,64:-64],changed[64:-64,64:-64])
                records.append(dict(image=filename,model=name,poses=poses,input_noise=input_noise,
                    output_noise=output_noise,noise_MAE_gain=output_noise['mae_u8']/input_noise['mae_u8']))
                save_json(root/'progress.json',dict(state='running',image=filename,model=name,
                    native_inference_frames=frames,elapsed_seconds=time.monotonic()-started))
    summary={}
    for name in models:
        selected=[r for r in records if r['model']==name]
        non_grid=[p for r in selected for p in r['poses'] if not p['same_encoder_grid']]
        summary[name]=dict(non_grid_aligned_mae_u8=sum(p['mae_u8'] for p in non_grid)/len(non_grid),
                          worst_pose_aligned_mae_u8=max(p['mae_u8'] for p in non_grid),
                          noise_MAE_gain=sum(r['noise_MAE_gain'] for r in selected)/len(selected),
                          noise_output_mae_u8=sum(r['output_noise']['mae_u8'] for r in selected)/len(selected))
    report=dict(state='complete',public_images=3,test_images_read=0,input_shape=[480,640],
                border_exclusion=64,poses=list(POSES),noise='seeded independent RGB integer noise in {-1,0,1}, clipped to byte range',
                native_inference_frames=frames,exact_control_checks=checks,max_RGB_grid_error=max_grid_error,
                summary=summary,records=records,elapsed_seconds=time.monotonic()-started,
                candidate_qat_run=None if args.candidate_qat_run is None else str(args.candidate_qat_run.resolve()),
                real_video=False,RTL_simulated=False,temporal_quality_signoff=False,models_retrained=False)
    save_json(root/'stability.json',report)
    save_json(root/'progress.json',dict(state='complete',native_inference_frames=frames,
                                      exact_control_checks=checks,elapsed_seconds=report['elapsed_seconds']))
    print('C36_STYLE_STABILITY_PROBE_PASS '+json.dumps({k:v for k,v in report.items() if k!='records'},separators=(',',':')))


if __name__=='__main__':
    main()
