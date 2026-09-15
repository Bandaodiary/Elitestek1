"""C36 trainable float reference for supported candidate DAGs, NOT QAT/export.

Convolution+BN blocks make normalization explicit during training. Deployment
must fold frozen BN, calibrate tied residual scales, and use the existing INT8
rounding/affine contracts. No trained weights are produced by this module.
"""
import torch
from torch import nn
from torch.nn import functional as F

from r2_style_candidates import candidate_nodes
from r2_execution_plan import FRAME,OP_CONV1X1,OP_CONV3X3,OP_DWCONV3X3,OP_RESIDUAL_ADD,OP_UPSAMPLE2,OP_OUTPUT_RGB


class R2StyleStudent(nn.Module):
    def __init__(self,blocks=2,expansion=24,preproject=True):
        super().__init__()
        self.config=dict(blocks=blocks,expansion=expansion,preproject=preproject)
        self.nodes=candidate_nodes(**self.config)
        self.weighted_indices={}
        self.layers=nn.ModuleDict()
        for i,n in enumerate(self.nodes):
            s=n.spec
            if s.opcode not in (OP_CONV1X1,OP_CONV3X3,OP_DWCONV3X3):continue
            self.weighted_indices[s.name]=str(i)
            conv=nn.Conv2d(s.input_channels,s.output_channels,s.kernel,stride=s.stride,
                padding=s.kernel//2,padding_mode='replicate',
                groups=s.input_channels if s.opcode==OP_DWCONV3X3 else 1,bias=False)
            self.layers[str(i)]=nn.Sequential(conv,nn.BatchNorm2d(s.output_channels))

    def forward(self,rgb01,return_stages=False):
        if rgb01.ndim!=4 or rgb01.shape[1]!=3:raise ValueError('NCHW RGB input required')
        h,w=rgb01.shape[-2:]
        if not (4<=w<=640 and 4<=h<=480) or w%4 or h%4:raise ValueError('unsupported frame geometry')
        x=rgb01.clamp(0,1)*255
        x=x+(torch.round(x)-x).detach()
        values={FRAME:(x-128)/128}
        for i,n in enumerate(self.nodes):
            s=n.spec;args=[values[k] for k in n.inputs]
            if s.opcode in (OP_CONV1X1,OP_CONV3X3,OP_DWCONV3X3):value=self.layers[str(i)](args[0])
            elif s.opcode==OP_RESIDUAL_ADD:value=args[0]+args[1]
            elif s.opcode==OP_UPSAMPLE2:value=F.interpolate(args[0],scale_factor=2,mode='nearest')
            elif s.opcode==OP_OUTPUT_RGB:
                value=args[0].clamp(-1,127/128)*128+128
                value=value+(torch.round(value)-value).detach()
                value=value.clamp(0,255)/255
            else:raise ValueError('unsupported graph operator')
            if s.activation==1:value=F.relu(value)
            values[s.name]=value
        result=values[self.nodes[-1].spec.name]
        return (result,values) if return_stages else result


def copy_retained_float_baseline(student,reference):
    if student.config!=dict(blocks=3,expansion=48,preproject=False):raise ValueError('baseline-only copy')
    source={'encoder1.conv3x3_s2':(reference.encoder1,reference.encoder1_norm),
            'encoder2.conv3x3_s2':(reference.encoder2,reference.encoder2_norm),
            'output.conv3x3':(reference.output,reference.output_norm)}
    for b in range(3):
        block=reference.residual[b]
        source.update({f'res{b}.expand1x1':(block.expand,block.expand_norm),
                       f'res{b}.depthwise3x3':(block.depthwise,block.depthwise_norm),
                       f'res{b}.project1x1':(block.project,block.project_norm)})
    for name in ('decoder1','decoder2'):
        block=getattr(reference,name)
        source.update({name+'.depthwise3x3':(block.depthwise,block.depthwise_norm),
                       name+'.pointwise1x1':(block.pointwise,block.pointwise_norm)})
    for name,(conv,bn) in source.items():
        layer=student.layers[student.weighted_indices[name]]
        layer[0].load_state_dict(conv.state_dict());layer[1].load_state_dict(bn.state_dict())
