"""C34 exact source derivation and full camera/CPU/DDR numerical evidence."""
import argparse
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

import check_r2_rgb2_host_evidence as baseline
import check_r2_credit_host_evidence as credit

ROOT=baseline.ROOT
need=baseline.need
read=baseline.read
c30=baseline.c30
PREFIX='C1_R2_RING_RGB2_HOST_SYSTEM_'
FAULT='C1_R2_RING_RGB2_HOST_FAULT_'
RENAMES={
    'c1_r2_tensor_burst_credit_writer':'c1_r2_tensor_credit_ring_writer',
    'c1_r2_credit_pingpong_graph':'c1_r2_ring_pingpong_graph',
    'c1_r2_credit_rgbx_axi_graph':'c1_r2_ring_rgbx_axi_graph',
    'c1_r2_video_credit_rgb2_system':'c1_r2_video_ring_rgb2_system',
    'c1_r2_credit_rgb2_host_system':'c1_r2_ring_rgb2_host_system',
    'c1_ti60_r2_credit_rgb2_host96':'c1_ti60_r2_ring_rgb2_host96',
    'tb_c1_r2_credit_rgb2_host_faults':'tb_c1_r2_ring_rgb2_host_faults',
    'C1_R2_CREDIT_RGB2_HOST_SYSTEM_':PREFIX,
    'C1_R2_CREDIT_RGB2_HOST_FAULT_':FAULT,
}


def renamed(text):
    for before,after in RENAMES.items():text=text.replace(before,after)
    return text


def source_gate():
    # The only functional implementation replacement is the independent leaf
    # writer. These four wrappers, clocks and two testbenches must be identical
    # after explicit name substitution, including every retained assertion.
    paths=[f'rtl/r2/{name}.sv' for name in (
        'c1_r2_credit_pingpong_graph','c1_r2_credit_rgbx_axi_graph',
        'c1_r2_video_credit_rgb2_system','c1_r2_credit_rgb2_host_system')]
    paths += [f'efinity/c1_ti60_r2_credit_rgb2_host96.{suffix}'
              for suffix in ('sv','xml','sdc','audit.tcl','cdc.tcl')]
    paths += ['sim/tb_c1_r2_credit_rgb2_host_system.sv','sim/tb_c1_r2_credit_rgb2_host_faults.sv']
    for path in paths:
        old=(ROOT/path).read_text(encoding='utf-8-sig').strip()
        new=(ROOT/renamed(path)).read_text(encoding='utf-8-sig').strip()
        assert renamed(old)==new,'unplanned source/test/clock change: '+path
    project=ROOT/'efinity/c1_ti60_r2_ring_rgb2_host96.xml'
    sources=[(project.parent/e.attrib['name']).resolve() for e in ET.parse(project).getroot().iter()
             if e.tag.rsplit('}',1)[-1]=='design_file']
    assert len(sources)==len(set(sources))==47 and all(p.is_file() and p.is_relative_to(ROOT.resolve()) for p in sources)
    names={p.name for p in sources}
    assert {'c1_r2_tensor_credit_ring_writer.sv','c1_r2_axi_credit_row_write.sv',
            'c1_r2_rgbx_credit_row_write.sv','c1_r2_ring_pingpong_graph.sv'}<=names
    assert not {'c1_r2_tensor_burst_credit_writer.sv','c1_r2_credit_pingpong_graph.sv',
                'c1_r2_tensor_cutthrough_writer.sv','c1_r2_tensor_pingpong_writer.sv'}&names
    assert sum(p.name=='execution_plan.sv' for p in sources)==1
    print('C34_HOST_SOURCE_PASS production_sources=46 identical_named_derivatives=11 unchanged_model=1 '
          'unchanged_test_assertions=1 RTL_compiled=0 FPGA_resource_measured=0')


