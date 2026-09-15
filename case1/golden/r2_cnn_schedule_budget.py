"""Mixed maturity budget: measured C3 row schedules + unimplemented R2-A ideals.

NOT measured frame throughput. Excludes load/writeback, DMA/contention, graph
dispatch, and unimplemented encoder/PW/view costs beyond their ideal bounds.
"""
from __future__ import annotations
import json
from microstyle_workload import build_layout
from r2_architecture_budget import plan, ceildiv


def row_cycles(mode, size, channels=0):
    if mode == 0 and channels == 16 and 1 <= size <= 1024:
        return ceildiv(size*8, 6)+13
    if mode == 1 and channels == 8 and 1 <= size <= 1024:
        return ceildiv(size, 2)*5+15
    if mode == 2 and channels in (16, 24, 48) and size > 0 and ceildiv(size, 2)*(channels//8) <= 1024:
        return ceildiv(size, 2)*(channels//8)*3+15
    if mode == 3 and 1 <= size <= 8192:
        return ceildiv(size, 6)+13
    raise ValueError('shape is not supported by the C3 row engine')


def budget():
    initial = plan(rows=6, requant_lanes=6)
    descriptors, _ = build_layout(640, 480)
    rows = []
    for stage in initial['stages']:
        i = stage['stage']; d = descriptors[i]; cycles = stage['minimum_cycles']; implemented = True
        if i in (3, 7, 11, 15, 18): per_row = row_cycles(2, d.output_width, d.input_channels)
        elif i in (5, 9, 13): per_row = row_cycles(3, d.output_width*d.output_channels)
        elif i == 19: per_row = row_cycles(0, d.output_width, d.input_channels)
        elif i == 20: per_row = row_cycles(1, d.output_width, d.input_channels)
        else: per_row = None; implemented = False
        # start_ready cannot be asserted on the final output handshake itself:
        # owner releases on that edge. Even with zero loading, successive row
        # start edges are separated by row_cycles+1, not just row_cycles.
        restart_gaps = d.output_height-1 if per_row is not None else 0
        if per_row is not None: cycles = per_row*d.output_height+restart_gaps
        rows.append(dict(stage=i, name=stage['name'], cycles=cycles, row_cycles=per_row, minimum_restart_gaps=restart_gaps,
                         basis='C3 simulation-checked row formula plus mandatory restart gaps; no refill cost' if implemented else 'R2-A unimplemented ideal, including elided views'))
    total = sum(r['cycles'] for r in rows)
    return dict(width=640, height=480, previous_ideal_cycles=initial['minimum_cycles'], mixed_schedule_cycles=total,
                assumed_clock_MHz=150, deadline_15fps_cycles=10000000,
                remaining_deadline_cycles=10000000-total, measured_frame_fps=None,
                scope=__doc__.strip(), stages=rows)


if __name__ == '__main__':
    for mode, size, c in ((0, 640, 16), (1, 640, 8), (2, 640, 16), (2, 320, 24), (2, 160, 48), (3, 3840, 0)):
        print(f'C1_R2_CNN_ROW_BUDGET mode={mode} size={size} channels={c} cycles={row_cycles(mode,size,c)}')
    for mode, size, c in ((2, 341, 48), (2, 683, 24), (2, 1025, 16), (2, 1, 8), (3, 8193, 0), (0, 1, 8)):
        try: row_cycles(mode, size, c)
        except ValueError: pass
        else: raise AssertionError('unsupported bank capacity accepted')
    result = budget(); assert result['mixed_schedule_cycles'] == 6098030
    print('C1_R2_CNN_SCHEDULE_BUDGET '+json.dumps(result))
