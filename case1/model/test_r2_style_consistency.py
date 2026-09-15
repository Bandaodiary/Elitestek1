"""Motion alignment, perturbation bounds, real QAT gradient/optimizer tests."""
from pathlib import Path
import numpy as np
import torch
from torch import nn

from compare_r2_style_models import load_new_qat
from r2_style_consistency import POSES, rgb_grid, shifted, aligned, noise_input, consistency_terms


def main():
    torch.set_num_threads(1)
    torch.manual_seed(20260915)
    source = rgb_grid(torch.rand(1, 3, 96, 112))
    for dx, dy in POSES:
        a, b = aligned(source, shifted(source, dx, dy), dx, dy)
        torch.testing.assert_close(a, b, atol=0, rtol=0)
    generator = torch.Generator().manual_seed(123)
    torch.testing.assert_close(noise_input(source, generator, 0), source, atol=0, rtol=0)
    noisy = noise_input(source, generator)
    codes = ((noisy-source)*255).round()
    assert codes.abs().max() == 1 and codes.abs().sum() > 0
    torch.testing.assert_close(noisy*255, (noisy*255).round(), atol=2e-5, rtol=0)
    for pose in ((-1, 0), (0, -1), (112, 0), (.5, 0)):
        try:
            shifted(source, *pose)
        except ValueError:
            pass
        else:
            raise AssertionError('invalid shift accepted')
    identity = nn.Identity()
    terms = consistency_terms(identity, source, source, (3, 2), generator)
    assert terms['translation'] == 0 and terms['noise'] > 0
    case = Path(__file__).resolve().parents[1]
    qat = load_new_qat(case/'outputs/c36_qat_b_mosaic_equalized_20260915a')
    before = {k: tuple(a.copy() for a in qat.quantized_arrays(k)) for k in qat.quant_parameters}
    optimizer = torch.optim.Adam(qat.parameters(), lr=2e-5)
    terms = consistency_terms(qat, source, qat(source), (1, 1), generator)
    loss = 4*terms['translation']+2*terms['noise']
    assert torch.isfinite(loss) and loss > 0
    loss.backward()
    assert all(p.grad is not None and torch.isfinite(p.grad).all() for p in qat.parameters())
    optimizer.step()
    assert any(not np.array_equal(a, b) for k in before
               for a, b in zip(before[k], qat.quantized_arrays(k)))
    print('C36_CONSISTENCY_UNIT_PASS exact_motion_controls=9 invalid_shifts_rejected=4 '
          'noise_code_bound=1 actual_QAT_gradient=1 deployed_arrays_changed=1 RTL_changed=0')


if __name__ == '__main__':
    main()
