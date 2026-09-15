"""Small, frozen training-only perceptual features; never compiled into RTL.

SqueezeNet 1.1 layer dimensions and checkpoint names follow torchvision's
official model (https://github.com/pytorch/vision/blob/main/torchvision/models/squeezenet.py).
This independently expressed feature stack excludes the classifier. The loss
is an experimental lightweight alternative to VGG, not a reproduction of
Johnson et al.'s exact perceptual loss or a proven equivalent quality metric.
"""
from pathlib import Path

import torch
from torch import nn
from torch.nn import functional as F


class Fire(nn.Module):
    def __init__(self, incoming, squeeze, branch):
        super().__init__()
        self.squeeze = nn.Conv2d(incoming, squeeze, 1)
        self.expand1x1 = nn.Conv2d(squeeze, branch, 1)
        self.expand3x3 = nn.Conv2d(squeeze, branch, 3, padding=1)

    def forward(self, value):
        compressed = F.relu(self.squeeze(value))
        return torch.cat((F.relu(self.expand1x1(compressed)),
                          F.relu(self.expand3x3(compressed))), dim=1)


class PerceptualFeatures(nn.Module):
    taps = (1, 4, 7, 10)

    def __init__(self, weights: Path):
        super().__init__()
        pool = lambda: nn.MaxPool2d(3, stride=2, ceil_mode=True)
        self.features = nn.Sequential(
            nn.Conv2d(3, 64, 3, stride=2), nn.ReLU(), pool(),
            Fire(64, 16, 64), Fire(128, 16, 64), pool(),
            Fire(128, 32, 128), Fire(256, 32, 128), pool(),
            Fire(256, 48, 192), Fire(384, 48, 192),
            Fire(384, 64, 256), Fire(512, 64, 256))
        state = torch.load(weights, map_location='cpu', weights_only=True)
        feature_state = {k.removeprefix('features.'): v for k, v in state.items()
                         if k.startswith('features.')}
        if set(state) - {f'features.{k}' for k in feature_state} != {'classifier.1.weight', 'classifier.1.bias'}:
            raise ValueError('not the expected official SqueezeNet 1.1 state dictionary')
        self.features.load_state_dict(feature_state, strict=True)
        self.register_buffer('mean', torch.tensor([.485, .456, .406]).view(1, 3, 1, 1))
        self.register_buffer('std', torch.tensor([.229, .224, .225]).view(1, 3, 1, 1))
        self.requires_grad_(False)
        self.eval()

    def forward(self, rgb):
        value = (rgb - self.mean) / self.std
        result = []
        for index, layer in enumerate(self.features):
            value = layer(value)
            if index in self.taps:
                result.append(value)
            if index == self.taps[-1]:
                break
        return result


def gram(value):
    flat = value.flatten(2)
    return flat.bmm(flat.transpose(1, 2)) / flat.shape[-1]


def luma(value):
    return (value * value.new_tensor([.299, .587, .114])[None, :, None, None]).sum(1, keepdim=True)


def spatial_gradient(value):
    return value[..., 1:] - value[..., :-1], value[..., 1:, :] - value[..., :-1, :]


def ssim_luma(left, right):
    # Local population moments, 11x11 box window, data range 1. This is not
    # silently reported as the Gaussian-window SSIM used by another package.
    left, right = luma(left), luma(right)
    mean = lambda x: F.avg_pool2d(x, 11, stride=1)
    a, b = mean(left), mean(right)
    va = (mean(left.square()) - a.square()).clamp_min(0)
    vb = (mean(right.square()) - b.square()).clamp_min(0)
    covariance = mean(left*right) - a*b
    score = ((2*a*b+.01**2)*(2*covariance+.03**2) /
             ((a.square()+b.square()+.01**2)*(va+vb+.03**2)))
    return score.mean()


class StyleObjective(nn.Module):
    def __init__(self, features: PerceptualFeatures, style, style_gain=1.):
        super().__init__()
        if not 0 < style_gain <= 8:
            raise ValueError('style_gain must be in (0,8]')
        self.style_gain = float(style_gain)
        self.features = features
        with torch.no_grad():
            for index, value in enumerate(features(style)):
                self.register_buffer(f'style_gram_{index}', gram(value).mean(0, keepdim=True))
            self.register_buffer('style_mean', style.mean((2, 3), keepdim=True))
            self.register_buffer('style_std', style.std((2, 3), keepdim=True, unbiased=False))

    def forward(self, output, content, strength=1.):
        predicted_features = self.features(output)
        with torch.no_grad():
            content_features = self.features(content)
        feature_content = sum(F.mse_loss(predicted_features[i], content_features[i]) /
                              content_features[i].square().mean().clamp_min(.01)
                              for i in (1, 2)) / 2
        feature_style = output.new_zeros(())
        for index, value in enumerate(predicted_features):
            target = getattr(self, f'style_gram_{index}')
            feature_style = feature_style + (gram(value)-target).square().mean() / target.square().mean().clamp_min(.01)
        feature_style = feature_style / len(predicted_features)
        gray_out, gray_in = luma(output), luma(content)
        out_edges, in_edges = spatial_gradient(gray_out), spatial_gradient(gray_in)
        edge = sum(F.l1_loss(a, b) for a, b in zip(out_edges, in_edges))
        low = F.l1_loss(F.avg_pool2d(gray_out, 8), F.avg_pool2d(gray_in, 8))
        color = (F.l1_loss(output.mean((2, 3), keepdim=True), self.style_mean.expand(output.shape[0], -1, -1, -1)) +
                 F.l1_loss(output.std((2, 3), keepdim=True, unbiased=False), self.style_std.expand(output.shape[0], -1, -1, -1)))
        tv = sum(v.abs().mean() for v in spatial_gradient(output))
        # No brightness-sorted palette teacher. Retain structure while matching
        # learned multi-scale feature statistics from the actual style image.
        total = (2*feature_content + strength*self.style_gain*feature_style + .4*edge + .6*low +
                 .25*strength*self.style_gain*color + .02*tv)
        return total, dict(content=feature_content, style=feature_style, edge=edge,
                          low_luma=low, color=color, tv=tv)
