"""Small generated-fixture seam checks; no RTL execution or FPS claim."""
import argparse
import json
from pathlib import Path

from r2_trained_style_vectors import ROOT,bound_candidate,build_vectors
from r2_fused_camera_vectors import vectors as retained_vectors
from r2_plan_package import compile_package,profile_nodes


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--qat-run',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    root=args.output.resolve()
    if root.exists() or not root.is_relative_to(ROOT/'outputs'):
        raise ValueError('new outputs directory required')
    root.mkdir()
    old=root/'old';old.mkdir()
    package=compile_package(profile_nodes('microstyle24'))
    before=retained_vectors(old,8,8,'microstyle24',package)
    after=build_vectors(root/'same_graph',8,8,package,
                        dict(blocks=3,expansion=48,preproject=False),dict(test_only=True))
    names=['owners.mem','views.mem','parameters.mem','expected.mem','dw_expected.mem',
           'input0.mem','input1.mem','source0.mem','source1.mem','fusion_plan.sv',
           'package/execution_plan.sv','package/parameters.bin']
    for name in names:
        assert (old/name).read_bytes()==(root/'same_graph'/name).read_bytes(), 'changed existing fixture: '+name
    for key in ('stage_count','rgb_stage','dw_stage','pw_stage','parameter_words','input_words','expected_words','dw_packets','frames','sources'):
        assert before[key]==after[key], 'changed fixture metadata: '+key
    package,config,proof=bound_candidate(args.qat_run)
    small=build_vectors(root/'trained',8,8,package,config,proof)
    assert small['stage_count']==18 and (small['dw_stage'],small['pw_stage'])==(14,15)
    assert small['parameter_words']==package.manifest['transfer_beats128']
    assert small['dw_packets']==6*8*8
    assert proof['all_exported_arrays_equal_checkpoint']
    assert small['expected_words']!=before['expected_words'], 'new traffic did not change'
    print('C36_TRAINED_VECTOR_SEAM_PASS '+json.dumps(dict(old_fixture_files_identical=len(names),
        trained_stages=small['stage_count'],trained_parameter_words=small['parameter_words'],
        trained_expected_words=small['expected_words'],checkpoint_arrays_matched=True,
        new_RTL_simulated=False,private_test_output=str(root))))


if __name__=='__main__':
    main()
