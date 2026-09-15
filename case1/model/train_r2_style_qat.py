"""Train the new candidate on the deployed integer grid and export its R2 plan.

Requires an actually completed/exited float training worker. No test-split
images, original C35 files, EDA processes, or hardware resource claims touched.
"""
import argparse
from dataclasses import asdict
import json
import math
import os
from pathlib import Path
import time

import numpy as np
import psutil
import torch
from torch.nn import functional as F

from prepare_r2_style_data import outside_job, save_json
from r2_execution_plan import OP_OUTPUT_RGB, render_sv
from r2_plan_package import compile_package, export_new
from r2_row_fused_plan import fused_steps, fusion_sv
from r2_style_candidates import candidate_nodes
from r2_style_student import R2StyleStudent
from r2_style_perceptual import PerceptualFeatures, StyleObjective, ssim_luma
from r2_style_quant import fold_student, calibrate_student, QATStudent, export_student, integer_student
from r2_style_equalize import equalize_student
from train_r2_style_student import load_rgb, Patches, LoadGuard, validate, evaluation_input


def require_float_finished(directory):
    status = json.loads((directory/'status.json').read_text(encoding='utf-8'))
    if status['state'] != 'complete' or not status['trained']:
        raise ValueError('float training did not complete')
    try:
        worker = psutil.Process(status['pid'])
        if abs(worker.create_time()-status['process_start']) < .001:
            raise RuntimeError('float worker is still alive; do not overlap GPU training')
    except psutil.NoSuchProcess:
        pass
    return status


def save_qat(path, qat, metadata, step):
    temporary = path.with_suffix('.pending')
    torch.save(dict(model_config=qat.config, model_state=qat.model.state_dict(),
                    activation_scales=qat.activation_scales,
                    weight_scales={k:v['weight_scales'].tolist() for k,v in qat.quant_parameters.items()},
                    metadata=metadata, step=step, quantized=True, trained=True), temporary)
    temporary.replace(path)


@torch.no_grad()
def exact_export_probe(qat, package, content, device):
    nodes = candidate_nodes(**qat.config, width=16, height=12)
    image = F.interpolate(content[None], size=(12,16), mode='bilinear', align_corners=False)
    image = image[0].mul(255).round().byte().numpy().transpose(1,2,0)
    rng = np.random.default_rng(20260915)
    stimuli = [image, np.zeros_like(image), np.full_like(image,255),
               rng.integers(0,256,image.shape,dtype=np.uint8)]
    for stimulus in stimuli:
        expected, stages = integer_student(stimulus, nodes, package.layers, collect=True)
        tensor = torch.from_numpy(stimulus.transpose(2,0,1).copy())[None].float().to(device)/255
        output, observed = qat(tensor, return_stages=True)
        actual = output[0].mul(255).round().byte().cpu().numpy().transpose(1,2,0)
        np.testing.assert_array_equal(actual, expected)
        for node in nodes:
            if node.spec.opcode != OP_OUTPUT_RGB:
                layer = observed[node.spec.name][0].cpu().numpy().transpose(1,2,0)
                np.testing.assert_array_equal(layer, stages[node.spec.name])
    return dict(frames=len(stimuli), all_signed_stages_bitexact=True, device=str(device), RTL_simulated=False)


