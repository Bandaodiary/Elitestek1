"""Read bounded vvp metadata, never the multi-MB compiled simulation body."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from c39_native_sources import ROOT, verify

EXPECTED = (
    'rtl/c39_direct/c1_r2_cnn_row_shadow_engine.sv',
    'rtl/c39_native/c1_r2_spatial_partitioned_feeder.sv',
    'rtl/c39/c1_r2_partitioned_window_store.sv',
    'rtl/c39/c37_compute6_indexed.sv',
    'rtl/c39/c39_requant_bank8_narrow.sv',
    'rtl/c39/c39_operand_codec.sv',
)


def metadata(path, stalls, expected_sources=EXPECTED):
    with path.open('rb') as stream:
        head = stream.read(65536).decode('utf-8', errors='replace')
        stream.seek(max(0, path.stat().st_size-65536))
        tail = stream.read(65536).decode('utf-8', errors='replace')
    tables = list(re.finditer(r'^:file_names (\d+);\s*$', tail, re.M))
    if len(tables) != 1:
        raise ValueError('missing/duplicate terminal source table')
    marker = tables[0]
    names = re.findall(r'^\s*"([^"]+)";\s*$', tail[marker.end():], re.M)
    if len(names) != int(marker[1]):
        raise ValueError('truncated source table')
    paths = [Path(name.replace('\\\\', '\\')).resolve() for name in names if name.endswith('.sv')]
    for relative in expected_sources:
        expected = (ROOT / relative).resolve()
        same_name = [path for path in paths if path.name == expected.name]
        if same_name != [expected]:
            raise ValueError('wrong/duplicate compiled candidate source: ' + relative)
    old_quant = [path for path in paths if path.name == 'c1_requant_bank8_compact.sv']
    if old_quant:
        raise ValueError('old requantizer is in compiled snapshot')
    values = re.findall(r'\.param/l "STALLS"[^\r\n]*\+C4<([01]+)>;', head)
    if not values or int(values[0], 2) != stalls:
        raise ValueError('actual snapshot STALLS parameter differs')
    return dict(snapshot=str(path), bytes=path.stat().st_size, stalls=stalls,
                active_source_table_entries=len(names), active_sv_sources=list(map(str, paths)),
                required_native_sources_verified=list(expected_sources), metadata_read_limit_bytes=131072)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', required=True)
    parser.add_argument('--private', type=Path, required=True)
    parser.add_argument('--vvp-pid', type=int, required=True)
    parser.add_argument('--emit-patch', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch('[A-Za-z0-9_-]+', args.run):
        raise ValueError('invalid run name')
    private = args.private.resolve()
    if not private.is_relative_to((ROOT / 'sim').resolve()) or not private.name.startswith('c39_datapath_'):
        raise ValueError('not a private C39 simulation directory')
    log = ROOT / 'logs/c39_datapath_runs' / args.run
    status = json.loads((log / 'status.json').read_text(encoding='utf-8-sig'))
    if status['variant'] != 'native' or status['state'] != 'running':
        raise ValueError('expected original live native run')
    verify()
    command = (f'$p=Get-CimInstance Win32_Process -Filter "ProcessId={args.vvp_pid}";'
               'if(-not $p){exit 2};$p|Select-Object ProcessId,ParentProcessId,'
               '@{n="started";e={$_.CreationDate.ToString("o")}},CommandLine|ConvertTo-Json -Compress')
    process = subprocess.run(['C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
        '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', command], capture_output=True,
        text=True, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
    if process.returncode or process.stderr.strip():
        raise ValueError('cannot inspect original live vvp')
    running = json.loads(process.stdout)
    expected_command = subprocess.list2cmdline(['D:/iverilog/bin/vvp.exe', '-i',
        str(private / 'tb_c37_operator_fallback_1.vvp'),
        '+INPUTS=' + private.as_posix() + '/fallback/bulk.mem',
        '+OUTPUTS=' + private.as_posix() + '/fallback/reference/output.mem',
        '+N=150731', '+M=167635', '+J=187'])
    if running['ParentProcessId'] != status['child_pid'] or running['CommandLine'] != expected_command:
        raise ValueError('actual process parent/snapshot/fixtures differ')
    records = [metadata(private / f'tb_c37_operator_fallback_{stalls}.vvp', stalls) for stalls in (0, 1)]
    report = dict(marker='C39_NATIVE_ACTUAL_VVP_SOURCE_AUDIT_PASS', run=args.run,
                  worker_pid=status['worker_pid'], worker_start=status['worker_start'],
                  python_pid=status['child_pid'], python_start=status['child_start'],
                  actual_running_vvp=running, snapshots=records,
                  entire_regression_complete=False, hashes_used=False, waveform_read=False)
    content = json.dumps(report, indent=2) + '\n'
    if args.emit_patch:
        target = log / 'actual_compiled_sources.json'
        if target.exists():
            raise ValueError('refuse overwrite original compile audit')
        print('*** Begin Patch\n*** Add File: ' + target.as_posix())
        print('\n'.join('+' + line for line in content.splitlines()))
        print('*** End Patch')
    else:
        print(content)


if __name__ == '__main__':
    main()
