"""Training-only learned-teacher distillation into the unchanged R2 student.

The target is a pretrained Fast Neural Style network's actual RGB output,
not a hand-crafted filter. The large teacher and its InstanceNorm never enter
the student's exported graph. Matching quality remains an empirical question.
"""
from pathlib import Path
import torch
from torch import nn
from torch.nn import functional as F

from r2_style_teacher import load_teacher, teacher_rgb
from r2_style_perceptual import gram, luma, spatial_gradient


class TeacherDistillObjective(nn.Module):
    def __init__(self, features, teacher_directory):
        super().__init__()
        self.features = features
        self.teacher_directory = str(Path(teacher_directory).resolve())
        self.teacher = load_teacher(teacher_directory)

    def forward(self, output, content, strength=1.):
        with torch.no_grad():
            target = teacher_rgb(self.teacher, content)
            target_features = self.features(target)
        predicted = self.features(output)
        pixel = F.l1_loss(output,target)
        feature = sum(F.mse_loss(predicted[i],target_features[i]) /
                      target_features[i].square().mean().clamp_min(.01) for i in (1,2))/2
        style = sum((gram(value)-gram(wanted)).square().mean() /
                    gram(wanted).square().mean().clamp_min(.01)
                    for value,wanted in zip(predicted,target_features))/len(predicted)
        edges = sum(F.l1_loss(a,b) for a,b in zip(spatial_gradient(output),spatial_gradient(target)))
        color = (F.l1_loss(output.mean((2,3)),target.mean((2,3)))+
                 F.l1_loss(output.std((2,3),unbiased=False),target.std((2,3),unbiased=False)))
        low = F.l1_loss(F.avg_pool2d(luma(output),8),F.avg_pool2d(luma(content),8))
        tv = sum(x.abs().mean() for x in spatial_gradient(output))
        source_match = F.l1_loss(output,content)
        distilled = 3*pixel+.5*feature+.3*style+edges+.5*color
        total = strength*distilled+(1-strength)*source_match+.2*low+.03*tv
        return total, dict(teacher_rgb=pixel,teacher_features=feature,teacher_gram=style,
                           teacher_edges=edges,teacher_color=color,source_low_luma=low,tv=tv)
