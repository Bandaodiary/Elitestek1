"""Export the trained R1 arena into the C6 graph parameter command image.

No retraining, checksums, or descriptor mutation. Binary image is directly
uploadable to parameter_base; original artifact remains unchanged.
"""
from __future__ import annotations
import argparse,json,struct,tempfile
from pathlib import Path
from generate_microstyle_engine_bitexact_vectors import STAGE_NAMES
from microstyle_quant import _read_layer_arrays
from run_r2_array_probe import ROOT
from microstyle_workload import build_layout


def build(artifact):
    manifest=json.loads((artifact/'manifest.json').read_text());arena=(artifact/manifest['parameter_file']).read_bytes()
    lookup={r['name']:r for r in manifest['quantized_layers']}
    image=bytearray(22*8192);stages=[];descriptors,_=build_layout()
    for stage,name in enumerate(STAGE_NAMES):
        if stage in (5,9,13,14,17,21):continue
        row=lookup[name];weight,bias,mult,shift=_read_layer_arrays(arena,row)
        depthwise=stage in (3,7,11,15,18);commands=[]
        d=descriptors[stage]
        if weight.shape!=(d.output_channels,1 if depthwise else d.input_channels,d.kernel_height,d.kernel_width):raise ValueError('artifact topology differs from frozen graph')
        def emit(kind,address,value):
            if not 1<=kind<=3 or not 0<=address<16384:raise ValueError('invalid SRAM command')
            commands.append((kind<<46)|(address<<32)|(int(value)&0xffffffff))
        for co in range(weight.shape[0]):
            terms=[int(weight[co,ci,ky,kx]) for ky in range(weight.shape[2]) for kx in range(weight.shape[3])
                   for ci in range(1 if depthwise else weight.shape[1])]
            k=(len(terms)+15)//16
            if k>8 or co>=48:raise ValueError('operator parameter bank capacity')
            # Padding ignored by RTL, retained nonzero to match the audit
            # fixture; changing this constant does not change the model.
            terms += [117]*(k*16-len(terms))
            for beat in range(k):
                for word in range(4):
                    address=(co&7)*256+(co//8)*32+beat*4+word
                    value=sum((terms[beat*16+word*4+i]&255)<<(i*8) for i in range(4))
                    emit(1,address,value)
            if not -(1<<17)<=int(mult[co])<(1<<17) or not 0<=int(shift[co])<=47 or int(row['activation']) not in (0,1):raise ValueError('invalid affine')
            emit(2,co,bias[co]);emit(3,co,(int(row['activation'])<<24)|(int(shift[co])<<18)|(int(mult[co])&0x3ffff))
        if len(commands)*8>8192 or len(commands)%2:raise ValueError('invalid stage command slot')
        offset=stage*8192
        for i,command in enumerate(commands):struct.pack_into('<Q',image,offset+i*8,command)
        stages.append(dict(stage=stage,name=name,offset=offset,commands=len(commands),transfer_beats128=len(commands)//2))
    info=dict(format='c1_r2_graph_parameter_commands_v1',image_bytes=len(image),stage_slot_bytes=8192,
              active_bytes=sum(s['commands']*8 for s in stages),transfer_beats128=sum(s['transfer_beats128'] for s in stages),
              source_artifact=artifact.name,source_parameter_file=manifest['parameter_file'],
              command='little-endian uint64: reserved[63:48]=0, kind[47:46], SRAM address[45:32], data[31:0]',
              loading='upload entire image at parameter_base; FPGA reads only listed active prefixes',
              stages=stages,compatible_with_r1_parameter_abi=False)
    return bytes(image),info


def audit_fixture(image,info,artifact):
    # Separately implemented existing graph test generator is the actual
    # source used in the completed RTL simulation, not this exporter.
    from run_r2_graph_probe import vectors
    with tempfile.TemporaryDirectory(prefix='c1_r2_graph_export_',dir=ROOT/'sim') as tmp:
        folder=Path(tmp);meta=vectors(folder,4,4,artifact=artifact)
        words=[int(s,16) for s in (folder/'parameters.mem').read_text().splitlines()]
        if len(words)!=meta['parameter_words'] or len(words)!=info['transfer_beats128']:raise ValueError('wrong active image length')
        for record in words:
            offset=(record>>128)-5*(1<<23)
            if int.from_bytes(image[offset:offset+16],'little')!=record&((1<<128)-1):raise ValueError(f'fixture mismatch at {offset}')
    return len(words)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--artifact',type=Path,default=ROOT/'model/microstyle24_starry_functional')
    parser.add_argument('--output',type=Path,default=ROOT/'model/r2_microstyle24_starry_functional');parser.add_argument('--verify',action='store_true');args=parser.parse_args()
    image,info=build(args.artifact)
    if args.verify:
        if (args.output/'parameters.bin').read_bytes()!=image or json.loads((args.output/'manifest.json').read_text())!=info:raise ValueError('export differs from trained source')
    else:
        if any((args.output/name).exists() for name in ('parameters.bin','manifest.json')):raise FileExistsError('export exists; use --verify or a new directory')
        args.output.mkdir(parents=True,exist_ok=True)
        (args.output/'parameters.bin').write_bytes(image);(args.output/'manifest.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8')
    compared=audit_fixture(image,info,args.artifact)
    print(f'C1_R2_GRAPH_PARAMETER_EXPORT_PASS image_bytes={len(image)} active_bytes={info["active_bytes"]} compared_words128={compared} trained_source_unchanged=1 temporary_fixture_removed=1')


if __name__=='__main__':main()
