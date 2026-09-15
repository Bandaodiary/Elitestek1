"""C35 actual xelab configuration plus unchanged full-host data checks."""
import argparse
import json
from pathlib import Path
import re

from check_r2_fused_host_evidence import ROOT,PREFIX,baseline,check_text
from r2_native_performance_contract import elaborated_configuration,assess_intervals
from check_r2_fused_host_source import source_gate
from r2_row_fused_plan import fused_steps,fusion_sv
from r2_execution_plan import render_sv
from r2_plan_package import profile_nodes

TOP='tb_c1_r2_fused_rgb2_host_system'
OLD_TOP='tb_c1_r2_credit_rgb2_host_system'


def configuration(text,s,meta):
    commands=[line for line in text.splitlines() if line.startswith('Running: ') and 'xelab.exe '+TOP+' ' in line]
    if len(commands)!=1:raise ValueError('actual fused xelab invocation missing/duplicated')
    command=commands[0]
    if OLD_TOP in text:raise ValueError('old host elaboration present')
    model=elaborated_configuration(command.replace(TOP,OLD_TOP),s,meta,top=OLD_TOP)
    for name,key in (('FUSED_DW_STAGE','dw_stage'),('FUSED_PW_STAGE','pw_stage')):
        values=re.findall(r'(?:^|\s)-generic_top\s+'+name+r'=(-?\d+)(?=\s|$)',command)
        if values!=[str(meta[key])]:raise ValueError('wrong actual fusion metadata '+name)
    return model


def run_gate(run):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',run):raise ValueError('invalid run')
    folder=ROOT/'logs/r2_fused_rgb2_host_xsim_runs'/run
    s,text=baseline.finished(folder)
    recovered=s.get('completion_recovered',False)
    if recovered:
        recovery=json.loads((folder/'supervision_recovery.json').read_text(encoding='utf-8-sig'))
        if (recovery['state']!='complete' or recovery['run_id']!=run or
            recovery['recovery_pid']!=s['recovery_pid'] or recovery['recovery_start']!=s['recovery_start'] or
            recovery['recovery_in_windows_job'] is not False or s['recovery_in_windows_job'] is not False or
            recovery['cmd_exit_code']!=0 or recovery['kernel_exit_code']!=0 or
            recovery['restarted_simulation'] is not False or recovery['terminated_simulation'] is not False or
            recovery['changed_original_status'] is not True):raise ValueError('incomplete recovered simulation provenance')
        chain=[(p['pid'],p['parent'],p['name']) for p in recovery['tracked_processes']]
        if chain!=[(21688,35892,'cmd'),(40416,21688,'xsim'),(29412,40416,'xsimk')]:raise ValueError('wrong recovered process chain')
    private=ROOT/'sim'/f'c1_r2_fused_rgb2_host_xsim_{run}'
    if s['run_id']!=run or Path(s['run_directory']).resolve()!=private.resolve():raise ValueError('wrong run identity/directory')
    b=s['workload_budget']
    if b['policy']!='single-heavy-worker' or b['logical_processors'] not in (1,2) or b['priority']!='BelowNormal':raise ValueError('wrong workload budget')
    if s['free_memory_kib_before_launch']<8388608:raise ValueError('memory admission missing')
    meta=json.loads((folder/'metadata.json').read_text(encoding='utf-8-sig'))
    if not meta['actual_vs_de'] or meta['source_pixels_per_word']!=2 or meta['frame_divisor']!=s['frame_divisor']:raise ValueError('wrong camera metadata')
    steps,pairs=fused_steps(profile_nodes(s['profile']))
    if pairs!=[(meta['dw_stage'],meta['pw_stage'])]:raise ValueError('wrong logical fusion pair')
    for name,expected in (('execution_plan.sv',render_sv(steps)),('fusion_plan.sv',fusion_sv(steps,pairs))):
        if (folder/name).read_text(encoding='utf-8-sig').strip()!=expected.strip():raise ValueError('retained fused plan mismatch '+name)
    if meta['dw_packets']!=6*s['width']*s['height']:raise ValueError('incomplete internal DW checker vectors')
    elaboration=(folder/'xelab.tail.log').read_text(encoding='utf-8-sig')
    model=configuration(elaboration,s,meta)
    invocation=(folder/'xsim.tail.log').read_text(encoding='utf-8-sig')
    # Vivado retains its actual testplusarg invocation in the short-run tail.
    # Long runs may evict the header; verify DW via a separately retained launch line.
    launch=folder/'xsim.invocation.log'
    if launch.exists():invocation=launch.read_text(encoding='utf-8-sig')
    if re.findall(r'-testplusarg\s+DW=(\d+)(?=\s|$)',invocation)!=[str(meta['dw_packets'])]:raise ValueError('actual DW checker plusarg not proven')
    native=(s['width'],s['height'])==(640,480)
    override=None if native or s['clocks_native']==-1 else s['clocks_native']
    result=check_text(text,profile=s['profile'],nn=s['nn_target'],clock_native_override=override)
    if ((result['width'],result['height'])==(640,480))!=native:raise ValueError('native geometry mismatch')
    if native:
        if s['nn_target']!=6 or s['profile']!='microstyle24' or s['clocks_native'] not in (-1,1) or s['cpu_start_negative']!=0:
            raise ValueError('native original six-frame clock/start configuration not proven')
        startup=baseline.one(text,'CPU_START',PREFIX);early=baseline.one(text,'CPU_EARLY',PREFIX)
        if startup['native_clocks']!=1 or startup['active']!=1 or startup['full_core_pulse']!=1 or min(early['reads'],early['writes'])<2:
            raise ValueError('native startup/early CPU traffic absent')
        performance=assess_intervals(result['completion_intervals'])
    else:performance=dict(native_fps_claim=False)
    rejected=0
    for damaged in (elaboration.replace('FUSED_DW_STAGE='+str(meta['dw_stage']),'FUSED_DW_STAGE=31',1),
                    elaboration.replace('AW_WAIT_W='+str(s['aw_wait_w']),'AW_WAIT_W=99',1),elaboration.replace(TOP,OLD_TOP)):
        try:configuration(damaged,s,meta)
        except (ValueError,AssertionError):rejected+=1
        else:raise ValueError('wrong elaboration accepted')
    source_gate()
    print('C35_FUSED_XSIM_EVIDENCE_PASS '+json.dumps(dict(run=run,seconds=s['elapsed_seconds'],
        **result,**performance,ddr_model=model,actual_AXI=True,actual_CPU_IP=False,physical_cdc_signoff=False,
        configuration_corruption_rejections=rejected,supervision_recovered=recovered,
        temporary_removed=True,process_liveness_not_inferred=True),separators=(',',':')))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run',required=True);run_gate(p.parse_args().run)
