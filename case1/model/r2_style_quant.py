"""Candidate-DAG BN folding, scale tying, exact-grid QAT and R2 arena export.

Independent of the frozen original-model QAT/export implementation. Uses the
existing signed8/INT32/signed18/shift47 contract and existing R2 package compiler.
No trained or quality claim follows merely from successfully exporting arrays.
"""
from copy import deepcopy
from dataclasses import asdict
import json
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

from microstyle_quant import _fold_pair, _integer_conv, _round_ste, _round_shift_away_ste, choose_multiplier_shift
from r2_execution_plan import FRAME, OP_CONV1X1, OP_CONV3X3, OP_DWCONV3X3, OP_RESIDUAL_ADD, OP_UPSAMPLE2, OP_OUTPUT_RGB
from r2_style_candidates import candidate_nodes

WEIGHTED = (OP_CONV1X1, OP_CONV3X3, OP_DWCONV3X3)


def convolutions(model):
    return {name: model.layers[index][0] for name, index in model.weighted_indices.items()}


def fold_student(model):
    folded = deepcopy(model).eval()
    for layer in folded.layers.values():
        if not isinstance(layer[1], nn.BatchNorm2d):
            raise ValueError('student already folded or unsupported normalization')
        _fold_pair(layer[0], layer[1])
        layer[1] = nn.Identity()
    return folded


@torch.no_grad()
def calibrate_student(model, batches, headroom=120):
    if not 1 <= headroom <= 127:
        raise ValueError('headroom must fit positive signed8')
    names = [FRAME] + [n.spec.name for n in model.nodes]
    parent = {name:name for name in names}
    def find(name):
        while parent[name] != name:
            parent[name] = parent[parent[name]]
            name = parent[name]
        return name
    for node in model.nodes:
        if node.spec.opcode in (OP_UPSAMPLE2, OP_RESIDUAL_ADD, OP_OUTPUT_RGB):
            for source in node.inputs:
                parent[find(source)] = find(node.spec.name)
    peaks = {name:0. for name in names}
    observed = 0
    model.eval()
    for batch in batches:
        _, values = model(batch, return_stages=True)
        for name, value in values.items():
            if name == model.nodes[-1].spec.name:
                continue  # Unsigned RGB display tensor is not an internal signed activation.
            peak = float(value.abs().max())
            if not np.isfinite(peak):
                raise ValueError('nonfinite calibration activation')
            peaks[name] = max(peaks[name], peak)
        observed += 1
    if not observed:
        raise ValueError('empty calibration stream')
    group_peaks = {}
    for name, peak in peaks.items():
        root = find(name)
        group_peaks[root] = max(group_peaks.get(root, 0.), peak)
    scales = {name:max(group_peaks[find(name)]/headroom, 1/32768) for name in names}
    fixed = {find(FRAME), find(model.nodes[-1].spec.name)}
    for name in names:
        if find(name) in fixed:
            scales[name] = 1/128
    return scales


def quant_parameters(model, scales, weight_scales=None):
    convs = convolutions(model)
    parameters = {}
    for node in model.nodes:
        spec = node.spec
        if spec.opcode not in WEIGHTED:
            if any(scales[source] != scales[spec.name] for source in node.inputs):
                raise ValueError('nonweighted edge requires equal activation scales')
            continue
        conv = convs[spec.name]
        if not isinstance(model.layers[model.weighted_indices[spec.name]][1], nn.Identity):
            raise ValueError('BN must be folded before quantization')
        if weight_scales is None:
            weights = conv.weight.detach().cpu().numpy().astype(np.float64)
            channel_scales = np.maximum(np.abs(weights).reshape(spec.output_channels, -1).max(1)/127, 2**-24)
        else:
            channel_scales = np.asarray(weight_scales[spec.name], dtype=np.float64)
        if channel_scales.shape != (spec.output_channels,) or not np.isfinite(channel_scales).all() or (channel_scales <= 0).any():
            raise ValueError('invalid per-channel weight scales')
        source_scale, destination_scale = scales[node.inputs[0]], scales[spec.name]
        affine = [choose_multiplier_shift(source_scale*float(scale)/destination_scale) for scale in channel_scales]
        parameters[spec.name] = dict(input_scale=source_scale, output_scale=destination_scale,
                                     weight_scales=channel_scales, multipliers=np.asarray([a[0] for a in affine], dtype=np.int32),
                                     shifts=np.asarray([a[1] for a in affine], dtype=np.uint8))
    if scales[FRAME] != 1/128 or scales[model.nodes[-1].spec.name] != 1/128:
        raise ValueError('input/output signed-to-RGB grid changed')
    return parameters


