"""Read-only C33 run cleanup and document-link audit; never deletes files."""
import json
from pathlib import Path
import re
from urllib.parse import unquote

ROOT=Path(__file__).resolve().parents[1]


def main():
    docs=('README.md','RESOURCE_BUDGET.md','RTL_FILE_GUIDE.md','IMPLEMENTATION_STATUS.md',
          'DEVELOPMENT_LOG.md','review/R2_BURST_CREDIT_WRITER_20260914.md')
    links=0
    for name in docs:
        file=ROOT/name
        for m in re.finditer(r'!?\[[^\]]*\]\((<[^>]+>|[^)]+)\)',file.read_text(encoding='utf-8-sig')):
            target=m[1].strip().strip('<>')
            if target.startswith(('#','http://','https://','mailto:','data:')):continue
            target=re.sub(r':\d+$','',unquote(target.split('#',1)[0]))
            if not target:continue
            p=Path(target);p=p if p.is_absolute() else file.parent/p
            assert p.exists(),f'broken link {name}: {target}'
            links+=1
    closed=files=size=0;pending=[]
    for root in ('r2_credit_write_axi_runs','r2_credit_rgb2_regression_runs','r2_credit_rgb2_host_xsim_runs','efinity_resource_runs'):
        for folder in sorted((ROOT/'logs'/root).glob('c33_*')):
            s=json.loads((folder/'status.json').read_text(encoding='utf-8-sig'))
            assert s['run_id']==folder.name
            if s['state'] not in ('complete','failed'):
                pending.append(dict(run=folder.name,worker_pid=s.get('worker_pid',s.get('process_id')),
                                    worker_start=s.get('worker_start'),process_liveness_not_inferred=True))
                continue
            private=Path(s['run_directory']).resolve()
            if root=='efinity_resource_runs':
                assert private.name==f'c1_efinity_resource_c1_ti60_r2_credit_rgb2_host96_{folder.name}'
                assert s['run_directory_present'] is False
            else:
                assert private.is_relative_to((ROOT/'sim').resolve()) and folder.name in private.name
                assert s['simulator_directory_present'] is False
            assert not private.exists(),f'closed temporary directory remains: {private}'
            closed+=1
            for f in folder.rglob('*'):
                if f.is_file():
                    assert f.suffix.lower() not in ('.wdb','.vcd','.vvp','.mem','.dcp','.jou','.dll','.exe','.o')
                    files+=1;size+=f.stat().st_size
    print('C33_HOUSEKEEPING_PASS '+json.dumps(dict(documents=len(docs),local_links=links,
        closed_runs=closed,retained_files=files,retained_bytes=size,pending=pending,deleted_by_audit=0),separators=(',',':')))


if __name__=='__main__':main()
