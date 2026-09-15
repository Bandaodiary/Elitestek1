"""Real-parameter DW/up2 -> PW row-fusion component vectors and oracle.

Only the original low-resolution input and real parameter commands are DUT
inputs. DW/PW golden outputs and physical shadow words are checker-only.
"""
import json
from pathlib import Path
import struct
import tempfile

from r2_tail_tile_contract import (ROOT,np,compile_package,profile_nodes,DEFAULT_ARTIFACT,
                                    tail_pair,_integer_conv,dw_packets,pw_packets)


def hex_file(path,values,digits):
    path.write_text(''.join(f'{value:0{digits}x}\n' for value in values),encoding='ascii')


def parameters(package,name,mode):
    stage=next(s for s in package.manifest['stages'] if s['name']==name)
    result=[]
    for index in range(stage['commands']):
        command=struct.unpack_from('<Q',package.image,stage['offset']+index*8)[0]
        kind=(command>>46)&3;address=(command>>32)&0x3fff;data=command&0xffffffff
        assert kind in (1,2,3)
        result.append((kind<<164)|(mode<<161)|(address<<128)|data)
    return result


def start(mode,size,ci,co,*,capture=False,read=False,top=False,bottom=False,phase=False,row_map=36):
    # Row start configuration is separate from the partition lease command.
    config=size|(ci<<14)|(co<<20)|(int(capture)<<26)|(int(top)<<27)|(int(bottom)<<28)|\
        (int(phase)<<29)|(int(capture)<<30)|(int(read)<<31)|(row_map<<32)
    return (4<<164)|(mode<<161)|config


def packets(values,mode):
    return [(mode<<70)|(p['tag']<<54)|(p['mask']<<48)|p['data'] for p in values]


def vectors(folder,width,height,seed=35001):
    folder=Path(folder)
    assert 2<=width<=320 and width%2==0 and 1<=height<=4
    package=compile_package(profile_nodes('microstyle24'),DEFAULT_ARTIFACT)
    _,dw_name,pw_name=tail_pair(profile_nodes('microstyle24'))
    dw=package.layers[dw_name];pw=package.layers[pw_name]
    random=np.random.default_rng(seed+width*13+height)
    source=random.integers(-128,128,(height,width,16),dtype=np.int16).astype(np.int8)
    up=np.repeat(np.repeat(source,2,axis=0),2,axis=1)
    dw_golden=_integer_conv(up,*dw,1,16,1)
    pw_golden=_integer_conv(dw_golden,*pw,1,1,1)
    # Pick a real bias-write corruption that changes an observed first-row
    # result. This is used ONLY for an explicit negative simulation.
    bad_bias_channel=None
    for channel in range(16):
        changed_bias=dw[1].copy();changed_bias[channel]=1<<30
        changed=_integer_conv(up,dw[0],changed_bias,dw[2],dw[3],1,16,1)
        if np.any(changed[0]!=dw_golden[0]):bad_bias_channel=channel;break
    assert bad_bias_channel is not None,'negative bias corruption is not observable'
    dw_commands=parameters(package,dw_name,2);pw_commands=parameters(package,pw_name,0)
    assert (len(dw_commands),len(pw_commands))==(96,48)
    output_width=width*2;base=output_width//4;end=base+output_width//2
    commands=[6<<164,(6<<164)|1|(base<<1)|(end<<10)]
    expected=[];shadow=[];bulk=reloads=0
    for y in range(height*2):
        center=y//2;mapping=tuple((center+k)%3 for k in range(3))
        packed_map=sum(bank<<(k*2) for k,bank in enumerate(mapping))
        commands.extend(dw_commands);reloads+=len(dw_commands)
        # Preserve physical DW source rows across the PW phase. Adjacent up2
        # output rows reuse exactly the same three actual cache contents.
        if y%2==0:
            for logical,physical in enumerate(mapping):
                source_y=min(height-1,max(0,center+logical-1))
                for pair in range(width//2):
                    for group in range(2):
                        values=source[source_y,pair*2:pair*2+2,group*8:group*8+8].reshape(-1)
                        data=int.from_bytes(values.tobytes(),'little')
                        commands.append((5<<164)|(2<<161)|(physical<<144)|(2<<141)|(group<<138)|(pair<<128)|data)
                        bulk+=1
        commands.append(start(2,width,16,16,capture=True,top=center==0,bottom=center==height-1,
                              phase=bool(y%2),row_map=packed_map))
        expected.extend(packets(dw_packets(dw_golden[y],0),2))
        for pair in range(output_width//2):
            pixels=dw_golden[y,pair*2:pair*2+2].reshape(-1)
            shadow.extend(int.from_bytes(pixels[bank*4:bank*4+4].tobytes(),'little') for bank in range(8))
        commands.append((7<<164)|output_width)
        commands.extend(pw_commands);reloads+=len(pw_commands)
        commands.append(start(0,output_width,16,8,read=True,row_map=packed_map))
        expected.extend(packets(pw_packets(pw_golden[y],0),0))
    commands.append(6<<164)
    meta=dict(source_width=width,source_height=height,width=output_width,height=height*2,
        commands=len(commands),packets=len(expected),shadow_words=len(shadow),operations=height*4,
        DW_rows=height*2,PW_rows=height*2,bulk_writes=bulk,parameter_writes=reloads,
        same_cache_pairs=height,parameters_per_pair=144,actual_model='microstyle24_starry_functional',
        bad_bias_channel=bad_bias_channel,
        includes_real_DW_and_PW=True,actual_AXI=False,full_graph=False,native_fps_claim=False)
    assert meta['shadow_words']==output_width*4*height*2
    assert bulk==height*3*width and reloads==height*2*144
    assert len(expected)==height*2*(output_width*3+(output_width*8+5)//6)
    assert max(commands).bit_length()<=168 and max(expected).bit_length()<=73
    assert all(len(values)<32768 for values in (commands,expected,shadow))
    hex_file(folder/'commands.mem',commands,42);hex_file(folder/'expected.mem',expected,19)
    hex_file(folder/'shadow.mem',shadow,8)
    (folder/'metadata.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
    return meta


def selftest():
    totals=dict(commands=0,packets=0,shadow_words=0,operations=0,bulk_writes=0,parameter_writes=0)
    with tempfile.TemporaryDirectory(prefix='c1_r2_shadow_math_',dir=ROOT/'sim') as td:
        for width,height in ((2,2),(6,3),(16,3),(320,2)):
            meta=vectors(td,width,height)
            for key in totals:totals[key]+=meta[key]
            # Directly inspect each just-created vector file/count and decode
            # all parameter header fields, not a digest/checksum comparison.
            records=[int(line,16) for line in (Path(td)/'commands.mem').read_text().splitlines()]
            assert len(records)==meta['commands']
            loads=[record for record in records if record>>164 in (1,2,3)]
            assert len(loads)==meta['parameter_writes']
            assert all(((record>>161)&7) in (0,2) for record in loads)
            assert len((Path(td)/'expected.mem').read_text().splitlines())==meta['packets']
            assert len((Path(td)/'shadow.mem').read_text().splitlines())==meta['shadow_words']
    print('C35_SHADOW_ENGINE_VECTOR_MODEL_PASS '+json.dumps(dict(configurations=4,totals=totals,
        original_parameters=True,checker_only_intermediates=True,temporary_vectors_removed=True,
        RTL_compiled=False,RTL_simulated=False,native_fps_claim=False),separators=(',',':')))


if __name__=='__main__':selftest()
