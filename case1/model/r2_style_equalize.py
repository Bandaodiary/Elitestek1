"""Positive channel balancing through exclusive Conv/ReLU/nearest chains.

For a positive diagonal S, ReLU(S*z)=S*ReLU(z). Multiply a producer's
output-channel weights AND bias by S and divide its sole weighted consumer's
input-channel weights by S. Nearest-upsample views commute with S. The float
network function is preserved, subject only to floating-point roundoff.

Never cross a residual add, fork, final RGB conversion, non-homogeneous op or
unsupported grouping. This changes offline weights, not the RTL instruction set.
"""
from copy import deepcopy

import numpy as np
import torch
from torch import nn

from r2_execution_plan import OP_UPSAMPLE2
from r2_style_quant import WEIGHTED, convolutions


def exclusive_pairs(nodes):
    lookup = {n.spec.name:n for n in nodes}
    users = {n.spec.name:[] for n in nodes}
    for node in nodes:
        for source in node.inputs:
            if source in users:
                users[source].append(node.spec.name)
    pairs = []
    for producer in nodes:
        name = producer.spec.name
        if producer.spec.opcode not in WEIGHTED or producer.spec.activation not in (0,1):
            continue
        current = name
        views = []
        while len(users[current]) == 1:
            consumer = lookup[users[current][0]]
            if consumer.inputs != (current,):
                break
            if consumer.spec.opcode == OP_UPSAMPLE2:
                views.append(consumer.spec.name)
                current = consumer.spec.name
                continue
            if consumer.spec.opcode in WEIGHTED and consumer.spec.input_channels == producer.spec.output_channels:
                pairs.append((name, consumer.spec.name, tuple(views)))
            break
    return pairs


@torch.no_grad()
def equalize_student(folded, batches, maximum_gain=16.):
    if not 1 <= maximum_gain <= 64:
        raise ValueError('invalid balancing gain limit')
    model = deepcopy(folded).eval()
    convs = convolutions(model)
    if any(not isinstance(layer[1],nn.Identity) for layer in model.layers.values()):
        raise ValueError('normalization must be folded first')
    pairs = exclusive_pairs(model.nodes)
    peaks = {name:torch.zeros(convs[name].out_channels,dtype=torch.float64) for name,_,_ in pairs}
    seen = 0
    for batch in batches:
        _,values = model(batch,True)
        for name in peaks:
            peaks[name] = torch.maximum(peaks[name], values[name].abs().amax((0,2,3)).double().cpu())
        seen += 1
    if not seen:
        raise ValueError('empty balancing calibration')
    report = []
    for producer, consumer, views in pairs:
        first, second = convs[producer], convs[consumer]
        observed = peaks[producer]
        positive = observed > 1e-6
        if not positive.any():
            continue
        # Normalize observed hidden-channel dynamic ranges around a geometric
        # mean; unlike max-only normalization this avoids arbitrarily inflating
        # all values. Inactive channels are left alone.
        target = observed[positive].log().mean().exp()
        factors = torch.ones_like(observed)
        factors[positive] = (target/observed[positive]).clamp(1/maximum_gain,maximum_gain)
        gain = factors.to(device=first.weight.device,dtype=first.weight.dtype)
        first.weight.mul_(gain[:,None,None,None])
        first.bias.mul_(gain)
        if second.groups == 1:
            second.weight.div_(gain[None,:,None,None])
        elif second.groups == second.in_channels == second.out_channels:
            second.weight.div_(gain[:,None,None,None])
        else:
            raise ValueError('unsupported consumer grouping')
        report.append(dict(producer=producer,consumer=consumer,views=list(views),
                           gains=factors.tolist(),observed_channel_peaks=observed.tolist()))
    return model, dict(method='positive exclusive-chain activation-range balancing',
                       calibration_batches=seen,pairs=report,RTL_operators_added=0,
                       claim='float-function preservation needs explicit numerical verification')
