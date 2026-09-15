"""Short CPU contract checks, not aesthetic-quality evidence."""
from pathlib import Path
import torch

from r2_style_perceptual import PerceptualFeatures, StyleObjective
from r2_style_objectives import make_objective, coarse_rgb, color_covariance
from r2_style_student import R2StyleStudent


def main():
    torch.set_num_threads(1)
    torch.manual_seed(20260915)
    case = Path(__file__).resolve().parents[1]
    features = PerceptualFeatures(case/'assets/training/c36_openimages320_20260915a/squeezenet1_1.pth')
    style = torch.rand(1, 3, 96, 128)
    content = torch.rand(2, 3, 64, 80)
    output = torch.rand_like(content, requires_grad=True)
    original = StyleObjective(features, style, style_gain=1.5)
    factory = make_objective('original', features, style, style_gain=1.5)
    for strength in (0., .4, 1.):
        a, aa = original(output, content, strength)
        b, bb = factory(output, content, strength)
        torch.testing.assert_close(a, b, rtol=0, atol=0)
        for key in aa:
            torch.testing.assert_close(aa[key], bb[key], rtol=0, atol=0)
    coarse = make_objective('coarse_palette', features, style, style_gain=1.5)
    model = R2StyleStudent(blocks=2, expansion=24, preproject=True)
    parameters = {name: value.detach().clone() for name, value in model.named_parameters()}
    optimizer = torch.optim.Adam(model.parameters(), lr=.0003)
    prediction = model(content)
    loss, terms = coarse(prediction, content)
    assert torch.isfinite(loss) and all(torch.isfinite(x) and x >= 0 for x in terms.values())
    loss.backward()
    assert all(p.grad is None for p in features.parameters())
    assert all(p.grad is not None and torch.isfinite(p.grad).all() for p in model.parameters())
    optimizer.step()
    assert any(not torch.equal(parameters[n], p) for n, p in model.named_parameters())
    zero, _ = coarse(output, content, strength=0.)
    full, full_terms = coarse(output, content, strength=1.)
    torch.testing.assert_close(full-zero, 1.5*full_terms['style']+.3*full_terms['color'])
    constant = torch.full((1, 3, 64, 80), .4)
    torch.testing.assert_close(coarse_rgb(constant), constant[..., ::2, ::2])
    torch.testing.assert_close(color_covariance(constant), torch.zeros(1, 3, 3), atol=1e-12, rtol=0)
    for invalid in ('unknown', ''):
        try:
            make_objective(invalid, features, style)
        except ValueError:
            pass
        else:
            raise AssertionError('unknown objective accepted')
    print('C36_STYLE_OBJECTIVES_PASS original_exact=1 pretrained_features_frozen=1 real_optimizer_update=1 strength_formula=1 RTL_graph_unchanged=1 aesthetic_quality_claim=0')


if __name__ == '__main__':
    main()
