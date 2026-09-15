"""Evaluate a completed Mosaic student against its actual learned teacher.

Val is the default. The explicit test mode is for a frozen final choice and
must not be used for selection. Teacher similarity is not an aesthetic score.
Native previews compare differing styles without ranking them by Mosaic loss.
"""
import argparse
import json
import math
import os
from pathlib import Path
import time

import numpy as np
from PIL import Image, ImageOps, ImageDraw
import psutil
import torch

from prepare_r2_style_data import save_json
from r2_style_student import R2StyleStudent
from r2_style_teacher import load_teacher, teacher_rgb
from r2_style_perceptual import ssim_luma, luma, spatial_gradient
from r2_style_quant import integer_student
from r2_style_candidates import candidate_nodes
from r2_plan_package import compile_package
from train_r2_style_student import load_rgb, evaluation_input, image_from_tensor
from train_r2_style_qat import require_float_finished
from compare_r2_style_models import load_new_qat
from microstyle_quant import load_qat_checkpoint


def comparison_metrics(output, target, content):
    delta = output-target
    mse = float(delta.square().mean())
    edges = lambda x:sum(g.abs().mean() for g in spatial_gradient(luma(x)))
    return dict(teacher_mae_u8=float(delta.abs().mean()*255),
                teacher_psnr_db=-10*math.log10(max(mse,1e-12)),
                teacher_ssim_box11=float(ssim_luma(output,target)),
                input_ssim_box11=float(ssim_luma(output,content)),
                input_change_mae_u8=float((output-content).abs().mean()*255),
                saturation_fraction=float(((output<=0)|(output>=1)).float().mean()),
                edge_energy_ratio=float(edges(output)/edges(content).clamp_min(1e-6)),
                teacher_RGB_mean_error_u8=float((output.mean((2,3))-target.mean((2,3))).abs().mean()*255))


