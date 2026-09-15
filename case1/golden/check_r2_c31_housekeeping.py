"""Read-only local links/closed simulator cleanup audit; never deletes files."""
import json
import re
from pathlib import Path
from urllib.parse import unquote
import check_r2_rgb2_host_evidence as c31


def main():
    docs=['README.md','ARCHITECTURE.md','RTL_FILE_GUIDE.md','RESOURCE_BUDGET.md',
          'TEST_RESULTS.md','IMPLEMENTATION_STATUS.md','DEVELOPMENT_LOG.md',
          'rtl/r2/README.md','software/README.md','review/R2_RGB2_HOST_INTEGRATION_20260914.md',
          'review/R2_CUTTHROUGH_WRITER_20260914.md','review/R2_OFFICIAL_DDR_INTEGRATION_BOUNDARY_20260914.md']
    count=0
    for name in docs:
        file=c31.ROOT/name
        for match in re.finditer(r'!?\[[^\]]*\]\((<[^>]+>|[^)]+)\)',c31.read(file)):
            target=match[1].strip().strip('<>')
            if target.startswith(('#','http://','https://','mailto:','data:')):continue
            target=unquote(target.split('#',1)[0])
            target=re.sub(r':\d+$','',target)
            if not target:continue
            path=Path(target)
            if not path.is_absolute():path=file.parent/path
            c31.need(path.exists(),f'missing local link: {name} -> {target}')
            count+=1
    print(f'C31_DOCUMENT_LINKS_PASS documents={len(docs)} local_links={count}')
    closed=interrupted=files=total=0;pending=[]
    for root in ('r2_rgb2_regression_runs','r2_rgb2_host_xsim_runs'):
        for folder in (c31.ROOT/'logs'/root).glob('c31_*'):
            s=json.loads(c31.read(folder/'status.json'))
            private=Path(s['run_directory']).resolve()
            c31.need(private.is_relative_to((c31.ROOT/'sim').resolve()),'private path escaped sim root')
            if (folder/'interruption.json').exists():interrupted+=1
            elif s['state'] not in ('complete','failed'):
                pending.append(dict(run=folder.name,worker_pid=s['worker_pid'],worker_start=s.get('worker_start'),
                                    note='state only; real process must be revalidated separately'))
                continue
            c31.need(not private.exists(),'closed private simulation directory remains: '+folder.name)
            closed+=1
            for f in folder.rglob('*'):
                if f.is_file():
                    c31.need(f.suffix.lower() not in ('.wdb','.vcd','.vvp','.mem','.dcp','.jou'),'large temporary artifact retained')
                    files+=1;total+=f.stat().st_size
    print('C31_CLOSED_SIM_CLEAN_PASS '+json.dumps(dict(closed=closed,interrupted=interrupted,
        retained_files=files,retained_bytes=total,pending=pending,deleted_by_this_audit=0),separators=(',',':')))
    # These are only this C32 diagnostic chain's roots, not a blanket claim
    # about other sessions or every simulation directory in the workspace.
    candidate_closed=candidate_files=candidate_bytes=0;candidate_pending=[]
    scopes=(('r2_cutthrough_writer_runs','c32_writer_matrix_20260914_*','c1_r2_cutthrough_writer_',False),
            ('r2_cutthrough_write_axi_runs','c32_write_axi_contention_20260914_*','c1_r2_cutthrough_write_axi_',False),
            ('r2_serial_queue_runs','c32_after_c31_native_20260914_a','c1_r2_c32_queue_',True),
            ('r2_serial_queue_runs','c32_axi_after_writer_20260914_a','c1_r2_c32_axi_queue_',True))
    for root,pattern,private_prefix,queue in scopes:
        for folder in sorted((c31.ROOT/'logs'/root).glob(pattern)):
            s=json.loads(c31.read(folder/'status.json'))
            c31.need(s['run_id']==folder.name,'candidate status RunId differs')
            terminal=('dispatched','failed') if queue else ('complete','failed')
            if s['state'] not in terminal:
                candidate_pending.append(dict(run=folder.name,worker_pid=s['worker_pid'],worker_start=s.get('worker_start'),
                                              note='state only; real process must be revalidated separately'))
                continue
            private=(c31.ROOT/'sim'/(private_prefix+folder.name)).resolve()
            c31.need(private.is_relative_to((c31.ROOT/'sim').resolve()),'candidate private path escaped')
            if not queue:c31.need(Path(s['run_directory']).resolve()==private,'candidate private path differs')
            field='private_directory_present' if queue else 'simulator_directory_present'
            c31.need(s[field] is False and not private.exists(),'closed candidate private directory remains')
            candidate_closed+=1
            for f in folder.rglob('*'):
                if f.is_file():
                    c31.need(f.suffix.lower() not in ('.wdb','.vcd','.vvp','.mem','.dcp','.jou','.dll','.exe','.o'),
                              'temporary binary/vector retained in candidate logs')
                    candidate_files+=1;candidate_bytes+=f.stat().st_size
    print('C32_CLOSED_CHAIN_CLEAN_PASS '+json.dumps(dict(closed=candidate_closed,retained_files=candidate_files,
          retained_bytes=candidate_bytes,pending=candidate_pending,deleted_by_this_audit=0),separators=(',',':')))


if __name__=='__main__':main()
