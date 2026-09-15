"""C33 integration evidence using the retained full camera/CPU/DDR data audit."""
import argparse
import contextlib
import io
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET

import check_r2_rgb2_host_evidence as baseline
from r2_native_performance_contract import assess_intervals, elaborated_configuration

ROOT=baseline.ROOT
PREFIX='C1_R2_CREDIT_RGB2_HOST_SYSTEM_'
RENAMES={'c1_r2_capacity_pingpong_graph':'c1_r2_credit_pingpong_graph',
         'c1_r2_capacity_rgbx_axi_graph':'c1_r2_credit_rgbx_axi_graph',
         'c1_r2_video_rgb2_system':'c1_r2_video_credit_rgb2_system',
         'c1_r2_rgb2_host_system':'c1_r2_credit_rgb2_host_system',
         'c1_ti60_r2_rgb2_host96':'c1_ti60_r2_credit_rgb2_host96'}


def source_gate():
    def read(p):return (ROOT/p).read_text(encoding='utf-8-sig').strip()
    def renamed(s):
        for a,b in RENAMES.items():s=s.replace(a,b)
        return s
    # Shell, CDC constraints and test assertions are exact named derivatives.
    for p in ('rtl/r2/c1_r2_video_rgb2_system.sv','rtl/r2/c1_r2_rgb2_host_system.sv',
              'efinity/c1_ti60_r2_rgb2_host96.sv','efinity/c1_ti60_r2_rgb2_host96.sdc',
              'efinity/c1_ti60_r2_rgb2_host96.audit.tcl','efinity/c1_ti60_r2_rgb2_host96.cdc.tcl'):
        assert renamed(read(p))==read(renamed(p)),f'unplanned wrapper/clock change {p}'
    expected_tb=renamed(read('sim/tb_c1_r2_rgb2_host_system.sv')).replace('C1_R2_RGB2_HOST_SYSTEM_',PREFIX)
    assert expected_tb==read('sim/tb_c1_r2_credit_rgb2_host_system.sv'),'test assertions changed'
    project=ROOT/'efinity/c1_ti60_r2_credit_rgb2_host96.xml'
    sources=[(project.parent/e.attrib['name']).resolve() for e in ET.parse(project).getroot().iter()
             if e.tag.rsplit('}',1)[-1]=='design_file']
    assert len(sources)==len(set(sources))==47 and all(p.is_file() for p in sources)
    assert all(p.is_relative_to(ROOT.resolve()) for p in sources)
    names={p.name for p in sources}
    assert {'c1_r2_tensor_burst_credit_writer.sv','c1_r2_axi_credit_row_write.sv',
            'c1_r2_rgbx_credit_row_write.sv','c1_r2_credit_pingpong_graph.sv',
            'c1_r2_credit_rgbx_axi_graph.sv'}<=names
    assert not {'c1_r2_tensor_pingpong_writer.sv','c1_r2_tensor_cutthrough_writer.sv',
                'c1_r2_capacity_rgbx_axi_graph.sv'}&names
    print('C33_HOST_SOURCE_PASS production_sources=46 unchanged_test_assertions=1 unchanged_camera_cpu_fabric=1')


