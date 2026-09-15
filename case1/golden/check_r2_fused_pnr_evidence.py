"""C35 full-host Ti60 resource/directional timing gate; not board signoff."""
import argparse
import json
from pathlib import Path
import re

from check_r2_ring_host_evidence import c30,need,read,writer_footprint
from check_r2_fused_host_source import source_gate

def physical_gate(run_id):
    assert re.fullmatch(r'[A-Za-z0-9_-]+',run_id)
    folder,s=c30.c29.c27.run(run_id)
    assert s['worker_in_windows_job'] is False and s['worker_start']
    assert s['run_directory_present'] is False and not Path(s['run_directory']).exists()
    assert s['workload_budget']['policy']=='single-heavy-worker'
    assert 1<=s['workload_budget']['logical_processors']<=2 and s['workload_budget']['priority']=='BelowNormal'
    assert s['metrics']['module_row'].startswith('c1_ti60_r2_fused_rgb2_host96:')
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
    need(0<resources['memory_blocks_used']<=256 and 0<resources['dsp_blocks_used']<=160 and 0<resources['xlr_cells_used']<=60800, 'candidate does not fit the bare Ti60 resource limits')
    writer=writer_footprint(read(folder/'pnr_before_cdc_hier_util.rpt'))
    assert writer['ram']==16 and writer['dsp']==0,'intended ring writer footprint not proven'
    classification=json.loads(read(folder/'cdc_classification_status.json'))
    print('C35_FUSED_PNR_PASS '+json.dumps({'run':run_id,'bare_device_fit':True,'official_platform_fit_claim':False,'native_fps_claim':False,'RAM_delta_vs_C34':resources['memory_blocks_used']-129,'XLR_delta_vs_C34':resources['xlr_cells_used']-43286,'resources':resources,'writer_resources':writer,'timing':timing,'gray_setup_skew_ns':[v[1] for v in skew],
          'cdc_classification':classification,'physical_cdc_signoff':False},separators=(',',':')))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--pnr',required=True);args=parser.parse_args()
    source_gate();physical_gate(args.pnr)

