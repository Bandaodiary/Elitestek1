"""Independent terminal audit of the requested complete 100MHz Icarus flow."""
import argparse
import json
from pathlib import Path
from c40_100mhz_contract import ROOT, TOP, fixture, replace_once, throughput
from c39_onehot_sources import sources
from check_r2_trained_host_evidence import check_text
from c40_four_row_candidate import render as four_row_source

MODELS=('c36_qat_b_starry_equalized_20260915a','c36_qat_b_mosaic_equalized_20260915a',
        'c36_qat_b_mosaic_stable_20260915a')


def load(path):return json.loads(path.read_text(encoding='utf-8-sig'))
def need(value,message):
    if not value:raise AssertionError(message)


def audit(directory):
    directory=directory.resolve()
    need(directory.is_relative_to(ROOT/'logs/c40_100mhz_runs'),'outside C40 evidence tree')
    state=load(directory/'status.json');pipe=load(directory/'pipeline.json')
    need(state['state']=='complete' and state['exit_code']==0,'original worker is not complete/0')
    need(state['worker_in_windows_job'] is False and state['child_in_windows_job'] is False,'Job independence unproven')
    need(pipe['state']=='complete' and pipe['scope']=='full' and state['phase'] in ('full','full_four'),'full requested flow incomplete')
    expected=[f'm{i}_{side}_{stall}' for i in range(3) for side,stall in ((8,0),(8,1),(32,0),(32,1))]
    expected += [f'm{i}_negative_{n}' for i in range(3) for n in (1,2)]
    expected += ['native']
    need(len(pipe['completed'])==19 and set(r['case']['id'] for r in pipe['completed'])==set(expected),'three model matrices/native coverage missing')
    tb=fixture((ROOT/'sim'/f'{TOP}.sv').read_text(encoding='utf-8-sig'))
    tb=replace_once(tb,'c40_previous_core=$realtime;c40_core_edges=c40_core_edges+1;',
        '''c40_previous_core=$realtime;c40_core_edges=c40_core_edges+1;
        if(c40_core_edges%1000000==0)$display("C40_PROGRESS core_cycles=%0d simulation_ns=%0t",c40_core_edges,$time);''')
    results=[]
    for name in expected:
        entry=directory/name;record=load(entry/'result.json');case=record['case'];native=name=='native'
        model=MODELS[2] if native else MODELS[int(name[1])]
        need(case['id']==name and case['model']==model,'model identity mismatch')
        parts=name.split('_')
        negative=0 if native or parts[1]!='negative' else int(parts[2])
        side=640 if native else 8 if negative else int(parts[1])
        stall=0 if native else 1 if negative else int(parts[2])
        need(case['width']==side and case['height']==(480 if native else side),'named case geometry mismatch')
        need(case['negative']==negative and case['stalls']==stall,'named case stimulus mismatch')
        need(record['temporary_removed'] is True,'missing cleanup proof')
        compile=load(entry/'compile.json');opts=compile['options'];commands=compile['commands']
        need(opts['MEMORY_DIV']==2 and opts['COMMAND_LATENCY']==20 and opts['AW_WAIT_W']==2,'changed baseline DDR pressure')
        need(opts['WIDTH']==(640 if native else case['width']) and opts['HEIGHT']==(480 if native else case['height']),'wrong shape')
        need(opts['NN_TARGET']==(6 if native else 2) and opts['CLOCKS_NATIVE']==1,'wrong frames/clock override')
        need(opts['FRAME_DIVISOR']==(1 if native else 2) and opts['STAGE_COUNT']==18 and opts['RGB_STAGE']==16,'wrong admission or graph')
        need(opts['STALLS']==stall and opts['NEGATIVE_CONTROL']==negative and opts['CPU_START_NEGATIVE']==0,'actual stimulus differs')
        need(commands[0][0]=='D:/iverilog/bin/iverilog.exe' and commands[1][0]=='D:/iverilog/bin/vvp.exe','wrong simulator')
        for key,value in opts.items():need(commands[0].count(f'-P{TOP}.{key}={value}')==1,'compiler options differ')
        selected=list(map(Path,compile['sources']))
        retained=[p for p in sources() if p.name not in ('execution_plan.sv','row_fusion_plan.sv')]
        four=state['phase']=='full_four'
        need(compile.get('four_rows',False) is four,'sampler variant inconsistent with worker')
        if four:
            original=ROOT/'rtl/r2/c1_r2_resize_line_sampler.sv'
            need(retained.count(original)==1,'sampler replacement is not unique')
            candidate=selected[retained.index(original)]
            need(candidate==selected[-1].parents[1]/'c40_four_row_sampler.sv','candidate outside private closure')
            need((entry/'candidate.sv').read_text(encoding='utf-8')==four_row_source(),'candidate source drift')
            retained=[candidate if p==original else p for p in retained]
        need(selected[:47]==retained and len(selected)==49,'source closure differs')
        for p in selected:need(commands[0].count(str(p))==1,'compiler source missing/duplicate')
        private=selected[-1].parents[1]
        need(private.is_relative_to(ROOT/'sim') and private.name.startswith('c40_pipeline_') and not private.exists(),'private files still retained or wrong path')
        need((entry/'testbench.sv').read_text(encoding='utf-8')==tb,'clock/display fixture drift')
        for step in ('compile','simulate'):
            end=load(entry/(step+'.exit.json'));identity=load(entry/(step+'.process.json'))
            need(end['process']==identity and identity['in_windows_job'] is False and identity['start_filetime']>0,'child provenance missing')
            if step=='compile':need(end['exit_code']==0,'compile failed')
        text=(entry/'simulate.stdout.log').read_text(encoding='utf-8')
        code=load(entry/'simulate.exit.json')['exit_code']
        if case['negative']:
            fatal={1:'CNN golden mismatch stage=0',2:'display pair not actually produced'}[case['negative']]
            need(code!=0 and fatal in text and 'SYSTEM_PASS ' not in text,'actual RAM fault not rejected')
        else:
            need(code==0 and (entry/'simulate.stderr.log').stat().st_size==0,'simulation failed')
            need('C40_CLOCK_PASS core_hz=100000000 ' in text,'100MHz clock evidence missing')
            checked=check_text(text,dict(blocks=2,expansion=24,preproject=True),nn=6 if native else 2,
                clock_native_override=None if native else 1,camera_profile='camera30' if native else 'legacy',core_period_ps=10000)
            need(checked['completion_intervals']==record['completion_intervals'],'completion interval summary drift')
            if native:results.append(dict(**checked,performance=throughput(checked['completion_intervals'])))
    need(len(results)==1,'native evidence missing')
    return dict(marker='C40_FULL_ICARUS_TERMINAL_PASS',models=3,positive_small_cases=12,
        actual_RAM_negative_cases=6,native=results[0],actual_CPU_IP=False,board_measured=False)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--run',required=True);args=parser.parse_args()
    print(json.dumps(audit(ROOT/'logs/c40_100mhz_runs'/args.run),ensure_ascii=False,indent=2))
