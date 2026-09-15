"""Training-only, known-motion consistency on the deployed RGB grid.

No flow estimation, frame buffer, filter or operator is added to the student.
The crop excludes the B model's receptive-field boundary. This is a synthetic
regularizer, not proof of coherent real video or aesthetic quality.
"""
import torch
from torch.nn import functional as F

POSES = ((1, 0), (0, 1), (1, 1), (2, 0), (0, 2), (2, 2),
         (3, 0), (0, 3), (3, 3))


def rgb_grid(content):
    if content.ndim != 4 or content.shape[1] != 3 or not torch.isfinite(content).all():
        raise ValueError('finite NCHW RGB required')
    return content.clamp(0, 1).mul(255).round()/255


def shifted(content, dx, dy):
    if not isinstance(dx, int) or not isinstance(dy, int) or min(dx, dy) < 0:
        raise ValueError('nonnegative integer motion required')
    h, w = content.shape[-2:]
    if dx >= w or dy >= h:
        raise ValueError('motion exceeds frame')
    return F.pad(content, (dx, 0, dy, 0), mode='replicate')[..., :h, :w]


def aligned(reference, moved, dx, dy, margin=32):
    h, w = reference.shape[-2:]
    if (moved.shape != reference.shape or min(dx, dy) < 0 or
            margin <= max(dx, dy) or min(h, w) <= 2*margin):
        raise ValueError('invalid motion alignment/interior')
    return (reference[..., margin:h-margin, margin:w-margin],
            moved[..., margin+dy:h-margin+dy, margin+dx:w-margin+dx])


def noise_input(content, generator, amplitude=1):
    if amplitude not in (0, 1):
        raise ValueError('only 0/1-LSB bounded perturbations supported')
    pixels = rgb_grid(content)*255
    noise = torch.randint(-amplitude, amplitude+1, content.shape,
                          generator=generator, device=content.device)
    return (pixels+noise).clamp(0, 255)/255


def consistency_terms(model, content, output, pose, generator, margin=32):
    dx, dy = pose
    translated = model(shifted(content, dx, dy))
    left, right = aligned(output, translated, dx, dy, margin)
    noisy = noise_input(content, generator)
    noisy_output = model(noisy)
    base, perturbed = aligned(output, noisy_output, 0, 0, margin)
    return dict(translation=F.l1_loss(left, right), noise=F.l1_loss(base, perturbed))


@torch.no_grad()
def validation_consistency(model, images, device, guard=None):
    """Fixed 128-square validation views; no test/public-demo image is used."""
    generator = torch.Generator(device=device).manual_seed(20260915)
    was_training = model.training
    model.eval()
    rows = []
    try:
        for index, (name, image) in enumerate(images):
            if guard:
                guard.begin()
            content = rgb_grid(F.interpolate(image[None].to(device), size=(128, 128),
                              mode='bilinear', align_corners=False, antialias=True))
            output = model(content)
            pose = POSES[index % len(POSES)]
            terms = consistency_terms(model, content, output, pose, generator)
            rows.append(dict(image=name, dx=pose[0], dy=pose[1],
                             **{key: float(value) for key, value in terms.items()}))
            if guard:
                guard.end()
    finally:
        model.train(was_training)
    if not rows:
        raise ValueError('nonempty validation partition required')
    return dict(split='val', test_images_read=0, shape=[128, 128], margin=32,
                real_video=False, images=rows,
                mean={key: sum(row[key] for row in rows)/len(rows)
                      for key in ('translation', 'noise')})
