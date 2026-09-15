"""C13 ID/narrow normal-DDR seam audit; not actual Sapphire execution evidence."""
import argparse,json,re
from pathlib import Path
import check_r2_rgbx_system_evidence as c12
ROOT=c12.ROOT
need=c12.need
def read(p):return (ROOT/p).read_text(encoding='utf-8-sig')
def normalized(t):return t.replace('C1_R2_CPU_VIDEO_SYSTEM_','C1_R2_RGBX_SYSTEM_')
def cpu_ids(t):
    previous=[];profiles=0
    for line in t.splitlines():
        if line.startswith('C1_R2_CPU_VIDEO_SYSTEM_IDS '):previous.append(c12.fields(line))
        if line.startswith('C1_R2_CPU_VIDEO_SYSTEM_PASS '):
            p=c12.fields(line);need(len(previous)==1,'missing/duplicate CPU ID evidence');i=previous[0]
            need(p['cpu_adapter']==1 and i['restored_bits']==8 and i['reads']>=2 and i['writes']>=2,'CPU ID adapter coverage absent')
            need(i['reads']*16==p['cpu_r'] and i['writes']*16==p['cpu_w'],'CPU restored transactions/real beats disagree')
            profiles+=1;previous=[]
    need(not previous and profiles>0,'unterminated CPU ID profile')
    return profiles
def unit(t):
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError',t),'CPU adapter unit failure')
    need(t.splitlines().count('C1_R2_CPU_AXI_ADAPTER_CLEAN temporary_simulator_removed=1')==1,'unit cleanup missing')
    rs=[c12.fields(x) for x in t.splitlines() if x.startswith('C1_R2_CPU_AXI_ADAPTER_PASS ')]
    need(len(rs)==12 and {(r['stalls'],r['aw_mode'],r['id_bits']) for r in rs}=={(s,w,i) for s in (0,1) for w in (0,2) for i in (4,8,12)},'unit matrix incomplete')
    for r in rs:
        need((r['reads'],r['writes'],r['rejects'],r['protocol_cases'],r['response_cases'])==(36,38 if r['aw_mode']==0 else 37,16,8 if r['aw_mode']==0 else 7,2),'CPU boundary/fault counts disagree')
        need((r['actual_byte_ram'],r['independent_rw'],r['held_ids'],r['narrow_sizes'],r['max_beats'])==(1,1,1,5,256),'missing RAM/ID/narrow/burst coverage')
    return dict(configs=12,jobs=sum(r['reads']+r['writes'] for r in rs),rejects=192,protocol_cases=90,response_cases=24)
def xsim(run_id,native=False):
    f=Path('logs/r2_cpu_video_xsim_runs')/run_id;s=json.loads(read(f/'status.json'))
    need(s['run_id']==run_id and s['state']=='complete' and s['exit_code']==0,'C13 xsim incomplete')
    need(s['worker_in_windows_job'] is False and not s['simulator_directory_present'] and not Path(s['run_directory']).exists(),'C13 xsim not isolated/clean')
    profile=(640,480,0,0,6,2,20) if native else (12,12,1,2,6,2,20)
    need((s['width'],s['height'],s['stalls'],s['aw_wait_w'],s['nn_target'],s['memory_div'],s['command_latency'])==profile,'wrong C13 xsim profile')
    t=read(f/'result.log');need(cpu_ids(t)==1,'wrong C13 xsim ID profiles');nt=normalized(t)
    need(not re.search(r'FATAL|ERROR|Traceback|RuntimeError',t),'failed C13 xsim log')
    ps=c12.rows(nt,'PASS');fs=c12.rows(nt,'FRAME');need(len(ps)==1,'missing xsim pass');tm=c12.run(ps[0],fs,nt,native,6)
    if native:
        commits=c12.rows(nt,'STAGE');need(len(commits)==132,'missing native stage evidence')
        for frame in fs:
            cc=[x for x in commits if x['tag']==frame['tag']]
            need([x['stage'] for x in cc]==list(range(22)) and cc[-1]['words']==frame['write_beats'] and cc[-1]['cycles']==frame['cycles'],'native commit mismatch')
        m=json.loads(read(f/'metadata.json'))
        need((m['parameter_words'],m['input_words'],m['expected_words'],m['frames'][0]['scalars'])==(2333,153600,2860800,21043200),'wrong native golden')
    return dict(run_id=run_id,cnn_frames=6,frame_cycles=[x['cycles'] for x in fs],timeline=tm,**c12.throughput(tm,native),actual_cpu_ip_execution=False)