class QATStudent(nn.Module):
    def __init__(self, folded, scales, weight_scales=None):
        super().__init__()
        self.model = folded
        self.config = folded.config
        self.activation_scales = dict(scales)
        self.quant_parameters = quant_parameters(folded, scales, weight_scales)

    def quantized_arrays(self, name):
        conv = convolutions(self.model)[name]
        row = self.quant_parameters[name]
        scales = row['weight_scales']
        round_away = lambda x: np.sign(x)*np.floor(np.abs(x)+.5)
        weight = conv.weight.detach().cpu().numpy().astype(np.float64)
        qweight = np.clip(round_away(weight/scales[:,None,None,None]), -127, 127).astype(np.int8)
        bias = conv.bias.detach().cpu().numpy().astype(np.float64)
        qbias = round_away(bias/(scales*row['input_scale']))
        if not np.isfinite(qbias).all() or (np.abs(qbias) + 128*np.abs(qweight.astype(np.int64)).reshape(len(qbias), -1).sum(1) >= 2**31).any():
            raise OverflowError('bias or worst-case convolution accumulator exceeds signed32')
        return qweight, qbias.astype(np.int32), row['multipliers'].copy(), row['shifts'].copy()

    def _conv(self, name, value):
        conv = convolutions(self.model)[name]
        row = self.quant_parameters[name]
        # Double precision BEFORE division and multiplier multiplication avoids
        # float32 moving a requantization midpoint. The convolution itself uses
        # exact float32 integer arithmetic only under a proven absolute bound.
        scales = torch.as_tensor(row['weight_scales'], dtype=torch.float64, device=value.device)
        weights = _round_ste(conv.weight.double()/scales[:,None,None,None]).clamp(-127,127)
        bias = _round_ste(conv.bias.double()/(scales*row['input_scale']))
        bound = bias.abs()+128*weights.abs().flatten(1).sum(1)
        if bool(torch.any(bound >= 2**31)):
            raise OverflowError('QAT signed32 accumulator bound exceeded')
        dtype = torch.float64 if bool(torch.any(bound >= 2**24)) else torch.float32
        padding = conv.padding[0]
        padded = F.pad(value, (padding,)*4, mode='replicate') if padding else value
        accumulator = F.conv2d(padded.to(dtype), weights.to(dtype), bias.to(dtype),
                               stride=conv.stride, groups=conv.groups)
        multipliers = torch.as_tensor(row['multipliers'], dtype=torch.float64, device=value.device)[None,:,None,None]
        shifts = torch.as_tensor(row['shifts'], device=value.device)
        return _round_shift_away_ste(accumulator.double()*multipliers, shifts).clamp(-128,127)

    def forward(self, rgb01, return_stages=False):
        h,w = rgb01.shape[-2:]
        if rgb01.ndim != 4 or rgb01.shape[1] != 3 or min(h,w)<4 or h>480 or w>640 or h%4 or w%4:
            raise ValueError('unsupported RGB geometry')
        scaled = rgb01.clamp(0,1)*255
        values = {FRAME: scaled+(torch.round(scaled)-scaled).detach()-128}
        for node in self.model.nodes:
            spec = node.spec
            sources = [values[name] for name in node.inputs]
            if spec.opcode in WEIGHTED:
                result = self._conv(spec.name, sources[0])
            elif spec.opcode == OP_UPSAMPLE2:
                result = F.interpolate(sources[0], scale_factor=2, mode='nearest')
            elif spec.opcode == OP_RESIDUAL_ADD:
                result = (sources[0]+sources[1]).clamp(-128,127)
            elif spec.opcode == OP_OUTPUT_RGB:
                result = (sources[0]+128).clamp(0,255)/255
            else:
                raise ValueError('unsupported opcode')
            if spec.activation == 1:
                result = F.relu(result)
            values[spec.name] = result
        result = values[self.model.nodes[-1].spec.name]
        return (result, values) if return_stages else result


