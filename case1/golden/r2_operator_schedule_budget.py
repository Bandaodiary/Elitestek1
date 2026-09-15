"""C5 measured-formula operator budget, not a full-frame performance test."""
from __future__ import annotations
import json
from r2_architecture_budget import ceildiv
from r2_tile_schedule_budget import row_cycles as c4_cycles
from microstyle_workload import build_layout


def row_cycles(mode,size,channels,outputs=0,virtual_up2=False):
    if virtual_up2:
        if mode!=2 or channels not in (16,24,48) or size<1 or size>512 or ceildiv(size,2)*(channels//8)>1024:
            raise ValueError('unsupported virtual DW geometry')
        return size*(channels//8)*3+16
    if mode in (4,5):
        if size<1 or size>1024 or (channels,outputs)!=((3,12) if mode==4 else (12,24)):
            raise ValueError('unsupported encoder geometry')
        vectors=ceildiv(size,2)*outputs//6
        return vectors*(2 if mode==4 else 7)+(17 if mode==4 else 19)
    if mode not in (0,1,2,3): raise ValueError('unsupported operator')
    return c4_cycles(mode,size,channels,outputs)


def budget():
    descriptors,layout=build_layout(640,480);rows=[]
    for i,(d,layer) in enumerate(zip(descriptors,layout['layers'])):
        per_row=None
        if i in (0,1): per_row=row_cycles(4+i,d.input_width,d.input_channels,d.output_channels)
        elif i in (2,4,6,8,10,12,16,19): per_row=row_cycles(0,d.output_width,d.input_channels,d.output_channels)
        elif i in (3,7,11): per_row=row_cycles(2,d.output_width,d.input_channels)
        elif i in (15,18): per_row=row_cycles(2,d.input_width//2,d.input_channels,virtual_up2=True)
        elif i in (5,9,13): per_row=row_cycles(3,d.output_width*d.output_channels,0)
        elif i==20: per_row=row_cycles(1,d.output_width,d.input_channels)
        gaps=d.output_height-1 if per_row is not None else 0
        cycles=per_row*d.output_height+gaps if per_row is not None else 0
        basis='C5 row formula plus restart gaps; excludes refill/writeback' if per_row is not None else 'folded virtual coordinates at DW' if i in (14,17) else 'unimplemented/fused final display-format conversion assumption'
        rows.append(dict(stage=i,name=layer['name'],cycles=cycles,row_cycles=per_row,minimum_restart_gaps=gaps,basis=basis))
    total=sum(r['cycles'] for r in rows)
    return dict(width=640,height=480,row_schedule_estimate=total,assumed_clock_MHz=150,deadline_15fps_cycles=10000000,
                remaining_deadline_cycles=10000000-total,measured_frame_fps=None,
                scope='19 independent operator row schedules; no graph, DMA/refill/writeback, DDR contention, or board proof',stages=rows)


if __name__=='__main__':
    for mode,size,cin,cout,up2 in ((4,640,3,12,False),(5,320,12,24,False),(2,160,24,24,True),(2,320,16,16,True)):
        print(f'C1_R2_OPERATOR_ROW_BUDGET mode={mode} input_width={size} cin={cin} cout={cout} up2={int(up2)} cycles={row_cycles(mode,size,cin,cout,up2)}')
    for mode,size,cin,cout,up2 in ((4,1025,3,12,False),(5,1,3,24,False),(2,513,16,16,True),(2,341,48,48,True),(1,3,8,3,True),(6,3,16,8,False)):
        try: row_cycles(mode,size,cin,cout,up2)
        except ValueError: pass
        else: raise AssertionError('illegal C5 shape accepted')
    result=budget();assert result['row_schedule_estimate']==6119861
    print('C1_R2_OPERATOR_SCHEDULE_BUDGET '+json.dumps(result))