def physical(run_id):
    f=Path('logs/efinity_resource_runs')/run_id;s=json.loads(read(f/'status.json'));m=json.loads(read(f/'summary.json'))
    need(s['run_id']==m['run_id']==run_id and s['state']==m['state']=='complete' and s['exit_code']==m['pnr_exit_code']==0,'C13 Efinity incomplete')
    need(m['marker']=='C1_TI60_R2_CPU_VIDEO96_MAP_PNR_PASS' and m['family']=='Titanium' and m['device']=='Ti60F225' and m['flow']=='map+pnr','wrong C13 target')
    private=Path('C:/Users/30982/AppData/Local/Temp')/('c1_efinity_resource_c1_ti60_r2_cpu_video96_'+run_id)
    need(not private.exists() and '--timing_model I3 ' in read(f/'efinity.pnr.stdout.tail.log'),'wrong grade/unclean PNR')
    r=m['pnr_resources'];t=m['timing'];mm=m['metrics'];hh=set(mm['module_rows']+mm.get('module_focus_rows',[]))
    need(r['dsp_blocks_used']==112 and r['memory_blocks_used']==172 and 0<r['xlr_cells_used']<=60800,'unexpected/pruned C13 footprint')
    need(mm['primitive_counts'].get('EFX_DSP24')==96 and mm['primitive_counts'].get('EFX_DSP48')==16,'wrong retained array')
    for name in ('+u_cpu_adapter:c1_r2_cpu_axi_adapter','+u_system:c1_r2_video_rgbx_system','+u_cnn:c1_r2_microstyle_rgbx_axi_graph'):
        need(sum(name in row for row in hh)==1,'missing hierarchy '+name)
    need(t['final_slack_ns']>=0 and t['final_hold_slack_ns']>=0 and abs(t['final_slack_ns']+t['final_period_ns']-6.666)<.002,'C13 150MHz timing failed')
    return dict(run_id=run_id,resources=r,timing=t,scope='C12 + normal-DDR CPU adapter, not actual Sapphire/PHY/CDC/board')
def main():
    p=argparse.ArgumentParser();p.add_argument('--pnr-run');p.add_argument('--native-run');p.add_argument('--require-15fps',action='store_true');a=p.parse_args()
    t=read('logs/r2_cpu_axi_adapter_matrix_20260913_b.log');print('C1_R2_C13_UNIT_GATE_PASS '+json.dumps(unit(t)))
    matrix=read('logs/r2_cpu_video_system_sixframe_20260913_a.log');need(cpu_ids(matrix)==4,'missing CPU/CNN/video profiles')
    print('C1_R2_C13_SYSTEM_GATE_PASS '+json.dumps(c12.matrix(normalized(matrix),((8,8),(32,32)),6)))
    print('C1_R2_C13_XSIM_GATE_PASS '+json.dumps(xsim('c13_cpu_video_xsim_12x12_20260913_a')))
    for old,new in [('actual_byte_ram=1','actual_byte_ram=0'),('max_beats=256','max_beats=16'),('id_bits=12','id_bits=9')]:
        need(old in t,'missing unit audit mutation')
        try:unit(t.replace(old,new,1))
        except ValueError:pass
        else:raise ValueError('corrupt unit evidence accepted')
    for old,new in [('restored_bits=8','restored_bits=4'),('cpu_adapter=1','cpu_adapter=0')]:
        need(old in matrix,'missing system audit mutation')
        try:cpu_ids(matrix.replace(old,new,1))
        except ValueError:pass
        else:raise ValueError('corrupt ID evidence accepted')
    print('C1_R2_C13_AUDIT_NEGATIVE_PASS rejected=5')
    if a.native_run:
        result=xsim(a.native_run,True);print('C1_R2_C13_NATIVE_GATE_PASS '+json.dumps(result))
        if a.require_15fps:c12.require_throughput(result,4)
    else:need(not a.require_15fps,'native run required for C13 throughput claim')
    if a.pnr_run:print('C1_R2_C13_PHYSICAL_GATE_PASS '+json.dumps(physical(a.pnr_run)))
if __name__=='__main__':main()
