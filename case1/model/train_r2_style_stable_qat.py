"""Fine-tune a frozen-grid B checkpoint for synthetic motion/noise robustness.

The original learned-teacher objective and float-student anchor are retained.
Selection uses an explicitly weighted quality/consistency score on VAL only.
No network arithmetic, topology, current EDA source, or existing run is changed.
"""
import argparse
from dataclasses import asdict
import json
import os
from pathlib import Path
import time

import numpy as np
import psutil
import torch
from torch.nn import functional as F

from compare_r2_style_models import load_new_qat
from prepare_r2_style_data import outside_job, save_json
from r2_execution_plan import render_sv
from r2_plan_package import compile_package, export_new
from r2_row_fused_plan import fused_steps, fusion_sv
from r2_style_candidates import candidate_nodes
from r2_style_consistency import POSES, rgb_grid, consistency_terms, validation_consistency
from r2_style_objectives import make_objective
from r2_style_perceptual import PerceptualFeatures
from r2_style_quant import export_student
from r2_style_student import R2StyleStudent
from train_r2_style_student import load_rgb, Patches, LoadGuard, validate
from train_r2_style_qat import require_float_finished, save_qat, exact_export_probe, compare_float


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--initial-qat-run', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--steps', type=int, default=600)
    parser.add_argument('--translation-weight', type=float, default=4.)
    parser.add_argument('--noise-weight', type=float, default=2.)
    parser.add_argument('--learning-rate', type=float, default=2e-5)
    parser.add_argument('--device', default='cuda:0')
    parser.add_argument('--duty', type=float, default=.20)
    args = parser.parse_args()
    if (not 1 <= args.steps <= 2400 or not 0 < args.duty <= .25 or
            not 0 < args.translation_weight <= 8 or not 0 < args.noise_weight <= 8 or
            not 0 < args.learning_rate <= 1e-4):
        raise ValueError('invalid bounded fine-tuning settings')
    case = Path(__file__).resolve().parents[1]
    root = args.output.resolve()
    if root.exists() or not root.is_relative_to(case/'outputs'):
        raise ValueError('new case1/outputs directory required')
    detached = outside_job()
    if detached is not True:
        raise RuntimeError('training must be launched outside a Windows Job')
    process = psutil.Process()
    process.cpu_affinity(process.cpu_affinity()[-1:])
    if os.name == 'nt':
        process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
    if psutil.virtual_memory().available < 8*2**30:
        raise RuntimeError('less than 8 GiB free before training')
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    torch.manual_seed(20260915)
    device = torch.device(args.device)
    if device.type == 'cuda' and device.index is None:
        device = torch.device('cuda', 0)
    if device.type == 'cuda':
        torch.cuda.set_per_process_memory_fraction(.25, device)
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.allow_tf32 = False
    torch.backends.cuda.matmul.allow_tf32 = False
    qat = load_new_qat(args.initial_qat_run).to(device)
    initial = torch.load(args.initial_qat_run/'checkpoint_best.pt', map_location='cpu', weights_only=True)
    metadata = dict(initial['metadata'])
    if qat.config != dict(blocks=2, expansion=24, preproject=True) or metadata['objective_variant'] != 'teacher_distill':
        raise ValueError('this bounded experiment requires the Mosaic B graph and teacher')
    float_run = Path(metadata['float_run'])
    require_float_finished(float_run)
    floating = torch.load(float_run/'checkpoint_best.pt', map_location='cpu', weights_only=True)
    if (floating['model_config'] != qat.config or floating['step'] != metadata['float_selected_step'] or
            Path(floating['metadata']['config']['teacher_directory']).resolve() != Path(metadata['teacher_directory']).resolve()):
        raise ValueError('float/quantized/teacher provenance mismatch')
    teacher = R2StyleStudent(**floating['model_config']).to(device).eval()
    teacher.load_state_dict(floating['model_state'], strict=True)
    teacher.requires_grad_(False)
    dataset = Path(metadata['dataset_manifest']).parent
    data = json.loads((dataset/'manifest.json').read_text(encoding='utf-8'))
    if data['state'] != 'complete':
        raise ValueError('incomplete dataset')
    authors = {split: {r['AuthorProfileURL'].rstrip('/') for r in data['images'] if r['split'] == split}
               for split in ('train', 'val', 'test')}
    if any(authors[a] & authors[b] for a, b in (('train', 'val'), ('train', 'test'), ('val', 'test'))):
        raise ValueError('dataset photographer leakage')
    training = [load_rgb(dataset/r['file'], 384) for r in data['images'] if r['split'] == 'train']
    validation = [(r['ImageID'], load_rgb(dataset/r['file'])) for r in data['images'] if r['split'] == 'val']
    if len(training) != 192 or len(validation) != 32:
        raise ValueError('unexpected split size')
    root.mkdir(parents=True)
    started = time.monotonic()
    status = dict(state='preparing', pid=os.getpid(), process_start=process.create_time(),
                  outside_windows_job=detached, cpu_affinity=process.cpu_affinity(),
                  trained=True, quantized=True, step=0, RTL_simulated=False, quality_validated=False)
    save_json(root/'status.json', status)
    try:
        guard = LoadGuard(device, args.duty, root/'status.json', status)
        guard.begin()
        objective = make_objective('teacher_distill',
            PerceptualFeatures(dataset/data['feature_weights']['file']).to(device), None,
            teacher_directory=metadata['teacher_directory']).to(device)
        guard.end()
        metadata.update(initial_qat_run=str(args.initial_qat_run.resolve()), initial_QAT_step=initial['step'],
                        QAT_steps=args.steps, selected_QAT_step=None, test_images_read=0,
                        consistency=dict(translation_weight=args.translation_weight, noise_weight=args.noise_weight,
                            poses=list(POSES), margin=32, noise_LSB=1, real_video=False),
                        selection_rule='VAL teacher objective + translation_weight*VAL128 translation + noise_weight*VAL128 noise',
                        learning_rate=args.learning_rate, recalibration_performed=False, production_RTL_changed=False)
        save_json(root/'training_config.json', metadata)
        stream = Patches(training, 20260918)
        generator = torch.Generator(device=device).manual_seed(20260919)

        def assess(step):
            quality = validate(qat, objective, validation, device, root/'validation_latest.png', guard)
            stable = validation_consistency(qat, validation, device, guard)
            score = (quality['mean']['objective']+args.translation_weight*stable['mean']['translation']+
                     args.noise_weight*stable['mean']['noise'])
            result = dict(step=step, selection_score=score, quality=quality, consistency=stable)
            save_json(root/'validation_latest.json', result)
            return result

        result = assess(0)
        save_json(root/'validation_initial.json', result)
        best = result['selection_score']
        save_qat(root/'checkpoint_best.pt', qat, metadata, 0)
        save_json(root/'validation_best.json', result)
        optimizer = torch.optim.Adam(qat.parameters(), lr=args.learning_rate)
        with (root/'progress.jsonl').open('x', encoding='utf-8', buffering=1) as history:
            for step in range(1, args.steps+1):
                guard.begin()
                qat.train()
                content = rgb_grid(stream.batch(2, 128, device))
                output = qat(content)
                with torch.no_grad():
                    target = teacher(content)
                loss, _ = objective(output, content)
                match = F.l1_loss(output, target)
                terms = consistency_terms(qat, content, output, POSES[(step-1) % len(POSES)], generator)
                loss = loss+match+args.translation_weight*terms['translation']+args.noise_weight*terms['noise']
                if not torch.isfinite(loss):
                    raise RuntimeError('nonfinite consistency QAT loss')
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                gradient = torch.nn.utils.clip_grad_norm_(qat.parameters(), 5., error_if_nonfinite=True)
                optimizer.step()
                status.update(state='training', step=step, loss=float(loss.detach()),
                              elapsed_seconds=round(time.monotonic()-started, 3),
                              heartbeat_local=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
                if step == 1 or step % 25 == 0:
                    history.write(json.dumps(dict(step=step, loss=status['loss'], float_match=float(match.detach()),
                        gradient_norm=float(gradient), **{k: float(v.detach()) for k, v in terms.items()}))+'\n')
                    save_json(root/'status.json', status)
                guard.end()
                if step % 200 == 0 or step == args.steps:
                    result = assess(step)
                    save_qat(root/'checkpoint_latest.pt', qat, metadata, step)
                    if result['selection_score'] < best:
                        best = result['selection_score']
                        save_qat(root/'checkpoint_best.pt', qat, metadata, step)
                        save_json(root/'validation_best.json', result)
                    history.write(json.dumps(dict(step=step, selection_score=result['selection_score'],
                                                  best_score=best))+'\n')
        selected = torch.load(root/'checkpoint_best.pt', map_location=device, weights_only=True)
        qat.model.load_state_dict(selected['model_state'], strict=True)
        qat.eval()
        metadata['selected_QAT_step'] = selected['step']
        manifest = export_student(qat, root/'artifact', metadata)
        nodes = candidate_nodes(**qat.config)
        package = compile_package(nodes, artifact=root/'artifact')
        package.manifest.update(topology_retraining_performed=True, training_provenance=metadata)
        export_new(package, root/'plan_unfused')
        steps, pairs = fused_steps(nodes)
        if pairs != [(14, 15)]:
            raise AssertionError('B tail fusion changed')
        fused = root/'plan_fused'
        fused.mkdir()
        (fused/'execution_plan.sv').write_text(render_sv(steps), encoding='utf-8')
        (fused/'row_fusion_plan.sv').write_text(fusion_sv(steps, pairs), encoding='utf-8')
        save_json(fused/'manifest.json', dict(parameter_image='../plan_unfused/parameters.bin', pairs=pairs,
                  steps=[asdict(step) for step in steps], RTL_simulated=False))
        for filename in ('execution_plan.sv', 'row_fusion_plan.sv'):
            if (fused/filename).read_bytes() != (args.initial_qat_run/'plan_fused'/filename).read_bytes():
                raise AssertionError('consistency training changed compiled hardware plan')
        probe = exact_export_probe(qat, package, training[0], device)
        save_json(root/'integer_export_probe.json', probe)
        save_json(root/'selected_float_delta.json', compare_float(qat, teacher, validation, device, guard))
        save_json(root/'validation_selected.json', assess(selected['step']))
        status.update(state='complete', selected_QAT_step=selected['step'], integer_probe=probe,
            parameter_arena_bytes=manifest['parameter_arena_bytes'], parameter_plan_bytes=len(package.image),
            fusion_pair=pairs[0], test_images_read=0, elapsed_seconds=round(time.monotonic()-started, 3),
            compiled_plans_unchanged=True, finished_local=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
        save_json(root/'status.json', status)
        print('C36_STABLE_QAT_EXPORT_COMPLETE '+json.dumps(status))
    except Exception as exc:
        status.update(state='failed', error=repr(exc), elapsed_seconds=round(time.monotonic()-started, 3))
        save_json(root/'status.json', status)
        raise


if __name__ == '__main__':
    main()
