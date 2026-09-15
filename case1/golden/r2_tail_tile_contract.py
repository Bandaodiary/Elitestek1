"""C35 mathematical/packet contract for SAME nearest2x DW16 -> PW16x8.

Independent candidate only: no retained RTL/plan edits and no FPGA tools.
Keeps BOTH exported INT8 requantization/activation boundaries. Testbench-side
arrays may collect a whole result; the candidate producer yields one tile.
"""
from __future__ import annotations
import os
for _thread_variable in ('OMP_NUM_THREADS','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS','NUMEXPR_NUM_THREADS'):
    os.environ[_thread_variable]='1'
import json
from dataclasses import replace
from pathlib import Path
import struct
import sys

import numpy as np

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'model'))
from r2_plan_package import compile_package,profile_nodes,DEFAULT_ARTIFACT
from r2_execution_plan import Node,OP_DWCONV3X3,OP_CONV1X1,OP_UPSAMPLE2
from microstyle_quant import _integer_conv,integer_infer_rgb


def tail_pair(nodes):
    """Find an exclusive semantic pattern, not hard-coded stage numbers."""
    by_name={node.spec.name:node for node in nodes}
    users={name:[] for name in by_name}
    for node in nodes:
        for source in node.inputs:
            if source in users:users[source].append(node.spec.name)
    found=[]
    for node in nodes:
        s=node.spec
        if s.opcode!=OP_DWCONV3X3 or (s.input_channels,s.output_channels,s.kernel,s.stride)!=(16,16,3,1):continue
        if len(users[s.name])!=1 or len(node.inputs)!=1:continue
        view=by_name.get(node.inputs[0]);pw=by_name[users[s.name][0]]
        if view is None or view.spec.opcode!=OP_UPSAMPLE2 or len(users[view.spec.name])!=1:continue
        p=pw.spec
        if p.opcode!=OP_CONV1X1 or (p.input_channels,p.output_channels,p.kernel,p.stride)!=(16,8,1,1):continue
        if (p.input_width,p.input_height)!=(s.output_width,s.output_height):continue
        if s.activation not in (0,1) or p.activation not in (0,1):continue
        found.append((view.inputs[0],s.name,p.name))
    if len(found)!=1:raise ValueError('requires exactly one exclusive up2/DW16/PW8 pattern')
    return found[0]


