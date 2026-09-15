"""C36 float training with bounded load, held-out validation and safe checkpoints.

Produces newly optimized float CNNs, not QAT artifacts or RTL FPS evidence.
The dataset's test partition is NEVER opened by this training script. Existing
C35 vectors, RTL, golden model and running simulations are never modified.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import random
import subprocess
import time

import numpy as np
from PIL import Image, ImageOps, ImageDraw
import psutil
import torch
from torch.nn import functional as F

from prepare_r2_style_data import outside_job, save_json
from r2_style_student import R2StyleStudent
from r2_style_perceptual import PerceptualFeatures, StyleObjective, luma, spatial_gradient, ssim_luma
from r2_style_objectives import make_objective


def load_rgb(path, longest=640):
    with Image.open(path) as source:
        image = ImageOps.exif_transpose(source).convert('RGB')
        image.thumbnail((longest, longest), Image.Resampling.LANCZOS)
        return torch.from_numpy(np.asarray(image, dtype=np.uint8).copy().transpose(2, 0, 1)).float()/255


class Patches:
    def __init__(self, images, seed):
        self.images = images
        self.rng = random.Random(seed)

    def batch(self, count, side, device):
        result = []
        for _ in range(count):
            value = self.images[self.rng.randrange(len(self.images))]
            # Variable-scale patches expose both object structure and texture.
            h, w = value.shape[-2:]
            crop = min(h, w, self.rng.randint(side, side*2))
            top, left = self.rng.randrange(h-crop+1), self.rng.randrange(w-crop+1)
            patch = value[:, top:top+crop, left:left+crop]
            if crop != side:
                patch = F.interpolate(patch[None], size=(side, side), mode='bilinear', align_corners=False, antialias=True)[0]
            if self.rng.random() < .5:
                patch = patch.flip(-1)
            result.append(patch)
        return torch.stack(result).to(device)


def evaluation_input(image):
    h, w = image.shape[-2:]
    scale = min(256/w, 192/h)
    # Avoid 255.99999999999997 rounding a nominal 256-wide frame down to 252.
    w, h = max(16, int(w*scale+1e-7)//4*4), max(16, int(h*scale+1e-7)//4*4)
    return F.interpolate(image[None], size=(h, w), mode='bilinear', align_corners=False, antialias=True)


def image_from_tensor(tensor):
    value = tensor.detach().clamp(0, 1).mul(255).round().byte().cpu().numpy().transpose(1, 2, 0)
    return Image.fromarray(value)


@torch.no_grad()
def validate(model, objective, images, device, preview_path=None, guard=None):
    model.eval()
    rows = []
    panels = []
    for name, image in images:
        if guard:
            guard.begin()
        content = evaluation_input(image).to(device)
        output = model(content)
        total, components = objective(output, content)
        gradients = lambda value: sum(x.abs().mean() for x in spatial_gradient(luma(value)))
        rows.append(dict(image=name, objective=float(total), **{k: float(v) for k, v in components.items()},
                         content_ssim_box11=float(ssim_luma(output, content)),
                         change_mae_u8=float((output-content).abs().mean()*255),
                         edge_energy_ratio=float(gradients(output)/gradients(content).clamp_min(1e-6)),
                         saturation_fraction=float(((output<=0)|(output>=1)).float().mean())))
        if len(panels) < 6:
            panels.append((name, image_from_tensor(content[0]), image_from_tensor(output[0])))
        if guard:
            guard.end()
    mean = {k: sum(row[k] for row in rows)/len(rows) for k in rows[0] if k != 'image'}
    if preview_path:
        canvas = Image.new('RGB', (512, 216*len(panels)), 'white')
        draw = ImageDraw.Draw(canvas)
        for index, (name, left, right) in enumerate(panels):
            label = 'NEW INT8-grid CNN' if hasattr(model, 'quant_parameters') else 'NEW FLOAT CNN (not INT8)'
            draw.text((4, index*216+3), f'{name} | input / {label}', fill='black')
            canvas.paste(left, (0, index*216+22))
            canvas.paste(right, (256, index*216+22))
        canvas.save(preview_path)
    model.train()
    return dict(mean=mean, images=rows, split='val', test_images_read=0)


def checkpoint(path, model, optimizer, metadata, step):
    temporary = path.with_suffix('.pending')
    torch.save(dict(model_config=model.config, model_state=model.state_dict(), optimizer_state=optimizer.state_dict(),
                    step=step, metadata=metadata, trained=step>0, quantized=False), temporary)
    temporary.replace(path)


class LoadGuard:
    def __init__(self, device, duty, status_path, status):
        self.device, self.duty = device, duty
        self.status_path, self.status = status_path, status
        self.step_started = time.monotonic()
        self.last_check = 0.
        self.total_pause = 0.

    def begin(self):
        # Guard reads no EDA logs and never alters another process. Exit on
        # unavailable telemetry instead of silently continuing a heavy GPU run.
        if time.monotonic()-self.last_check > 15:
            while True:
                free = psutil.virtual_memory().available/2**30
                cpu = psutil.cpu_percent(interval=.1)
                temperature = None
                if self.device.type == 'cuda':
                    result = subprocess.run(['C:/Windows/System32/nvidia-smi.exe',
                        '--query-gpu=temperature.gpu,power.draw,memory.used', '--format=csv,noheader,nounits'],
                        capture_output=True, text=True, timeout=10, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                    if result.returncode:
                        raise RuntimeError('GPU safety telemetry unavailable')
                    fields = result.stdout.strip().splitlines()[0].split(',')
                    temperature = float(fields[0])
                    self.status['gpu_telemetry'] = dict(temperature_c=temperature, power_w=float(fields[1]), used_mib=float(fields[2]))
                self.status.update(ram_free_gib=round(free, 3), cpu_percent=cpu)
                if free >= 8 and cpu < 75 and (temperature is None or temperature < 70):
                    break
                self.status.update(state='paused_for_load', heartbeat_local=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
                save_json(self.status_path, self.status)
                time.sleep(5)
                self.total_pause += 5
                if self.total_pause > 4*3600:
                    raise RuntimeError('resource pause budget exceeded; checkpoint retained')
            self.last_check = time.monotonic()
        self.step_started = time.monotonic()

    def end(self):
        if self.device.type == 'cuda':
            torch.cuda.synchronize(self.device)
        work = time.monotonic()-self.step_started
        time.sleep(min(5., max(0., work*(1/self.duty-1))))


def run(args):
    root = args.output.resolve()
    if root.exists():
        raise FileExistsError('new training output directory required')
    if not (0 < args.duty <= .35 and 32 <= args.patch <= 192 and args.patch%4 == 0 and 1 <= args.batch <= 2):
        raise ValueError('safe duty/patch/batch bounds violated')
    if not (0 < args.identity_steps < args.steps and args.validation_every > 0 and args.ramp_steps > 0):
        raise ValueError('invalid training schedule')
    if args.objective=='teacher_distill':
        if args.teacher_directory is None or args.style_gain!=1.:
            raise ValueError('teacher distillation needs an explicit teacher and style_gain=1')
    elif args.style is None:
        raise ValueError('a style image is required for a Gram-trained candidate')
    detached = outside_job()
    if args.require_detached and detached is not True:
        raise RuntimeError('training worker must not be in a Windows Job')
    process = psutil.Process()
    process.cpu_affinity(process.cpu_affinity()[-1:])
    if os.name == 'nt':
        process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
    if psutil.virtual_memory().available < 8*2**30:
        raise RuntimeError('less than 8 GiB free before training launch')
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = torch.device(args.device)
    if device.type == 'cuda' and device.index is None:
        device = torch.device('cuda', 0)
    if device.type == 'cuda':
        torch.cuda.set_per_process_memory_fraction(.25, device)
        torch.cuda.manual_seed_all(args.seed)
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    root.mkdir(parents=True)
    started = time.monotonic()
    status = dict(state='preparing', pid=os.getpid(), process_start=process.create_time(),
                  outside_windows_job=detached, cpu_affinity=process.cpu_affinity(), step=0,
                  config={k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
                  trained=False, quantized=False, RTL_simulated=False, quality_validated=False)
    save_json(root/'status.json', status)
    try:
        dataset = json.loads((args.dataset/'manifest.json').read_text(encoding='utf-8'))
        # Integrity checking reads image headers but never uses test pixels in a
        # training tensor, loss, model selection or preview. Avoid even that by
        # validating split metadata here; the separate dataset verifier checks files.
        if dataset['state'] != 'complete':
            raise ValueError('dataset is not complete')
        authors = {k: {r['AuthorProfileURL'].rstrip('/') for r in dataset['images'] if r['split']==k}
                   for k in ('train', 'val', 'test')}
        if any(authors[a] & authors[b] for a, b in (('train','val'),('train','test'),('val','test'))):
            raise ValueError('photographer leakage between splits')
        train_images = [load_rgb(args.dataset/r['file'], longest=384) for r in dataset['images'] if r['split']=='train']
        validation = [(r['ImageID'], load_rgb(args.dataset/r['file'])) for r in dataset['images'] if r['split']=='val']
        if len(train_images) != dataset['requested']['train'] or len(validation) != dataset['requested']['val']:
            raise ValueError('dataset split counts changed')
        stream = Patches(train_images, args.seed+1)
        student = R2StyleStudent(blocks=args.blocks, expansion=args.expansion, preproject=not args.retained_decoder).to(device)
        if args.initial_checkpoint:
            initial = torch.load(args.initial_checkpoint,map_location='cpu',weights_only=True)
            if initial['model_config'] != student.config or not initial['trained'] or initial['quantized']:
                raise ValueError('warm start requires a trained float checkpoint of the identical graph')
            student.load_state_dict(initial['model_state'],strict=True)
        features = PerceptualFeatures(args.dataset/dataset['feature_weights']['file']).to(device)
        style = None if args.objective=='teacher_distill' else load_rgb(args.style, longest=384)[None].to(device)
        objective = make_objective(args.objective, features, style, style_gain=args.style_gain,
                                   teacher_directory=args.teacher_directory).to(device)
        optimizer = torch.optim.Adam(student.parameters(), lr=args.learning_rate)
        guard = LoadGuard(device, args.duty, root/'status.json', status)
        metadata = dict(config=status['config'], dataset_manifest=str((args.dataset/'manifest.json').resolve()),
                        split_counts=dataset['requested'], validation_rule='mean configured style objective, fixed full val set',
                        test_images_read=0, objective_variant=args.objective,
                        reference_style_image_used=args.objective!='teacher_distill',
                        loss=dict(original='learned SqueezeNet features, Gram, edge, low luma, color, TV',
                                  coarse_palette='grayscale content features, low-pass RGB Gram, color mean/covariance, edge, luma, TV, high-frequency penalty',
                                  teacher_distill='frozen Fast Neural Style teacher RGB, features, Gram, edges, color; weak source luma and TV')[args.objective],
                        temporal_proxy='one-pixel translation, every eighth stylization step, not real video validation',
                        normalized_internal_ops=False, deployment='requires BN fold / calibration / INT8 QAT / export / RTL test')
        save_json(root/'training_config.json', metadata)
        student.train()
        best = math.inf
        with (root/'progress.jsonl').open('x', encoding='utf-8', buffering=1) as history:
            for step in range(1, args.steps+1):
                guard.begin()
                source = stream.batch(args.batch, args.patch, device)
                output = student(source)
                optimizer.zero_grad(set_to_none=True)
                stage = 'identity' if step <= args.identity_steps else 'style'
                if stage == 'identity':
                    loss = F.l1_loss(output, source) + .5*F.mse_loss(output, source)
                    loss = loss + .2*sum(F.l1_loss(a, b) for a, b in zip(spatial_gradient(output), spatial_gradient(source)))
                    components = {'identity': loss}
                else:
                    strength = min(1., (step-args.identity_steps)/args.ramp_steps)
                    loss, components = objective(output, source, strength)
                    if step%8 == 0:
                        shifted = F.pad(source, (1,0,0,0), mode='replicate')[..., :source.shape[-1]]
                        shifted_output = student(shifted)
                        temporal = F.l1_loss(shifted_output[:, :, 4:-4, 5:-4], output[:, :, 4:-4, 4:-5])
                        loss = loss + .1*temporal
                        components['translation_proxy'] = temporal
                if not torch.isfinite(loss):
                    raise RuntimeError('nonfinite training objective')
                loss.backward()
                gradient_norm = torch.nn.utils.clip_grad_norm_(student.parameters(), 5., error_if_nonfinite=True)
                optimizer.step()
                lr = args.learning_rate*(.2+.8*.5*(1+math.cos(math.pi*step/args.steps)))
                for group in optimizer.param_groups:
                    group['lr'] = lr
                status.update(state='training', stage=stage, step=step, trained=True, loss=float(loss.detach()),
                              elapsed_seconds=round(time.monotonic()-started, 3),
                              heartbeat_local=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
                if step == 1 or step%25 == 0:
                    record = dict(step=step, stage=stage, loss=status['loss'], lr=lr,
                                  gradient_norm=float(gradient_norm), **{k: float(v.detach()) for k,v in components.items()})
                    history.write(json.dumps(record)+'\n')
                    save_json(root/'status.json', status)
                guard.end()
                if step%args.validation_every == 0 or step == args.steps:
                    # Validation is also duty-limited, one frame at a time.
                    result = validate(student, objective, validation, device, root/'validation_preview.png', guard)
                    result['step'] = step
                    save_json(root/'validation_latest.json', result)
                    checkpoint(root/'checkpoint_latest.pt', student, optimizer, metadata, step)
                    if stage=='style' and step >= args.identity_steps+args.ramp_steps and result['mean']['objective'] < best:
                        best = result['mean']['objective']
                        checkpoint(root/'checkpoint_best.pt', student, optimizer, metadata, step)
                        save_json(root/'validation_best.json', result)
                    history.write(json.dumps(dict(step=step, validation=result['mean'], best_objective=best if math.isfinite(best) else None))+'\n')
            checkpoint(root/'checkpoint_final.pt', student, optimizer, metadata, args.steps)
        status.update(state='complete', elapsed_seconds=round(time.monotonic()-started, 3),
                      best_validation_objective=best if math.isfinite(best) else None,
                      finished_local=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
        save_json(root/'status.json', status)
        print('C36_FLOAT_TRAINING_COMPLETE', json.dumps(status))
    except Exception as exc:
        status.update(state='failed', error=repr(exc), elapsed_seconds=round(time.monotonic()-started, 3))
        save_json(root/'status.json', status)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset', type=Path, required=True)
    parser.add_argument('--style', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--blocks', type=int, default=2)
    parser.add_argument('--expansion', type=int, default=24)
    parser.add_argument('--retained-decoder', action='store_true')
    parser.add_argument('--initial-checkpoint',type=Path)
    parser.add_argument('--style-gain',type=float,default=1.)
    parser.add_argument('--objective',choices=('original','coarse_palette','teacher_distill'),default='original')
    parser.add_argument('--teacher-directory',type=Path)
    parser.add_argument('--steps', type=int, default=3500)
    parser.add_argument('--identity-steps', type=int, default=500)
    parser.add_argument('--ramp-steps', type=int, default=300)
    parser.add_argument('--learning-rate', type=float, default=.001)
    parser.add_argument('--patch', type=int, default=128)
    parser.add_argument('--batch', type=int, default=2)
    parser.add_argument('--seed', type=int, default=20260915)
    parser.add_argument('--validation-every', type=int, default=250)
    parser.add_argument('--device', default='cuda:0')
    parser.add_argument('--duty', type=float, default=.25)
    parser.add_argument('--require-detached', action='store_true')
    args = parser.parse_args()
    run(args)


if __name__ == '__main__':
    main()
