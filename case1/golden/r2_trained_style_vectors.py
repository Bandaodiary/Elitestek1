"""C36 trained candidate -> unchanged C35 camera/host testbench fixtures.

Only camera RGB and trained parameter commands initialize DUT storage. Every
intermediate tensor and fused DW packet is checker-only data. No golden tensor
is returned on the AXI bus. Large native fixture files are streamed to a private
run directory and must be removed by the supervising worker after tool exit.
"""
from pathlib import Path
import json
import sys

import numpy as np

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'model'))
from r2_style_candidates import candidate_nodes
from r2_style_student import R2StyleStudent
from r2_style_quant import fold_student,QATStudent
from r2_plan_package import compile_package,export_new,verify,WEIGHTED
from r2_execution_plan import FRAME,OP_UPSAMPLE2,OP_OUTPUT_RGB,render_sv
from r2_row_fused_plan import fused_steps,fusion_sv
from audit_r2_style_candidates import budget
from r2_fused_camera_vectors import camera_geometry,infer
from r1_isp import resize_axis_q16,resize_bilinear_q16_u8
from generate_r1_resize_line_sampler_vectors import source_image
from run_r2_graph_probe import p2c8,SLOT
from r2_tail_tile_contract import dw_packets
from r2_trained_deployment_contract import verify_saved_deployment


def bound_candidate(qat_run):
    import torch
    root=Path(qat_run).resolve()
    status=json.loads((root/'status.json').read_text(encoding='utf-8-sig'))
    manifest=json.loads((root/'artifact/manifest.json').read_text(encoding='utf-8-sig'))
    if status['state']!='complete' or not status['trained'] or not status['quantized'] or not status['integer_probe']['all_signed_stages_bitexact']:
        raise ValueError('candidate training/QAT/export not complete')
    checkpoint=torch.load(root/'checkpoint_best.pt',map_location='cpu',weights_only=True)
    if not checkpoint['trained'] or not checkpoint['quantized'] or checkpoint['step']!=status['selected_QAT_step']:
        raise ValueError('wrong selected trained checkpoint')
    config=checkpoint['model_config']
    if config!=manifest['model_config'] or manifest['trained'] is not True:
        raise ValueError('artifact/checkpoint topology provenance differs')
    model=fold_student(R2StyleStudent(**config))
    model.load_state_dict(checkpoint['model_state'],strict=True)
    qat=QATStudent(model,checkpoint['activation_scales'],
                   {k:np.asarray(v,dtype=np.float64) for k,v in checkpoint['weight_scales'].items()})
    package=compile_package(candidate_nodes(**config),artifact=root/'artifact')
    for name,arrays in package.layers.items():
        for actual,expected in zip(arrays,qat.quantized_arrays(name)):
            np.testing.assert_array_equal(actual,expected,err_msg='exported arena differs from trained checkpoint')
    package.manifest.update(topology_retraining_performed=True,training_provenance=manifest['training'])
    verify_saved_deployment(root,package,config)
    provenance=dict(qat_run=str(root),config=config,selected_QAT_step=checkpoint['step'],
                    source_parameter_bytes=manifest['parameter_arena_bytes'],
                    all_exported_arrays_equal_checkpoint=True,production_RTL_changed=False)
    return package,config,provenance


def write_hex(path,values,digits):
    with path.open('x',encoding='ascii',buffering=65536) as stream:
        for value in values:
            stream.write(f'{int(value):0{digits}x}\n')


