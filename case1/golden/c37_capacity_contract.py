"""Fail-closed software capacity checks for the actual C37 compile-time ROM.

This is not an RTL or resource measurement. Physical virtual-up2 source widths
come from the compiled manifest, not the enlarged output image dimensions.
"""
import argparse
import copy
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'model'))
from r2_execution_plan import Step, render_sv


def validate_steps(steps, max_channels=24, row_words=512):
    if max_channels not in (24,48) or row_words not in (512,1024):
        raise ValueError('invalid C37 hardware capacity profile')
    spatial = []
    for step in steps:
        mode, ci, co, width = (step[key] for key in ('mode','cin','cout','src_width'))
        if not 0 < ci <= max_channels or not 0 < co <= max_channels:
            raise ValueError('C37 channel capacity: ' + step['name'])
        if step['view']:
            continue
        if mode in (1,2,4,5):
            words = ((width+1)//2) * ((ci+7)//8)
            if words > row_words:
                raise ValueError('C37 spatial row capacity: ' + step['name'])
            spatial.append(dict(index=step['index'], words=words))
        elif mode == 0:
            words = ((width+1)//2) * ((ci+15)//16)
            if words > 512:
                raise ValueError('C37 shared linear row capacity: ' + step['name'])
    if not spatial:
        raise ValueError('no spatial operations audited')
    return spatial


def check_package(model, max_channels=24, row_words=512):
    folder = Path(model) / 'plan_fused'
    manifest = json.loads((folder / 'manifest.json').read_text(encoding='utf-8-sig'))
    steps = manifest['steps']
    # Do not accept a stale or hand-edited manifest that disagrees with the
    # RTL ROM that will actually be compiled.
    expected = render_sv([Step(**item) for item in steps])
    if (folder / 'execution_plan.sv').read_text(encoding='utf-8-sig') != expected:
        raise ValueError('capacity manifest does not reproduce actual execution ROM')
    spatial = validate_steps(steps, max_channels, row_words)
    return dict(model=Path(model).name, steps=len(steps), spatial=spatial,
                maximum_row_words=max(item['words'] for item in spatial),
                max_channels=max_channels, row_words=row_words)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    roots = [ROOT / 'outputs' / name for name in (
        'c36_qat_b_starry_equalized_20260915a', 'c36_qat_b_mosaic_equalized_20260915a',
        'c36_qat_b_mosaic_stable_20260915a')]
    for root in roots:
        print('C37_MODEL_CAPACITY_PASS ' + json.dumps(check_package(root), separators=(',', ':')))
    if args.self_test:
        original = json.loads((roots[0] / 'plan_fused/manifest.json').read_text())['steps']
        failures = 0
        for field, value in (('cin',48), ('cout',48), ('src_width',2048)):
            bad = copy.deepcopy(original)
            bad[0][field] = value
            try:
                validate_steps(bad)
            except ValueError:
                failures += 1
            else:
                raise AssertionError('capacity negative control accepted')
        print(f'C37_MODEL_CAPACITY_NEGATIVE_PASS rejected={failures}')


if __name__ == '__main__':
    main()