def preview_tensor(path):
    with Image.open(path) as opened:
        rgb=ImageOps.fit(ImageOps.exif_transpose(opened).convert('RGB'),(640,480),Image.Resampling.LANCZOS)
    pixels=np.asarray(rgb,dtype=np.uint8).copy()
    return torch.from_numpy(pixels.transpose(2,0,1).copy())[None].float()/255,pixels


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--float-run',type=Path,required=True)
    parser.add_argument('--qat-run',type=Path)
    parser.add_argument('--baseline-qat-run',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--split',choices=('val','test'),default='val')
    parser.add_argument('--native-integer-check',action='store_true')
    parser.add_argument('--skip-previews',action='store_true',help='evaluate the fixed partition without regenerating public preview images')
    args=parser.parse_args()
    case=Path(__file__).resolve().parents[1]
    root=args.output.resolve()
    if root.exists() or not root.is_relative_to(case/'outputs'):
        raise ValueError('new case1/outputs evaluation directory required')
    if (args.native_integer_check or args.split=='test') and args.qat_run is None:
        raise ValueError('native integer / final-test evaluation requires a completed QAT artifact')
    if args.baseline_qat_run and args.qat_run is None:
        raise ValueError('baseline comparison requires a candidate QAT artifact')
    if args.native_integer_check and args.skip_previews:
        raise ValueError('native integer check requires its public full-resolution input')
    process=psutil.Process()
    process.cpu_affinity(process.cpu_affinity()[-1:])
    if os.name=='nt':
        process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
    if psutil.virtual_memory().available<8*2**30:
        raise RuntimeError('less than 8 GiB free before evaluation')
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    require_float_finished(args.float_run)
    checkpoint=torch.load(args.float_run/'checkpoint_best.pt',map_location='cpu',weights_only=True)
    config=checkpoint['metadata']['config']
    if config.get('objective')!='teacher_distill':
        raise ValueError('not a learned-teacher distilled student')
    floating=R2StyleStudent(**checkpoint['model_config']).eval()
    floating.load_state_dict(checkpoint['model_state'],strict=True)
    models={'mosaic_FLOAT':floating}
    teacher=load_teacher(config['teacher_directory'])
    qat_checkpoint=None
    package=None
    if args.qat_run:
        models['mosaic_INT8']=load_new_qat(args.qat_run)
        qat_checkpoint=torch.load(args.qat_run/'checkpoint_best.pt',map_location='cpu',weights_only=True)
        qat_status=json.loads((args.qat_run/'status.json').read_text(encoding='utf-8-sig'))
        if (qat_checkpoint['step']!=qat_status['selected_QAT_step'] or
            qat_checkpoint.get('trained') is not True or qat_checkpoint.get('quantized') is not True):
            raise ValueError('candidate is not the recorded frozen QAT selection')
        metadata=qat_checkpoint['metadata']
        if (Path(metadata['float_run']).resolve()!=args.float_run.resolve() or
            metadata['float_selected_step']!=checkpoint['step'] or metadata['objective_variant']!='teacher_distill' or
            Path(metadata['teacher_directory']).resolve()!=Path(config['teacher_directory']).resolve() or
            models['mosaic_INT8'].config!=floating.config):
            raise ValueError('quantized artifact is not the same trained model/teacher')
        package=compile_package(candidate_nodes(**floating.config),artifact=args.qat_run/'artifact')
        # The full-frame integer check must use the exported arena, not an
        # independently re-quantized in-memory float model.
        for name,arrays in package.layers.items():
            for exported,expected in zip(arrays,models['mosaic_INT8'].quantized_arrays(name)):
                np.testing.assert_array_equal(exported,expected)
    if args.baseline_qat_run:
        baseline_checkpoint=torch.load(args.baseline_qat_run/'checkpoint_best.pt',map_location='cpu',weights_only=True)
        baseline_status=json.loads((args.baseline_qat_run/'status.json').read_text(encoding='utf-8-sig'))
        if (baseline_checkpoint['step']!=baseline_status['selected_QAT_step'] or
            baseline_checkpoint.get('trained') is not True or baseline_checkpoint.get('quantized') is not True):
            raise ValueError('baseline is not the recorded frozen QAT selection')
        baseline_metadata=baseline_checkpoint['metadata']
        if (Path(baseline_metadata['float_run']).resolve()!=args.float_run.resolve() or
            baseline_metadata['float_selected_step']!=checkpoint['step'] or
            Path(baseline_metadata['teacher_directory']).resolve()!=Path(config['teacher_directory']).resolve()):
            raise ValueError('baseline does not share the selected float student and style teacher')
        models['mosaic_BASELINE_INT8']=load_new_qat(args.baseline_qat_run)
        if models['mosaic_BASELINE_INT8'].config!=floating.config:
            raise ValueError('baseline topology differs from the selected float student')
        baseline_package=compile_package(candidate_nodes(**floating.config),artifact=args.baseline_qat_run/'artifact')
        for name,arrays in baseline_package.layers.items():
            for exported,expected in zip(arrays,models['mosaic_BASELINE_INT8'].quantized_arrays(name)):
                np.testing.assert_array_equal(exported,expected)
    dataset=Path(config['dataset'])
    manifest=json.loads((dataset/'manifest.json').read_text(encoding='utf-8'))
    selected=[row for row in manifest['images'] if row['split']==args.split]
    if len(selected)!=32 or manifest['state']!='complete':
        raise ValueError('unexpected held-out partition')
    root.mkdir(parents=True)
    started=time.monotonic()
    rows=[]
    deltas=[]
    baseline_deltas=[]
    native=None
    with torch.no_grad():
        for entry in selected:
            # Both teacher and students receive the same actual 8-bit input.
            content=evaluation_input(load_rgb(dataset/entry['file'])).clamp(0,1).mul(255).round()/255
            target=teacher_rgb(teacher,content)
            outputs={name:model(content) for name,model in models.items()}
            for name,output in outputs.items():
                if output.shape!=content.shape or not torch.isfinite(output).all():
                    raise AssertionError('invalid student frame')
                rows.append(dict(image=entry['ImageID'],model=name,**comparison_metrics(output,target,content)))
            if 'mosaic_INT8' in outputs:
                deltas.append(dict(image=entry['ImageID'],**comparison_metrics(outputs['mosaic_INT8'],outputs['mosaic_FLOAT'],content)))
            if 'mosaic_BASELINE_INT8' in outputs:
                baseline_deltas.append(dict(image=entry['ImageID'],**comparison_metrics(
                    outputs['mosaic_INT8'],outputs['mosaic_BASELINE_INT8'],content)))
            save_json(root/'progress.json',dict(state='evaluation',split=args.split,images=len(rows)//len(models),
                elapsed_seconds=time.monotonic()-started))
        # Public demos only; old and new Starry outputs are shown with their
        # actual model identities, not called poor Mosaic reproductions.
        old=None if args.baseline_qat_run or args.skip_previews else load_qat_checkpoint(case/'model/microstyle24_starry_functional/checkpoint_qat.pt')
        starry=None if args.baseline_qat_run or args.skip_previews else load_new_qat(case/'outputs/c36_qat_b_starry_equalized_20260915a')
        for filename in (() if args.skip_previews else ('astronaut.png','coffee.png','rocket.jpg')):
            content,pixels=preview_tensor(case/'assets/images'/filename)
            output=models['mosaic_INT8'](content) if 'mosaic_INT8' in models else None
            if args.baseline_qat_run:
                baseline=models['mosaic_BASELINE_INT8'](content)
                images=[('INPUT',content),('BEFORE: MOSAIC B INT8',baseline),('CANDIDATE: MOSAIC B INT8',output),
                        ('OFFICIAL TEACHER - NOT FPGA',teacher_rgb(teacher,content)),
                        ('FLOAT REFERENCE',floating(content)),('ABS DIFFERENCE x4',(output-baseline).abs()*4)]
            else:
                images=[('INPUT',content),('OLD STARRY QAT',old(content)),('B STARRY INT8',starry(content)),
                        ('OFFICIAL MOSAIC TEACHER - NOT FPGA',teacher_rgb(teacher,content)),
                        ('B MOSAIC FLOAT',floating(content))]
                if output is not None:
                    images.append(('B MOSAIC INT8',output))
            canvas=Image.new('RGB',(960,528),'white')
            draw=ImageDraw.Draw(canvas)
            for i,(name,image) in enumerate(images):
                x,y=(i%3)*320,(i//3)*264
                draw.text((x+3,y+4),name,fill='black')
                canvas.paste(image_from_tensor(image[0]).resize((320,240),Image.Resampling.LANCZOS),(x,y+24))
            canvas.save(root/(Path(filename).stem+'_mosaic_comparison.png'))
            if args.native_integer_check and native is None:
                expected=integer_student(pixels,candidate_nodes(**floating.config),package.layers)
                actual=output[0].mul(255).round().byte().numpy().transpose(1,2,0)
                np.testing.assert_array_equal(actual,expected)
                native=dict(image=filename,width=640,height=480,RGB_bytes_checked=921600,
                            integer_arena_vs_QAT_max_error=0,RTL_simulated=False)
    means={}
    for name in models:
        group=[r for r in rows if r['model']==name]
        means[name]={key:sum(r[key] for r in group)/len(group) for key in group[0] if key not in ('image','model')}
    quant_delta=None if not deltas else {key:sum(r[key] for r in deltas)/len(deltas) for key in deltas[0] if key!='image'}
    baseline_delta=None if not baseline_deltas else {key:sum(r[key] for r in baseline_deltas)/len(baseline_deltas)
                                                   for key in baseline_deltas[0] if key!='image'}
    report=dict(state='complete',split=args.split,images=32,test_images_read=32 if args.split=='test' else 0,
                float_selected_step=checkpoint['step'],QAT_selected_step=None if qat_checkpoint is None else qat_checkpoint['step'],
                float_run=str(args.float_run.resolve()),qat_run=None if args.qat_run is None else str(args.qat_run.resolve()),
                baseline_qat_run=None if args.baseline_qat_run is None else str(args.baseline_qat_run.resolve()),
                teacher_directory=config['teacher_directory'],means=means,rows=rows,quantized_vs_float=quant_delta,
                quantized_vs_float_scope='selected_INT8_vs_original_pre_QAT_float_including_QAT_training_drift_not_isolated_rounding_error',
                quantized_vs_baseline=baseline_delta,
                native_integer_probe=native,public_preview_shape=None if args.skip_previews else [480,640],
                public_previews_generated=0 if args.skip_previews else 3,
                input_quantization='nearest_uint8_before_teacher_and_all_students',
                dataset=str(dataset.resolve()),elapsed_seconds=time.monotonic()-started,
                teacher_similarity_is_aesthetic_score=False,model_styles_differ_in_public_comparison=not bool(args.baseline_qat_run),
                RTL_simulated=False,RTL_FPS_measured=False)
    save_json(root/'evaluation.json',report)
    save_json(root/'progress.json',dict(state='complete',split=args.split,images=32,
        elapsed_seconds=time.monotonic()-started,report_file='evaluation.json'))
    print('C36_DISTILLED_STUDENT_EVALUATED '+json.dumps({k:v for k,v in report.items() if k!='rows'},separators=(',',':')))


if __name__=='__main__':
    main()
