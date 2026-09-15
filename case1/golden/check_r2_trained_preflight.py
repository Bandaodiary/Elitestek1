"""Admit C36 after terminal C35, without concealing C35's missing launch record.

C35's strict native gate remains unchanged and fails if its actual xsim launch
line was lost. That archival defect does not prevent an independent C36 run.
The old native numbers below are diagnostic, not a replacement signoff gate.
"""
import json

from check_r2_fused_xsim_evidence import ROOT, baseline, run_gate, configuration, check_text
from r2_native_performance_contract import assess_intervals


def main():
    # Independently retained small run still proves the full old strict gate.
    run_gate('c35_fused_xsim_smoke_20260915_a')
    run = 'c35_fused_native_sixframe_20260915_a'
    strict = True
    gap = None
    try:
        run_gate(run)
    except ValueError as exc:
        if str(exc) != 'actual DW checker plusarg not proven':
            raise
        strict = False
        gap = str(exc)
    # The strict gate already checked exact recovery provenance and terminal
    # status before reaching the missing-command check. Do not invent a line.
    folder = ROOT / 'logs/r2_fused_rgb2_host_xsim_runs' / run
    status, text = baseline.finished(folder)
    meta = json.loads((folder / 'metadata.json').read_text(encoding='utf-8-sig'))
    model = configuration((folder / 'xelab.tail.log').read_text(encoding='utf-8-sig'), status, meta)
    result = check_text(text, profile='microstyle24', nn=6)
    performance = assess_intervals(result['completion_intervals'])
    print('C36_TRAINED_PREFLIGHT_PASS ' + json.dumps(dict(
        predecessor=run, predecessor_terminal=True, predecessor_strict_gate_passed=strict,
        predecessor_evidence_gap=gap, old_native_host_diagnostic=result,
        old_native_performance_diagnostic=performance, ddr_model=model,
        new_model_RTL_simulated=False, native_signoff_claim=False), separators=(',', ':')))


if __name__ == '__main__':
    main()
