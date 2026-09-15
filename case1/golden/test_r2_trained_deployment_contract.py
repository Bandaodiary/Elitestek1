"""Saved deployment positives plus in-memory faults; never edit model files."""
import json
from pathlib import Path
from unittest.mock import patch

import psutil
process=psutil.Process()
process.cpu_affinity(process.cpu_affinity()[-1:])
process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)

from r2_trained_style_vectors import ROOT,bound_candidate
from r2_trained_deployment_contract import verify_saved_deployment


def main():
    names=('c36_qat_b_starry_equalized_20260915a','c36_qat_b_mosaic_equalized_20260915a',
           'c36_qat_b_mosaic_stable_20260915a')
    verified=[];packages=[]
    for name in names:
        root=ROOT/'outputs'/name
        package,config,_=bound_candidate(root)
        verified.append(dict(model=name,**verify_saved_deployment(root,package,config)))
        packages.append((root,package,config))
    root,package,config=packages[-1]
    image=root/'plan_unfused/parameters.bin'
    read_bytes=Path.read_bytes;read_text=Path.read_text
    original=image.read_bytes()
    active=bytearray(original);active[0]^=1
    padding=bytearray(original);padding[-1]^=1
    manifest_path=root/'plan_fused/manifest.json'
    manifest=json.loads(manifest_path.read_text(encoding='utf-8-sig'))
    bad_reference=dict(manifest);bad_reference['parameter_image']='../../wrong/parameters.bin'
    bad_pair=dict(manifest);bad_pair['pairs']=[[12,13]]
    corruptions=(
        ('active_byte',image,bytes(active),'bytes'),
        ('unused_padding_byte',image,bytes(padding),'bytes'),
        ('different_trained_style',image,packages[1][1].image,'bytes'),
        ('truncated_image',image,original[:-1],'bytes'),
        ('unfused_ROM_in_fused_slot',root/'plan_fused/execution_plan.sv',
            (root/'plan_unfused/execution_plan.sv').read_text(encoding='utf-8-sig'),'text'),
        ('wrong_image_reference',manifest_path,json.dumps(bad_reference),'text'),
        ('wrong_fusion_pair',manifest_path,json.dumps(bad_pair),'text'),
    )
    rejected=[]
    for label,target,bad,kind in corruptions:
        source=read_bytes(target) if kind=='bytes' else read_text(target,encoding='utf-8-sig')
        if source==bad:
            raise AssertionError('ineffective corruption: '+label)
        def altered_bytes(path,*args,**kwargs):
            return bad if kind=='bytes' and path.resolve()==target.resolve() else read_bytes(path,*args,**kwargs)
        def altered_text(path,*args,**kwargs):
            return bad if kind=='text' and path.resolve()==target.resolve() else read_text(path,*args,**kwargs)
        with patch.object(Path,'read_bytes',altered_bytes),patch.object(Path,'read_text',altered_text):
            try:
                verify_saved_deployment(root,package,config)
            except (ValueError,AssertionError):
                rejected.append(label)
            else:
                raise AssertionError('corrupted deployment accepted: '+label)
    # Re-read the real files after faults are removed; no source mutation used.
    for root,package,config in packages:
        verify_saved_deployment(root,package,config)
    print('C36_SAVED_DEPLOYMENT_CONTRACT_PASS '+json.dumps(dict(models=verified,
        corruptions_rejected=rejected,model_files_modified=0,temporary_directories_created=0,
        runtime_style_switch_tested=False,new_RTL_execution=False),separators=(',',':')))


if __name__=='__main__':
    main()
