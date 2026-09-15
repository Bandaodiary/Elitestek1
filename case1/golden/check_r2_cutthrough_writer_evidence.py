"""C32 isolated writer evidence gate, with explicitly synthetic checker tests.

No run can pass this gate without real terminal logs. --self-test exercises
only this checker's rejection logic and makes no RTL or performance claim.
"""
import argparse
import copy
import json
import re
from pathlib import Path
import check_r2_cutthrough_candidate_source as source

ROOT=Path(__file__).resolve().parents[1]
EXPECTED={(m,c,w) for m,c in ((0,8),(0,16),(0,24),(0,48),(1,3),
          (2,16),(2,24),(2,48),(3,24),(4,12),(5,24)) for w in (3,16)}
FIELDS={'mode','channels','width','rows','words_each','candidate_early_words',
        'odd_tail_response_stalls','retained_reference','golden_both',
        'response_errors','page_debt_peak','actual_AXI'}


def need(condition,message):
    if not condition:raise AssertionError(message)


def validate_rows(rows):
    need(len(rows)==22,'need 22 actual writer configurations')
    for r in rows:need(set(r)==FIELDS,'writer evidence fields differ')
    keys=[(r['mode'],r['channels'],r['width']) for r in rows]
    need(len(set(keys))==22 and set(keys)==EXPECTED,'duplicate or missing operator/shape')
    words=early=0
    for r in rows:
        need(r['rows']==4,'missing four-row page reuse')
        expected=4*((r['width']+1)//2)*((r['channels']+7)//8)
        need(r['words_each']==expected,'wrong actual output amount')
        need(0<=r['candidate_early_words']<=expected,'impossible early-word count')
        if r['width']==16:need(r['candidate_early_words']>0,'no real pre-row-completion output')
        if r['mode']==2 and r['width']==3:
            need(r['odd_tail_response_stalls']>0,'empty DW final packet response hold not tested')
        else:need(r['odd_tail_response_stalls']==0,'unexpected pre-last response')
        need(r['retained_reference']==r['golden_both']==1,'independent reference/golden missing')
        need(r['response_errors']==r['page_debt_peak']==2,'response/error/page-credit coverage missing')
        need(r['actual_AXI']==0,'row-interface test relabeled as AXI')
        words+=expected;early+=r['candidate_early_words']
    need(words==1280,'aggregate word coverage differs')
    return dict(configurations=22,rows_per_writer=88,words_per_writer=words,
                both_writers_bytes=words*16*2,candidate_early_words=early,
                observed_error_responses_both=44,actual_AXI=False,whole_CNN_fps_claim=False)


def parse_rows(text):
    need(not re.search(r'(?im)FATAL|ERROR:|Traceback|RuntimeError',text),'runtime failure in evidence')
    rows=[]
    for line in text.splitlines():
        if not line.startswith('C32_WRITER_RTL_PASS '):continue
        fields={}
        for token in line.split()[1:]:
            need(re.fullmatch(r'[A-Za-z_]+=-?\d+',token) is not None,'malformed writer field')
            key,value=token.split('=')
            need(key not in fields,'duplicate writer field')
            fields[key]=int(value)
        rows.append(fields)
    return rows


def self_test():
    # Synthetic records are deliberately never written as a simulator log.
    rows=[dict(mode=m,channels=c,width=w,rows=4,
               words_each=4*((w+1)//2)*((c+7)//8),candidate_early_words=1,
               odd_tail_response_stalls=int(m==2 and w==3),retained_reference=1,
               golden_both=1,response_errors=2,page_debt_peak=2,actual_AXI=0)
          for m,c,w in sorted(EXPECTED)]
    validate_rows(rows)
    bad=[]
    r=copy.deepcopy(rows);r.pop();bad.append(r)
    r=copy.deepcopy(rows);r[0]=copy.deepcopy(r[1]);bad.append(r)
    r=copy.deepcopy(rows);del r[0]['mode'];bad.append(r)
    for field,value,select in (
        ('rows',3,lambda r:True),('words_each',0,lambda r:True),
        ('candidate_early_words',0,lambda r:r['width']==16),
        ('candidate_early_words',1000000,lambda r:True),
        ('odd_tail_response_stalls',0,lambda r:r['mode']==2 and r['width']==3),
        ('retained_reference',0,lambda r:True),('golden_both',0,lambda r:True),
        ('response_errors',0,lambda r:True),('page_debt_peak',3,lambda r:True),
        ('actual_AXI',1,lambda r:True)):
        r=copy.deepcopy(rows);next(x for x in r if select(x))[field]=value;bad.append(r)
    for r in bad:
        try:validate_rows(r)
        except AssertionError:pass
        else:raise AssertionError('checker accepted corrupt synthetic evidence')
    for t in ('C32_WRITER_RTL_PASS mode=0 mode=2', 'FATAL: synthetic failure'):
        try:parse_rows(t)
        except AssertionError:pass
        else:raise AssertionError('checker accepted malformed evidence')
    print(f'C32_CHECKER_SELFTEST_PASS synthetic_only=1 rejected_cases={len(bad)+2} RTL_simulated=0 performance_claim=0')


def gate(name):
    need(re.fullmatch(r'[A-Za-z0-9_-]+',name) is not None,'unsafe RunId')
    folder=ROOT/'logs/r2_cutthrough_writer_runs'/name
    s=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
    need(s['run_id']==name and s['state']=='complete' and s['exit_code']==0,'writer run not successfully terminal')
    need(s['worker_in_windows_job'] is False and s['worker_start'],'worker isolation/identity missing')
    expected=(ROOT/'sim'/f'c1_r2_cutthrough_writer_{name}').resolve()
    need(Path(s['run_directory']).resolve()==expected and not expected.exists() and s['simulator_directory_present'] is False,'private cleanup incomplete')
    need(not (folder/'interruption.json').exists(),'interrupted run')
    budget=s['workload_budget']
    need(budget['policy']=='single-heavy-worker' and 1<=budget['logical_processors']<=2 and budget['priority']=='BelowNormal','missing low-load policy')
    need(s['actual_AXI'] is False and s['whole_CNN_fps_claim'] is False,'unit scope misrepresented')
    text=(folder/'result.log').read_text(encoding='utf-8-sig')
    stderr=(folder/'stderr.log').read_text(encoding='utf-8-sig')
    need(not stderr.strip(),'unexpected stderr')
    need(text.count('C32_WRITER_CLEAN temporary_vectors_and_simulator_removed=1')==1,'missing cleanup evidence')
    need(text.count('C32_WRITER_ORDER_MODEL_PASS shapes=113 producer_packets=49838 ')==1,'ordering model coverage differs')
    result=validate_rows(parse_rows(text))
    source.main()
    result.update(run=name,seconds=s['elapsed_seconds'])
    print('C32_WRITER_UNIT_GATE_PASS '+json.dumps(result,separators=(',',':')))


def main():
    p=argparse.ArgumentParser();p.add_argument('--self-test',action='store_true');p.add_argument('--run')
    a=p.parse_args()
    if not a.self_test and not a.run:p.error('select --self-test or an actual --run')
    if a.self_test:self_test()
    if a.run:gate(a.run)


if __name__=='__main__':main()
