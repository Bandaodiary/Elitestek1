"""Reproduce a trained R2 CNN from its exported INT8 arena, without checkpoints.

Only artifact/manifest.json and its local parameter file are read for the
model. No teacher, training dataset, .pt loading, network or FPGA tool is used.
The existing Python modules still require installed PyTorch, NumPy and Pillow.
This is an offline integer golden, not a software/RTL/board FPS benchmark.
"""
import argparse
import json
import os
from pathlib import Path
import time

import numpy as np
from PIL import Image, ImageOps
import psutil
import torch

from prepare_r2_style_data import save_json
from r2_plan_package import compile_package
from r2_style_candidates import candidate_nodes
from r2_style_quant import integer_student


def geometry(width, height):
    if (type(width) is not int or type(height) is not int or
            not 4 <= width <= 640 or not 4 <= height <= 480 or width % 4 or height % 4):
        raise ValueError('input must be 4..640 x 4..480, with both dimensions divisible by four; use --fit explicitly')


def input_pixels(path, fit=None):
    if fit is not None:
        geometry(*fit)
    with Image.open(path) as source:
        if source.width*source.height > 32_000_000:
            raise ValueError('input exceeds the 32-megapixel offline import limit')
        rgb = ImageOps.exif_transpose(source).convert('RGB')
        original_size = list(rgb.size)
        if fit is not None:
            rgb = ImageOps.fit(rgb, tuple(fit), Image.Resampling.LANCZOS)
        geometry(*rgb.size)
        pixels = np.asarray(rgb, dtype=np.uint8).copy()
    return pixels, dict(original_oriented_size=original_size, input_size=[pixels.shape[1], pixels.shape[0]],
        preprocessing='Pillow center-fit/Lanczos; not RTL ISP golden' if fit else 'EXIF orientation / RGB; no resize')


def infer_artifact(artifact, pixels):
    if pixels.dtype != np.uint8 or pixels.ndim != 3 or pixels.shape[2] != 3:
        raise ValueError('HWC uint8 RGB input required')
    height, width = pixels.shape[:2]
    geometry(width, height)
    artifact = Path(artifact).resolve()
    manifest = json.loads((artifact/'manifest.json').read_text(encoding='utf-8-sig'))
    if manifest.get('trained') is not True or not isinstance(manifest.get('model_config'), dict):
        raise ValueError('a trained exported R2 candidate artifact is required')
    nodes = candidate_nodes(**manifest['model_config'], width=width, height=height)
    # Compiler checks layer shape, stride, activation, residual scales, affine
    # bounds, array offsets and local arena path. It never opens a checkpoint.
    # The deployable package compiler validates the fixed 640x480 RTL graph.
    # Smaller offline images reuse those same convolution arrays, exactly as
    # the QAT export probe does; they are not alternate hardware plans.
    package = compile_package(candidate_nodes(**manifest['model_config']), artifact=artifact)
    output = integer_student(pixels, nodes, package.layers)
    if output.dtype != np.uint8 or output.shape != pixels.shape:
        raise AssertionError('integer golden returned invalid RGB geometry')
    return output, dict(model_config=manifest['model_config'],
        graph_items=len(nodes), parameter_arena_bytes=manifest['parameter_arena_bytes'],
        parameter_file=manifest['parameter_file'], artifact_role=manifest.get('artifact_role'),
        artifact_only=True, checkpoint_loaded=False, teacher_loaded=False,
        RTL_simulated=False, FPS_measured=False)


def run(args):
    case = Path(__file__).resolve().parents[1]
    root = args.output_dir.resolve()
    if root.exists() or not root.is_relative_to(case/'outputs'):
        raise ValueError('a new case1/outputs subdirectory is required; existing outputs are never overwritten')
    pixels, preprocessing = input_pixels(args.input, args.fit)
    started = time.monotonic()
    output, model_info = infer_artifact(args.artifact, pixels)
    root.mkdir(parents=True)
    Image.fromarray(pixels).save(root/'input.png')
    Image.fromarray(output).save(root/'stylized.png')
    report = dict(state='complete', artifact=str(args.artifact.resolve()), input_file=str(args.input.resolve()),
        output_file=str(root/'stylized.png'), **preprocessing, **model_info,
        elapsed_wall_seconds=time.monotonic()-started,
        elapsed_scope='offline NumPy integer golden plus image output; not FPGA throughput')
    save_json(root/'inference.json', report)
    print('C36_ARTIFACT_INFERENCE_COMPLETE '+json.dumps(report, separators=(',', ':')))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--fit', nargs=2, type=int, metavar=('WIDTH', 'HEIGHT'))
    args = parser.parse_args()
    process = psutil.Process()
    process.cpu_affinity(process.cpu_affinity()[-1:])
    if os.name == 'nt':
        process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
    if psutil.virtual_memory().available < 8*2**30:
        raise RuntimeError('less than 8 GiB free before full-frame integer inference')
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    run(args)


if __name__ == '__main__':
    main()
