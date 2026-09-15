"""DAG-driven integer oracle and fixtures; expected tensors are checker-only.

Numerical execution follows logical edges, not the compiled mode/slot table.
RAM owner expectations follow physical roots resolved from those edges; an
incorrect slot choice/overwrite must fail instead of supplying golden data.
"""
from pathlib import Path
import json
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'model'))
from r2_execution_plan import FRAME, OP_RESIDUAL_ADD, OP_UPSAMPLE2, OP_OUTPUT_RGB, OP_DWCONV3X3, lower
from r2_plan_package import WEIGHTED, compile_package, profile_nodes, export_new, verify
from microstyle_quant import _integer_conv
from generate_microstyle_engine_bitexact_vectors import _image
from run_r2_graph_probe import p2c8, SLOT


def infer(nodes, bound_arrays, rgb):
    if rgb.dtype != np.uint8 or rgb.ndim != 3 or rgb.shape[2] != 3:
        raise ValueError('golden requires RGB uint8')
    values = {FRAME: (rgb.astype(np.int16)-128).astype(np.int8)}
    for node in nodes:
        s = node.spec
        args = [values[x] for x in node.inputs]
        if args[0].shape != (s.input_height, s.input_width, s.input_channels):
            raise ValueError('golden input edge shape')
        if s.opcode in WEIGHTED:
            value = _integer_conv(args[0], *bound_arrays[s.name], s.stride,
                                  s.input_channels if s.opcode == OP_DWCONV3X3 else 1, s.activation)
        elif s.opcode == OP_RESIDUAL_ADD:
            if args[0].shape != args[1].shape:
                raise ValueError('golden residual shape')
            value = np.clip(args[0].astype(np.int16)+args[1].astype(np.int16), -128, 127)
            if s.activation == 1:
                value = np.maximum(value, 0)
            value = value.astype(np.int8)
        elif s.opcode == OP_UPSAMPLE2:
            value = np.repeat(np.repeat(args[0], 2, axis=0), 2, axis=1)
        elif s.opcode == OP_OUTPUT_RGB:
            value = np.clip(args[0].astype(np.int16)+128, 0, 255).astype(np.uint8)
        else:
            raise ValueError('golden unsupported opcode')
        if value.shape != (s.output_height, s.output_width, s.output_channels):
            raise ValueError('golden output edge shape')
        values[s.name] = value
    return values[nodes[-1].spec.name], {k: v for k, v in values.items() if k != FRAME}


def vectors(directory, width, height, profile='drop_res1', package=None, parameter_override=None):
    directory = Path(directory)
    package = package or compile_package(profile_nodes(profile))
    package_dir = directory/'package'
    export_new(package, package_dir)
    verify(package, package_dir)
    image = (package_dir/'parameters.bin').read_bytes()
    parameter_stages = package.manifest['stages']
    if parameter_override is not None:
        # Negative-only: actual DDR gets a stale parameter image. Neither
        # numerical golden nor the compiled target plan changes.
        image, parameter_stages = parameter_override.image, parameter_override.manifest['stages']
    nodes = profile_nodes(profile, width, height)
    steps = lower(nodes, width, height)
    indexes = {n.spec.name: i for i, n in enumerate(nodes)}
    roots, expected_owners, views = {FRAME: FRAME}, [-99]*(32*6), [1]*32
    for node, step in zip(nodes, steps):
        s = node.spec
        view = s.opcode in (OP_UPSAMPLE2, OP_OUTPUT_RGB)
        views[step.index] = int(view)
        roots[s.name] = roots[node.inputs[0]] if view else s.name
        if not view:
            for name in node.inputs:
                root = roots[name]
                if root == FRAME:
                    slot, owner = 0, -2
                else:
                    producer = steps[indexes[root]]
                    slot, owner = (4 if producer.output_rgb else 1+producer.dst_slot), indexes[root]
                expected_owners[step.index*6+slot] = owner
    # A read using a compiler-selected incorrect source slot will encounter
    # the wrong expected owner or -99. This does not use step.physical_inputs.
    (directory/'owners.mem').write_text(''.join(f'{v & 0xffffffff:08x}\n' for v in expected_owners), encoding='ascii')
    (directory/'views.mem').write_text(''.join(f'{v:x}\n' for v in views), encoding='ascii')
    initial = []
    for stage in parameter_stages:
        for j in range(stage['transfer_beats128']):
            offset = stage['offset']+j*16
            initial.append(((5*SLOT+offset) << 128) | int.from_bytes(image[offset:offset+16], 'little'))
    expected, frames = [], []
    for frame in range(2):
        rgb = _image(width, height)
        if frame:
            rgb = np.bitwise_xor(np.roll(rgb, 1, axis=1), np.uint8(0x5b))
        result, tensors = infer(nodes, package.layers, rgb)
        inputs = p2c8(rgb)
        (directory/f'input{frame}.mem').write_text(''.join(f'{x:032x}\n' for x in inputs), encoding='ascii')
        stage_shapes, scalars, frame_words = [], 0, 0
        for node, step in zip(nodes, steps):
            if node.spec.opcode in (OP_UPSAMPLE2, OP_OUTPUT_RGB):
                continue
            tensor = result if step.output_rgb else tensors[node.spec.name]
            words = p2c8(tensor)
            scalars += int(tensor.size)
            frame_words += len(words)
            slot = 4 if step.output_rgb else 1+step.dst_slot
            stage_shapes.append(dict(stage=step.index, name=node.spec.name, shape=list(tensor.shape), words=len(words)))
            expected += [(step.index << 160) | ((slot*SLOT+j*16) << 128) | word for j, word in enumerate(words)]
        frames.append(dict(frame=frame, output_words=frame_words, scalars=scalars, stages=stage_shapes))
    (directory/'parameters.mem').write_text(''.join(f'{x:040x}\n' for x in initial), encoding='ascii')
    (directory/'expected.mem').write_text(''.join(f'{x:042x}\n' for x in expected), encoding='ascii')
    info = dict(profile=profile, width=width, height=height, stage_count=len(nodes),
                rgb_stage=indexes[nodes[-1].inputs[0]], view_stages=[i for i in range(len(nodes)) if views[i]],
                parameter_words=len(initial), planned_parameter_words=package.manifest['transfer_beats128'],
                input_words=len(inputs), expected_words=len(expected), frames=frames, quality_validated=False)
    (directory/'metadata.json').write_text(json.dumps(info, indent=2)+'\n', encoding='utf-8')
    return info