@torch.no_grad()
def compare_float(qat, teacher, validation, device, guard):
    results = []
    for name,image in validation:
        guard.begin()
        value = evaluation_input(image).to(device)
        reference, quantized = teacher(value), qat(value)
        delta = quantized-reference
        mse = float(delta.square().mean())
        results.append(dict(image=name, mae_u8=float(delta.abs().mean()*255),
                            max_error_u8=float(delta.abs().max()*255),
                            psnr_db=-10*math.log10(max(mse, 1e-12)),
                            ssim_box11=float(ssim_luma(reference,quantized))))
        guard.end()
    return dict(split='val', reference='new float checkpoint, NOT original input or an external standard NST model',
                images=results, mean={k:sum(r[k] for r in results)/len(results) for k in results[0] if k!='image'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--float-run', type=Path, required=True)
    parser.add_argument('--dataset', type=Path, required=True)
    parser.add_argument('--style', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--steps', type=int, default=600)
    parser.add_argument('--device', default='cuda:0')
    parser.add_argument('--duty', type=float, default=.25)
    parser.add_argument('--equalize', action='store_true')
    parser.add_argument('--require-detached', action='store_true')
    args = parser.parse_args()
    float_status = require_float_finished(args.float_run)
    if args.steps < 1 or not 0 < args.duty <= .35:
        raise ValueError('invalid QAT schedule/load')
    root = args.output.resolve()
    if root.exists():
        raise FileExistsError('new QAT directory required')
    detached = outside_job()
    if args.require_detached and detached is not True:
        raise RuntimeError('QAT worker must not be in a Windows Job')
    process = psutil.Process()
    process.cpu_affinity(process.cpu_affinity()[-1:])
    if os.name == 'nt':
        process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
    root.mkdir(parents=True)
    started = time.monotonic()
    status = dict(state='preparing', pid=os.getpid(), process_start=process.create_time(),
                  outside_windows_job=detached, cpu_affinity=process.cpu_affinity(), step=0,
                  trained=True, quantized=False, RTL_simulated=False, quality_validated=False)
    save_json(root/'status.json', status)
    try:
        torch.set_num_threads(1)
        torch.set_num_interop_threads(1)
        torch.manual_seed(20260915)
        device = torch.device(args.device)
        if device.type == 'cuda' and device.index is None:
            device = torch.device('cuda',0)
        if psutil.virtual_memory().available < 8*2**30:
            raise RuntimeError('less than 8 GiB free before QAT')
        if device.type == 'cuda':
            torch.cuda.set_per_process_memory_fraction(.25,device)
        torch.backends.cudnn.benchmark = False
        torch.backends.cudnn.deterministic = True
        torch.backends.cudnn.allow_tf32 = False
        torch.backends.cuda.matmul.allow_tf32 = False
        checkpoint = torch.load(args.float_run/'checkpoint_best.pt',map_location='cpu',weights_only=True)
        if not checkpoint['trained'] or checkpoint['quantized'] or checkpoint['step'] < 1:
            raise ValueError('not an optimized float checkpoint')
        teacher = R2StyleStudent(**checkpoint['model_config']).to(device).eval()
        teacher.load_state_dict(checkpoint['model_state'],strict=True)
        teacher.requires_grad_(False)
        folded = fold_student(teacher)
        folded.requires_grad_(True)
        data = json.loads((args.dataset/'manifest.json').read_text(encoding='utf-8'))
        if data['state'] != 'complete':
            raise ValueError('incomplete dataset')
        training = [load_rgb(args.dataset/r['file'],384) for r in data['images'] if r['split']=='train']
        validation = [(r['ImageID'],load_rgb(args.dataset/r['file'])) for r in data['images'] if r['split']=='val']
        calibration = Patches(training, 20260916)
        stream = Patches(training, 20260917)
        guard = LoadGuard(device,args.duty,root/'status.json',status)
        def batches():
            for _ in range(32):
                guard.begin()
                yield calibration.batch(2,128,device)
                guard.end()
        if args.equalize:
            folded, balancing = equalize_student(folded,batches())
            save_json(root/'channel_equalization.json',balancing)
            # Identical calibration crops to the non-balanced experiment.
            calibration = Patches(training,20260916)
        scales = calibrate_student(folded,batches())
        with torch.no_grad():
            sample = stream.batch(2,128,device)
            maximum = float((teacher(sample)-folded(sample)).abs().max()*255)
        if maximum > 1.001:
            raise AssertionError('BN folding changed RGB by more than one rounding code')
        qat = QATStudent(folded,scales).to(device)
        style_gain = float(checkpoint['metadata']['config'].get('style_gain',1.))
        from r2_style_objectives import make_objective
        objective_variant = checkpoint['metadata']['config'].get('objective','original')
        teacher_directory = checkpoint['metadata']['config'].get('teacher_directory')
        if objective_variant!='teacher_distill' and args.style is None:
            raise ValueError('a style image is required for Gram QAT')
        style = None if objective_variant=='teacher_distill' else load_rgb(args.style,384)[None].to(device)
        objective = make_objective(objective_variant,PerceptualFeatures(args.dataset/data['feature_weights']['file']).to(device),
                                   style,style_gain=style_gain,teacher_directory=teacher_directory).to(device)
        metadata = dict(trained=True, float_run=str(args.float_run.resolve()),
                        float_total_steps=float_status['step'], float_selected_step=checkpoint['step'],
                        QAT_steps=args.steps, calibration_batches=32, calibration_split='train',
                        dataset_manifest=str((args.dataset/'manifest.json').resolve()), test_images_read=0,
                        feature_network='SqueezeNet 1.1, training only', float_fold_max_rgb_code_delta=maximum,
                        channel_equalization=args.equalize,
                        style_gain=style_gain, objective_variant=objective_variant, teacher_directory=teacher_directory,
                        arithmetic='candidate exact-grid QAT; frozen per-channel weight and tied activation scales')
        save_json(root/'training_config.json',metadata)
        before = validate(qat,objective,validation,device,root/'ptq_validation_preview.png',guard)
        save_json(root/'ptq_validation.json',before)
        save_json(root/'ptq_float_delta.json',compare_float(qat,teacher,validation,device,guard))
        best = before['mean']['objective']
        save_qat(root/'checkpoint_best.pt',qat,metadata,0)
        optimizer = torch.optim.Adam(qat.parameters(),lr=2e-5)
        with (root/'progress.jsonl').open('x',encoding='utf-8',buffering=1) as history:
            for step in range(1,args.steps+1):
                guard.begin()
                qat.train()
                content = stream.batch(2,128,device)
                output = qat(content)
                with torch.no_grad():
                    target = teacher(content)
                loss,components = objective(output,content)
                match = F.l1_loss(output,target)
                loss = loss+match
                if not torch.isfinite(loss):
                    raise RuntimeError('nonfinite QAT loss')
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                gradient = torch.nn.utils.clip_grad_norm_(qat.parameters(),5.,error_if_nonfinite=True)
                optimizer.step()
                status.update(state='training',step=step,quantized=True,loss=float(loss.detach()),
                              elapsed_seconds=round(time.monotonic()-started,3),
                              heartbeat_local=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
                if step == 1 or step%25 == 0:
                    history.write(json.dumps(dict(step=step,loss=status['loss'],float_match=float(match.detach()),gradient_norm=float(gradient)))+'\n')
                    save_json(root/'status.json',status)
                guard.end()
                if step%100 == 0 or step==args.steps:
                    result = validate(qat,objective,validation,device,root/'validation_latest.png',guard)
                    result['step']=step
                    save_json(root/'validation_latest.json',result)
                    save_qat(root/'checkpoint_latest.pt',qat,metadata,step)
                    if result['mean']['objective'] < best:
                        best=result['mean']['objective']
                        save_qat(root/'checkpoint_best.pt',qat,metadata,step)
                        save_json(root/'validation_best.json',result)
                    history.write(json.dumps(dict(step=step,validation=result['mean'],best_objective=best))+'\n')
        selected = torch.load(root/'checkpoint_best.pt',map_location=device,weights_only=True)
        qat.model.load_state_dict(selected['model_state'],strict=True)
        qat.eval()
        metadata['selected_QAT_step']=selected['step']
        manifest = export_student(qat,root/'artifact',metadata)
        nodes=candidate_nodes(**qat.config)
        package=compile_package(nodes,artifact=root/'artifact')
        package.manifest.update(topology_retraining_performed=True,training_provenance=metadata)
        export_new(package,root/'plan_unfused')
        steps,pairs=fused_steps(nodes)
        if len(pairs)!=1:
            raise AssertionError('expected exactly one supported tail fusion')
        fused=root/'plan_fused'
        fused.mkdir()
        (fused/'execution_plan.sv').write_text(render_sv(steps),encoding='utf-8')
        (fused/'row_fusion_plan.sv').write_text(fusion_sv(steps,pairs),encoding='utf-8')
        save_json(fused/'manifest.json',dict(parameter_image='../plan_unfused/parameters.bin',pairs=pairs,
                  steps=[asdict(step) for step in steps],RTL_simulated=False))
        probe=exact_export_probe(qat,package,training[0],device)
        save_json(root/'integer_export_probe.json',probe)
        final=validate(qat,objective,validation,device,root/'validation_selected.png',guard)
        final['selected_QAT_step']=selected['step']
        save_json(root/'validation_selected.json',final)
        save_json(root/'selected_float_delta.json',compare_float(qat,teacher,validation,device,guard))
        status.update(state='complete',selected_QAT_step=selected['step'],quantized=True,
                      integer_probe=probe,parameter_arena_bytes=manifest['parameter_arena_bytes'],
                      parameter_plan_bytes=len(package.image),fusion_pair=pairs[0],
                      elapsed_seconds=round(time.monotonic()-started,3),test_images_read=0,
                      finished_local=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
        save_json(root/'status.json',status)
        print('C36_QAT_TRAINING_EXPORT_COMPLETE '+json.dumps(status))
    except Exception as exc:
        status.update(state='failed',error=repr(exc),elapsed_seconds=round(time.monotonic()-started,3))
        save_json(root/'status.json',status)
        raise


if __name__=='__main__':
    main()
