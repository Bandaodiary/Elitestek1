"""Verify two trained styles share the same compiled student hardware plan.

This is a packaging/parameter test, NOT an actual runtime style-switch test.
It does not prove CPU upload latency, cache invalidation, or frame ownership.
"""
import argparse
import json
from pathlib import Path

import numpy as np

from r2_trained_style_vectors import bound_candidate


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--left',type=Path,required=True)
    parser.add_argument('--right',type=Path,required=True)
    args=parser.parse_args()
    left,lc,lp=bound_candidate(args.left)
    right,rc,rp=bound_candidate(args.right)
    if lc!=rc or args.left.resolve()==args.right.resolve():
        raise ValueError('two distinct trained runs of the same topology required')
    names=('execution_plan.sv','row_fusion_plan.sv')
    for name in names:
        if (args.left/'plan_fused'/name).read_bytes()!=(args.right/'plan_fused'/name).read_bytes():
            raise ValueError('plans differ: '+name)
    if (len(left.image)!=len(right.image) or left.manifest['transfer_beats128']!=right.manifest['transfer_beats128'] or
        set(left.layers)!=set(right.layers)):
        raise ValueError('different parameter layout or transfer count')
    if left.image==right.image:
        raise ValueError('two named styles actually contain identical parameter images')
    changed=[]
    for name in left.layers:
        if any(a.shape!=b.shape or a.dtype!=b.dtype for a,b in zip(left.layers[name],right.layers[name])):
            raise ValueError('quantized parameter shape/type differs: '+name)
        if any(not np.array_equal(a,b) for a,b in zip(left.layers[name],right.layers[name])):
            changed.append(name)
    if len(changed)!=len(left.layers):
        raise ValueError('unexpected unchanged trained layer')
    print('C36_STYLE_DEPLOYMENT_PAIR_PASS '+json.dumps(dict(
        left=lp,right=rp,identical_compiled_plan_files=list(names),different_trained_layers=len(changed),
        parameter_image_bytes_each=len(left.image),parameter_transaction_beats_each=left.manifest['transfer_beats128'],
        matching_parameter_shapes=True,production_RTL_change_needed_for_topology=False,
        runtime_style_switch_tested=False,style_switch_latency_measured=False,RTL_simulated=False),separators=(',',':')))


if __name__=='__main__':
    main()
