"""C7 exact graph traffic. A cycle lower bound is NOT an achieved fps."""
from __future__ import annotations
import json
from microstyle_workload import build_layout
from r2_graph_traffic_budget import budget as c6_budget


def budget(width=640,height=480,cache=True):
    old=c6_budget(width,height);descriptors,_=build_layout(width,height);rows=[]
    for item in old['stages']:
        stage=item['stage'];row=dict(item)
        if cache and stage in (0,1,3,7,11,15,18,20):
            d=descriptors[stage];virtual=stage in (15,18)
            w=d.input_width//2 if virtual else d.input_width;h=d.input_height//2 if virtual else d.input_height
            row['read_beats']=((w+1)//2)*((d.input_channels+7)//8)*h
        rows.append(row)
    feature=sum(s['read_beats'] for s in rows);params=old['parameter_beats'];writes=old['write_beats'];compute=old['compute_cycles']
    # Without overlap, ideal bulk refill+compute+stream durations add. With
    # overlap only refill vs preceding write can overlap; compute still owns
    # the sole feature pool and row writer. Neither bound is a measured fps.
    return dict(width=width,height=height,cache=cache,feature_read_beats=feature,parameter_beats=params,
                read_beats=feature+params,write_beats=writes,external_bytes=(feature+params+writes)*16,
                c6_external_bytes=old['external_bytes'],feature_reads_saved=old['feature_read_beats']-feature,
                compute_cycles=compute,ideal_serial_bulk_lower_bound=compute+feature+writes+params*2,
                optimistic_overlap_lower_bound=compute+max(feature,writes)+params*2,
                measured_native_fps=None,stages=rows,
                scope='exact scheduled traffic; cycle lower bounds omit DMA/control/DDR contention, NOT proof of 15fps')


if __name__=='__main__':
    for w,h in ((4,4),(12,12),(32,32),(640,12),(640,480)):
        result=budget(w,h)
        print('C1_R2_STREAM_TRAFFIC_BUDGET '+json.dumps({k:v for k,v in result.items() if k!='stages'}))
