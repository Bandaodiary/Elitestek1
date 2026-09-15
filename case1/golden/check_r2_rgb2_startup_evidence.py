"""C31 CPU-start repair gate: real negative, two clock ratios, actual bus load."""
import json
import re
import check_r2_rgb2_host_evidence as c31


def state(folder,expected):
    s=json.loads(c31.read(folder/'status.json'))
    c31.need(s['state']==expected and s['exit_code']==int(expected=='failed'),'unexpected terminal state')
    c31.need(s['worker_in_windows_job'] is False and not c31.ROOT.joinpath(s['run_directory']).exists(),'isolation/cleanup incomplete')
    b=s['workload_budget']
    c31.need(b['policy']=='single-heavy-worker' and 1<=b['logical_processors']<=2 and b['priority']=='BelowNormal','worker budget missing')
    c31.need(s['worker_start'] and not (folder/'interruption.json').exists(),'run interrupted')
    return s


def main():
    c31.source_gate()
    folder=c31.ROOT/'logs/r2_rgb2_regression_runs/c31_startup_phase_20260914_d'
    state(folder,'complete')
    t=c31.read(folder/'result.log')
    c31.need(t.count('C31_STARTUP_NEGATIVE_PASS native_clocks=1 legacy_pulse=1 missing_start_detected=1')==1,'legacy actual negative missing')
    parts=re.split(r'(?=^C1_R2_RGB2_HOST_SYSTEM_CPU_START )',t,flags=re.M)[1:]
    c31.need(len(parts)==2,'two actual clock configurations required')
    for native,part in enumerate(parts):
        c31.run(part,expected_nn=2,clock_native_override=native)
        try:c31.run(part,expected_nn=2,clock_native_override=1-native)
        except AssertionError:pass
        else:raise AssertionError('wrong clock ratio evidence accepted')
    print('C31_STARTUP_ICARUS_PASS actual_legacy_negative=1 correct_CNN=4 clock_ratios=2 wrong_clock_negatives=2')
    neg=c31.ROOT/'logs/r2_rgb2_host_xsim_runs/c31_startup_negative_xsim_20260914_a'
    s=state(neg,'failed')
    c31.need(s['clocks_native']==s['cpu_start_negative']==1,'not legacy native-clock negative')
    result=c31.read(neg/'result.log');tail=c31.read(neg/'xsim.tail.log')
    check=c31.one(result,'CPU_START_CHECK',c31.P)
    c31.need(check['active']==0 and check['legacy_pulse']==check['native_clocks']==1,'missing actual missed start')
    c31.need('Fatal: CPU source did not start: no sampled core-clock pulse' in tail and c31.P+'PASS ' not in result,'wrong xsim failure')
    print('C31_STARTUP_XSIM_NEGATIVE_PASS active=0 failed_status_preserved=1 compact_failure_checkpoints_retained=1')
    name='c31_startup_positive_xsim_20260914_a'
    pos=c31.ROOT/'logs/r2_rgb2_host_xsim_runs'/name
    state(pos,'complete');c31.xsim_gate(name)
    result=c31.read(pos/'result.log')
    early=c31.one(result,'CPU_EARLY',c31.P)
    c31.need(early['reads']>=2 and early['writes']>=2,'early actual CPU workload missing')
    print('C31_STARTUP_GATE_PASS production_RTL_unchanged=1 xsim_correct_CNN=6 native_geometry_signoff=0 fps_claim=0')


if __name__=='__main__':main()
