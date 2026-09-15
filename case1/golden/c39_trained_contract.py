"""Explicit native-format C39 model/source/resource contract, not a C37 relabel."""
import argparse
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET
from c37_trained_contract import (ROOT, MODEL, TOP, SIM, PREFIX, PLAN_SOURCE, FUSION_SOURCE,
    bound_candidate as retained_bound_candidate, build_vectors, candidate_nodes, camera_geometry,
    source_gate as retained_source_gate)
from c39_native_sources import sources, verify
from c39_resource_comparison import exact_source_gate, compare

SOURCES = tuple(p.relative_to(ROOT).as_posix() for p in sources())


def bound_candidate(model):
    package, config, provenance = retained_bound_candidate(model)
    sources(Path(model).resolve(), max_channels=24, row_words=512)
    provenance.update(production_RTL_changed=True, candidate='C39_NATIVE',
                      source_replacement_contract='golden/c39_native_sources.py')
    return package, config, provenance


def source_gate():
    retained_source_gate()
    exact_source_gate()
    verify()
    project = ROOT / 'efinity/c1_ti60_c39_host_native.xml'
    compiled = [(project.parent / e.attrib['name']).resolve()
                for e in ET.parse(project).getroot().iter()
                if e.tag.rsplit('}', 1)[-1] == 'design_file']
    probe = ROOT / 'efinity/c1_ti60_c39_host_native.sv'
    if compiled != sources() + [probe] or len(compiled) != 50 or len(set(compiled)) != 50:
        raise ValueError('C39 native project differs from exact 49-source closure')
    modules = {}
    for path in compiled:
        text = re.sub(r'/\*.*?\*/|//[^\n]*', '', path.read_text(encoding='utf-8-sig'), flags=re.S)
        for name in re.findall(r'\bmodule\s+(\w+)', text):
            if name in modules:
                raise ValueError('duplicate C39 module: ' + name)
            modules[name] = path
    for module, relative in {
        'c37_compute6_indexed': 'rtl/c39/c37_compute6_indexed.sv',
        'c39_requant_bank8_narrow': 'rtl/c39/c39_requant_bank8_narrow.sv',
        'c1_r2_cnn_row_shadow_engine': 'rtl/c39_direct/c1_r2_cnn_row_shadow_engine.sv',
        'c1_r2_spatial_partitioned_feeder': 'rtl/c39_native/c1_r2_spatial_partitioned_feeder.sv',
        'c1_r2_partitioned_window_store': 'rtl/c39/c1_r2_partitioned_window_store.sv',
        'c39_operand_unpack': 'rtl/c39/c39_operand_codec.sv',
    }.items():
        if modules.get(module) != ROOT / relative:
            raise ValueError('wrong native module implementation: ' + module)
    if 'c1_requant_bank8_compact' in modules or 'c1_r2_compute6_compact' in modules:
        raise ValueError('old compute/quant implementation is active')
    print('C39_NATIVE_SOURCE_CONTRACT_PASS ' + json.dumps(dict(production_sources=49,
        candidate='C39_NATIVE', max_channels=24, row_words=512, retained_C37_gate_preserved=True,
        model_ROM_matched=True, RTL_compiled=False, native_fps_claim=False), separators=(',', ':')), flush=True)
    return compiled


def resource_preflight():
    report = compare(['c39_host_native_pnr_20260915a'])
    baseline, candidate = report['baseline'], report['candidates'][0]
    if (not candidate['pnr_timing_pass'] or not candidate['private_removed'] or
            candidate['pnr_xlr'] >= baseline['pnr_xlr'] or
            candidate['ram'] > baseline['ram'] or candidate['dsp'] > baseline['dsp']):
        raise ValueError('native candidate lacks actual net resource gain and clean PNR/timing')
    folder = ROOT / 'logs/efinity_resource_runs' / candidate['run']
    status = json.loads((folder / 'status.json').read_text(encoding='utf-8-sig'))
    if status['exit_code'] != 0 or status['worker_in_windows_job'] is not False:
        raise ValueError('candidate resource isolation/exit unproven')
    print('C39_NATIVE_RESOURCE_PREFLIGHT_PASS ' + json.dumps(report, separators=(',', ':')), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--qat-run', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--width', type=int)
    parser.add_argument('--height', type=int)
    args = parser.parse_args()
    import torch
    torch.set_num_threads(2)
    source_gate()
    if args.output:
        if not args.qat_run or not args.width or not args.height:
            parser.error('vector build needs model and dimensions')
        if not args.output.resolve().is_relative_to(ROOT / 'sim'):
            raise ValueError('vectors must stay in private sim directory')
        package, config, provenance = bound_candidate(args.qat_run)
        meta = build_vectors(args.output, args.width, args.height, package, config, provenance)
        print('C39_TRAINED_VECTOR_BUILD ' + json.dumps(dict(model_binding=provenance,
            width=args.width, height=args.height, stage_count=meta['stage_count'],
            parameter_words=meta['parameter_words'], expected_words=meta['expected_words'],
            dw_packets=meta['dw_packets'])), flush=True)
    else:
        resource_preflight()


if __name__ == '__main__':
    main()
