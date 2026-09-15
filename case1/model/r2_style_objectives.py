"""Experimental training-only objectives; no new deployed layer or operation.

The coarse-palette variant is a hypothesis addressing the visible high-frequency
ripples in the stronger-Gram trial. It is not a proven better art metric. All
candidate comparisons must also use the unchanged original objective and images.
"""
import torch
from torch import nn
from torch.nn import functional as F

from r2_style_perceptual import StyleObjective, gram, luma, spatial_gradient


def coarse_rgb(rgb):
    # Low-pass BEFORE decimation. Neither this filter nor the feature extractor
    # is in the inference graph; the student still emits the full RGB frame.
    smooth = F.avg_pool2d(rgb, 3, stride=1, padding=1, count_include_pad=False)
    return F.avg_pool2d(smooth, 2)


def color_covariance(rgb):
    flat = rgb.flatten(2)
    centered = flat - flat.mean(-1, keepdim=True)
    return centered.bmm(centered.transpose(1, 2)) / flat.shape[-1]


class CoarsePaletteObjective(nn.Module):
    def __init__(self, features, style, style_gain=1.):
        super().__init__()
        if not 0 < style_gain <= 8 or min(style.shape[-2:]) < 64:
            raise ValueError('invalid coarse palette objective configuration')
        self.features = features
        self.style_gain = float(style_gain)
        with torch.no_grad():
            for i, value in enumerate(features(coarse_rgb(style))):
                self.register_buffer(f'style_gram_{i}', gram(value).mean(0, keepdim=True))
            self.register_buffer('style_mean', style.mean((2, 3)))
            self.register_buffer('style_std', style.std((2, 3), unbiased=False).clamp_min(.05))
            self.register_buffer('style_cov', color_covariance(style))

    def forward(self, output, content, strength=1.):
        if min(output.shape[-2:]) < 64:
            raise ValueError('coarse perceptual training/evaluation needs at least 64 pixels per side')
        # Retain luminance structure without forcing the original photograph's
        # chroma through the content features. Style still sees true RGB.
        gray_out, gray_in = luma(output), luma(content)
        out_features = self.features(gray_out.expand(-1, 3, -1, -1))
        with torch.no_grad():
            in_features = self.features(gray_in.expand(-1, 3, -1, -1))
        feature_content = sum(F.mse_loss(out_features[i], in_features[i]) /
                              in_features[i].square().mean().clamp_min(.01)
                              for i in (1, 2)) / 2
        color_features = self.features(coarse_rgb(output))
        feature_style = output.new_zeros(())
        for i, value in enumerate(color_features):
            target = getattr(self, f'style_gram_{i}')
            feature_style = feature_style + (gram(value) - target).square().mean() / target.square().mean().clamp_min(.01)
        feature_style = feature_style / len(color_features)
        mean_error = ((output.mean((2, 3)) - self.style_mean) / self.style_std).abs().mean()
        cov_scale = self.style_std.unsqueeze(2) * self.style_std.unsqueeze(1)
        cov_error = ((color_covariance(output) - self.style_cov) / cov_scale).square().mean()
        color = mean_error + .25 * cov_error
        edge = sum(F.l1_loss(a, b) for a, b in zip(spatial_gradient(gray_out), spatial_gradient(gray_in)))
        low = F.l1_loss(F.avg_pool2d(gray_out, 8), F.avg_pool2d(gray_in, 8))
        tv = sum(v.abs().mean() for v in spatial_gradient(output))
        smooth = F.avg_pool2d(output, 3, stride=1, padding=1, count_include_pad=False)
        high_frequency = F.l1_loss(output, smooth)
        total = (2 * feature_content + strength * self.style_gain * feature_style + .3 * edge + .6 * low +
                 .3 * strength * color + .4 * tv + .4 * high_frequency)
        return total, dict(content=feature_content, style=feature_style, edge=edge, low_luma=low,
                           color=color, tv=tv, high_frequency=high_frequency)


def make_objective(name, features, style, style_gain=1., teacher_directory=None):
    if name == 'original':
        return StyleObjective(features, style, style_gain=style_gain)
    if name == 'coarse_palette':
        return CoarsePaletteObjective(features, style, style_gain=style_gain)
    if name == 'teacher_distill':
        if teacher_directory is None or style_gain != 1.:
            raise ValueError('teacher distillation requires a teacher directory and default style_gain=1')
        from r2_style_distill import TeacherDistillObjective
        return TeacherDistillObjective(features,teacher_directory)
    raise ValueError('unknown style training objective: ' + name)
