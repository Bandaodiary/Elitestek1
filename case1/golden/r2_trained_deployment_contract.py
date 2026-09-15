"""Bind saved GUI/deployment files to the actual trained parameter compiler.

Direct content comparison only. This is not a runtime model-switch test.
"""
from dataclasses import asdict
import json
from pathlib import Path

from r2_plan_package import verify
from r2_row_fused_plan import fused_steps,fusion_sv
from r2_execution_plan import render_sv
from r2_style_candidates import candidate_nodes


def verify_saved_deployment(root,package,config):
    root=Path(root).resolve()
    # Include the actual saved sparse DDR image, its unfused ROM and metadata.
    # Checking only a freshly rebuilt image does not verify the file a user loads.
    verify(package,root/'plan_unfused')
    steps,pairs=fused_steps(candidate_nodes(**config))
    for filename,expected in (('execution_plan.sv',render_sv(steps)),
                               ('row_fusion_plan.sv',fusion_sv(steps,pairs))):
        if (root/'plan_fused'/filename).read_text(encoding='utf-8-sig').strip()!=expected.strip():
            raise ValueError('saved generated plan differs from trained topology: '+filename)
    manifest=json.loads((root/'plan_fused/manifest.json').read_text(encoding='utf-8-sig'))
    expected=json.loads(json.dumps(dict(parameter_image='../plan_unfused/parameters.bin',
        pairs=pairs,steps=[asdict(s) for s in steps],RTL_simulated=False)))
    if manifest!=expected:
        raise ValueError('saved fused manifest differs from the trained plan or DDR image reference')
    target=(root/'plan_fused'/manifest['parameter_image']).resolve()
    if target!=(root/'plan_unfused/parameters.bin').resolve():
        raise ValueError('fused parameter reference escaped its deployment directory')
    return dict(saved_DDR_image_bytes=len(package.image),saved_DDR_active_bytes=package.manifest['active_bytes'],
        saved_files_verified=6,fused_parameter_reference_bound=True,direct_content_comparison=True,
        runtime_style_switch_tested=False,new_RTL_execution=False)
