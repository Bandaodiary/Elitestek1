"""Training-only teacher compatible with PyTorch's fast_neural_style example.

Adapted from pytorch/examples/fast_neural_style/neural_style/transformer_net.py.
Copyright (c) 2017, Pytorch contributors. BSD 3-Clause; complete notice retained
in assets/teachers/c36_pytorch_mosaic_20260915b/UPSTREAM_LICENSE.txt.

Its 9x9 convolutions, 128-channel trunk and dynamic InstanceNorm are NOT sent
to the FPGA compiler. Only a separately trained, existing-op student can deploy.
"""
import json
from pathlib import Path
import re

import torch
from torch import nn
from torch.nn import functional as F


class TeacherConv(nn.Module):
    def __init__(self, incoming, outgoing, kernel, stride=1, upsample=None):
        super().__init__()
        self.upsample = upsample
        self.reflection_pad = nn.ReflectionPad2d(kernel//2)
        self.conv2d = nn.Conv2d(incoming,outgoing,kernel,stride)

    def forward(self, value):
        if self.upsample:
            value = F.interpolate(value,scale_factor=self.upsample,mode='nearest')
        return self.conv2d(self.reflection_pad(value))


class TeacherResidual(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = TeacherConv(128,128,3)
        self.in1 = nn.InstanceNorm2d(128,affine=True)
        self.conv2 = TeacherConv(128,128,3)
        self.in2 = nn.InstanceNorm2d(128,affine=True)

    def forward(self, value):
        return value+self.in2(self.conv2(F.relu(self.in1(self.conv1(value)))))


class TeacherNetwork(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1,self.conv2,self.conv3 = TeacherConv(3,32,9),TeacherConv(32,64,3,2),TeacherConv(64,128,3,2)
        self.in1,self.in2,self.in3 = (nn.InstanceNorm2d(n,affine=True) for n in (32,64,128))
        for i in range(1,6):
            self.add_module('res'+str(i),TeacherResidual())
        self.deconv1,self.deconv2 = TeacherConv(128,64,3,upsample=2),TeacherConv(64,32,3,upsample=2)
        self.in4,self.in5 = nn.InstanceNorm2d(64,affine=True),nn.InstanceNorm2d(32,affine=True)
        self.deconv3 = TeacherConv(32,3,9)

    def forward(self, value):
        for i in range(1,4):
            value = F.relu(getattr(self,'in'+str(i))(getattr(self,'conv'+str(i))(value)))
        for i in range(1,6):
            value = getattr(self,'res'+str(i))(value)
        value = F.relu(self.in4(self.deconv1(value)))
        value = F.relu(self.in5(self.deconv2(value)))
        return self.deconv3(value)


def teacher_state(directory):
    root = Path(directory)
    manifest = json.loads((root/'manifest.json').read_text(encoding='utf-8'))
    if manifest['state']!='complete' or not manifest['checkpoint_loaded_weights_only']:
        raise ValueError('official teacher download incomplete')
    state = torch.load(root/manifest['checkpoint_file'],map_location='cpu',weights_only=True)
    # Same deprecated InstanceNorm-buffer removal as the upstream evaluator.
    state = {k:v for k,v in state.items() if not re.search(r'in\d+\.running_(mean|var)$',k)}
    return state


def load_teacher(directory):
    model = TeacherNetwork().eval()
    model.load_state_dict(teacher_state(directory),strict=True)
    model.requires_grad_(False)
    return model


@torch.no_grad()
def teacher_rgb(model, rgb):
    if rgb.ndim!=4 or rgb.shape[1]!=3 or min(rgb.shape[-2:])<16 or any(d%4 for d in rgb.shape[-2:]):
        raise ValueError('teacher RGB geometry must be NCHW with multiples of four')
    # Bilinear antialias weights may sum to 1 +/- a few float32 ULPs even
    # for an all-white input. Admit only this numerical envelope, then clamp;
    # do not silently accept genuinely unnormalized images or non-finite data.
    if rgb.dtype not in (torch.float32,torch.float64) or not torch.isfinite(rgb).all() or rgb.min() < -1e-6 or rgb.max() > 1+1e-6:
        raise ValueError('teacher RGB input must be in [0,1]')
    return model(rgb.clamp(0,1)*255).clamp(0,255)/255
