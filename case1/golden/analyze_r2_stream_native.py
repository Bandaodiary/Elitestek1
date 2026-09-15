"""Compact measured per-stage graph cycles, with separately labelled budgets."""
import argparse,json
from pathlib import Path
from check_r2_stream_evidence import native_run,read,records
from r2_stream_traffic_budget import budget

p=argparse.ArgumentParser();p.add_argument('--run',required=True);args=p.parse_args()
result=native_run(args.run)
commits=records(read(Path('logs/r2_stream_xsim_runs')/args.run/'result.log'),'STAGE_COMMIT')
plan=budget()['stages'];previous=0;rows=[]
for c in commits:
    s=c['stage'];cycles=c['cycles']-previous;previous=c['cycles'];b=plan[s]
    rows.append(dict(stage=s,actual_graph_cycles=cycles,compute_row_model_cycles=b['compute_cycles'],
                     planned_feature_read_words=b['read_beats'],planned_write_words=b['write_beats'],
                     fraction_of_frame=round(cycles/result['cycles'],6)))
if sum(s['actual_graph_cycles'] for s in rows)!=result['cycles']:raise ValueError('stage sum mismatch')
print('C1_R2_STREAM_NATIVE_CYCLES '+json.dumps(result))
for s in rows:print('C1_R2_STREAM_NATIVE_STAGE_ANALYSIS '+json.dumps(s))
print('C1_R2_STREAM_NATIVE_ANALYSIS_SCOPE stage_cycles_are_measured_compute_and_traffic_columns_are_separate_schedule_budgets_not_measured_stall_counters=1')
