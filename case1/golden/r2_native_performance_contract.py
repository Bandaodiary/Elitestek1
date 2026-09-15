"""Separate sampled throughput from functional PASS; no board-clock claim.

Pure functions and synthetic boundary tests. Elaboration configuration is
read from Vivado's own retained command line, not inferred from filenames.
"""
import re


def need(condition,message):
    if not condition:raise AssertionError(message)


def assess_intervals(intervals):
    need(len(intervals)==5 and all(type(x) is int and x>0 for x in intervals),
         'six completed CNN jobs must provide five positive integer intervals')
    worst=max(intervals)
    return dict(modeled_min_fps_at_150mhz=150000000/worst,
                observed_interval_count=5,worst_interval_cycles=worst,
                target_fps=15,target_interval_budget_cycles=10000000,
                worst_interval_margin_cycles=10000000-worst,
                target_15fps_met_for_observed_intervals=worst<=10000000,
                board_frequency_measured=False,
                performance_scope='five sampled completion intervals at nominal 150 MHz')


def elaborated_configuration(text,status,meta,top='tb_c1_r2_rgb2_host_system'):
    need(top in ('tb_c1_r2_rgb2_host_system','tb_c1_r2_credit_rgb2_host_system'), 'unknown elaborated host')
    commands=[line for line in text.splitlines()
              if line.startswith('Running: ') and ('xelab.exe '+top+' ') in line]
    need(len(commands)==1,'missing/duplicate real xelab invocation')
    pairs=re.findall(r'(?:^|\s)-generic_top\s+([A-Z_]+)=(-?\d+)(?=\s|$)',commands[0])
    generics={}
    for name,value in pairs:
        need(name not in generics,'duplicate elaboration generic '+name)
        generics[name]=int(value)
    expected={key:status[field] for key,field in (
        ('WIDTH','width'),('HEIGHT','height'),('MEMORY_DIV','memory_div'),
        ('COMMAND_LATENCY','command_latency'),('STALLS','stalls'),
        ('AW_WAIT_W','aw_wait_w'),('NN_TARGET','nn_target'),('FRAME_DIVISOR','frame_divisor'))}
    expected.update(STAGE_COUNT=meta['stage_count'],RGB_STAGE=meta['rgb_stage'],
                    CPU_START_NEGATIVE=status.get('cpu_start_negative',0))
    if status.get('clocks_native',-1)!=-1:expected['CLOCKS_NATIVE']=status['clocks_native']
    else:need('CLOCKS_NATIVE' not in generics,'unrecorded clock override in real elaboration')
    for name,value in expected.items():
        need(generics.get(name)==value,'status/actual elaboration mismatch: '+name)
    need(status['aw_wait_w'] in (0,1,2) and status['stalls'] in (0,1), 'unknown BFM policy')
    return dict(memory_div=status['memory_div'],command_latency=status['command_latency'],
                stalls=status['stalls'],aw_wait_w=status['aw_wait_w'],
                frame_divisor=status['frame_divisor'],elaboration_generics_verified=True,
                official_DDR_policy_verified=False)


def self_test():
    need(assess_intervals([10000000]*5)['target_15fps_met_for_observed_intervals'], 'exact target rejected')
    need(not assess_intervals([10000000]*4+[10000001])['target_15fps_met_for_observed_intervals'], 'one-cycle target miss hidden by rounding')
    # Last interval need not be worst; do not report only the final interval.
    need(assess_intervals([10000001]+[9999999]*4)['worst_interval_margin_cycles']==-1, 'worst interval omitted')
    rejected=0
    for intervals in ([10000000]*4,[10000000]*6,[10000000]*4+[0],
                      [10000000]*4+[-1],[10000000]*4+[True],[10000000]*4+[10000000.0]):
        try:assess_intervals(intervals)
        except AssertionError:rejected+=1
        else:raise AssertionError('invalid synthetic interval set accepted')
    status=dict(width=640,height=480,memory_div=2,command_latency=20,stalls=0,
                aw_wait_w=2,nn_target=6,frame_divisor=2,clocks_native=-1,cpu_start_negative=0)
    meta=dict(stage_count=22,rgb_stage=20)
    command=('Running: D:/synthetic/xelab.exe tb_c1_r2_rgb2_host_system '
        '-generic_top WIDTH=640 -generic_top HEIGHT=480 -generic_top MEMORY_DIV=2 '
        '-generic_top COMMAND_LATENCY=20 -generic_top STALLS=0 -generic_top AW_WAIT_W=2 '
        '-generic_top NN_TARGET=6 -generic_top FRAME_DIVISOR=2 -generic_top STAGE_COUNT=22 '
        '-generic_top RGB_STAGE=20 -generic_top CPU_START_NEGATIVE=0 ')
    elaborated_configuration(command,status,meta)
    credit_command=command.replace('tb_c1_r2_rgb2_host_system','tb_c1_r2_credit_rgb2_host_system')
    elaborated_configuration(credit_command,status,meta,top='tb_c1_r2_credit_rgb2_host_system')
    for wrong_text,wrong_top in ((command,'tb_c1_r2_credit_rgb2_host_system'),(credit_command,'tb_c1_r2_rgb2_host_system')):
        try:elaborated_configuration(wrong_text,status,meta,top=wrong_top)
        except AssertionError:rejected+=1
        else:raise AssertionError('wrong host elaboration accepted')
    mutations=(command.replace('AW_WAIT_W=2','AW_WAIT_W=0'),
               command.replace('-generic_top MEMORY_DIV=2 ',''),
               command+'-generic_top AW_WAIT_W=2 ',
               command+'-generic_top CLOCKS_NATIVE=0 ',
               command.replace('CPU_START_NEGATIVE=0','CPU_START_NEGATIVE=1'),
               command+'\n'+command)
    for text in mutations:
        try:elaborated_configuration(text,status,meta)
        except AssertionError:rejected+=1
        else:raise AssertionError('invalid synthetic elaboration accepted')
    print(f'C31_PERFORMANCE_CONTRACT_SELFTEST_PASS boundary_checks=3 rejected_cases={rejected} synthetic_only=1 RTL_simulated=0 real_fps_claim=0')


if __name__=='__main__':self_test()
