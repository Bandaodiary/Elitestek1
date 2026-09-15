"""C6 graph traffic and NON-overlap lower bound, not native measured fps.

No fitted extrapolation from tiny frame cycles. Counts include P2C8 padding,
three independently loaded raw rows at spatial operators, both add inputs,
and final RGB row writes. Parameter command image loads once per layer.
"""
from __future__ import annotations
import json
from microstyle_workload import build_layout
from r2_operator_schedule_budget import row_cycles


def budget(width=640,height=480):
    descriptors,layout=build_layout(width,height);stages=[]
    for stage,d in enumerate(descriptors):
        if stage in (14,17,21):
            stages.append(dict(stage=stage,read_beats=0,write_beats=0,parameter_beats=0,compute_cycles=0));continue
        virtual=stage in (15,18)
        raw_width=d.input_width//2 if virtual else d.input_width
        groups=(d.input_channels+7)//8;out_groups=(d.output_channels+7)//8
        mode=4+stage if stage in (0,1) else 3 if stage in (5,9,13) else 1 if stage==20 else 2 if stage in (3,7,11,15,18) else 0
        spatial=mode in (1,2,4,5)
        reads=((raw_width+1)//2)*groups*d.output_height*(3 if spatial else 2 if mode==3 else 1)
        writes=((d.output_width+1)//2)*out_groups*d.output_height
        k=2 if stage==0 else 7 if stage==1 else 5 if stage==20 else 1 if mode==2 else (d.input_channels+15)//16
        params=0 if mode==3 else d.output_channels*(2*k+1)
        size=d.output_width*d.output_channels if mode==3 else raw_width
        compute=row_cycles(mode,size,d.input_channels,d.output_channels,virtual)*d.output_height
        stages.append(dict(stage=stage,read_beats=reads,write_beats=writes,parameter_beats=params,compute_cycles=compute))
    feature=sum(s['read_beats'] for s in stages);writes=sum(s['write_beats'] for s in stages)
    params=sum(s['parameter_beats'] for s in stages);compute=sum(s['compute_cycles'] for s in stages)
    # C6 strictly separates feature loads, compute, and row stream. These
    # durations therefore add; buffering alone cannot hide the 32-bit port.
    floor=feature*4+params*2+compute+writes
    return dict(width=width,height=height,parameter_beats=params,feature_read_beats=feature,
                read_beats=feature+params,write_beats=writes,external_bytes=(feature+writes+params)*16,
                compute_cycles=compute,serialized_32bit_load_cycles=feature*4+params*2,
                nonoverlap_lower_bound_cycles=floor,clock_assumption_MHz=150,
                best_possible_fps_under_current_nonoverlap_bound=150000000/floor,
                meets_15fps_even_under_ideal_transfers=floor<=10000000,
                measured_native_fps=None,stages=stages,
                exclusions='memory latency, command/response/control overhead; not board or native full-frame measurement')


if __name__=='__main__':
    for w,h in ((4,4),(12,12),(32,32),(640,12),(640,480)):
        b=budget(w,h)
        print('C1_R2_GRAPH_TRAFFIC_BUDGET '+json.dumps({k:v for k,v in b.items() if k!='stages'}))
