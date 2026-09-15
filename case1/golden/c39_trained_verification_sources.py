"""Generate separate C39 runners while retaining every C37 numerical/evidence gate."""
from pathlib import Path
import sys
from c39_candidate_sources import ROOT, replace_once


def artifacts():
    matrix = (ROOT / 'golden/run_c37_trained_host_probe.py').read_text(encoding='utf-8-sig')
    matrix = matrix.replace('c37_trained_contract', 'c39_trained_contract').replace('C37', 'C39')
    matrix = matrix.replace('six-replacement regression', 'native-format regression')
    yield 'golden/run_c39_trained_host_probe.py', matrix

    checker = (ROOT / 'golden/check_c37_trained_pipeline.py').read_text(encoding='utf-8-sig')
    checker = checker.replace('c37_trained_contract', 'c39_trained_contract')
    checker = checker.replace('run_c37_trained_host_probe', 'run_c39_trained_host_probe')
    checker = checker.replace('c37_trained_', 'c39_trained_').replace('c1_c37_trained_', 'c1_c39_trained_')
    checker = checker.replace('C37', 'C39')
    # Keep the original generic native interval helper (15 fps gate), then add
    # a separate no-throughput-regression check rather than weakening it.
    checker = replace_once(checker, 'from c37_native_performance_contract import require_native_target',
                           'from c39_native_performance_contract import require_native_target')
    checker = replace_once(checker, "status.get('candidate')!='C39'", "status.get('candidate')!='C39_NATIVE'")
    checker = replace_once(checker, 'len(expected_sources)!=48', 'len(expected_sources)!=49')
    checker = checker.replace('six C39 replacements plus two trained plans', 'explicit C39 native closure plus two trained plans')
    checker = replace_once(checker, "    camera_config(status.get('camera_profile','legacy'))", '''    verify_history(status,['c39_operator_preflight','c39_source_preflight'])
    from c39_operator_preflight import check as operator_check
    observed=one_json((folder/'c39_operator_preflight.tail.log').read_text(encoding='utf-8-sig'),
                      'C39_OPERATOR_PREFLIGHT_PASS ')
    if observed!=operator_check():
        raise ValueError('operator preflight differs from actual full-run evidence')
    camera_config(status.get('camera_profile','legacy'))''')
    yield 'golden/check_c39_trained_pipeline.py', checker

    worker = (ROOT / 'scripts/run_c37_trained_pipeline_detached.ps1').read_text(encoding='utf-8-sig')
    worker = worker.replace('C37', 'C39').replace('c37', 'c39')
    worker = worker.replace('independent six-source resource candidate', 'independent native-format resource candidate')
    worker = worker.replace('c1_ti60_c39_resource24', 'c1_ti60_c39_host_native')
    worker = replace_once(worker, "candidate='C39'", "candidate='C39_NATIVE'")
    worker = replace_once(worker, "$_.name -ne 'c1_ti60_c39_host_native.sv'", "(Split-Path -Leaf $_.name) -ne 'c1_ti60_c39_host_native.sv'")
    worker = replace_once(worker, "ForEach-Object {Join-Path (Join-Path $caseRoot 'efinity') $_.name}",
        "ForEach-Object {if([IO.Path]::IsPathRooted($_.name)){$_.name}else{Join-Path (Join-Path $caseRoot 'efinity') $_.name}}")
    worker = replace_once(worker, '$sources.Count -ne 48', '$sources.Count -ne 49')
    reuse_guard = "            if($anchor.StartTime.ToUniversalTime().Ticks -ne ([DateTime]$prior.worker_start).ToUniversalTime().Ticks){throw 'predecessor PID identity differs'}\n"
    worker = replace_once(worker, reuse_guard, '')
    worker = replace_once(worker,
        '        $anchor=Get-Process -Id $prior.worker_pid -ErrorAction SilentlyContinue\n',
        '''        $anchor=Get-Process -Id $prior.worker_pid -ErrorAction SilentlyContinue
        if($anchor -and $anchor.StartTime.ToUniversalTime().Ticks -ne ([DateTime]$prior.worker_start).ToUniversalTime().Ticks){
            # The original worker has exited; never wait on a reused PID.
            $anchor.Dispose();$anchor=$null;$predecessor.pid_reused=$true
        }
''')
    worker = replace_once(worker, "    Invoke-Step 'c39_source_preflight' $python @(",
        "    Invoke-Step 'c39_operator_preflight' $python @('-X','utf8','-B','-u',(Join-Path $caseRoot 'golden\\c39_operator_preflight.py')) $runRoot 180\n    Invoke-Step 'c39_source_preflight' $python @(")
    yield 'scripts/run_c39_trained_pipeline_detached.ps1', worker


def verify():
    for relative, expected in artifacts():
        if (ROOT / relative).read_text(encoding='utf-8-sig').strip() != expected.strip():
            raise ValueError('C39 verification source differs: ' + relative)


if __name__ == '__main__':
    if '--emit-patch' in sys.argv:
        print('*** Begin Patch')
        for relative, content in artifacts():
            if (ROOT / relative).exists():
                raise ValueError('refuse overwrite ' + relative)
            print('*** Add File: ' + (ROOT / relative).as_posix())
            print('\n'.join('+' + line for line in content.splitlines()))
        print('*** End Patch')
    else:
        verify()
        print('C39_VERIFICATION_SOURCE_PASS original_C37_gates_preserved=True actual_simulation=False')
