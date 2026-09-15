"""Lightweight C34 dispatch and checker tests. Never launches a hardware tool."""
import ast
import contextlib
import io
import json
import runpy
import sys
from unittest.mock import patch

import run_r2_ring_rgb2_host_probe as candidate
import run_r2_credit_rgb2_host_fault_probe as fault
import check_r2_ring_host_evidence as audit


def main():
    original_sources=candidate.retained.SOURCES
    original_top=candidate.retained.TOP
    original_prefix=candidate.retained.PREFIX
    original_project=candidate.retained.PROJECT
    calls=[]
    def record():
        calls.append(dict(top=candidate.retained.TOP,prefix=candidate.retained.PREFIX,
                          sources=tuple(candidate.retained.SOURCES),argv=tuple(sys.argv)))
    try:
        with patch.object(candidate.retained,'main',record),patch.object(sys,'argv',
            ['run_r2_ring_rgb2_host_probe.py','--paired','--shapes','32x32','--stalls','1','--nn-target','2','--aw-wait-w','2']):
            candidate.main()
        assert len(calls)==2 and calls[0]['top']==original_top and calls[1]['top']==candidate.TOP
        assert calls[0]['sources']==tuple(original_sources) and calls[1]['sources']==tuple(candidate.SOURCES)
        assert calls[0]['argv']==calls[1]['argv'] and '--paired' not in calls[0]['argv']
        assert len(candidate.SOURCES)==len(set(candidate.SOURCES))==46
        # Exactly five source names change: four wrappers and the leaf writer.
        assert len(set(original_sources)-set(candidate.SOURCES))==5
        assert len(set(candidate.SOURCES)-set(original_sources))==5
        with patch.object(candidate.retained,'main',record),patch.object(sys,'argv',['probe','--compile-only']):
            try:candidate.main()
            except ValueError:pass
            else:raise AssertionError('wrong compile-only top accepted')
        assert len(calls)==2,'compile-only dispatched an old top'
    finally:
        candidate.retained.SOURCES=original_sources;candidate.retained.TOP=original_top
        candidate.retained.PREFIX=original_prefix;candidate.retained.PROJECT=original_project
    with patch.object(fault,'main',lambda: calls.append(dict(fault_top=fault.TOP,sources=tuple(fault.SOURCES)))),\
         patch.object(fault,'SOURCES',fault.SOURCES),patch.object(fault,'TOP',fault.TOP),patch.object(fault,'PREFIX',fault.PREFIX):
        runpy.run_module('run_r2_ring_rgb2_host_fault_probe',run_name='__main__')
    assert calls[-1]['fault_top']=='tb_c1_r2_ring_rgb2_host_faults' and calls[-1]['sources']==tuple(candidate.SOURCES)
    for name in ('check_r2_ring_write_evidence.py','check_r2_ring_host_evidence.py',
                 'run_r2_ring_rgb2_host_probe.py','run_r2_ring_rgb2_host_fault_probe.py'):
        path=candidate.ROOT/'golden'/name;ast.parse(path.read_text(encoding='utf-8-sig'),filename=str(path))
    with contextlib.redirect_stdout(io.StringIO()):audit.source_gate()
    # Feed renamed real C33 records only to the pure parser, never to the
    # run-identity/physical-resource gate. This is a parser test, NOT C34 data.
    text=(candidate.ROOT/'logs/r2_credit_rgb2_regression_runs/c33_credit_host_smoke_20260914_a/result.log').read_text(encoding='utf-8-sig')
    text=text.replace(audit.credit.PREFIX,audit.PREFIX)
    result=audit.baseline.run(text,prefix=audit.PREFIX,expected_nn=2)
    assert result['cnn_frames']==2
    corrupted=text.replace('source_backpressure_allowed=0','source_backpressure_allowed=1')
    assert corrupted!=text
    try:audit.baseline.run(corrupted,prefix=audit.PREFIX,expected_nn=2)
    except (AssertionError,ValueError,KeyError):pass
    else:raise AssertionError('invalid source contract accepted')
    hierarchy=(candidate.ROOT/'logs/efinity_resource_runs/c33_credit_rgb2_host96_pnr_20260914_a/pnr_before_cdc_hier_util.rpt').read_text(encoding='utf-8-sig')
    assert audit.writer_footprint(hierarchy)==dict(xlr=2757.0,ram=32,dsp=0)
    bad=hierarchy.replace('+u_writer ','+WRITER_MISSING ')
    assert bad!=hierarchy
    try:audit.writer_footprint(bad)
    except AssertionError:pass
    else:raise AssertionError('missing writer hierarchy accepted')
    print('C34_HOST_PREFLIGHT_PASS '+json.dumps(dict(source_count=46,changed_production_names=5,
        paired_same_arguments=True,fault_dispatch_correct=True,rejected_wrong_compile_top=True,
        parser_control_rejected=True,retained_C33_writer_ram=32,missing_writer_hierarchy_rejected=True,
        RTL_compiled=False,RTL_simulated=False,FPGA_resource_measured=False),separators=(',',':')))


if __name__=='__main__':main()
