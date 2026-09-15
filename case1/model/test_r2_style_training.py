"""Short CPU checks of data separation and real pretrained feature gradients."""
import argparse
import csv
import io
import json
from pathlib import Path

import torch

from prepare_r2_style_data import FIELDS, split_metadata
from r2_style_perceptual import PerceptualFeatures, StyleObjective, gram, ssim_luma
from r2_style_student import R2StyleStudent
from train_r2_style_student import Patches, evaluation_input


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--weights', required=True, type=Path)
    args = parser.parse_args()
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    torch.manual_seed(20260915)
    output = io.StringIO()
    writer = csv.DictWriter(output, fieldnames=FIELDS)
    writer.writeheader()
    for i in range(100):
        writer.writerow(dict(ImageID=f'{i:016x}', OriginalURL=f'https://example.org/{i}.jpg',
                             OriginalLandingURL=f'https://example.org/photo/{i}',
                             AuthorProfileURL=f'https://example.org/author/{i//3}', Author=f'A{i//3}',
                             Title='test, quoted title', License='https://creativecommons.org/licenses/by/2.0/', Rotation='0'))
    candidates = split_metadata(output.getvalue().encode(), 20260915)
    assert candidates == split_metadata(output.getvalue().encode(), 20260915)
    groups = {k: {r['AuthorProfileURL'] for r in v} for k,v in candidates.items()}
    assert all(groups.values())
    assert not (groups['train']&groups['val'] or groups['train']&groups['test'] or groups['val']&groups['test'])
    assert sum(map(len, candidates.values())) == 100
    features = PerceptualFeatures(args.weights)
    assert all(not p.requires_grad for p in features.parameters())
    content = torch.rand(2, 3, 64, 64)
    style = torch.rand(1, 3, 96, 96)
    student = R2StyleStudent()
    objective = StyleObjective(features, style)
    before = student.layers['0'][0].weight.detach().clone()
    predicted = student(content)
    loss, components = objective(predicted, content)
    assert torch.isfinite(loss) and loss > 0
    loss.backward()
    convolutions = [p for n,p in student.named_parameters() if n.endswith('0.weight')]
    assert len(convolutions) == 13
    assert all(p.grad is not None and torch.isfinite(p.grad).all() and p.grad.abs().sum()>0 for p in convolutions)
    assert all(p.grad is None for p in features.parameters())
    optimizer = torch.optim.Adam(student.parameters(), lr=.001)
    optimizer.step()
    assert not torch.equal(before, student.layers['0'][0].weight), 'optimizer made no change'
    assert abs(float(ssim_luma(content, content))-1) < 1e-6
    assert torch.allclose(gram(content), gram(content.flip(-1)), atol=1e-6)
    stronger = StyleObjective(features,style,style_gain=3.)
    with torch.no_grad():
        base_loss, base_terms = objective(predicted.detach(),content)
        strong_loss, strong_terms = stronger(predicted.detach(),content)
        torch.testing.assert_close(strong_loss-base_loss,2*base_terms['style']+.5*base_terms['color'])
        torch.testing.assert_close(strong_terms['content'],base_terms['content'])
    patches = Patches([torch.rand(3, 80, 112), torch.rand(3, 128, 80)], 9)
    assert patches.batch(2, 64, torch.device('cpu')).shape == (2,3,64,64)
    assert evaluation_input(torch.rand(3, 333, 499)).shape == (1,3,168,256)
    print('C36_STYLE_TRAINING_PIPELINE_PASS '+json.dumps(dict(
        official_feature_weights_loaded=True, train_val_test_photographer_disjoint=True,
        convolution_gradients=len(convolutions), optimizer_changed_student=True, feature_network_frozen=True,
        smoke_optimizer_steps=1, real_image_training_completed=False, quality_validated=False,
        loss_components={k:float(v.detach()) for k,v in components.items()})))


if __name__ == '__main__':
    main()