def gate(name):
    assert re.fullmatch(r'[A-Za-z0-9_-]+',name)
    folder=ROOT/'logs/r2_credit_rgb2_regression_runs'/name
    status,text=baseline.finished(folder)
    assert status['run_id']==name and not (folder/'stderr.log').read_text(encoding='utf-8-sig').strip()
    budget=status['workload_budget'];assert budget['logical_processors']<=2 and budget['priority']=='BelowNormal'
    assert budget['policy']=='single-heavy-worker'
    if status['test_kind'] in ('smoke','paired'):
        result=baseline.run(text,prefix=PREFIX,expected_nn=2)
        assert (result['width'],result['height'],result['stalls'])==((8,8,1) if status['test_kind']=='smoke' else (32,32,1))
        if status['test_kind']=='paired':
            old=baseline.run(text,expected_nn=2)
            for field in ('width','height','stalls','cnn_frames'):
                assert old[field]==result[field]
            old_frames=baseline.rows(text,'FRAME',baseline.P)
            new_frames=baseline.rows(text,'FRAME',PREFIX)
            for a,b in zip(old_frames,new_frames):
                for field in ('read_beats','write_beats','producers','commits'):
                    assert a[field]==b[field],'CNN traffic/plan changed'
            print('C33_HOST_PAIRED_OBSERVATION '+json.dumps(dict(
                width=32,height=32,stalls=1,
                retained_frame_cycles=[r['cycles'] for r in old_frames],
                candidate_frame_cycles=[r['cycles'] for r in new_frames],
                retained_interval=old['completion_intervals'][0],candidate_interval=result['completion_intervals'][0],
                interval_reduction_percent=100*(1-result['completion_intervals'][0]/old['completion_intervals'][0]),
                native_640x480_fps_claim=False),separators=(',',':')))
        print('C33_HOST_SELECTED_EVIDENCE_PASS '+json.dumps(dict(run=name,seconds=status['elapsed_seconds'],
            native_fps_claim=False,board_claim=False,**result),separators=(',',':')))
    elif status['test_kind']=='faults':
        prefix='C1_R2_CREDIT_RGB2_HOST_FAULT_'
        # The retained validator selects fault-specific invariants by prefix.
        # Normalize only the parser input, then report this run as C33.
        normalized=text.replace(prefix,baseline.F)
        assert normalized.count(baseline.F+'CLEAN temporary_vectors_and_simulator_removed=1')==1
        cases=baseline.c24.groups(normalized,baseline.F)
        results=[baseline.run(chunk,prefix=baseline.F,expected_nn=6) for chunk in cases]
        assert len(results)==8 and {(r['fault_mode'],r['stalls']) for r in results}=={(f,s) for f in (1,2,3,4) for s in (0,1)}
        assert all(baseline.one(chunk,'RGB2',baseline.F)['frame_divisor']==status['frame_divisor'] for chunk in cases)
        print('C33_HOST_FAULT_EVIDENCE_PASS '+json.dumps(dict(run=name,configurations=len(results),seconds=status['elapsed_seconds'],board_claim=False)))
    else:raise AssertionError('use a kind-specific gate for larger matrices')


def physical_gate(name):
    assert re.fullmatch(r'[A-Za-z0-9_-]+',name)
    folder=ROOT/'logs/efinity_resource_runs'/name
    status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    assert status['worker_in_windows_job'] is False and status['worker_start']
    assert status['workload_budget']['logical_processors']<=2 and status['workload_budget']['priority']=='BelowNormal'
    assert status['run_directory_present'] is False and not Path(status['run_directory']).exists()
    # The shell/SDC are exact derivatives, so the complete retained endpoint,
    # Gray skew, setup/hold and mapped-synchronizer audit applies to this run.
    buffer=io.StringIO()
    with contextlib.redirect_stdout(buffer):baseline.physical_gate(name)
    records=[json.loads(line.split(' ',1)[1]) for line in buffer.getvalue().splitlines() if line.startswith('C31_PNR_PASS ')]
    assert len(records)==1
    print('C33_PNR_EVIDENCE_PASS '+json.dumps(dict(run=name,seconds=status['elapsed_seconds'],**records[0]),separators=(',',':')))


def xsim_gate(name):
    assert re.fullmatch(r'[A-Za-z0-9_-]+',name)
    folder=ROOT/'logs/r2_credit_rgb2_host_xsim_runs'/name
    status,text=baseline.finished(folder)
    meta=json.loads((folder/'metadata.json').read_text(encoding='utf-8-sig'))
    model=elaborated_configuration((folder/'xelab.tail.log').read_text(encoding='utf-8-sig'),status,meta,
                                  top='tb_c1_r2_credit_rgb2_host_system')
    override=None if status['clocks_native']==-1 else status['clocks_native']
    result=baseline.run(text,profile=status['profile'],prefix=PREFIX,expected_nn=status['nn_target'],clock_native_override=override)
    performance=assess_intervals(result['completion_intervals']) if status['native_timing'] else dict(native_fps_claim=False)
    print('C33_XSIM_EVIDENCE_PASS '+json.dumps(dict(run=name,seconds=status['elapsed_seconds'],ddr_model=model,
          board_claim=False,**result,**performance),separators=(',',':')))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run');p.add_argument('--pnr');p.add_argument('--xsim');a=p.parse_args();source_gate()
    if a.run:gate(a.run)
    if a.pnr:physical_gate(a.pnr)
    if a.xsim:xsim_gate(a.xsim)