def requant(acc,mult,shift,activation):
    """Independent integer arithmetic, with the retained signed32 contract."""
    acc=np.asarray(acc,dtype=np.int64);mult=np.asarray(mult,dtype=np.int64);shift=np.asarray(shift,dtype=np.int64)
    if np.any(acc<-(1<<31)) or np.any(acc>(1<<31)-1):raise OverflowError('signed32 accumulator')
    if np.any(mult<-(1<<17)) or np.any(mult>=(1<<17)) or np.any(shift<0) or np.any(shift>47):raise ValueError('affine contract')
    if acc.shape[-1]!=len(mult) or len(mult)!=len(shift) or activation not in (0,1):raise ValueError('quantization shape/activation')
    product=acc*mult
    denominator=np.left_shift(np.int64(1),shift)
    half=np.where(shift==0,0,denominator//2)
    magnitude=(np.abs(product)+half)//denominator
    signed=np.where(product<0,-magnitude,magnitude)
    return np.clip(signed,0 if activation else -128,127).astype(np.int8)


def tile_configuration(tile_pixels):
    # DW emits pairs; the current PW writer advances SIX scalar positions on
    # every packet. Each nonfinal tile must contain a whole number of both.
    if not isinstance(tile_pixels,int) or not 6<=tile_pixels<=48 or tile_pixels%6:
        raise ValueError('tile must be a multiple of 6 pixels, in 6..48')
    packets=tile_pixels*3
    bank_depth=1<<(((packets+1)//2-1).bit_length())
    return dict(tile_pixels=tile_pixels,logical_dw_bytes=tile_pixels*16,dw_packets=packets,
                two_packet_bank_bytes=2*bank_depth*6,bank_depth=bank_depth,
                physical_RAM_blocks_measured=False)


def fused_tiles(source,dw,pw,dw_activation=1,pw_activation=1,tile_pixels=24):
    tile_configuration(tile_pixels)
    if source.dtype!=np.int8 or source.ndim!=3 or source.shape[2]!=16:raise ValueError('input must be HWC INT8/C16')
    if not 1<=source.shape[1]<=512 or not 1<=source.shape[0]<=240:raise ValueError('source geometry')
    if dw[0].shape!=(16,1,3,3) or pw[0].shape!=(8,16,1,1):raise ValueError('kernel dimensions')
    height,width=source.shape[0]*2,source.shape[1]*2
    for y in range(height):
        for x in range(0,width,tile_pixels):
            count=min(tile_pixels,width-x);columns=np.arange(x,x+count)
            accumulator=np.broadcast_to(np.asarray(dw[1],dtype=np.int64),(count,16)).copy()
            for ky in range(3):
                sy=min(max(y+ky-1,0),height-1)//2
                for kx in range(3):
                    sx=np.clip(columns+kx-1,0,width-1)//2
                    accumulator+=source[sy,sx,:].astype(np.int64)*dw[0][:,0,ky,kx].astype(np.int64)
            # Do not combine this rounding, clipping or ReLU with PW affine.
            middle=requant(accumulator,dw[2],dw[3],dw_activation)
            output_acc=middle.astype(np.int64)@pw[0][:,:,0,0].astype(np.int64).T+pw[1]
            output=requant(output_acc,pw[2],pw[3],pw_activation)
            yield y,x,middle,output


def dw_packets(tile,x_base):
    if tile.dtype!=np.int8 or tile.ndim!=2 or tile.shape[1]!=16 or len(tile)%2:raise ValueError('DW pair geometry')
    packets=[]
    for pair in range(0,len(tile),2):
        for group in range(2):
            for phase in range(3):
                mask=0;data=0
                for lane in range(6):
                    flat=phase*6+lane
                    # Poison invalid bytes: downstream must actually discard them.
                    byte=0xa5
                    if flat<16:
                        byte=int(tile[pair+flat//8,group*8+flat%8])&255;mask|=1<<lane
                    data|=byte<<(lane*8)
                packets.append(dict(tag=((x_base+pair)<<5)|(group<<2)|phase,mask=mask,data=data))
    return packets


def pairs_from_banks(packets,pixels,x_base):
    if len(packets)!=pixels*3 or pixels%2:raise ValueError('packet count')
    banks=[[],[]]
    for index,packet in enumerate(packets):
        pair,phase6=divmod(index,6);group,phase=divmod(phase6,3)
        if packet['tag']!=((x_base+2*pair)<<5)|(group<<2)|phase:raise ValueError('DW packet tag/order')
        if packet['mask']!=(15 if phase==2 else 63):raise ValueError('DW packet mask')
        if not 0<=packet['data']<1<<48:raise ValueError('packet width')
        banks[index%2].append(packet['data'])
    output=[]
    for pair in range(pixels//2):
        a,b,c=(banks[0][pair*3+i] for i in range(3))
        d,e,f=(banks[1][pair*3+i] for i in range(3))
        group0=a|(d<<48)|((b&0xffffffff)<<96)
        group1=e|(c<<48)|((f&0xffffffff)<<96)
        low_mask=(1<<64)-1
        packed=(group0&low_mask)|((group1&low_mask)<<64)|((group0>>64)<<128)|((group1>>64)<<192)
        output.append(np.frombuffer(packed.to_bytes(32,'little'),dtype=np.int8).reshape(2,16))
    return np.concatenate(output,axis=0)


def pw_packets(tile,x_base):
    flat=tile.reshape(-1)
    return [dict(tag=x_base*8+offset,mask=(1<<min(6,len(flat)-offset))-1,
                 data=sum((int(value)&255)<<(lane*8) for lane,value in enumerate(flat[offset:offset+6])))
            for offset in range(0,len(flat),6)]


def check_pw_row(packets,expected):
    # Mirror the writer's scalar advancement, not the encoder's coordinate tags.
    scalar=0;bytes_out=[]
    for index,packet in enumerate(packets):
        if packet['tag']!=scalar:raise ValueError('PW tile broke continuous six-scalar ABI')
        expected_mask=(1<<min(6,max(0,expected.size-scalar)))-1
        if packet['mask']!=expected_mask:raise ValueError('PW mask does not match row coordinates')
        if packet['mask']!=63 and index+1!=len(packets):raise ValueError('non-final partial PW packet')
        for lane in range(6):
            if packet['mask']&(1<<lane):bytes_out.append((packet['data']>>(8*lane))&255)
        scalar+=6
    if bytes(bytes_out)!=expected.tobytes():raise ValueError('PW byte reconstruction')


def collect_checked(source,dw,pw,da,pa,tile_pixels):
    shape=(source.shape[0]*2,source.shape[1]*2)
    # These whole-frame arrays and packet lists belong to the CHECKER only.
    middle=np.empty((*shape,16),dtype=np.int8);output=np.empty((*shape,8),dtype=np.int8)
    rows=[[] for _ in range(shape[0])];tile_count=packet_count=0
    for y,x,m,o in fused_tiles(source,dw,pw,da,pa,tile_pixels):
        packed=dw_packets(m,x);restored=pairs_from_banks(packed,len(m),x)
        assert np.array_equal(restored,m),'bank reassembly changed DW tensor'
        observed_pw=_integer_conv(restored[None,...],*pw,1,1,pa)[0]
        assert np.array_equal(observed_pw,o),'PW consumed wrong DW values'
        middle[y,x:x+len(m)]=m;output[y,x:x+len(o)]=o
        rows[y].extend(pw_packets(o,x));tile_count+=1;packet_count+=len(packed)
    for y,packets in enumerate(rows):check_pw_row(packets,output[y])
    return middle,output,tile_count,packet_count


def traffic_contract(package):
    _,dw_name,pw_name=tail_pair(profile_nodes('microstyle24'))
    steps={s['name']:s for s in package.manifest['steps']}
    parameter_beats=steps[dw_name]['parameter_beats']+steps[pw_name]['parameter_beats']
    assert parameter_beats==72
    saved=2*640*480*16;rows=[]
    for tile in (6,12,24,48):
        tiles=((640+tile-1)//tile)*480
        naive_extra=(tiles-1)*parameter_beats*16
        rows.append(dict(**tile_configuration(tile),native_tiles=tiles,
            naive_extra_parameter_bytes=naive_extra,
            naive_net_bytes_saved=saved-naive_extra))
    return dict(intermediate_roundtrip_bytes=saved,parameter_beats_per_pair=parameter_beats,
                co_resident_parameters_required=True,co_resident_parameter_bytes=parameter_beats*16,
                # Logical output-channel allocation only; RTL address routing/ports still unimplemented.
                proposed_dw_parameter_channels=[0,15],proposed_pw_parameter_channels=[16,23],
                shared_parameter_channels_available=48,tiles=rows,
                cache_alias_requires_new_PW_feature_path=True,RTL_implemented=False,
                FPGA_resource_measured=False,native_fps_claim=False)


def resident_parameters(package,pw_channel_base=16):
    """Remap real command bytes into disjoint existing weight/affine slots.

    This is a logical address check, not a simulation of RAM primitive timing
    or of the future joint feeder's read arbitration.
    """
    _,dw_name,pw_name=tail_pair(profile_nodes('microstyle24'))
    metadata={row['name']:row for row in package.manifest['stages']}
    locations={};boundaries={};commands=[]
    for name,base in ((dw_name,0),(pw_name,pw_channel_base)):
        weight,bias,mult,shift=package.layers[name]
        channels=weight.shape[0];stage=metadata[name]
        if not (0<=base and base+channels<=48):raise ValueError('resident parameter channel range')
        for index in range(stage['commands']):
            cmd=struct.unpack_from('<Q',package.image,stage['offset']+index*8)[0]
            kind=(cmd>>46)&3;address=(cmd>>32)&0x3fff;data=cmd&0xffffffff
            if kind==1:
                co=((address>>5)&7)*8+((address>>8)&7)
                if co>=channels or (address&31)>=4:raise ValueError('unexpected tail weight command')
                channel=co+base
                mapped=((channel&7)<<8)|((channel//8)<<5)|(address&31)
            elif kind in (2,3):
                if address>=channels:raise ValueError('unexpected affine command')
                channel=address+base;mapped=channel
            else:raise ValueError('unexpected parameter kind')
            key=kind,mapped
            if key in locations:raise ValueError('DW/PW resident parameter collision')
            if mapped>=2048 or channel>=48:raise ValueError('resident address capacity')
            locations[key]=data;commands.append((kind,mapped,data))
        boundaries[name]=(base,base+channels-1)
    checked=0
    for name,base in ((dw_name,0),(pw_name,pw_channel_base)):
        weight,bias,mult,shift=package.layers[name]
        for co in range(weight.shape[0]):
            channel=base+co
            # Mirror documented lane_addr, then four 32-bit slices. Six RAM
            # replicas have the same load image but independent lane addresses.
            lane_address=((channel&7)<<6)|((channel//8)<<3)
            expected=weight[co].reshape(-1).astype(np.int8).tobytes()
            expected+=bytes([117])*(16-len(expected))
            for lane in range(6):
                observed=b''.join(locations[1,lane_address*4+word].to_bytes(4,'little') for word in range(4))
                assert observed==expected;checked+=16
            observed_bias=locations[2,channel]
            if observed_bias&(1<<31):observed_bias-=1<<32
            assert observed_bias==int(bias[co])
            affine=locations[3,channel]
            signed_multiplier=affine&0x3ffff
            if signed_multiplier&(1<<17):signed_multiplier-=1<<18
            assert signed_multiplier==int(mult[co]) and ((affine>>18)&63)==int(shift[co])
            assert ((affine>>24)&1)==1
            # Bank/group selection is identical for DW and PW after remap.
            assert channel%8<8 and channel//8<6
    assert len(commands)==144 and len({a for k,a in locations if k==1})==96
    return dict(commands=len(commands),weight_word_locations=96,coefficient_slots=24,
                replica_weight_bytes_checked=checked,channel_ranges=boundaries,
                RTL_RAM_executed=False,read_arbitration_verified=False,physical_resource_claim=False)


def main():
    package=compile_package(profile_nodes('microstyle24'));root,dn,pn=tail_pair(profile_nodes('microstyle24'))
    dw,pw=package.layers[dn],package.layers[pn]
    assert tail_pair(profile_nodes('drop_res1'))==(root,dn,pn)
    nodes=profile_nodes('microstyle24')
    names={node.spec.name:f'node_{i}' for i,node in enumerate(nodes)}
    renamed=[Node(replace(node.spec,name=names[node.spec.name]),tuple(names.get(s,s) for s in node.inputs)) for node in nodes]
    assert tail_pair(renamed)==tuple(names[s] for s in (root,dn,pn))
    rng=np.random.default_rng(35);cases=tiles=packets=scalar_count=0
    for height,width in ((1,1),(2,3),(3,8),(4,16),(2,320)):
        source=rng.integers(-128,128,(height,width,16),dtype=np.int16).astype(np.int8)
        up=np.repeat(np.repeat(source,2,axis=0),2,axis=1)
        reference_dw=_integer_conv(up,*dw,1,16,1)
        reference_pw=_integer_conv(reference_dw,*pw,1,1,1)
        for tile in (6,12,24,48):
            middle,output,tc,pc=collect_checked(source,dw,pw,1,1,tile)
            assert np.array_equal(middle,reference_dw) and np.array_equal(output,reference_pw)
            cases+=1;tiles+=tc;packets+=pc;scalar_count+=middle.size+output.size
    full_frames=0
    for width in (12,32):
        rgb=rng.integers(0,256,(width,width,3),dtype=np.uint8)
        expected,layers=integer_infer_rgb(rgb,DEFAULT_ARTIFACT,collect=True)
        middle,output,tc,pc=collect_checked(layers[root],dw,pw,1,1,24)
        assert np.array_equal(middle,layers[dn]) and np.array_equal(output,layers[pn])
        actual=_integer_conv(output,*package.layers['output.conv3x3'],1,1,0)
        actual=np.clip(actual.astype(np.int16)+128,0,255).astype(np.uint8)
        assert np.array_equal(actual,expected)
        full_frames+=1;tiles+=tc;packets+=pc
    # Quantization must not collapse: 1 * 1/2 rounds to 1, then *2 -> 2;
    # one combined *1 gives 1. Also exercise negative halfway values.
    halfway=requant(np.array([[-3],[-1],[0],[1],[3]]),np.array([1]),np.array([1]),0)
    assert halfway[:,0].tolist()==[-2,-1,0,1,2]
    first=requant(np.ones((1,16),dtype=np.int64),np.ones(16,dtype=np.int64),np.ones(16,dtype=np.int64),0)
    assert int(first[0,0])*2==2 and int(requant(np.array([[2]]),np.array([1]),np.array([1]),0)[0,0])==1
    # Reordering/partial writes must be rejected even if concatenated pixel
    # values look right. Eight-pixel tiles violate the existing PW writer ABI.
    rejected=0
    dummy=np.arange(16*16,dtype=np.int16).astype(np.int8).reshape(16,16)
    valid=dw_packets(dummy,0)
    invalid=[valid[:-1],[dict(p) for p in valid],[dict(p) for p in valid]]
    invalid[1][4]['tag']^=4;invalid[2][2]['mask']=63
    for bad in invalid:
        try:pairs_from_banks(bad,16,0)
        except ValueError:rejected+=1
        else:raise AssertionError('bad DW packets accepted')
    output=np.arange(16*8,dtype=np.int16).astype(np.int8).reshape(16,8)
    bad=pw_packets(output[:8],0)+pw_packets(output[8:],8)
    try:check_pw_row(bad,output)
    except ValueError:rejected+=1
    else:raise AssertionError('misaligned PW tile accepted')
    for tile in (0,2,8,16,32,54):
        try:tile_configuration(tile)
        except ValueError:rejected+=1
        else:raise AssertionError('unsupported tile accepted')
    resident=resident_parameters(package)
    extra=next(node for node in nodes if node.spec.name==pn)
    fanout=nodes+[Node(replace(extra.spec,name='other_consumer'),extra.inputs)]
    try:tail_pair(fanout)
    except ValueError:rejected+=1
    else:raise AssertionError('DW fanout fused without preserving other consumer')
    try:resident_parameters(package,pw_channel_base=0)
    except ValueError:rejected+=1
    else:raise AssertionError('colliding resident weights accepted')
    for base in (-8,-1,47,48):
        try:resident_parameters(package,pw_channel_base=base)
        except ValueError:rejected+=1
        else:raise AssertionError('out-of-capacity parameter channels accepted')
    print('C35_TAIL_TILE_GOLDEN_PASS '+json.dumps(dict(component_cases=cases,full_model_frames=full_frames,
        checked_tiles=tiles,DW_packets=packets,component_scalars=scalar_count,rejected=rejected,
        retained_intermediate_quantization=True,nonzero_padding_ignored=True,
        unchanged_model=True,graph_rename_and_drop_block_supported=True,
        RTL_compiled=False,RTL_simulated=False),separators=(',',':')))
    print('C35_TAIL_TILE_TRAFFIC_CONTRACT '+json.dumps(traffic_contract(package),separators=(',',':')))
    print('C35_TAIL_RESIDENT_PARAMETER_PASS '+json.dumps(resident,separators=(',',':')))


if __name__=='__main__':main()
