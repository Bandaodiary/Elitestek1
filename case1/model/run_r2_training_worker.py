"""Detached same-process training supervision with early-error capture.

Launched by hidden WMI Win32_Process.Create, not a Codex child Windows Job.
This wrapper never starts/stops Vivado, Efinity or any other worker.
"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import runpy
import sys
import time
import traceback

import psutil

from prepare_r2_style_data import outside_job, save_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log-dir', type=Path, required=True)
    parser.add_argument('--script', type=Path, required=True)
    parser.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    script = args.script.resolve()
    if script.parent != Path(__file__).resolve().parent or script.name not in ('train_r2_style_student.py', 'train_r2_style_qat.py', 'train_r2_style_stable_qat.py', 'compare_r2_style_models.py', 'compare_r2_float_candidates.py', 'evaluate_r2_style_distill.py', 'probe_r2_style_stability.py', 'infer_r2_style_artifact.py'):
        raise ValueError('only local C36 training entry points accepted')
    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=False)
    process = psutil.Process()
    detached = outside_job()
    status = dict(state='starting', pid=os.getpid(), process_start=process.create_time(),
                  outside_windows_job=detached, script=str(script), arguments=args.arguments,
                  created_local=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
    save_json(logs/'worker_status.json', status)
    code = 0
    with (logs/'console.log').open('x', encoding='utf-8', buffering=1) as stream:
        with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
            try:
                if detached is not True:
                    raise RuntimeError('WMI training worker is inside a Windows Job')
                arguments = args.arguments[1:] if args.arguments[:1] == ['--'] else args.arguments
                sys.argv = [str(script)] + arguments
                status['state'] = 'running'
                save_json(logs/'worker_status.json', status)
                runpy.run_path(str(script), run_name='__main__')
            except BaseException as exc:
                if isinstance(exc, SystemExit) and exc.code in (None, 0):
                    code = 0
                else:
                    code = 1
                    status['error'] = repr(exc)
                    traceback.print_exc()
    status.update(state='complete' if code == 0 else 'failed', exit_code=code,
                  finished_local=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
    save_json(logs/'worker_status.json', status)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
