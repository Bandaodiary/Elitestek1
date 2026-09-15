"""Read-only C34 preparation/links/retained-run audit. No process-liveness claim."""
import json
from pathlib import Path
import re
from urllib.parse import unquote

ROOT=Path(__file__).resolve().parents[1]


def main():
    docs=('README.md','IMPLEMENTATION_STATUS.md','DEVELOPMENT_LOG.md','RESOURCE_BUDGET.md',
          'RTL_FILE_GUIDE.md','review/R2_RING_WRITE_STORAGE_20260914.md','review/R2_NATIVE_STAGE_PROFILE_20260914.md',
          'review/R2_ROW_FUSED_TAIL_20260914.md','review/CNN_ALGORITHM_REASSESSMENT_20260915.md',
          'review/C36_CNN_TRAINING_LOG_20260915.md','model/R2_TRAINED_STYLE_CANDIDATES.md',
          'review/C36_CAMERA_CADENCE_REVIEW_20260915.md')
    links=0
    for name in docs:
        file=ROOT/name
        for match in re.finditer(r'!?\[[^\]]*\]\((<[^>]+>|[^)]+)\)',file.read_text(encoding='utf-8-sig')):
            target=match[1].strip().strip('<>')
            if target.startswith(('#','http://','https://','mailto:','data:')):continue
            target=re.sub(r':\d+$','',unquote(target.split('#',1)[0]))
            if not target:continue
            path=Path(target);path=path if path.is_absolute() else file.parent/path
            assert path.exists(),f'broken link {name}: {target}'
            links+=1
    closed=files=size=0;pending=[]
    for directory in ('r2_ring_write_axi_runs','r2_ring_rgb2_regression_runs','r2_serial_queue_runs',
                      'r2_validation_pipeline_runs','efinity_resource_runs','r2_row_shadow_runs','r2_pw_shadow_runs','r2_shadow_engine_runs',
                      'r2_row_fused_graph_runs','r2_row_fused_wide_runs','r2_row_fused_fault_runs','r2_fused_rgb2_host_runs',
                      'r2_fused_rgb2_regression_runs','r2_fused_rgb2_host_xsim_runs','r2_trained_host_runs'):
        pattern='c36_*' if directory=='r2_trained_host_runs' else 'c35_*' if directory in ('r2_row_shadow_runs','r2_pw_shadow_runs','r2_shadow_engine_runs',
                                        'r2_row_fused_graph_runs','r2_row_fused_wide_runs','r2_row_fused_fault_runs','r2_fused_rgb2_host_runs',
                                        'r2_fused_rgb2_regression_runs','r2_fused_rgb2_host_xsim_runs') else 'c34_*'
        patterns=('c34_*','c35_*') if directory=='efinity_resource_runs' else (pattern,)
        for folder in sorted(p for pat in patterns for p in (ROOT/'logs'/directory).glob(pat)):
            status=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
            assert status['run_id']==folder.name
            if status['state'] not in ('complete','failed','dispatched'):
                item=dict(run=folder.name,worker_pid=status.get('worker_pid',status.get('process_id')),worker_start=status['worker_start'],
                          process_liveness_not_inferred=True)
                recovery=folder/'supervision_recovery.json'
                if recovery.exists():
                    r=json.loads(recovery.read_text(encoding='utf-8-sig'))
                    item.update(recovery_pid=r['recovery_pid'],recovery_start=r['recovery_start'],recovery_state=r['state'],
                                tracked_pids=[p['pid'] for p in r['tracked_processes']])
                pending.append(item)
                continue
            if directory=='r2_validation_pipeline_runs':
                assert status['private_directory_present'] is False
                private=ROOT/'sim'/f'c1_r2_c34_pipeline_{folder.name}'
            elif directory=='efinity_resource_runs':
                assert status['run_directory_present'] is False
                private=Path(status['run_directory'])
                design='c1_ti60_r2_fused_rgb2_host96' if folder.name.startswith('c35_') else 'c1_ti60_r2_ring_rgb2_host96'
                assert private.name==f'c1_efinity_resource_{design}_{folder.name}'
            elif directory=='r2_serial_queue_runs':
                assert status['private_directory_present'] is False
                private=ROOT/'sim'/f'c1_r2_c34_queue_{folder.name}'
            else:
                assert status['simulator_directory_present'] is False
                private=Path(status['run_directory'])
                assert private.resolve().is_relative_to((ROOT/'sim').resolve()) and folder.name in private.name
            assert not private.exists();closed+=1
            for file in folder.rglob('*'):
                if file.is_file():
                    assert file.suffix.lower() not in ('.wdb','.vcd','.vvp','.mem','.dcp','.dll','.exe','.o')
                    files+=1;size+=file.stat().st_size
    print('C34_HOUSEKEEPING_PASS '+json.dumps(dict(documents=len(docs),local_links=links,closed_runs=closed,
        retained_files=files,retained_bytes=size,pending=pending,deleted_by_audit=0),separators=(',',':')))


if __name__=='__main__':main()
