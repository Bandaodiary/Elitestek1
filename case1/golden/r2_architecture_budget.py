"""R2 schedule/capacity lower bounds; no physical fps or memory-port proof."""
from __future__ import annotations
import argparse,json
from microstyle_workload import workload,build_layout

def ceildiv(a,b): return (a+b-1)//b

def plan(width=640,height=480,rows=8,tile_w=32,tile_h=16,requant_lanes=None):
    if rows not in (4,6,8) or tile_w<1 or tile_h<1 or (requant_lanes is not None and requant_lanes<1):
        raise ValueError('unsupported candidate or nonpositive tile')
    descriptors,layout=build_layout(width,height)
    old=workload(width,height,virtual_upsample=True,pack_rgb_reduction=True,elide_views=True,fuse_final=True)
    stages=[]
    for i,(d,s) in enumerate(zip(descriptors,layout['layers'])):
        outputs=d.output_width*d.output_height*d.output_channels
        conv=d.opcode in (1,2,3)
        k=d.kernel_width*d.kernel_height*(1 if d.opcode==3 else d.input_channels)
        reduction=ceildiv(k,16) if conv else 0
        transactions=sum(ceildiv(min(tile_h,d.output_height-y)*min(tile_w,d.output_width-x)*d.output_channels,rows)
                         for y in range(0,d.output_height,tile_h)
                         for x in range(0,d.output_width,tile_w)) if conv else 0
        beats=transactions*reduction
        # Optional ideal decoupled scalar requant budget. Perfect overlap and
        # cross-vector packing are assumptions, NOT implemented by this probe.
        quant=ceildiv(outputs,requant_lanes) if conv and requant_lanes else 0
        # Linear path is retained as a separate budget, not claimed implemented.
        linear=old['stages'][i]['linear_beats']
        iw=(min(tile_w,d.output_width)-1)*d.stride_x+d.kernel_width
        ih=(min(tile_h,d.output_height)-1)*d.stride_y+d.kernel_height
        payload=iw*ih*ceildiv(d.input_channels,8)*8 if conv else 0
        stages.append(dict(stage=i,name=s['name'],macs=outputs*k if conv else 0,
                           outputs=outputs if conv else 0,reduction_length=k if conv else 0,
                           transactions=transactions,array_beats=beats,requant_beats=quant,linear_beats=linear,
                           minimum_cycles=max(beats,quant)+linear,input_pingpong_payload=2*payload))
    return dict(width=width,height=height,rows=rows,products_per_beat=rows*16,tile=[tile_w,tile_h],
                requant_lanes=requant_lanes,
                scope='serial graph cuts; ideal operand delivery/overlap; excludes DMA, setup, drain and stalls; requant absent unless explicitly counted',
                minimum_cycles=sum(s['minimum_cycles'] for s in stages),
                old_minimum_cycles=old['minimum_cycles'],
                max_input_pingpong_payload=max(s['input_pingpong_payload'] for s in stages),
                hypothetical_input_weight_bytes_per_beat=rows*16*2,stages=stages)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--json',action='store_true')
    p.add_argument('--requant-lanes',type=int)
    a=p.parse_args(); candidates=[plan(rows=r,requant_lanes=a.requant_lanes) for r in (4,6,8)]
    if a.json: print(json.dumps(candidates,indent=2))
    else:
        for c in candidates:
            print(f"C1_R2_ARRAY_BUDGET rows={c['rows']} products={c['products_per_beat']} requant_lanes={c['requant_lanes']} minimum_cycles={c['minimum_cycles']} old_min={c['old_minimum_cycles']} input_pingpong_bytes={c['max_input_pingpong_payload']} assumed_MHz=100 ideal_fps={100e6/c['minimum_cycles']:.3f} physical_proof=0")
