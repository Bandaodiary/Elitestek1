"""C35 directed faults/resets *inside* the fused operator pair, detached only."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

from run_r2_row_fused_graph_probe import sources,fields,ROOT
from r2_row_fused_graph_vectors import vectors
from check_r2_row_fused_wide_evidence import run_gate
TOP='tb_c1_r2_row_fused_faults'


def main():
    p=argparse.ArgumentParser();p.add_argument('--wide-run',required=True)
    p.add_argument('--temporary-parent',type=Path,required=True);a=p.parse_args()
    run_gate(a.wide_run)
    parent=a.temporary_parent.resolve()
    if parent.parent!=ROOT/'sim' or not parent.name.startswith('c1_r2_row_fused_fault_') or not parent.is_dir():raise ValueError('invalid private parent')
    with tempfile.TemporaryDirectory(prefix='fault_',dir=parent) as private:
        folder=Path(private);m=vectors(folder,12,12)
        opts=dict(STALLS=1,MEMORY_DIV=2,COMMAND_LATENCY=20)
        exe=folder/'faults.vvp'
        cmd=['D:/iverilog/bin/iverilog.exe','-g2012','-s',TOP,*[f'-P{TOP}.{k}={v}' for k,v in opts.items()],
            '-o',str(exe),*map(str,sources()),str(folder/'package/execution_plan.sv'),str(folder/'fusion_plan.sv'),str(ROOT/f'sim/{TOP}.sv')]
        c=subprocess.run(cmd,capture_output=True,text=True,timeout=60)
        if c.returncode:raise RuntimeError(c.stderr[:1800]+'\n'+c.stderr[-1800:])
        cmd=['D:/iverilog/bin/vvp.exe',str(exe),f'+DIR={folder.as_posix()}','+W=12','+H=12',
            f'+P={m["parameter_words"]}',f'+I={m["input_words"]}',f'+E={m["expected_words"]}',f'+DW={m["dw_packets"]}']
        r=subprocess.run(cmd,capture_output=True,text=True,timeout=600)
        if r.returncode or r.stderr.strip() or re.search('FATAL|ERROR:',r.stdout):raise RuntimeError(r.stdout[-5000:]+r.stderr[-1000:])
        lines=r.stdout.splitlines()
        frames=[fields(x) for x in lines if x.startswith('C35_ROW_FUSED_GRAPH_FRAME ')]
        faults=[fields(x) for x in lines if x.startswith('C35_ROW_FUSED_GRAPH_FAULT ')]
        resets=[fields(x) for x in lines if x.startswith('C35_ROW_FUSED_GRAPH_RESET_PASS ')]
        if len(frames)!=8 or len(faults)!=4 or {f['fault'] for f in faults}!={13,14,15,16} or any(f['commits']!=18 or f['drained']!=1 for f in faults):raise ValueError('wrong directed fault coverage')
        if len(resets)!=3 or {r['phase'] for r in resets}!={6,7,8} or any(r['restart_golden']!=1 or r['cleared_pages']!=1 for r in resets):raise ValueError('wrong fused reset coverage')
        if any(f['commits']!=22 or f['write_beats']!=m['expected_words']//2 for f in frames):raise ValueError('incomplete recovery frame')
        if lines.count('C35_ROW_FUSED_FAULTS_PASS faults=4 normal_frames=8 fused_resets=3 same_instance_recovery=1 system_reset_only=1 actual_AXI=0 native_fps_claim=0')!=1:raise ValueError('missing suite pass')
        print('C35_ROW_FUSED_FAULTS_EVIDENCE '+json.dumps(dict(faults=faults,resets=resets,correct_frames=len(frames),
            full_DAG=True,actual_AXI=False,native_fps_claim=False,local_CPU_cancel_claim=False),separators=(',',':')),flush=True)
    print('C35_ROW_FUSED_FAULTS_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()
