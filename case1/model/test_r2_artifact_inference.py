"""Prove artifact-only inference matches all three frozen QAT candidates."""
from pathlib import Path
import numpy as np
import torch

from compare_r2_style_models import load_new_qat
from infer_r2_style_artifact import geometry, input_pixels, infer_artifact


def main():
    torch.set_num_threads(1)
    case = Path(__file__).resolve().parents[1]
    source = case/'assets/images/astronaut.png'
    pixels, resize = input_pixels(source, [16, 12])
    assert pixels.shape == (12, 16, 3) and resize['input_size'] == [16, 12]
    rejected = 0
    for width, height in ((638, 480), (640, 482), (0, 4), (4, 3), (644, 480), (4., 4)):
        try:
            geometry(width, height)
        except ValueError:
            rejected += 1
        else:
            raise AssertionError('unsupported geometry accepted')
    try:
        input_pixels(source)
    except ValueError:
        rejected += 1
    else:
        raise AssertionError('512-high image silently resized without --fit')
    original_load = torch.load
    def forbid_checkpoint(*args, **kwargs):
        raise AssertionError('artifact inference opened a training checkpoint')
    stimulus = torch.from_numpy(pixels.transpose(2, 0, 1).copy())[None].float()/255
    frames = 0
    for name in ('c36_qat_b_starry_equalized_20260915a', 'c36_qat_b_mosaic_equalized_20260915a',
                 'c36_qat_b_mosaic_stable_20260915a'):
        directory = case/'outputs'/name
        with torch.no_grad():
            expected = load_new_qat(directory)(stimulus)[0].mul(255).round().byte().numpy().transpose(1, 2, 0)
        torch.load = forbid_checkpoint
        try:
            actual, metadata = infer_artifact(directory/'artifact', pixels)
        finally:
            torch.load = original_load
        np.testing.assert_array_equal(actual, expected)
        assert metadata['artifact_only'] and not metadata['checkpoint_loaded'] and not metadata['teacher_loaded']
        frames += 1
    print(f'C36_ARTIFACT_INFERENCE_TEST_PASS trained_models={frames} RGB_bytes_checked={frames*pixels.size} '
          f'unsupported_or_implicit_resize_rejected={rejected} actual_checkpoint_load_forbidden=1 RTL_simulated=0')


if __name__ == '__main__':
    main()
