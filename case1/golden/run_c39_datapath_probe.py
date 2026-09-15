"""Apply unchanged C37 leaf test gates to the explicit C39 source closure."""
import argparse
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
import run_c37_leaf_probe as baseline_gate
from c39_candidate_sources import ROOT, REPLACEMENTS, sources


def stream_execute(command, folder, timeout):
    """Keep bounded progress visible without writing waves or a large raw log."""
    command = list(map(str, command))
    # The installed vvp -h documents -i as unbuffered stdio. No HDL semantics change.
    if Path(command[0]).name.lower() == 'vvp.exe':
        command.insert(1, '-i')
    began = time.monotonic()
    process = subprocess.Popen(command, cwd=folder, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, errors='replace')
    messages = queue.Queue()
    lines = []
    latest = 'no completed job yet'
    next_progress = began + 30

    def read_lines():
        try:
            for line in process.stdout:
                messages.put(line)
        finally:
            messages.put(None)

    reader = threading.Thread(target=read_lines, daemon=True)
    reader.start()
    print(f'C39_VVP_BEGIN pid={process.pid} wall_timeout_seconds={timeout}', flush=True)
    try:
        while True:
            now = time.monotonic()
            if now - began > timeout:
                raise TimeoutError(f'C39 wall timeout after {timeout}s; last_progress={latest}')
            try:
                line = messages.get(timeout=min(.25, timeout - (now - began)))
            except queue.Empty:
                line = ''
            if line is None:
                break
            if line:
                lines.append(line)
                if line.startswith('C37_OPERATOR_JOB '):
                    latest = line.strip()
            if now >= next_progress:
                print(f'C39_VVP_PROGRESS elapsed_seconds={int(now-began)} {latest}', flush=True)
                next_progress = now + 30
        code = process.wait(timeout=max(.1, timeout - (time.monotonic() - began)))
        print(f'C39_VVP_EXIT pid={process.pid} exit_code={code} elapsed_seconds={time.monotonic()-began:.3f}', flush=True)
        return code, ''.join(lines)
    finally:
        # Only this invocation's owned child is terminated on its explicit timeout.
        if process.poll() is None:
            process.kill()
        process.wait()
        reader.join(timeout=5)
        process.stdout.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--phase', choices=('compile', 'window', 'capacity', 'shadow', 'fallback', 'requant'), required=True)
    parser.add_argument('--fallback-timeout', type=int, default=900,
                        help='Per-vvp wall limit only; preserves RTL watchdog and all coverage checks')
    args = parser.parse_args()
    if not 900 <= args.fallback_timeout <= 3600:
        raise ValueError('fallback wall timeout must be 900..3600 seconds')
    if args.phase == 'requant':
        from run_c39_requant_probe import main as requant_main
        requant_main()
        print('C39_DATAPATH_PHASE_PASS phase=requant actual_candidate_sources=1 temporary_removed=1 waves=0', flush=True)
        return
    baseline_gate.budget()
    baseline_compile = baseline_gate.compile_test
    original_execute = baseline_gate.execute
    if args.phase == 'fallback':
        def observable_execute(command, folder, timeout=90):
            if Path(str(command[0])).name.lower() == 'vvp.exe':
                return stream_execute(command, folder, args.fallback_timeout)
            return original_execute(command, folder, timeout)
        baseline_gate.execute = observable_execute

    def compile_candidate(folder, top, source_list, options=()):
        mapped = []
        for file in source_list:
            path = Path(file)
            relative = path.relative_to(ROOT).as_posix()
            mapped.append(ROOT / REPLACEMENTS.get(relative, relative))
        return baseline_compile(folder, top, mapped, options)

    baseline_gate.compile_test = compile_candidate
    baseline_gate.sources = sources
    with tempfile.TemporaryDirectory(prefix='c39_datapath_', dir=ROOT / 'sim') as private:
        folder = Path(private)
        if args.phase == 'compile':
            compile_candidate(folder, 'c1_r2_fused_rgb2_host_system', sources())
            print('C39_FULL_HOST_ELABORATION_PASS sources=49', flush=True)
        else:
            getattr(baseline_gate, args.phase)(folder)
    print(f'C39_DATAPATH_PHASE_PASS phase={args.phase} actual_candidate_sources=1 temporary_removed=1 waves=0', flush=True)


if __name__ == '__main__':
    main()
