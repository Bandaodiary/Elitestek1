"""Frozen-model val/test comparison + permitted public-image native previews.

Uses no test images for model selection. Perceptual metrics are engineering
proxies, not a claim of competition-quality art. Native frame rate requires RTL.
"""
import argparse
import json
import os
from pathlib import Path
import time

import numpy as np
from PIL import Image, ImageDraw, ImageOps
import psutil
import torch

from microstyle_quant import load_qat_checkpoint, integer_infer_rgb
from prepare_r2_style_data import save_json
from r2_plan_package import compile_package
from r2_style_candidates import candidate_nodes
from r2_style_student import R2StyleStudent
from r2_style_quant import fold_student, QATStudent, integer_student
from r2_style_perceptual import PerceptualFeatures, StyleObjective, ssim_luma, luma, spatial_gradient
from train_r2_style_student import load_rgb, evaluation_input, image_from_tensor
from train_r2_style_qat import require_float_finished


def load_new_qat(directory):
    status=json.loads((directory/'status.json').read_text(encoding='utf-8'))
    if status['state']!='complete' or not status['integer_probe']['all_signed_stages_bitexact']:
        raise ValueError('new QAT/export not complete and numerically checked')
    try:
        p=psutil.Process(status['pid'])
        if abs(p.create_time()-status['process_start'])<.001:
            raise RuntimeError('QAT worker still alive; wait before evaluation')
    except psutil.NoSuchProcess:
        pass
    checkpoint=torch.load(directory/'checkpoint_best.pt',map_location='cpu',weights_only=True)
    model=fold_student(R2StyleStudent(**checkpoint['model_config']))
    model.load_state_dict(checkpoint['model_state'],strict=True)
    weights={k:np.asarray(v,dtype=np.float64) for k,v in checkpoint['weight_scales'].items()}
    return QATStudent(model,checkpoint['activation_scales'],weights).eval()