def export_student(qat, directory: Path, metadata):
    directory = directory.resolve()
    if directory.exists():
        raise FileExistsError('new artifact directory required')
    arena = bytearray()
    rows = []
    for node in qat.model.nodes:
        spec = node.spec
        if spec.opcode not in WEIGHTED:
            continue
        arrays = qat.quantized_arrays(spec.name)
        parameter = qat.quant_parameters[spec.name]
        conv = convolutions(qat.model)[spec.name]
        row = dict(name=spec.name, opcode=spec.opcode, activation=spec.activation, stride=spec.stride,
                   groups=conv.groups, weight_shape=list(arrays[0].shape),
                   input_scale=float(parameter['input_scale']), output_scale=float(parameter['output_scale']),
                   weight_scales=parameter['weight_scales'].tolist())
        for kind, array, dtype in zip(('weight','bias','multiplier','shift'), arrays, ('i1','<i4','<i4','u1')):
            arena.extend(bytes((-len(arena))%16))
            payload = np.asarray(array, dtype=dtype).tobytes()
            row[kind+'_offset'], row[kind+'_bytes'] = len(arena), len(payload)
            arena.extend(payload)
        rows.append(row)
    manifest = dict(schema_version=1, artifact_role='c36_candidate_pending_quality_and_RTL',
                    trained=bool(metadata.get('trained', False)), quality_validated=False,
                    topology_retraining_performed=bool(metadata.get('trained', False)),
                    parameter_file='parameter_arena.bin', parameter_arena_bytes=len(arena),
                    quantized_layers=rows, model_config=qat.config,
                    nodes=[dict(spec=asdict(n.spec), inputs=list(n.inputs)) for n in qat.model.nodes],
                    activation_scales=qat.activation_scales, training=metadata,
                    arithmetic='s8 weights/activations; s32 accumulator; signed18 multiplier; shift0..47; ties away from zero')
    directory.mkdir(parents=True)
    (directory/'parameter_arena.bin').write_bytes(arena)
    (directory/'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding='utf-8')
    return manifest


def integer_student(rgb_u8, nodes, arrays, collect=False):
    if rgb_u8.dtype != np.uint8 or rgb_u8.ndim != 3 or rgb_u8.shape[2] != 3:
        raise ValueError('HWC uint8 RGB required')
    values = {FRAME: (rgb_u8.astype(np.int16)-128).astype(np.int8)}
    for node in nodes:
        spec = node.spec
        sources = [values[k] for k in node.inputs]
        if spec.opcode in WEIGHTED:
            groups = spec.input_channels if spec.opcode == OP_DWCONV3X3 else 1
            result = _integer_conv(sources[0], *arrays[spec.name], spec.stride, groups, spec.activation)
        elif spec.opcode == OP_UPSAMPLE2:
            result = sources[0].repeat(2,0).repeat(2,1)
        elif spec.opcode == OP_RESIDUAL_ADD:
            result = np.clip(sources[0].astype(np.int16)+sources[1].astype(np.int16), -128,127)
            if spec.activation == 1:
                result = np.maximum(result,0)
            result = result.astype(np.int8)
        elif spec.opcode == OP_OUTPUT_RGB:
            result = (sources[0].astype(np.int16)+128).astype(np.uint8)
        else:
            raise ValueError('unsupported integer opcode')
        values[spec.name] = result
    output = values[nodes[-1].spec.name]
    return (output,values) if collect else output
