"""Explain endpoint counts without discarding high-saturation test samples.

Every frozen-report image is re-evaluated. Input white/black backgrounds are
separated from newly produced endpoints; neither number is an aesthetic score.
"""
import argparse
import json
import os
from pathlib import Path
import time

import psutil
import torch

from compare_r2_style_models import load_new_qat
from prepare_r2_style_data import save_json
from train_r2_style_student import load_rgb, evaluation_input


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--comparison',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    case=Path(__file__).resolve().parents[1]
    root=args.output.resolve()
    if root.exists() or not root.is_relative_to(case/'outputs'):
        raise ValueError('new case1/outputs audit directory required')
    process=psutil.Process()
    process.cpu_affinity(process.cpu_affinity()[-1:])
    if os.name=='nt':
        process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
    if psutil.virtual_memory().available<8*2**30:
        raise RuntimeError('less than 8 GiB free before audit')
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    report=json.loads(args.comparison.read_text(encoding='utf-8'))
    if report['state']!='complete' or report['split'] not in ('val','test'):
        raise ValueError('completed val/test report required')
    qat_run=Path(report['qat_run'])
    model=load_new_qat(qat_run)
    checkpoint=torch.load(qat_run/'checkpoint_best.pt',map_location='cpu',weights_only=True)
    dataset_manifest=Path(checkpoint['metadata']['dataset_manifest'])
    dataset=json.loads(dataset_manifest.read_text(encoding='utf-8'))
    entries={r['ImageID']:r for r in dataset['images'] if r['split']==report['split']}
    expected={r['image']:r for r in report['images'] if r['model']=='new_INT8_grid'}
    if set(entries)!=set(expected) or len(expected)!=report['images_per_model']:
        raise ValueError('report and dataset partition differ')
    started=time.monotonic()
    rows=[]
    with torch.no_grad():
        for identity,entry in entries.items():
            content=evaluation_input(load_rgb(dataset_manifest.parent/entry['file'])).clamp(0,1).mul(255).round()/255
            output=model(content)
            input_low,input_high=content<=0,content>=1
            output_low,output_high=output<=0,output>=1
            output_endpoint=output_low|output_high
            input_endpoint=input_low|input_high
            same_endpoint=(output_low&input_low)|(output_high&input_high)
            new_endpoint=output_endpoint&~same_endpoint
            middle=(content>16/255)&(content<239/255)
            fraction=lambda value:float(value.float().mean())
            output_fraction=fraction(output_endpoint)
            if abs(output_fraction-expected[identity]['saturation_fraction'])>1e-7:
                raise AssertionError('frozen comparison output not reproduced')
            rows.append(dict(image=identity,file=entry['file'],
                input_endpoint_fraction=fraction(input_endpoint),output_endpoint_fraction=output_fraction,
                preserved_endpoint_fraction=fraction(same_endpoint),new_endpoint_fraction=fraction(new_endpoint),
                midrange_to_endpoint_fraction=fraction(output_endpoint&middle)))
    keys=('input_endpoint_fraction','output_endpoint_fraction','preserved_endpoint_fraction',
          'new_endpoint_fraction','midrange_to_endpoint_fraction')
    result=dict(state='complete',split=report['split'],images=len(rows),
        test_images_read=len(rows) if report['split']=='test' else 0,
        source_comparison=str(args.comparison.resolve()),qat_run=str(qat_run.resolve()),
        mean={key:sum(r[key] for r in rows)/len(rows) for key in keys},
        largest_output_endpoint_samples=sorted(rows,key=lambda r:r['output_endpoint_fraction'],reverse=True)[:2],
        rows=rows,mean_is_per_image=True,samples_excluded=0,model_changed=False,
        definitions=dict(endpoint='per-channel exact RGB code 0 or 255',
            preserved='input and output have the same endpoint in the same channel',
            midrange='input code strictly greater than 16 and strictly less than 239'),
        quality_failure_proven_by_endpoint_alone=False,elapsed_seconds=time.monotonic()-started)
    root.mkdir(parents=True)
    save_json(root/'audit.json',result)
    print('C36_FROZEN_SATURATION_AUDIT_PASS '+json.dumps({k:v for k,v in result.items() if k!='rows'},separators=(',',':')))


if __name__=='__main__':
    main()