@torch.no_grad()
def metrics(model,objective,image):
    output=model(image)
    total,terms=objective(output,image)
    edges=lambda x:sum(g.abs().mean() for g in spatial_gradient(luma(x)))
    return output,dict(objective=float(total),content_feature=float(terms['content']),style_gram=float(terms['style']),
                       content_ssim_box11=float(ssim_luma(output,image)),change_mae_u8=float((output-image).abs().mean()*255),
                       edge_energy_ratio=float(edges(output)/edges(image).clamp_min(1e-6)),
                       saturation_fraction=float(((output<=0)|(output>=1)).float().mean()))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--float-run',type=Path,required=True)
    parser.add_argument('--qat-run',type=Path,required=True)
    parser.add_argument('--dataset',type=Path,required=True)
    parser.add_argument('--style',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--split',choices=('val','test'),default='val')
    parser.add_argument('--skip-previews',action='store_true')
    parser.add_argument('--native-integer-check',action='store_true')
    args=parser.parse_args()
    root=args.output.resolve()
    if root.exists():
        raise FileExistsError('new comparison directory required')
    if args.native_integer_check and args.skip_previews:
        raise ValueError('native integer probe requires public native previews')
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    process=psutil.Process()
    process.cpu_affinity(process.cpu_affinity()[-1:])
    if os.name=='nt':
        process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
    if psutil.virtual_memory().available<8*2**30:
        raise RuntimeError('less than 8 GiB free before model comparison')
    require_float_finished(args.float_run)
    quantized=load_new_qat(args.qat_run)
    checkpoint=torch.load(args.float_run/'checkpoint_best.pt',map_location='cpu',weights_only=True)
    qat_checkpoint=torch.load(args.qat_run/'checkpoint_best.pt',map_location='cpu',weights_only=True)
    float_config=checkpoint['metadata']['config']
    qat_metadata=qat_checkpoint['metadata']
    if (float_config.get('objective','original')!='original' or
        Path(qat_metadata['float_run']).resolve()!=args.float_run.resolve() or
        qat_metadata['float_selected_step']!=checkpoint['step'] or
        qat_checkpoint['model_config']!=checkpoint['model_config'] or
        Path(float_config['dataset']).resolve()!=args.dataset.resolve() or
        Path(qat_metadata['dataset_manifest']).resolve()!=(args.dataset/'manifest.json').resolve() or
        Path(float_config['style']).resolve()!=args.style.resolve()):
        raise ValueError('comparison requires the same frozen Gram-trained float/QAT model, dataset and style')
    floating=R2StyleStudent(**checkpoint['model_config']).eval()
    floating.load_state_dict(checkpoint['model_state'],strict=True)
    case=Path(__file__).resolve().parents[1]
    old_artifact=case/'model'/'microstyle24_starry_functional'
    old=load_qat_checkpoint(old_artifact/'checkpoint_qat.pt')
    models={'old_QAT_reference':old,'new_float':floating,'new_INT8_grid':quantized}
    data=json.loads((args.dataset/'manifest.json').read_text(encoding='utf-8'))
    selected=[entry for entry in data['images'] if entry['split']==args.split]
    if (data['state']!='complete' or len(selected)!=data['requested'][args.split] or
        len({entry['ImageID'] for entry in selected})!=len(selected) or not selected):
        raise ValueError('incomplete/duplicate evaluation partition')
    features=PerceptualFeatures(args.dataset/data['feature_weights']['file'])
    objective=StyleObjective(features,load_rgb(args.style,384)[None],style_gain=float(float_config.get('style_gain',1.)))
    package=compile_package(candidate_nodes(**quantized.config),args.qat_run/'artifact')
    for name,arrays in package.layers.items():
        for exported,expected in zip(arrays,quantized.quantized_arrays(name)):
            np.testing.assert_array_equal(exported,expected)
    root.mkdir(parents=True)
    start=time.monotonic()
    rows=[]
    quantization_rows=[]
    old_probe_error=[]
    for entry in selected:
        # All references, including the content loss, see the same actual
        # RGB byte codes. Older reports used fractional resized content.
        image=evaluation_input(load_rgb(args.dataset/entry['file'])).clamp(0,1).mul(255).round()/255
        observed={}
        for name,model in models.items():
            output,result=metrics(model,objective,image)
            observed[name]=output
            rows.append(dict(image=entry['ImageID'],model=name,**result))
        difference=observed['new_INT8_grid']-observed['new_float']
        mse=float(difference.square().mean())
        quantization_rows.append(dict(image=entry['ImageID'],mae_u8=float(difference.abs().mean()*255),
            max_error_u8=float(difference.abs().max()*255),
            psnr_db=-10*float(np.log10(max(mse,1e-12))),
            ssim_box11=float(ssim_luma(observed['new_INT8_grid'],observed['new_float']))))
        # Verify the old QAT's arithmetic on four tiny photographs separately;
        # a passing check is not silently extrapolated to all larger images.
        if len(old_probe_error)<4:
            tiny=torch.nn.functional.interpolate(image,size=(12,16),mode='bilinear',align_corners=False)
            pixels=tiny[0].mul(255).round().byte().numpy().transpose(1,2,0)
            expected,_=integer_infer_rgb(pixels,old_artifact)
            with torch.no_grad():
                predicted=old(torch.from_numpy(pixels.transpose(2,0,1).copy())[None].float()/255)
            actual=predicted[0].mul(255).round().byte().numpy().transpose(1,2,0)
            old_probe_error.append(int(np.abs(expected.astype(np.int16)-actual.astype(np.int16)).max()))
        if len(rows)%24==0:
            save_json(root/'progress.json',dict(state='evaluation',split=args.split,images=len(rows)//len(models),elapsed_seconds=time.monotonic()-start))
    means={name:{key:sum(row[key] for row in rows if row['model']==name)/len(selected)
                 for key in rows[0] if key not in ('image','model')} for name in models}
    # Only these already-reviewed default assets are included in public-ready
    # previews. They are diagnostic, not held-out from the OLD model's training.
    labels=['INPUT','OLD QAT REFERENCE','NEW FLOAT','NEW INT8 GRID']
    preview_paths=[]
    native_probe=None
    for filename in (() if args.skip_previews else ('astronaut.png','coffee.png','rocket.jpg')):
        with Image.open(case/'assets'/'images'/filename) as source:
            image=ImageOps.fit(ImageOps.exif_transpose(source).convert('RGB'),(640,480),Image.Resampling.LANCZOS)
        pixels=np.asarray(image,dtype=np.uint8).copy()
        tensor=torch.from_numpy(pixels.transpose(2,0,1).copy())[None].float()/255
        with torch.no_grad():
            outputs=[tensor[0]]+[model(tensor)[0] for model in models.values()]
        canvas=Image.new('RGB',(1280,266),'white')
        draw=ImageDraw.Draw(canvas)
        for i,(label,value) in enumerate(zip(labels,outputs)):
            draw.text((i*320+4,4),label,fill='black')
            canvas.paste(image_from_tensor(value).resize((320,240),Image.Resampling.LANCZOS),(i*320,24))
        target=root/(Path(filename).stem+'_comparison.png')
        canvas.save(target)
        preview_paths.append(target.name)
        if args.native_integer_check and native_probe is None:
            # Direct full 640x480 integer arithmetic using the EXPORTED arena.
            # No claim that this measures hardware time or tests the RTL.
            expected=integer_student(pixels,candidate_nodes(**quantized.config),package.layers)
            actual=outputs[-1].mul(255).round().byte().numpy().transpose(1,2,0)
            np.testing.assert_array_equal(actual,expected)
            native_probe=dict(image=filename,width=640,height=480,RGB_bytes_checked=640*480*3,
                               integer_arena_vs_QAT_max_error=0,RTL_simulated=False)
    quantization_mean={key:sum(row[key] for row in quantization_rows)/len(quantization_rows)
                       for key in quantization_rows[0] if key!='image'}
    report=dict(state='complete',split=args.split,test_images_read=len(selected) if args.split=='test' else 0,
                 images_per_model=len(selected),input_RGB_grid='explicit uint8; same codes for all models/content loss',
                 selected_float_step=checkpoint['step'],selected_QAT_step=qat_checkpoint['step'],
                 quantized_vs_float=dict(mean=quantization_mean,images=quantization_rows),
                 mean=means,images=rows,previews=preview_paths,
                 native_integer_probe=native_probe,
                 old_QAT_vs_integer_tiny_probe=dict(frames=len(old_probe_error),maximum_errors=old_probe_error),
                 caveat='Metrics are proxies, not aesthetic quality. Old QAT rounding is only separately checked on the listed tiny probes.',
                 float_run=str(args.float_run.resolve()),qat_run=str(args.qat_run.resolve()),
                 elapsed_seconds=time.monotonic()-start,RTL_FPS_measured=False)
    save_json(root/'comparison.json',report)
    save_json(root/'progress.json',dict(state='complete',split=args.split,images=len(selected),elapsed_seconds=report['elapsed_seconds']))
    print('C36_STYLE_COMPARISON_COMPLETE '+json.dumps(dict(mean=means,native_integer_probe=native_probe,
        quantized_vs_float=quantization_mean,split=args.split,
        old_tiny_probe_errors=old_probe_error,test_images_read=report['test_images_read'],elapsed_seconds=report['elapsed_seconds'])))


if __name__=='__main__':
    main()
