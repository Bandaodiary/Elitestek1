"""C35 native-width full-DAG paired row-transfer probe; not native FPS."""
import argparse
import json
from pathlib import Path
import tempfile

from run_r2_row_fused_graph_probe import run_case,ROOT,PREFIX
from check_r2_row_fused_graph_evidence import run_gate
from check_r2_row_fused_wide_evidence import resume_cases


def main():
    p=argparse.ArgumentParser();p.add_argument('--small-run',required=True)
    p.add_argument('--temporary-parent',required=True,type=Path)
    p.add_argument('--resume-run');a=p.parse_args()
    run_gate(a.small_run)
    parent=a.temporary_parent.resolve()
    if parent.parent!=ROOT/'sim' or not parent.name.startswith('c1_r2_row_fused_wide_') or not parent.is_dir():raise ValueError('invalid private parent')
    cached=resume_cases(a.resume_run) if a.resume_run else {}
    fresh=0;reused=0
    def obtain(private,profile,h,stalls,enabled):
        nonlocal fresh,reused
        key=(profile,h,stalls,bool(enabled))
        if key in cached:
            result=dict(cached[key]);result['evidence_origin_run']=a.resume_run
            print(PREFIX+'CASE '+json.dumps(result,separators=(',',':')),flush=True)
            reused+=1;return result
        fresh+=1;return run_case(Path(private),profile,640,h,stalls,enabled)
    with tempfile.TemporaryDirectory(prefix='matrix_',dir=parent) as private:
        for profile,h,stalls in [('microstyle24',4,0),('microstyle24',12,1),('drop_res1',12,1)]:
            fused=obtain(private,profile,h,stalls,1)
            plain=obtain(private,profile,h,stalls,0)
            samples=[]
            for f,b in zip(fused['frames'],plain['frames']):
                removed=640*h;extra=72*(h-1)
                if b['write_beats']-f['write_beats']!=removed or b['producer_reads']-f['producer_reads']!=removed or f['read_beats']-b['read_beats']!=extra-removed:raise ValueError('unexpected real fused traffic')
                samples.append(dict(frame=f['frame'],fused_cycles=f['cycles'],unfused_cycles=b['cycles'],
                    cycle_reduction_percent=100*(b['cycles']-f['cycles'])/b['cycles'],
                    removed_write_bytes=removed*16,removed_feature_read_bytes=removed*16,extra_parameter_bytes=extra*16,
                    net_transfer_reduction_bytes=(removed*2-extra)*16))
            print(PREFIX+'WIDE_PAIRED '+json.dumps(dict(profile=profile,width=640,height=h,stalls=stalls,
                samples=samples,actual_AXI=False,native_fps_claim=False),separators=(',',':')),flush=True)
        print(PREFIX+f'WIDE_EXECUTIONS fresh_configurations={fresh} reused_configurations={reused}',flush=True)
        print(PREFIX+'WIDE_SUMMARY configurations=6 correct_frames=12 comparisons=3 actual_AXI=0 native_fps_claim=0',flush=True)
    print(PREFIX+'WIDE_CLEAN temporary_vectors_and_simulator_removed=1',flush=True)


if __name__=='__main__':main()
