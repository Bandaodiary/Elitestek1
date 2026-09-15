"""C36 static topology/MAC/traffic audit. No EDA, training or FPS extrapolation."""
import argparse
from dataclasses import asdict,replace
import json
from pathlib import Path
import re

from r2_style_candidates import candidate_nodes,candidates
from r2_execution_plan import FRAME,Node,OP_UPSAMPLE2,OP_OUTPUT_RGB,OP_DWCONV3X3,microstyle_nodes,render_sv
from r2_row_fused_plan import fused_steps,fusion_sv

ROOT=Path(__file__).resolve().parents[1]


def budget(nodes,width,height):
    steps,pairs=fused_steps(nodes,width,height)
    shapes={FRAME:(width,height,3)};roots={FRAME:FRAME}
    features=writes=macs=weights=0
    words=lambda shape:((shape[0]+1)//2)*shape[1]*((shape[2]+7)//8)
    per_stage=[]
    for node in nodes:
        s=node.spec;shapes[s.name]=(s.output_width,s.output_height,s.output_channels)
        if s.opcode in (OP_UPSAMPLE2,OP_OUTPUT_RGB):
            roots[s.name]=roots[node.inputs[0]];continue
        roots[s.name]=s.name
        read=sum(words(shapes[roots[x]]) for x in node.inputs);write=words(shapes[s.name])
        features+=read;writes+=write
        useful=s.output_width*s.output_height*s.weight_count
        weights+=s.weight_count;macs+=useful
        per_stage.append(dict(name=s.name,macs=useful,unfused_feature_words128=read,unfused_write_words128=write))
    # RGBX32 only at external input/output. Intermediate tensors remain P2C8.
    features-=width*height//4;writes-=width*height//4
    params=sum(s.parameter_beats for s in steps);extra=removed=0
    for dw,pw in pairs:
        dw_shape=shapes[nodes[dw].spec.name];count=words(dw_shape)
        features-=count;writes-=count;removed+=2*count
        reload=(steps[dw].parameter_beats+steps[pw].parameter_beats)*(dw_shape[1]-1)
        params+=reload;extra+=reload
    return dict(nodes=len(nodes),convolutions=sum(n.spec.weight_count>0 for n in nodes),
                weights_int8_bytes=weights,macs=macs,cnn_feature_read_words128=features,
                cnn_parameter_read_words128=params,cnn_write_words128=writes,
                cnn_DDR_bytes=(features+params+writes)*16,
                fused_pairs=[[nodes[d].spec.name,nodes[p].spec.name] for d,p in pairs],
                fusion_removed_words128=removed,fusion_extra_parameter_words128=extra,
                three_slot_allocation_accepted=True,backend_plan_accepted=True,
                per_stage=per_stage)


def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path);a=p.parse_args()
    original=candidate_nodes()
    assert original==microstyle_nodes(),'baseline graph changed'
    rows=[];tested=0;rejected=0
    for name,config in candidates():
        for w,h in ((4,4),(12,12),(32,32),(640,480)):
            nodes=candidate_nodes(**config,width=w,height=h)
            steps,pairs=fused_steps(nodes,w,h)
            assert len(pairs)==1 and pairs[0]==(len(nodes)-4,len(nodes)-3)
            assert nodes[-1].spec.output_width==w and nodes[-1].spec.output_height==h
            assert steps[pairs[0][0]].src_slot!=steps[pairs[0][1]].dst_slot
            tested+=1
        nodes=candidate_nodes(**config);steps,pairs=fused_steps(nodes)
        assert render_sv(steps) and fusion_sv(steps,pairs)
        row=dict(name=name,config=config,**budget(nodes,640,480));rows.append(row)
    baseline=rows[0];assert baseline['macs']==428236800 and baseline['weights_int8_bytes']==12212
    # Independent closed-form arithmetic for this precise architecture family.
    for row in rows:
        c=row['config'];expect=270643200+c['blocks']*19200*(24*c['expansion']*2+9*c['expansion'])
        if c['preproject']:expect-=27648000
        assert row['macs']==expect
        row['MAC_reduction_percent']=100*(1-row['macs']/baseline['macs'])
        row['CNN_DDR_reduction_percent']=100*(1-row['cnn_DDR_bytes']/baseline['cnn_DDR_bytes'])
    # Reject an unsupported shape with valid edges, not just a malformed name.
    bad=candidate_nodes(expansion=24)
    changed=[]
    for n in bad:
        s=n.spec
        if s.name=='res0.expand1x1':s=replace(s,output_channels=32,weight_count=24*32)
        if s.name=='res0.depthwise3x3':s=replace(s,input_channels=32,output_channels=32,weight_count=32*9)
        if s.name=='res0.project1x1':s=replace(s,input_channels=32,weight_count=32*24)
        changed.append(Node(s,n.inputs))
    try:fused_steps(changed)
    except ValueError:rejected+=1
    else:raise AssertionError('unsupported channel configuration accepted')
    # Validate traffic derivation against retained actual original/18-node AXI
    # runs. These checkpoints are not evidence that other candidates executed.
    log=ROOT/'logs/r2_fused_rgb2_regression_runs/c35_fused_host_regression_20260915_a/result.log'
    text=log.read_text(encoding='utf-8-sig');checked_frames=0
    for marker,body in re.findall(r'^C35_HOST_CASE_BEGIN ([^\r\n]+)\r?\n(.*?)^C35_HOST_CASE_END \S+',text,re.M|re.S):
        case=json.loads(marker)
        if case['negative']:continue
        w,h=map(int,case['shape'].split('x'));b=budget(candidate_nodes(blocks=3 if case['profile']=='microstyle24' else 2,width=w,height=h),w,h)
        frames=re.findall(r'^C1_R2_FUSED_RGB2_HOST_SYSTEM_FRAME (.+)$',body,re.M)
        assert len(frames)==2
        for frame in frames:
            f={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',frame)}
            assert f['read_beats']==b['cnn_feature_read_words128']+b['cnn_parameter_read_words128']
            assert f['write_beats']==b['cnn_write_words128'] and f['commits']==b['nodes']
            checked_frames+=1
    assert checked_frames==10
    output=dict(scope='static exact logical MAC counts and conditional CNN-only traffic model',
        trained=False,visual_quality_validated=False,new_candidate_RTL_simulated=False,
        measured_fps_claim=False,official_compliance_signoff=False,geometries_accepted=tested,
        invalid_channel_rejections=rejected,retained_AXI_frames_crosschecked=checked_frames,candidates=rows)
    if a.output:
        target=a.output.resolve();allowed=(ROOT/'outputs').resolve()
        if not target.is_relative_to(allowed) or target.exists():raise ValueError('new output under case1/outputs required')
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_text(json.dumps(output,indent=2)+'\n',encoding='utf-8')
    compact=[{k:r[k] for k in ('name','nodes','weights_int8_bytes','macs','cnn_DDR_bytes','MAC_reduction_percent','CNN_DDR_reduction_percent')} for r in rows]
    print('C36_STYLE_CANDIDATE_AUDIT_PASS '+json.dumps(dict(geometries_accepted=tested,retained_AXI_frames_crosschecked=checked_frames,
        invalid_channel_rejections=rejected,trained=False,new_RTL_simulated=False,fps_claim=False,candidates=compact),separators=(',',':')))


if __name__=='__main__':main()