def build_vectors(directory,width,height,package,config,provenance):
    directory=Path(directory)
    directory.mkdir(parents=True,exist_ok=True)
    if any((directory/name).exists() for name in ('package','metadata.json','expected.mem')):
        raise FileExistsError('private vector outputs already exist')
    maximum_nodes=candidate_nodes(**config)
    nodes=candidate_nodes(**config,width=width,height=height)
    steps,pairs=fused_steps(nodes,width,height)
    maximum,maximum_pairs=fused_steps(maximum_nodes)
    if len(pairs)!=1 or pairs!=maximum_pairs:
        raise ValueError('one geometry-invariant tail fusion required')
    dw_stage,pw_stage=pairs[0]
    export_new(package,directory/'package')
    verify(package,directory/'package')
    (directory/'package/execution_plan.sv').write_text(render_sv(maximum),encoding='ascii')
    (directory/'fusion_plan.sv').write_text(fusion_sv(maximum,maximum_pairs),encoding='ascii')
    indexes={node.spec.name:i for i,node in enumerate(nodes)}
    roots,owners,views={FRAME:FRAME},[-99]*192,[1]*32
    for node,step in zip(nodes,steps):
        view=node.spec.opcode in (OP_UPSAMPLE2,OP_OUTPUT_RGB)
        views[step.index]=int(view)
        roots[node.spec.name]=roots[node.inputs[0]] if view else node.spec.name
        if not view:
            for edge in node.inputs:
                root=roots[edge]
                if root==FRAME:
                    slot,owner=0,-2
                else:
                    producer=steps[indexes[root]]
                    slot=4 if producer.output_rgb else 1+producer.dst_slot
                    owner=indexes[root]
                owners[step.index*6+slot]=owner
    write_hex(directory/'owners.mem',(x&0xffffffff for x in owners),8)
    write_hex(directory/'views.mem',views,1)
    parameter_words=0
    with (directory/'parameters.mem').open('x',encoding='ascii',buffering=65536) as stream:
        for stage in package.manifest['stages']:
            for beat in range(stage['transfer_beats128']):
                offset=stage['offset']+beat*16
                word=((5*SLOT+offset)<<128)|int.from_bytes(package.image[offset:offset+16],'little')
                stream.write(f'{word:040x}\n')
                parameter_words+=1
    sources,frames=[],[]
    expected_words=shadow_words=0
    with (directory/'expected.mem').open('x',encoding='ascii',buffering=65536) as expected_file, \
         (directory/'dw_expected.mem').open('x',encoding='ascii',buffering=65536) as shadow_file:
        for frame in range(2):
            sw,sh,rx,ry,rw,rh=camera_geometry(width,height)
            source=source_image(sw,sh,50+frame)
            rgb=resize_bilinear_q16_u8(source[ry:ry+rh,rx:rx+rw],width,height)
            xs,xp=resize_axis_q16(rw,width)
            ys,yp=resize_axis_q16(rh,height)
            packed=source.astype(np.uint32).reshape(-1,3)
            packed=(packed[:,0]<<16)|(packed[:,1]<<8)|packed[:,2]
            write_hex(directory/f'source{frame}.mem',packed,6)
            sources.append(dict(width=sw,height=sh,roi_x=rx,roi_y=ry,roi_width=rw,roi_height=rh,
                                xs=xs,ys=ys,xp=xp,yp=yp,pixels=sw*sh))
            result,tensors=infer(nodes,package.layers,rgb)
            for row in tensors[nodes[dw_stage].spec.name]:
                packets=dw_packets(row,0)
                for index,packet in enumerate(packets):
                    value=((int(index==len(packets)-1)<<70)|(packet['tag']<<54)|
                           (packet['mask']<<48)|packet['data'])
                    shadow_file.write(f'{value:018x}\n')
                    shadow_words+=1
            inputs=p2c8(rgb)
            write_hex(directory/f'input{frame}.mem',inputs,32)
            frame_words=scalars=0
            shapes=[]
            for node,step in zip(nodes,steps):
                if node.spec.opcode in (OP_UPSAMPLE2,OP_OUTPUT_RGB) or step.index==dw_stage:
                    continue
                tensor=result if step.output_rgb else tensors[node.spec.name]
                words=p2c8(tensor)
                slot=4 if step.output_rgb else 1+step.dst_slot
                for index,word in enumerate(words):
                    encoded=(step.index<<160)|((slot*SLOT+index*16)<<128)|word
                    expected_file.write(f'{encoded:042x}\n')
                expected_words+=len(words)
                frame_words+=len(words)
                scalars+=int(tensor.size)
                shapes.append(dict(stage=step.index,name=node.spec.name,shape=list(tensor.shape),words=len(words)))
            frames.append(dict(frame=frame,output_words=frame_words,scalars=scalars,stages=shapes))
    if parameter_words!=package.manifest['transfer_beats128'] or shadow_words!=6*width*height:
        raise AssertionError('incomplete parameter or fused DW fixture')
    info=dict(profile='c36_trained_student',model_binding=provenance,width=width,height=height,
              stage_count=len(nodes),rgb_stage=len(nodes)-2,dw_stage=dw_stage,pw_stage=pw_stage,
              dw_packets=shadow_words,sources=sources,actual_resize_golden=True,unstoppable_source=True,actual_roi=True,
              view_stages=[i for i in range(len(nodes)) if views[i]],parameter_words=parameter_words,
              planned_parameter_words=package.manifest['transfer_beats128'],input_words=len(inputs),
              expected_words=expected_words,frames=frames,traffic=budget(nodes,width,height),
              quality_validated=False,new_model_RTL_simulated=False)
    (directory/'metadata.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8')
    return info


def main():
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('--qat-run',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--width',type=int,required=True)
    parser.add_argument('--height',type=int,required=True)
    args=parser.parse_args()
    package,config,provenance=bound_candidate(args.qat_run)
    meta=build_vectors(args.output,args.width,args.height,package,config,provenance)
    print('C36_TRAINED_VECTOR_BUILD '+json.dumps(dict(model_binding=provenance,
        width=args.width,height=args.height,stage_count=meta['stage_count'],dw_stage=meta['dw_stage'],
        parameter_words=meta['parameter_words'],expected_words=meta['expected_words'],dw_packets=meta['dw_packets'])))


if __name__=='__main__':
    main()
