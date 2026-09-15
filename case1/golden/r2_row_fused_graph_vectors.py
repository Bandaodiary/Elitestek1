"""Full original-DAG oracle, remapped row-fusion DDR plan and DW checker data.

Only RGB input and original parameter commands initialize DUT memory. The
DW expected packets below are never a memory response or an operator input.
"""
from pathlib import Path
import json

from r2_plan_vectors import vectors as old_vectors, infer, _image, np, ROOT
from r2_plan_package import compile_package, profile_nodes
from r2_execution_plan import lower, render_sv
from r2_row_fused_plan import fused_steps, fusion_sv
from r2_tail_tile_contract import dw_packets


def vectors(folder,w,h,profile='microstyle24',enabled=True):
    folder=Path(folder);package=compile_package(profile_nodes(profile))
    m=old_vectors(folder,w,h,profile,package)
    nodes=profile_nodes(profile,w,h);old=lower(nodes,w,h)
    steps,pairs=fused_steps(nodes,w,h,enabled)
    maximum,maximum_pairs=fused_steps(profile_nodes(profile),enabled=enabled)
    assert pairs==maximum_pairs
    assert len(pairs)<=1,'this probe covers one exclusive pair per graph'
    (folder/'package/execution_plan.sv').write_text(render_sv(maximum),encoding='ascii')
    (folder/'fusion_plan.sv').write_text(fusion_sv(maximum,maximum_pairs),encoding='ascii')
    # Re-map each independently computed tensor's DDR destination; suppress
    # ONLY the matched DW tensor's writes. The mathematics is never skipped.
    dropped={dw for dw,pw in pairs};expected=[]
    old_expected=[int(x,16) for x in (folder/'expected.mem').read_text().splitlines()]
    for word in old_expected:
        index=word>>160
        if index in dropped:continue
        address=(word>>128)&0xffffffff
        offset=address&((1<<23)-1)
        slot=4 if steps[index].output_rgb else 1+steps[index].dst_slot
        expected.append((index<<160)|((slot*(1<<23)+offset)<<128)|(word&((1<<128)-1)))
    (folder/'expected.mem').write_text(''.join(f'{x:042x}\n' for x in expected),encoding='ascii')
    old_owners=[int(x,16) for x in (folder/'owners.mem').read_text().splitlines()]
    owners=[-99]*192
    for i in range(len(nodes)):
        for slot in range(6):
            owner=old_owners[i*6+slot]
            owner=owner if owner<(1<<31) else owner-(1<<32)
            if owner==-99:continue
            new_slot=slot if owner<0 else (4 if steps[owner].output_rgb else 1+steps[owner].dst_slot)
            owners[i*6+new_slot]=owner
    (folder/'owners.mem').write_text(''.join(f'{x&0xffffffff:08x}\n' for x in owners),encoding='ascii')
    packets=[]
    if pairs:
        dw,pw=pairs[0]
        for fid in range(2):
            rgb=_image(w,h)
            if fid:rgb=np.bitwise_xor(np.roll(rgb,1,axis=1),np.uint8(0x5b))
            _,tensors=infer(nodes,package.layers,rgb)
            tensor=tensors[nodes[dw].spec.name]
            for row in tensor:
                row_packets=dw_packets(row,0)
                for i,p in enumerate(row_packets):
                    packets.append((int(i==len(row_packets)-1)<<70)|(p['tag']<<54)|(p['mask']<<48)|p['data'])
    (folder/'dw_expected.mem').write_text(''.join(f'{x:018x}\n' for x in packets) or '0\n',encoding='ascii')
    original_words=m['expected_words'];m['expected_words']=len(expected)
    m.update(fusion_enabled=bool(pairs),dw_stage=pairs[0][0] if pairs else 31,
        pw_stage=pairs[0][1] if pairs else 31,dw_packets=len(packets),
        original_expected_words=original_words,
        removed_DDR_write_words_per_frame=(original_words-len(expected))//2,
        extra_parameter_beats_per_frame=(h-1)*sum(steps[i].parameter_beats for p in pairs for i in p))
    (folder/'metadata.json').write_text(json.dumps(m,indent=2)+'\n',encoding='utf-8')
    return m
