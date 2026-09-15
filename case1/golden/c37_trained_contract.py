"""C37 source/model contract; baseline C35/C36 gates remain unmodified.

The baseline gate below audits ONLY retained wrappers and baseline artifacts.
The separate C37 gate validates the actual six-replacement production closure.
Neither source inspection nor model binding is an RTL simulation result.
"""
import argparse
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET

from c37_sources import ROOT, MODEL, REPLACEMENTS, sources
from r2_trained_style_vectors import (
    bound_candidate as baseline_bound_candidate, build_vectors,
    candidate_nodes, camera_geometry,
)
from run_r2_fused_rgb2_host_probe import SIM, TOP, PREFIX

SOURCES = tuple(p.relative_to(ROOT).as_posix() for p in sources())
PLAN_SOURCE = (MODEL/'plan_fused/execution_plan.sv').relative_to(ROOT).as_posix()
FUSION_SOURCE = (MODEL/'plan_fused/row_fusion_plan.sv').relative_to(ROOT).as_posix()


def bound_candidate(model):
    package, config, provenance = baseline_bound_candidate(model)
    sources(Path(model).resolve(), max_channels=24, row_words=512)
    provenance.update(production_RTL_changed=True, candidate='C37',
                      source_replacement_contract='golden/c37_sources.py')
    return package, config, provenance


def source_gate():
    from check_r2_fused_host_source import source_gate as baseline_source_gate
    baseline_source_gate()
    expected = sources()
    project = ROOT/'efinity/c1_ti60_c37_resource24.xml'
    compiled = [(project.parent/e.attrib['name']).resolve()
                for e in ET.parse(project).getroot().iter()
                if e.tag.rsplit('}', 1)[-1] == 'design_file']
    probe = ROOT/'efinity/c1_ti60_c37_resource24.sv'
    if [p for p in compiled if p != probe] != expected or len(compiled) != 49:
        raise ValueError('C37 project does not match exact replacement closure')
    if len(set(compiled)) != len(compiled):
        raise ValueError('duplicate C37 source')
    for original, replacement in REPLACEMENTS.items():
        if ROOT/original in compiled or ROOT/replacement not in compiled:
            raise ValueError('wrong candidate replacement: '+original)
    modules = {}
    for path in compiled:
        text = re.sub(r'/\*.*?\*/|//[^\n]*', '', path.read_text(encoding='utf-8-sig'), flags=re.S)
        for name in re.findall(r'\bmodule\s+(\w+)', text):
            if name in modules:
                raise ValueError('duplicate candidate module: '+name)
            modules[name] = path
    if modules.get('c37_compute6_indexed') != ROOT/'rtl/c37/c37_compute6_indexed.sv':
        raise ValueError('wrong active indexed compute')
    if 'c1_r2_compute6_compact' in modules:
        raise ValueError('old compute is active')
    old_name, new_name = 'c1_ti60_r2_fused_rgb2_host96', 'c1_ti60_c37_resource24'
    original = (ROOT/f'efinity/{old_name}.sv').read_text(encoding='utf-8-sig')
    if probe.read_text(encoding='utf-8-sig').strip() != original.replace(old_name,new_name).strip():
        raise ValueError('undeclared C37 physical probe change')
    if (ROOT/f'efinity/{old_name}.sdc').read_text().strip() != (ROOT/f'efinity/{new_name}.sdc').read_text().strip():
        raise ValueError('C37 changed clock constraints')
    result = dict(production_sources=48, replacements=6, max_channels=24, row_words=512,
                  model_ROM_matched=True, old_source_gate_preserved=True,
                  RTL_compiled=False, native_fps_claim=False)
    print('C37_SOURCE_CONTRACT_PASS '+json.dumps(result,separators=(',',':')),flush=True)
    return compiled


def resource_preflight():
    baseline_project = ROOT/'efinity/c1_ti60_c37_baseline.xml'
    baseline_sources = [(baseline_project.parent/e.attrib['name']).resolve()
                        for e in ET.parse(baseline_project).getroot().iter()
                        if e.tag.rsplit('}',1)[-1] == 'design_file']
    originals = {ROOT/new: ROOT/old for old,new in REPLACEMENTS.items()}
    baseline_expected = [originals.get(path,path) for path in sources()]
    baseline_probe = ROOT/'efinity/c1_ti60_c37_baseline.sv'
    if [p for p in baseline_sources if p != baseline_probe] != baseline_expected:
        raise ValueError('resource baseline is not original RTL with the identical model')
    old_probe = (ROOT/'efinity/c1_ti60_r2_fused_rgb2_host96.sv').read_text()
    if baseline_probe.read_text().strip() != old_probe.replace(
            'c1_ti60_r2_fused_rgb2_host96','c1_ti60_c37_baseline').strip():
        raise ValueError('resource baseline probe changed')
    if (ROOT/'efinity/c1_ti60_c37_baseline.sdc').read_text().strip() != (
            ROOT/'efinity/c1_ti60_c37_resource24.sdc').read_text().strip():
        raise ValueError('resource baseline constraints differ')
    records = []
    for run in ('c37_same_model_baseline_pnr_20260915a','c37_resource24_pnr_20260915b'):
        folder = ROOT/'logs/efinity_resource_runs'/run
        status = json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
        summary = json.loads((folder/'summary.json').read_text(encoding='utf-8-sig'))
        if status['state'] != 'complete' or status['exit_code'] != 0 or summary['pnr_exit_code'] != 0:
            raise ValueError('resource comparison not terminal: '+run)
        if (status['worker_in_windows_job'] is not False or
                status['run_directory_present'] is not False or Path(status['run_directory']).exists()):
            raise ValueError('resource worker isolation/cleanup not proven: '+run)
        if summary['timing']['final_slack_ns'] < 0 or summary['timing']['final_hold_slack_ns'] < 0:
            raise ValueError('resource candidate failed reported timing')
        records.append(dict(run=run,resources=summary['pnr_resources']))
    print('C37_SAME_MODEL_RESOURCE_PREFLIGHT_PASS '+json.dumps(records,separators=(',',':')),flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--qat-run',type=Path)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--width',type=int)
    parser.add_argument('--height',type=int)
    args = parser.parse_args()
    import torch
    torch.set_num_threads(2)
    source_gate()
    if args.output:
        if not args.qat_run or not args.width or not args.height:
            parser.error('vector build needs model and dimensions')
        if not args.output.resolve().is_relative_to(ROOT/'sim'):
            raise ValueError('vectors must stay in private sim directory')
        package,config,provenance = bound_candidate(args.qat_run)
        meta = build_vectors(args.output,args.width,args.height,package,config,provenance)
        print('C37_TRAINED_VECTOR_BUILD '+json.dumps(dict(model_binding=provenance,
            width=args.width,height=args.height,stage_count=meta['stage_count'],
            parameter_words=meta['parameter_words'],expected_words=meta['expected_words'],
            dw_packets=meta['dw_packets'])),flush=True)
    else:
        resource_preflight()


if __name__ == '__main__':
    main()
