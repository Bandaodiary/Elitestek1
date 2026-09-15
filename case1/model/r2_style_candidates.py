"""Independent C36 model candidates; never change the frozen C35 model/RTL.

These are untrained graph specifications, not parameter binding, QAT export,
visual-quality evidence or measured hardware performance. All candidates keep
full 640x480 input/output and the existing DW16/PW8 row-fusion tail.
"""
from dataclasses import replace

from microstyle_layout import layer_specs
from r2_execution_plan import Node,FRAME,OP_DWCONV3X3,OP_CONV1X1,OP_CONV3X3


def candidate_nodes(blocks=3,expansion=48,preproject=False,width=640,height=480):
    if blocks not in (0,1,2,3) or expansion not in (24,48):
        raise ValueError('candidate family supports 0..3 blocks and 24/48 expansion')
    templates={s.name:s for s in layer_specs(width,height)}
    nodes=[];previous=FRAME
    def add(name,inputs=None,**changes):
        nonlocal previous
        s=replace(templates[name],**changes)
        if s.opcode in (OP_DWCONV3X3,OP_CONV1X1,OP_CONV3X3):
            count=s.output_channels*s.kernel*s.kernel*(1 if s.opcode==OP_DWCONV3X3 else s.input_channels)
            s=replace(s,weight_count=count)
        nodes.append(Node(s,(previous,) if inputs is None else inputs));previous=name
    add('encoder1.conv3x3_s2');add('encoder2.conv3x3_s2')
    for b in range(blocks):
        skip=previous
        add(f'res{b}.expand1x1',output_channels=expansion)
        add(f'res{b}.depthwise3x3',input_channels=expansion,output_channels=expansion)
        add(f'res{b}.project1x1',input_channels=expansion)
        add(f'res{b}.add_relu',inputs=(previous,skip))
    if preproject:
        # This changes the learned function. PW and DW do NOT commute;
        # weights must be retrained, never reordered as an exact optimization.
        add('decoder1.pointwise1x1',input_width=width//4,input_height=height//4,
            output_width=width//4,output_height=height//4)
        add('decoder1.upsample2',input_channels=16,output_channels=16)
        add('decoder1.depthwise3x3',input_channels=16,output_channels=16)
    else:
        add('decoder1.upsample2');add('decoder1.depthwise3x3');add('decoder1.pointwise1x1')
    for name in ('decoder2.upsample2','decoder2.depthwise3x3','decoder2.pointwise1x1',
                 'output.conv3x3','output.s8_to_rgb'):add(name)
    return nodes


def candidates():
    for blocks in (3,2,1,0):
        for expansion in ((48,24) if blocks else (24,)):
            for preproject in (False,True):
                name=f'r{blocks}_e{expansion}_'+('preproject' if preproject else 'retained_decoder')
                yield name,dict(blocks=blocks,expansion=expansion,preproject=preproject)
