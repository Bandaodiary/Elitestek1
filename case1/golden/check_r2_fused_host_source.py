"""C35 full-host source/plan pairing only; no RTL/PNR success claim."""
from pathlib import Path
import json
import re
import sys
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'model'))
from r2_plan_package import profile_nodes
from r2_row_fused_plan import fused_steps,fusion_sv
from r2_execution_plan import render_sv
PROJECT=ROOT/'efinity/c1_ti60_r2_fused_rgb2_host96.xml'


def source_gate():
    pairs=[('rtl/r2/c1_r2_ring_rgbx_axi_graph.sv','rtl/r2/c1_r2_fused_rgbx_axi_graph.sv',
        {'c1_r2_ring_rgbx_axi_graph':'c1_r2_fused_rgbx_axi_graph','c1_r2_ring_pingpong_graph':'c1_r2_row_fused_graph'}),
        ('rtl/r2/c1_r2_video_ring_rgb2_system.sv','rtl/r2/c1_r2_video_fused_rgb2_system.sv',
        {'c1_r2_video_ring_rgb2_system':'c1_r2_video_fused_rgb2_system','c1_r2_ring_rgbx_axi_graph':'c1_r2_fused_rgbx_axi_graph'}),
        ('rtl/r2/c1_r2_ring_rgb2_host_system.sv','rtl/r2/c1_r2_fused_rgb2_host_system.sv',
        {'c1_r2_ring_rgb2_host_system':'c1_r2_fused_rgb2_host_system','c1_r2_video_ring_rgb2_system':'c1_r2_video_fused_rgb2_system'}),
        ('efinity/c1_ti60_r2_ring_rgb2_host96.sv','efinity/c1_ti60_r2_fused_rgb2_host96.sv',
        {'c1_ti60_r2_ring_rgb2_host96':'c1_ti60_r2_fused_rgb2_host96','c1_r2_ring_rgb2_host_system':'c1_r2_fused_rgb2_host_system'})]
    for old,new,names in pairs:
        expected=(ROOT/old).read_text(encoding='utf-8-sig')
        for a,b in names.items():
            if a not in expected:raise ValueError('missing declared rename')
            expected=expected.replace(a,b)
        if (ROOT/new).read_text(encoding='utf-8-sig').strip()!=expected.strip():raise ValueError('undeclared host-shell change '+new)
    if (ROOT/'efinity/c1_ti60_r2_fused_rgb2_host96.sdc').read_text().strip()!=(ROOT/'efinity/c1_ti60_r2_ring_rgb2_host96.sdc').read_text().strip():raise ValueError('timing constraints changed')
    steps,pairs=fused_steps(profile_nodes('microstyle24'))
    if (ROOT/'rtl/r2/c1_r2_row_fused_microstyle_plan.sv').read_text().strip()!=render_sv(steps).strip():raise ValueError('stale default geometry/allocation plan')
    if (ROOT/'rtl/r2/c1_r2_row_fusion_plan.sv').read_text().strip()!=fusion_sv(steps,pairs).strip():raise ValueError('stale default fusion metadata')
    sources=[(PROJECT.parent/e.attrib['name']).resolve() for e in ET.parse(PROJECT).getroot().iter() if e.tag.rsplit('}',1)[-1]=='design_file']
    if len(sources)!=49 or len(set(sources))!=49 or any(not p.is_file() for p in sources):raise ValueError('wrong source closure')
    modules={}
    for path in sources:
        text=re.sub(r'/\*.*?\*/|//[^\n]*','',path.read_text(encoding='utf-8-sig'),flags=re.S)
        for name in re.findall(r'\bmodule\s+(\w+)',text):
            if name in modules:raise ValueError('duplicate module '+name)
            modules[name]=path
    if modules.get('c1_r2_microstyle_plan')!=ROOT/'rtl/r2/c1_r2_row_fused_microstyle_plan.sv':raise ValueError('wrong active plan module')
    for obsolete in ('c1_r2_cnn_capacity_engine','c1_r2_ring_pingpong_graph','c1_r2_ring_rgb2_host_system'):
        if obsolete in modules:raise ValueError('retained old datapath still active')
    # The original parameter image is reused unchanged: only tensor slots,
    # internal materialization and row schedule differ, not kernel math.
    print('C35_FUSED_HOST_SOURCE_PASS '+json.dumps(dict(production_sources=len(sources)-1,
        named_host_derivatives=4,unchanged_clock_constraints=True,generated_pair_count=len(pairs),
        compile_time_plan_pairing=True,RTL_compiled=False,actual_AXI_simulated=False,
        physical_RAM_measured=False,native_fps_claim=False),separators=(',',':')))
    return sources


if __name__=='__main__':source_gate()
