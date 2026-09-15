"""C4 row schedules, not measured frame throughput or DMA/encoder proof."""
from __future__ import annotations
import json
from r2_architecture_budget import plan, ceildiv
from microstyle_workload import build_layout
from r2_cnn_schedule_budget import row_cycles as c3_cycles


def row_cycles(mode, size, channels, outputs=0):
    if mode == 0:
        if channels not in (16,24,48) or outputs not in (8,16,24,48) or size < 1 or ceildiv(size,2)*ceildiv(channels,16) > 512:
            raise ValueError('unsupported C4 PW shape or parity bank capacity')
        return ceildiv(size*outputs,6)*ceildiv(channels,16)+13
    return c3_cycles(mode,size,channels)+(1 if mode in (1,2) else 0)


def budget():
    initial=plan(rows=6,requant_lanes=6);descriptors,_=build_layout(640,480);rows=[]
    for stage in initial['stages']:
        i=stage['stage'];d=descriptors[i];per_row=None
        if i in (2,4,6,8,10,12,16,19): per_row=row_cycles(0,d.output_width,d.input_channels,d.output_channels)
        elif i in (3,7,11,15,18): per_row=row_cycles(2,d.output_width,d.input_channels)
        elif i in (5,9,13): per_row=row_cycles(3,d.output_width*d.output_channels,0)
        elif i == 20: per_row=row_cycles(1,d.output_width,d.input_channels)
        gaps=d.output_height-1 if per_row is not None else 0
        cycles=per_row*d.output_height+gaps if per_row is not None else stage['minimum_cycles']
        rows.append(dict(stage=i,name=stage['name'],cycles=cycles,row_cycles=per_row,minimum_restart_gaps=gaps,
                         basis='C4 simulation-checked row schedule, excludes refill/writeback' if per_row is not None else 'R2-A unimplemented ideal, including elided views'))
    total=sum(r['cycles'] for r in rows)
    return dict(width=640,height=480,mixed_schedule_cycles=total,assumed_clock_MHz=150,deadline_15fps_cycles=10000000,
                remaining_deadline_cycles=10000000-total,measured_frame_fps=None,
                scope='17 row-executor stages plus ideal encoder/view assumptions; no DMA, graph dispatch, contention or board proof',stages=rows)


if __name__=='__main__':
    for cin,cout,width in ((24,48,160),(48,24,160),(24,16,320),(16,8,640)):
        print(f'C1_R2_TILE_ROW_BUDGET cin={cin} cout={cout} pixels={width} cycles={row_cycles(0,width,cin,cout)}')
    for size,cin,cout in ((513,24,48),(341,48,24),(1025,16,8),(1,8,16),(1,16,12),(0,16,8)):
        try: row_cycles(0,size,cin,cout)
        except ValueError: pass
        else: raise AssertionError('unsupported PW shape accepted')
    result=budget();assert result['mixed_schedule_cycles']==6113143
    print('C1_R2_TILE_SCHEDULE_BUDGET '+json.dumps(result))
