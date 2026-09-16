"""Compatibility entry point for the promoted four-row production sampler.

Simulation and Efinity consume rtl/r2/c1_r2_resize_line_sampler.sv directly.
render() remains for older diagnostic scripts; it no longer rewrites two-row RTL.
"""
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / 'rtl/r2/c1_r2_resize_line_sampler.sv'


def render():
    text = SOURCE.read_text(encoding='utf-8-sig')
    for required in ('logic [3:0] line_valid;', 'logic [15:0] line_y [0:3];',
                     'pair<2', 'bank_x0[read_y0_bank_q]', 'line_valid[write_bank]'):
        if required not in text:
            raise ValueError('production four-row sampler contract missing: ' + required)
    if 'logic line0_valid;' in text or 'NOT production signoff' in text:
        raise ValueError('obsolete private/two-row sampler')
    return text


if __name__ == '__main__':
    render()
    print('C40_PRODUCTION_SAMPLER_PASS rows=4 source=' + str(SOURCE))
