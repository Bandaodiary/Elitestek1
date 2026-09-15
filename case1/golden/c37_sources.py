"""Explicit C37 replacement closure; never modify or weaken a C35/C36 gate."""
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'efinity/c1_ti60_r2_fused_rgb2_host96.xml'
MODEL = ROOT / 'outputs/c36_qat_b_mosaic_stable_20260915a'
REPLACEMENTS = {
    'rtl/video/r1_bilinear_interp_rgb888.sv': 'rtl/c37/r1_bilinear_interp_rgb888.sv',
    'rtl/r2/c1_r2_partitioned_window_store.sv': 'rtl/c37/c1_r2_partitioned_window_store.sv',
    'rtl/r2/c1_r2_spatial_partitioned_feeder.sv': 'rtl/c37/c1_r2_spatial_partitioned_feeder.sv',
    'rtl/r2/c1_r2_weight_store6.sv': 'rtl/c37/c1_r2_weight_store6.sv',
    'rtl/r2/c1_r2_compute6_compact.sv': 'rtl/c37/c37_compute6_indexed.sv',
    'rtl/r2/c1_r2_cnn_row_shadow_engine.sv': 'rtl/c37/c1_r2_cnn_row_shadow_engine.sv',
}


def sources(model=MODEL, max_channels=24, row_words=512):
    from c37_capacity_contract import check_package
    check_package(model, max_channels, row_words)
    result, replaced = [], set()
    for element in ET.parse(PROJECT).getroot().iter():
        if element.tag.rsplit('}', 1)[-1] != 'design_file':
            continue
        path = (PROJECT.parent / element.attrib['name']).resolve()
        if path.name == 'c1_ti60_r2_fused_rgb2_host96.sv':
            continue
        relative = path.relative_to(ROOT).as_posix()
        if relative in REPLACEMENTS:
            replaced.add(relative)
            path = ROOT / REPLACEMENTS[relative]
        if relative == 'rtl/r2/c1_r2_row_fused_microstyle_plan.sv':
            path = model / 'plan_fused/execution_plan.sv'
        if relative == 'rtl/r2/c1_r2_row_fusion_plan.sv':
            path = model / 'plan_fused/row_fusion_plan.sv'
        if not path.is_file():
            raise ValueError(f'missing source: {path}')
        result.append(path)
    if replaced != set(REPLACEMENTS) or len(result) != len(set(result)):
        raise ValueError('incomplete or duplicate candidate source closure')
    return result
