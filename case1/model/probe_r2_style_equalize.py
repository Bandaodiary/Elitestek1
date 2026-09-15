"""Small real-checkpoint PTQ diagnosis on training images, no test selection."""
import argparse
import json
from pathlib import Path

import torch

from prepare_r2_style_data import save_json
from r2_style_student import R2StyleStudent
from r2_style_quant import fold_student, calibrate_student, QATStudent
from r2_style_equalize import equalize_student, exclusive_pairs
from r2_style_perceptual import ssim_luma
from train_r2_style_student import Patches, load_rgb


@torch.no_grad()
def measure(reference, model, samples, scales):
    results = []
    stage_errors = {}
    for image in samples:
        expected, float_stages = reference(image,True)
        observed, quant_stages = model(image,True)
        results.append(dict(mae_u8=float((observed-expected).abs().mean()*255),
                            ssim_box11=float(ssim_luma(expected,observed))))
        for node in reference.nodes[:-1]:
            name = node.spec.name
            base = float_stages[name]
            error = quant_stages[name]*scales[name]-base
            row = stage_errors.setdefault(name,[])
            row.append(dict(relative_rmse=float(error.square().mean().sqrt()/base.square().mean().sqrt().clamp_min(1e-6)),
                            saturation=float((quant_stages[name].abs()>=127).float().mean()),
                            max_float=float(base.abs().max()),scale=scales[name]))
    return dict(mean={k:sum(r[k] for r in results)/len(results) for k in results[0]},
                stages={name:{k:sum(v[k] for v in rows)/len(rows) for k in rows[0]} for name,rows in stage_errors.items()})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--float-run',type=Path,required=True)
    parser.add_argument('--dataset',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.output.exists():
        raise FileExistsError('new probe output required')
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    state=torch.load(args.float_run/'checkpoint_best.pt',map_location='cpu',weights_only=True)
    model=R2StyleStudent(**state['model_config']).eval()
    model.load_state_dict(state['model_state'],strict=True)
    folded=fold_student(model)
    data=json.loads((args.dataset/'manifest.json').read_text(encoding='utf-8'))
    sources=[load_rgb(args.dataset/r['file'],192) for r in data['images'] if r['split']=='train'][:32]
    stream=Patches(sources,20260919)
    calibration=[stream.batch(2,64,torch.device('cpu')) for _ in range(8)]
    evaluation=[stream.batch(1,64,torch.device('cpu')) for _ in range(8)]
    equalized,details=equalize_student(folded,calibration)
    with torch.no_grad():
        differences=[float((folded(x)-equalized(x)).abs().max()*255) for x in evaluation]
    if max(differences)>1.001:
        raise AssertionError('equalization changed float function beyond one RGB rounding code')
    results={}
    for name,reference in [('original',folded),('equalized',equalized)]:
        scales=calibrate_student(reference,calibration)
        qat=QATStudent(reference,scales).eval()
        results[name]=measure(reference,qat,evaluation,scales)
    report=dict(split='train',evaluation_patches=8,calibration_batches=8,
                full_validation=False,RTL_simulated=False,trained_checkpoint_step=state['step'],
                equalization=details,float_rgb_max_code_delta=max(differences),results=results)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    save_json(args.output,report)
    print('C36_EQUALIZATION_PROBE '+json.dumps(dict(float_rgb_max_code_delta=max(differences),
        balanced_pairs=len(details['pairs']),metrics={k:v['mean'] for k,v in results.items()},
        full_validation=False,RTL_simulated=False)))


if __name__=='__main__':
    main()
