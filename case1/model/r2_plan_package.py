"""Compile a supported tensor DAG and bound INT8 parameters as one package.

This is a static RTL plan, not writable microcode or a training/exporter for
arbitrary frameworks. Derived topology is a functional test, NOT a newly
trained quality model. Existing R1/C8/C16 files are never overwritten.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
import math
from pathlib import Path
import struct
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from r2_execution_plan import (
    FRAME, Node, OP_CONV1X1, OP_CONV3X3, OP_DWCONV3X3,
    OP_RESIDUAL_ADD, OP_UPSAMPLE2, OP_OUTPUT_RGB, lower, microstyle_nodes, render_sv, require,
)
from microstyle_layout import LayerSpec
from microstyle_quant import _read_layer_arrays

ROOT = Path(__file__).resolve().parents[1]
WEIGHTED = (OP_CONV1X1, OP_CONV3X3, OP_DWCONV3X3)
PROFILE_NAMES = ('microstyle24', 'drop_res1')
DEFAULT_ARTIFACT = ROOT/'model/microstyle24_starry_functional'


def profile_nodes(profile, width=640, height=480):
    require(profile in PROFILE_NAMES, 'unknown profile')
    nodes = microstyle_nodes(width, height)
    if profile == 'drop_res1':
        nodes = [Node(n.spec, tuple('res0.add_relu' if x == 'res1.add_relu' else x for x in n.inputs))
                 for n in nodes if not n.spec.name.startswith('res1.')]
    return nodes


@dataclass
class Package:
    image: bytes
    plan_sv: str
    manifest: dict
    layers: dict  # bound source arrays; used by independent numerical golden


def equal_scale(a, b):
    # This backend has no general edge requantizer. Require equal exported
    # real scales; no loose tolerance that could conceal an unsupported edge.
    return math.isfinite(a) and a > 0 and a == b


def compile_package(nodes, artifact=DEFAULT_ARTIFACT, bindings=None):
    steps = lower(nodes)
    plan_sv = render_sv(steps)  # validates maximum geometry envelope
    artifact = Path(artifact)
    source = json.loads((artifact/'manifest.json').read_text(encoding='utf-8-sig'))
    arena_name = source['parameter_file']
    require(isinstance(arena_name, str) and Path(arena_name).name == arena_name and ':' not in arena_name,
            'parameter file must be local to artifact')
    arena = (artifact/arena_name).read_bytes()
    require(len(arena) == source['parameter_arena_bytes'], 'source arena size mismatch')
    source_rows = source['quantized_layers']
    lookup = {r['name']: r for r in source_rows}
    require(len(lookup) == len(source_rows), 'duplicate quantized layer')
    weighted_names = {n.spec.name for n in nodes if n.spec.opcode in WEIGHTED}
    bindings = dict(bindings) if bindings is not None else {name: name for name in weighted_names}
    require(set(bindings) == weighted_names and all(v in lookup for v in bindings.values()),
            'missing/extra/unknown parameter binding')
    scales, layers, commands_meta = {FRAME: 1/128}, {}, []
    image = bytearray(len(steps)*8192)
    for node, step in zip(nodes, steps):
        s, name = node.spec, node.spec.name
        if s.opcode not in WEIGHTED:
            values = [scales[x] for x in node.inputs]
            require(all(equal_scale(v, values[0]) for v in values), 'unmatched residual quantization scales')
            if s.opcode == OP_OUTPUT_RGB:
                require(equal_scale(values[0], 1/128), 'RGB conversion requires signed scale 1/128')
            scales[name] = values[0]
            continue
        row = lookup[bindings[name]]
        groups = s.input_channels if s.opcode == OP_DWCONV3X3 else 1
        shape = (s.output_channels, 1 if groups != 1 else s.input_channels, s.kernel, s.kernel)
        require(tuple(row['weight_shape']) == shape, 'bound weight shape mismatch')
        require((row['stride'], row['groups'], row['activation']) == (s.stride, groups, s.activation),
                'bound stride/groups/activation mismatch')
        in_scale, out_scale = float(row['input_scale']), float(row['output_scale'])
        require(equal_scale(in_scale, scales[node.inputs[0]]) and equal_scale(out_scale, out_scale),
                'bound input/output quantization scale mismatch')
        for key, size in (('weight', s.weight_count), ('bias', s.output_channels*4),
                          ('multiplier', s.output_channels*4), ('shift', s.output_channels)):
            offset = row[key+'_offset']
            require(type(offset) is int and offset >= 0 and offset+size <= len(arena), 'array outside source arena')
        weight, bias, mult, shift = _read_layer_arrays(arena, row)
        require(np.all(mult >= -(1 << 17)) and np.all(mult < (1 << 17)) and np.all(shift <= 47),
                'affine outside hardware range')
        scales[name] = out_scale
        layers[name] = (weight, bias, mult, shift)
        commands = []
        def emit(kind, address, value):
            require(1 <= kind <= 3 and 0 <= address < 16384, 'invalid parameter SRAM command')
            commands.append((kind << 46) | (address << 32) | (int(value) & 0xffffffff))
        for co in range(s.output_channels):
            terms = [int(weight[co, ci, ky, kx]) for ky in range(s.kernel) for kx in range(s.kernel)
                     for ci in range(shape[1])]
            chunks = (len(terms)+15)//16
            require(chunks <= 8 and co < 48, 'parameter store capacity')
            terms += [117]*(chunks*16-len(terms))
            for beat in range(chunks):
                for word in range(4):
                    address = (co & 7)*256+(co//8)*32+beat*4+word
                    value = sum((terms[beat*16+word*4+i] & 255) << (i*8) for i in range(4))
                    emit(1, address, value)
            emit(2, co, bias[co])
            emit(3, co, (s.activation << 24) | (int(shift[co]) << 18) | (int(mult[co]) & 0x3ffff))
        require(len(commands) == step.parameter_beats*2 and len(commands)*8 <= 8192,
                'parameter image and execution plan disagree')
        offset = step.parameter_block*8192
        for i, command in enumerate(commands):
            struct.pack_into('<Q', image, offset+i*8, command)
        commands_meta.append(dict(stage=step.index, name=name, source_layer=bindings[name], offset=offset,
                                  commands=len(commands), transfer_beats128=step.parameter_beats))
    manifest = dict(format='c1_r2_bound_plan_package_v1', frame_envelope=[640, 480],
                    source_artifact=artifact.name, source_parameter_file=arena_name,
                    source_artifact_role=source.get('artifact_role', 'unspecified'),
                    quality_validated=False, topology_retraining_performed=False, runtime_microcode=False,
                    stage_slot_bytes=8192, image_bytes=len(image),
                    active_bytes=sum(s.parameter_beats for s in steps)*16,
                    transfer_beats128=sum(s.parameter_beats for s in steps),
                    nodes=[dict(spec=asdict(n.spec), inputs=list(n.inputs)) for n in nodes],
                    bindings=dict(sorted(bindings.items())), tensor_scales=scales,
                    steps=[asdict(s) for s in steps], stages=commands_meta)
    return Package(bytes(image), plan_sv, manifest, layers)


def files(package):
    return {'parameters.bin': package.image, 'execution_plan.sv': package.plan_sv.encode('utf-8'),
            'manifest.json': (json.dumps(package.manifest, indent=2)+'\n').encode('utf-8')}


def export_new(package, directory):
    """Generated artifacts only: fail instead of replacing any existing path."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=False)
    for name, payload in files(package).items():
        with (directory/name).open('xb') as stream:
            stream.write(payload)


def verify(package, directory):
    for name, payload in files(package).items():
        require((Path(directory)/name).read_bytes() == payload, 'stale/mismatched package file: '+name)


def nodes_from_manifest(manifest):
    return [Node(LayerSpec(**r['spec']), tuple(r['inputs'])) for r in manifest['nodes']]


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--profile', choices=PROFILE_NAMES, default='microstyle24')
    p.add_argument('--artifact', type=Path, default=DEFAULT_ARTIFACT)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--verify', action='store_true')
    a = p.parse_args()
    package = compile_package(profile_nodes(a.profile), a.artifact)
    if not a.verify:
        export_new(package, a.output)
    verify(package, a.output)
    m = package.manifest
    print('C1_R2_PLAN_PACKAGE_PASS '+json.dumps(dict(profile=a.profile, steps=len(m['steps']),
          image_bytes=m['image_bytes'], active_bytes=m['active_bytes'], parameter_words=m['transfer_beats128'],
          bound_layers=len(m['bindings']), quality_validated=False, source_modified=False)))


if __name__ == '__main__':
    main()