def gate(name):
    assert re.fullmatch(r'[A-Za-z0-9_-]+',name)
    folder=ROOT/'logs/r2_ring_rgb2_regression_runs'/name
    status,text=baseline.finished(folder)
    assert status['run_id']==name and status['worker_start']
    private=(ROOT/'sim'/f'c1_r2_ring_rgb2_regression_{name}').resolve()
    assert Path(status['run_directory']).resolve()==private
    assert not (folder/'stderr.log').read_text(encoding='utf-8-sig').strip()
    budget=status['workload_budget']
    assert budget['policy']=='single-heavy-worker' and 1<=budget['logical_processors']<=2 and budget['priority']=='BelowNormal'
    assert status['aw_wait_w']==2
    kind=status['test_kind'];prefix=FAULT if kind=='faults' else PREFIX
    assert text.splitlines().count(prefix+'CLEAN temporary_vectors_and_simulator_removed=1')==1
    assert not re.search(r'FATAL|ERROR:|Traceback|RuntimeError',text)
    if kind=='negative':
        rows=baseline.rows(text,'NEGATIVE_PASS',PREFIX)
        assert len(rows)==8 and {(r['width'],r['height'],r['stalls'],r['corruption']) for r in rows}=={
            (w,w,s,c) for w in (8,32) for s in (0,1) for c in (1,2)}
        assert all(r['actual_ram_mutation']==1 for r in rows)
        print('C34_HOST_RAM_NEGATIVE_PASS '+json.dumps(dict(run=name,actual_ram_corruptions=8)))
        return
    if kind=='paired':
        new=baseline.run(text,prefix=PREFIX,expected_nn=2)
        old=baseline.run(text,prefix=credit.PREFIX,expected_nn=2)
        assert (new['width'],new['height'],new['stalls'])==(32,32,1)
        for field in ('width','height','stalls','cnn_frames'):assert old[field]==new[field]
        for before,after in zip(baseline.rows(text,'FRAME',credit.PREFIX),baseline.rows(text,'FRAME',PREFIX)):
            for field in ('read_beats','write_beats','producers','commits'):assert before[field]==after[field]
        for p in (PREFIX,credit.PREFIX):assert baseline.one(text,'RGB2',p)['frame_divisor']==status['frame_divisor']
        print('C34_HOST_PAIRED_OBSERVATION '+json.dumps(dict(run=name,
            retained_interval=old['completion_intervals'][0],candidate_interval=new['completion_intervals'][0],
            interval_change_percent=100*(new['completion_intervals'][0]/old['completion_intervals'][0]-1),
            native_fps_claim=False),separators=(',',':')))
        results=[new]
    else:
        assert kind in ('smoke','matrix','variant','faults')
        # Only fault prefix normalization is needed for retained fault invariants.
        if kind=='faults':text=text.replace(FAULT,baseline.F);prefix=baseline.F
        chunks=baseline.c24.groups(text,prefix)
        results=[baseline.run(chunk,profile='drop_res1' if kind=='variant' else 'microstyle24',
            prefix=prefix,expected_nn=2 if kind=='smoke' else 6) for chunk in chunks]
        if kind=='faults':
            assert len(results)==8 and {(r['fault_mode'],r['stalls']) for r in results}=={(f,s) for f in (1,2,3,4) for s in (0,1)}
        elif kind=='smoke':assert len(results)==1 and (results[0]['width'],results[0]['height'],results[0]['stalls'])==(8,8,1)
        else:assert len(results)==4 and {(r['width'],r['height'],r['stalls']) for r in results}=={(w,w,s) for w in (8,32) for s in (0,1)}
        assert all(baseline.one(chunk,'RGB2',prefix)['frame_divisor']==status['frame_divisor'] for chunk in chunks)
    print('C34_HOST_EVIDENCE_PASS '+json.dumps(dict(run=name,kind=kind,configurations=len(results),
        cnn_frames=sum(r['cnn_frames'] for r in results),seconds=status['elapsed_seconds'],
        native_fps_claim=False,board_claim=False),separators=(',',':')))


def writer_footprint(text):
    headers=[line for line in text.splitlines() if re.match(r'^\|\s*inst_name\s*\|',line)]
    assert len(headers)==1
    assert [s.strip() for s in headers[0].split('|')[1:5]]==['inst_name','xlr','mem','dsp']
    rows=[line for line in text.splitlines() if re.match(r'^\|\s*\+u_writer\s*\|',line)]
    assert len(rows)==1,'writer hierarchy missing/ambiguous'
    values=[]
    for cell in rows[0].split('|')[2:5]:
        match=re.fullmatch(r'\s*([\d.]+)\([\d.]+\)\s*',cell)
        assert match,'malformed hierarchy resource field'
        values.append(float(match[1]))
    assert values[1].is_integer() and values[2].is_integer()
    return dict(xlr=values[0],ram=int(values[1]),dsp=int(values[2]))


