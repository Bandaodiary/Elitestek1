"""Bounded OS admission before launching a C39 vendor-seam RTL test."""
import json
import subprocess


def check():
    command = (
        "$ErrorActionPreference='Stop';"
        "[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false);"
        "$p=@(Get-Process -Name efx_map,efx_pnr,efx_sta,xsim,xsimk,xelab,xvlog,vvp,ivl -ErrorAction SilentlyContinue);"
        "$m=[long](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory;"
        "[ordered]@{external_pids=@($p|Select-Object -ExpandProperty Id);free_memory_kib=$m}|ConvertTo-Json -Compress"
    )
    result = subprocess.run(['C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
        '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', command],
        capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=30,
        creationflags=subprocess.CREATE_NO_WINDOW)
    if result.returncode or result.stderr.strip():
        raise RuntimeError('cannot prove seam tool/memory admission: ' + result.stderr[-1000:])
    record = json.loads(result.stdout)
    if record['external_pids'] or record['free_memory_kib'] < 8388608:
        raise RuntimeError('seam admission refused: ' + json.dumps(record))
    print('C39_SEAM_ADMISSION_PASS ' + json.dumps(record, separators=(',', ':')), flush=True)
    return record
