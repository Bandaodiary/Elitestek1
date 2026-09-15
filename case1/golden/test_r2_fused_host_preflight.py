"""Small fixture/source checks only; intentionally no FPGA compiler/simulator."""
import ast
from pathlib import Path
import tempfile

from check_r2_fused_host_source import ROOT,source_gate
from r2_fused_camera_vectors import vectors


def main():
    source_gate()
    for name in ('r2_fused_camera_vectors.py','run_r2_fused_rgb2_host_probe.py','check_r2_fused_fault_evidence.py'):
        ast.parse((ROOT/'golden'/name).read_text(encoding='utf-8-sig'))
    with tempfile.TemporaryDirectory(prefix='c1_r2_fused_host_preflight_',dir=ROOT/'sim') as private:
        for profile in ('microstyle24','drop_res1'):
            folder=Path(private)/profile;folder.mkdir()
            m=vectors(folder,8,8,profile)
            assert m['dw_packets']==384 and m['dw_stage']+1==m['pw_stage']
            assert m['stage_count']==(22 if profile=='microstyle24' else 18)
            expected=[int(x,16) for x in (folder/'expected.mem').read_text().splitlines()]
            assert len(expected)==m['expected_words'] and all(x>>160!=m['dw_stage'] for x in expected)
            assert sum(x>>160==m['pw_stage'] for x in expected)==64
            assert len((folder/'dw_expected.mem').read_text().splitlines())==384
            # Two poison-tail lanes remain deliberately nonzero; the RTL
            # checker must mask only those lanes and still compare all tags.
            words=[int(x,16) for x in (folder/'dw_expected.mem').read_text().splitlines()]
            assert (words[2]>>48)&63==15 and (words[2]>>32)&65535==0xa5a5
    print('C35_FUSED_HOST_PREFLIGHT_PASS profiles=2 fixture_shapes=8x8 real_resize_golden=1 DW_checker_only=1 RTL_compiled=0 RTL_simulated=0 temporary_removed=1')


if __name__=='__main__':main()