def physical_gate(run_id):
    assert re.fullmatch(r'[A-Za-z0-9_-]+',run_id)
    folder,s=c30.c29.c27.run(run_id)
    assert s['worker_in_windows_job'] is False and s['worker_start']
    assert s['run_directory_present'] is False and not Path(s['run_directory']).exists()
    assert s['workload_budget']['policy']=='single-heavy-worker'
    assert 1<=s['workload_budget']['logical_processors']<=2 and s['workload_budget']['priority']=='BelowNormal'
    assert s['metrics']['module_row'].startswith('c1_ti60_r2_ring_rgb2_host96:')
    assert len(s['metrics']['module_row'])<1000
    mapped=c30.c29.map_gate(run_id)
    sta=read(folder/'cdc_sta.stdout.log')
    need(len(re.findall(r'^C27_MATCH .* expected=',sta,re.M))==16 and '\nC27_AUDIT_PASS\n' in sta, 'post-route pin checks incomplete')
    timing={}
    prefix='u_host/u_system/'
    camera_ends={f'{prefix}u_ingress/u_fifo/wr_sync1[{i}]~FF|D' for i in range(10)}
    camera_ends|={prefix+'u_ingress/'+x+'~FF|D' for x in ('req_sync1','done_sync1','bad_sync1')}
    camera_ends|={prefix+'u_camera_snapshot/req_sync1_q~FF|D'}
    dest_rx=r'^(?:u_host/u_system/capture_tag|u_host/u_system/u_ingress/failed_code|camera_result_code|camera_seen|camera_skipped|camera_fifo_peak|u_host/u_system/camera_snapshot)\[\d+\]~FF$'
    camera_ends|={n+'|D' for n in mapped if re.match(dest_rx,n)}
    core_ends={f'{prefix}u_ingress/u_fifo/rd_sync1[{i}]~FF|D' for i in range(10)}
    core_ends|={prefix+'u_ingress/'+x+'~FF|D' for x in ('ack_sync1','enable_sync1','cancel_sync1')}
    core_ends|={prefix+'u_camera_snapshot/ack_sync1_q~FF|D'}
    for stem in ('u_host/u_system/u_ingress/source_tag','u_host/u_system/capture_tag'):
        bits={int(re.search(r'\[(\d+)\]',n)[1]) for n in mapped if n.startswith(stem+'[')}
        need(bits==set(range(1,32)),'divisor-2 tag CDC must retain exact bits 1..31')
    need(len(camera_ends)==126 and len(core_ends)==14,'expected endpoint inventory wrong')
    for name in ('core_setup','core_hold','camera_setup','camera_hold','camera_to_core','core_to_camera'):
        report=read(folder/('c27_'+name+'.rpt'))
        slacks=list(map(float,re.findall(r'^Slack\s*:\s*([-+\d.]+) ns',report,re.M)))
        delays=list(map(float,re.findall(r'^Data Path Delay\s*:\s*([-+\d.]+) ns',report,re.M)))
        need(slacks and len(slacks)==len(delays) and min(slacks)>=0, 'timing violation/missing report '+name)
        if name in ('camera_to_core','core_to_camera'):
            count=126 if name=='camera_to_core' else 14
            need(len(slacks)==count and max(delays)<5 and report.count('Timing Exception : Max Delay Path 5.000 ns')==count, 'missing/masked crossing')
            endpoints=re.findall(r'^Path End\s*:\s*(\S+)\s*$',report,re.M)
            need(len(endpoints)==count and set(endpoints)==(camera_ends if name=='camera_to_core' else core_ends), 'crossing endpoint identities changed')
            if name=='core_to_camera':
                need(set(re.findall(r'^Logic Levels\s*:\s*(\d+)',report,re.M))=={'0'}, 'combinational logic still before CDC first stage')
        timing[name]={'min_slack_ns':min(slacks),'max_data_delay_ns':max(delays),'paths':len(slacks)}
    bus=read(folder/'c27_bus_setup.rpt')
    skew=[tuple(map(float,r)) for r in re.findall(r'^\[get_pins .*\|\s*Slow\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([-+\d.]+)\s*$',bus,re.M)]
    need(len(skew)==2 and all(req==1 and actual<1 and slack>0 for req,actual,slack in skew), 'Gray skew not proven')
    bits={(direction,int(bit)) for direction,bit in re.findall(r'u_ingress/u_fifo/(wr|rd)_sync1\[(\d+)\]~FF\|D',bus)}
    need(bits=={(d,i) for d in ('wr','rd') for i in range(10)},'Gray skew omitted bits')
    resources=s['metrics']['pnr_resources']
    need(resources['memory_blocks_used']==129 and resources['dsp_blocks_used']==130, 'C34 intended 129 RAM / 130 DSP footprint not proven')
    writer=writer_footprint(read(folder/'pnr_before_cdc_hier_util.rpt'))
    assert writer['ram']==16 and writer['dsp']==0,'intended ring writer footprint not proven'
    classification=json.loads(read(folder/'cdc_classification_status.json'))
    print('C34_PNR_PASS '+json.dumps({'run':run_id,'resource_target_verified':True,'resources':resources,'writer_resources':writer,'timing':timing,'gray_setup_skew_ns':[v[1] for v in skew],
          'cdc_classification':classification,'physical_cdc_signoff':False},separators=(',',':')))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--run');parser.add_argument('--pnr');args=parser.parse_args()
    source_gate()
    if args.run:gate(args.run)
    if args.pnr:physical_gate(args.pnr)
