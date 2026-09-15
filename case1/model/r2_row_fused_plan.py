"""C35 row-fusion plan candidate; retained model/compiler remain unchanged.

Keep the DW source alive through its PW consumer: the unfused allocator may
otherwise reuse that source slot for PW and overwrite future spatial rows.
This is a compile-time, exclusive operator-pattern optimization, not a new
model or an arbitrary CNN importer. Unsupported patterns use the old plan.
"""
from dataclasses import replace

from r2_execution_plan import (FRAME, OP_UPSAMPLE2, OP_DWCONV3X3,
                               OP_CONV1X1, lower, render_sv, require)


def eligible_pairs(nodes):
    users={n.spec.name:[] for n in nodes}
    by_name={n.spec.name:n for n in nodes}
    indices={n.spec.name:i for i,n in enumerate(nodes)}
    for n in nodes:
        for source in n.inputs:
            if source in users:users[source].append(n.spec.name)
    pairs=[]
    for i,n in enumerate(nodes):
        s=n.spec
        if s.opcode!=OP_DWCONV3X3 or (s.input_channels,s.output_channels,s.kernel,s.stride)!=(16,16,3,1):continue
        if len(n.inputs)!=1 or len(users[s.name])!=1:continue
        view=by_name.get(n.inputs[0]);pw=by_name[users[s.name][0]];p=pw.spec
        if view is None or view.spec.opcode!=OP_UPSAMPLE2 or users[view.spec.name]!=[s.name]:continue
        if p.opcode!=OP_CONV1X1 or (p.input_channels,p.output_channels,p.kernel,p.stride)!=(16,8,1,1):continue
        if indices[p.name]!=i+1 or pw.inputs!=(s.name,):continue
        if (p.input_width,p.input_height)!=(s.output_width,s.output_height):continue
        if not 4<=s.output_width<=640 or s.output_width%4:continue
        pairs.append((i,i+1))
    return pairs


def fused_steps(nodes,width=640,height=480,enabled=True):
    original=lower(nodes,width,height)
    pairs=eligible_pairs(nodes) if enabled else []
    if not pairs:return original,pairs
    indices={n.spec.name:i for i,n in enumerate(nodes)}
    last_use={FRAME:-1}
    for s in original:
        if not s.view:
            last_use.setdefault(s.name,s.index)
            for root in s.physical_inputs:last_use[root]=max(last_use.get(root,-1),s.index)
    for dw,pw in pairs:
        root=original[dw].physical_inputs[0]
        last_use[root]=max(last_use[root],pw)
    live={};assigned={};result=[]
    for s in original:
        live={name:slot for name,slot in live.items() if last_use[name]>=s.index}
        source=s.physical_inputs[0]
        src=assigned.get(source,0)
        skip=assigned.get(s.physical_inputs[-1],0) if len(s.physical_inputs)==2 else 0
        if s.view:dst=src
        elif s.output_rgb:dst=0
        else:
            free=[b for b in range(3) if b not in live.values()]
            require(free,'row fusion exceeds three tensor slots')
            dst=free[0];live[s.name]=dst;assigned[s.name]=dst
        result.append(replace(s,src_slot=src,dst_slot=dst,skip_slot=skip))
    for dw,pw in pairs:
        require(result[dw].src_slot!=result[pw].dst_slot,'fusion overwrites live spatial source')
        require(result[dw].mode==2 and result[dw].virtual_up2 and result[pw].mode==0,'fusion backend mismatch')
    return result,pairs


def fusion_sv(steps,pairs):
    # Only tiny fusion side metadata is decoded; do not instantiate a second
    # full geometry/plan decoder in the RTL scheduler.
    lines=['`timescale 1ns/1ps',
        '// Generated semantic DW16/PW8 pairing, paired with execution_plan.sv.',
        'module c1_r2_row_fusion_plan (input wire [4:0] index,',
        '    output logic enable, output logic [4:0] pw_parameter_block,',
        '    output logic [15:0] pw_parameter_beats, output logic [1:0] pw_dst_slot);',
        '    always_comb begin',
        '        enable=0;pw_parameter_block=0;pw_parameter_beats=0;pw_dst_slot=0;',
        '        case(index)']
    for dw,pw in pairs:
        s=steps[pw]
        lines.append(f"            5'd{dw}:begin enable=1;pw_parameter_block=5'd{s.parameter_block};pw_parameter_beats=16'd{s.parameter_beats};pw_dst_slot=2'd{s.dst_slot};end")
    lines+=['            default:begin end','        endcase','    end','endmodule','']
    return '\n'.join(lines)


def selftest():
    from r2_plan_package import profile_nodes
    from r2_execution_plan import Node
    cases=0;remapped=0
    for profile in ('microstyle24','drop_res1'):
        for w,h in ((4,4),(12,12),(32,32),(640,480)):
            nodes=profile_nodes(profile,w,h);old=lower(nodes,w,h)
            new,pairs=fused_steps(nodes,w,h);assert len(pairs)==1
            dw,pw=pairs[0]
            assert new[dw].src_slot!=new[pw].dst_slot
            remapped+=old[pw].dst_slot!=new[pw].dst_slot
            # Independent per-instruction source ownership replay, retaining
            # an additional live input on the PW step of every fused pair.
            owner={};lookup={s.name:s for s in new}
            for s in new:
                if s.view:continue
                inputs=list(s.physical_inputs)
                inputs += [new[d].physical_inputs[0] for d,p in pairs if p==s.index]
                for root in inputs:
                    if root!=FRAME:
                        producer=lookup[root]
                        assert owner[producer.dst_slot]==root
                        if not s.output_rgb:assert s.dst_slot!=producer.dst_slot
                if not s.output_rgb:owner[s.dst_slot]=s.name
            renamed={n.spec.name:f'node_{i}' for i,n in enumerate(nodes)}
            renamed_nodes=[Node(replace(n.spec,name=renamed[n.spec.name]),tuple(renamed.get(x,x) for x in n.inputs)) for n in nodes]
            assert eligible_pairs(renamed_nodes)==pairs
            assert fused_steps(nodes,w,h,False)==(old,[])
            if w==640:render_sv(new);fusion_sv(new,pairs)
            cases+=1
    assert remapped==cases
    print(f'C35_ROW_FUSION_PLAN_PASS cases={cases} renamed_cases={cases} fallback_cases={cases} source_aliases_prevented={remapped} RTL_executed=0')


if __name__=='__main__':selftest()
